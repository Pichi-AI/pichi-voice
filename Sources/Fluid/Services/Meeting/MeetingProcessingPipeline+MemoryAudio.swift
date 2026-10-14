@preconcurrency import AVFoundation
import CoreMedia
import Foundation

extension MeetingProcessingPipeline {
    /// PCM input is another input capability of the existing pipeline, not another meeting
    /// coordinator or model installer. Selection, residency, canonical assembly and storage are
    /// owned by the injected operations that the pipeline freezes before capture starts.
    nonisolated static func makeMemoryAudioConsumer(
        chunkSeconds: Double = 12,
        maximumPendingSeconds: Double = 24,
        initialChunkSeconds: Double? = nil,
        recognize: @escaping @Sendable ([Float], TimeInterval) async throws -> MeetingPCMTranscriptBatch,
        checkpoint: @escaping @Sendable (MeetingPCMTranscriptBatch) async throws -> Void,
        finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)? = nil,
        diagnostic: @escaping @Sendable (String) -> Void = { DebugLogger.shared.info($0, source: "MeetingMemoryAudio") },
        failure: @escaping @Sendable (Error) -> Void
    ) throws -> any MeetingMemoryAudioConsuming {
        try MeetingPipelineMemoryAudioConsumer(chunkSeconds: chunkSeconds,
                                              maximumPendingSeconds: maximumPendingSeconds,
                                              initialChunkSeconds: initialChunkSeconds,
                                              recognition: .sealed(recognize), checkpoint: checkpoint, finalize: finalize, diagnostic: diagnostic, failure: failure)
    }

    /// The same bounded transport can start one recognizer while an attribution window is
    /// still growing. The recognizer owns its accumulator and joins each inference before
    /// appending the next delta. No accepted frames leave the pending budget until it and its checkpoint return.
    nonisolated static func makeProgressiveMemoryAudioConsumer(
        chunkSeconds: Double = 12,
        maximumPendingSeconds: Double = 24,
        initialPreviewSeconds: Double = 3,
        previewIntervalSeconds: Double = 3,
        recognize: @escaping @Sendable (MeetingPCMProgressiveWindow, TimeInterval) async throws -> MeetingPCMTranscriptBatch,
        checkpoint: @escaping @Sendable (MeetingPCMTranscriptBatch) async throws -> Void,
        finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)? = nil,
        diagnostic: @escaping @Sendable (String) -> Void = { DebugLogger.shared.info($0, source: "MeetingMemoryAudio") },
        failure: @escaping @Sendable (Error) -> Void
    ) throws -> any MeetingMemoryAudioConsuming {
        try MeetingPipelineMemoryAudioConsumer(chunkSeconds: chunkSeconds,
                                              maximumPendingSeconds: maximumPendingSeconds,
                                              initialChunkSeconds: initialPreviewSeconds,
                                              recognition: .progressive(intervalSeconds: previewIntervalSeconds, recognize),
                                              checkpoint: checkpoint, finalize: finalize, diagnostic: diagnostic, failure: failure)
    }

}

nonisolated enum MeetingMemoryAudioError: LocalizedError, Equatable {
    case invalidBudget
    case invalidPCM
    case overload
    case timelineDiscontinuity

    var errorDescription: String? {
        switch self {
        case .invalidBudget: return PichiLocalization.text("The in-memory audio budget is invalid.")
        case .invalidPCM: return PichiLocalization.text("In-memory transcription requires finite mono 16 kHz PCM.")
        case .overload: return PichiLocalization.text("In-memory transcription could not keep up. Recording stopped and completed text was preserved.")
        case .timelineDiscontinuity: return PichiLocalization.text("The in-memory microphone timeline changed. Completed text was preserved.")
        }
    }
}

/// Ownership of the delta moves to the single worker. `totalFrames` describes the growing
/// window, not the delta length. A final empty delta seals a previously delivered prefix.
nonisolated struct MeetingPCMWindowUpdate: Sendable {
    let samples: [Float]
    let totalFrames: Int
    let isFinal: Bool
}

/// A single growing PCM window, used only underneath the existing memory transport. It holds
/// newly accepted deltas while inference owns an immutable prefix. `next` coalesces every
/// available delta and transfers its array storage; it never copies the full prior prefix.
nonisolated final class MeetingPCMProgressiveWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let initialFrames: Int
    private let intervalFrames: Int
    private var pending: [Float] = []
    private var acceptedFrames = 0
    private var deliveredAny = false
    private var sealed = false
    private var deliveredFinal = false
    private var terminalError: Error?
    private var waiter: CheckedContinuation<MeetingPCMWindowUpdate?, Error>?

    fileprivate init(initialFrames: Int, intervalFrames: Int) {
        self.initialFrames = initialFrames
        self.intervalFrames = intervalFrames
    }

    /// Call sequentially, after the prior inference has joined. Cancellation closes this window
    /// and wakes its sole waiter; the existing consumer then joins the recognizer on failure.
    func next() async throws -> MeetingPCMWindowUpdate? {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let result = self.lock.withLock { () -> Result<MeetingPCMWindowUpdate?, Error>? in
                    if let result = self.takeUpdateLocked() { return result }
                    guard self.waiter == nil else { return .failure(MeetingMemoryAudioError.invalidPCM) }
                    self.waiter = continuation
                    return nil
                }
                if let result { continuation.resume(with: result) }
            }
        } onCancel: {
            self.cancel(CancellationError())
        }
    }

    fileprivate var totalFrames: Int { self.lock.withLock { self.acceptedFrames } }
    fileprivate var consumedFinal: Bool { self.lock.withLock { self.deliveredFinal } }

    fileprivate func append(_ samples: UnsafeBufferPointer<Float>, isFinal: Bool) {
        let delivery = self.lock.withLock { () -> (CheckedContinuation<MeetingPCMWindowUpdate?, Error>, Result<MeetingPCMWindowUpdate?, Error>)? in
            guard !self.sealed, self.terminalError == nil else { return nil }
            self.pending.append(contentsOf: samples)
            self.acceptedFrames += samples.count
            self.sealed = isFinal
            return self.takeWaitingDeliveryLocked()
        }
        if let (continuation, result) = delivery { continuation.resume(with: result) }
    }

    fileprivate func seal() {
        let delivery = self.lock.withLock { () -> (CheckedContinuation<MeetingPCMWindowUpdate?, Error>, Result<MeetingPCMWindowUpdate?, Error>)? in
            self.sealed = true
            return self.takeWaitingDeliveryLocked()
        }
        if let (continuation, result) = delivery { continuation.resume(with: result) }
    }

    fileprivate func cancel(_ error: Error) {
        let continuation = self.lock.withLock { () -> CheckedContinuation<MeetingPCMWindowUpdate?, Error>? in
            guard self.terminalError == nil else { return nil }
            self.terminalError = error
            self.pending = []
            let continuation = self.waiter
            self.waiter = nil
            return continuation
        }
        continuation?.resume(throwing: error)
    }

    // Caller holds the window lock. Resetting the array transfers ownership without retaining
    // its storage here, so later microphone callbacks cannot mutate an inference prefix.
    private func takeUpdateLocked() -> Result<MeetingPCMWindowUpdate?, Error>? {
        if let terminalError { return .failure(terminalError) }
        if self.deliveredFinal { return .success(nil) }
        let threshold = self.deliveredAny ? self.intervalFrames : self.initialFrames
        guard self.sealed || self.pending.count >= threshold else { return nil }
        let update = MeetingPCMWindowUpdate(samples: self.pending, totalFrames: self.acceptedFrames, isFinal: self.sealed)
        self.pending = []
        self.deliveredAny = true
        self.deliveredFinal = self.sealed
        return .success(update)
    }

    private func takeWaitingDeliveryLocked() -> (CheckedContinuation<MeetingPCMWindowUpdate?, Error>, Result<MeetingPCMWindowUpdate?, Error>)? {
        guard let waiter, let result = self.takeUpdateLocked() else { return nil }
        self.waiter = nil
        return (waiter, result)
    }
}

/// Bounded PCM transport underneath MeetingProcessingPipeline. The budget includes the input
/// tail, queued jobs AND in-flight recognition/checkpoint work. There is no audio file operation,
/// path, materializer or provider-selection switch anywhere in this consumer.
private final nonisolated class MeetingPipelineMemoryAudioConsumer: MeetingMemoryAudioConsuming, @unchecked Sendable {
    fileprivate enum Recognition: Sendable {
        case sealed(@Sendable ([Float], TimeInterval) async throws -> MeetingPCMTranscriptBatch)
        case progressive(intervalSeconds: Double, @Sendable (MeetingPCMProgressiveWindow, TimeInterval) async throws -> MeetingPCMTranscriptBatch)
    }

    private enum Job: Sendable {
        case sealed([Float], TimeInterval)
        case progressive(MeetingPCMProgressiveWindow, TimeInterval)

        var start: TimeInterval {
            switch self { case .sealed(_, let start), .progressive(_, let start): return start }
        }
        var frameCount: Int {
            switch self { case .sealed(let samples, _): return samples.count
            case .progressive(let window, _): return window.totalFrames }
        }
        var progressiveWindow: MeetingPCMProgressiveWindow? {
            if case .progressive(let window, _) = self { return window }
            return nil
        }
    }

    private let lock = NSLock()
    private let chunkFrames: Int
    private let initialChunkFrames: Int
    private var emittedInitialWindow = false
    private let maximumPendingFrames: Int
    private let recognition: Recognition
    private let previewIntervalFrames: Int?
    private var openProgressiveWindow: MeetingPCMProgressiveWindow?
    private var openProgressiveStart: TimeInterval = 0
    private var openProgressiveScheduled = false
    private var activeProgressiveWindow: MeetingPCMProgressiveWindow?
    private let checkpoint: @Sendable (MeetingPCMTranscriptBatch) async throws -> Void
    private let finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)?
    private let failure: @Sendable (Error) -> Void
    private let diagnostic: @Sendable (String) -> Void
    private var accepting = true
    private var terminalError: Error?
    private var tail: [Float] = []
    private var tailStart: TimeInterval = 0
    private var jobs: [Job] = []
    private var pendingFrames = 0
    private var origin: CMTime?
    private var expectedPTS: CMTime?
    private var worker: Task<Void, Never>?
    private var finishTask: Task<Void, Error>?

    init(chunkSeconds: Double, maximumPendingSeconds: Double, initialChunkSeconds: Double?,
         recognition: Recognition,
         checkpoint: @escaping @Sendable (MeetingPCMTranscriptBatch) async throws -> Void,
         finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)?,
         diagnostic: @escaping @Sendable (String) -> Void,
         failure: @escaping @Sendable (Error) -> Void) throws {
        guard chunkSeconds.isFinite, maximumPendingSeconds.isFinite,
              chunkSeconds >= 0.25, chunkSeconds <= 30,
              maximumPendingSeconds >= chunkSeconds, maximumPendingSeconds <= 120 else {
            throw MeetingMemoryAudioError.invalidBudget
        }
        let initial = initialChunkSeconds ?? chunkSeconds
        guard initial.isFinite, initial >= 0.25, initial <= chunkSeconds else {
            throw MeetingMemoryAudioError.invalidBudget
        }
        self.chunkFrames = Int((chunkSeconds * 16_000).rounded())
        self.initialChunkFrames = Int((initial * 16_000).rounded())
        self.maximumPendingFrames = Int((maximumPendingSeconds * 16_000).rounded())
        self.recognition = recognition
        switch recognition {
        case .sealed: self.previewIntervalFrames = nil
        case .progressive(let interval, _):
            guard interval.isFinite, interval >= 0.25, interval <= chunkSeconds else {
                throw MeetingMemoryAudioError.invalidBudget
            }
            self.previewIntervalFrames = Int((interval * 16_000).rounded())
        }
        self.checkpoint = checkpoint
        self.finalize = finalize
        self.failure = failure
        self.diagnostic = diagnostic
        if self.previewIntervalFrames == nil { self.tail.reserveCapacity(self.chunkFrames) }
    }

    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        var rejected: Error?
        let accepted = self.lock.withLock { () -> Bool in
            guard self.accepting, self.terminalError == nil else { return false }
            let frameCount = CMSampleBufferGetNumSamples(sampleBuffer)
            guard frameCount > 0, frameCount <= 65_536,
                  frameCount <= self.maximumPendingFrames - self.pendingFrames else {
                rejected = frameCount > 0 ? MeetingMemoryAudioError.overload : MeetingMemoryAudioError.invalidPCM
                return false
            }
            guard CMSampleBufferIsValid(sampleBuffer), CMSampleBufferDataIsReady(sampleBuffer),
                  let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                  let contract = try? MeetingPCMFormatContract(formatDescription: description),
                  contract.sampleRate == 16_000, contract.channelCount == 1,
                  let copied = MeetingLiveSampleCopy.copy(sampleBuffer),
                  let data = copied.buffer.floatChannelData?[0] else {
                rejected = MeetingMemoryAudioError.invalidPCM
                return false
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            guard pts.isNumeric, pts >= .zero else {
                rejected = MeetingMemoryAudioError.invalidPCM
                return false
            }
            if let expectedPTS, abs(CMTimeGetSeconds(pts - expectedPTS)) > 1.0 / 16_000 {
                rejected = MeetingMemoryAudioError.timelineDiscontinuity
                return false
            }
            if self.origin == nil { self.origin = pts }
            let start = CMTimeGetSeconds(pts - (self.origin ?? pts))
            guard (0..<frameCount).allSatisfy({ data[$0].isFinite }) else {
                rejected = MeetingMemoryAudioError.invalidPCM
                return false
            }
            self.expectedPTS = pts + CMTime(value: Int64(frameCount), timescale: 16_000)
            self.pendingFrames += frameCount
            var position = 0
            while position < frameCount {
                if let intervalFrames = self.previewIntervalFrames {
                    if self.openProgressiveWindow == nil {
                        self.openProgressiveWindow = MeetingPCMProgressiveWindow(initialFrames: self.initialChunkFrames,
                                                                                 intervalFrames: intervalFrames)
                        self.openProgressiveStart = start + Double(position) / 16_000
                        self.openProgressiveScheduled = false
                    }
                    let window = self.openProgressiveWindow!
                    let priorFrames = window.totalFrames
                    let count = min(self.chunkFrames - priorFrames, frameCount - position)
                    let isFinal = priorFrames + count == self.chunkFrames
                    window.append(UnsafeBufferPointer(start: data.advanced(by: position), count: count), isFinal: isFinal)
                    position += count
                    if !self.openProgressiveScheduled, window.totalFrames >= self.initialChunkFrames {
                        self.jobs.append(.progressive(window, self.openProgressiveStart))
                        self.openProgressiveScheduled = true
                    }
                    if isFinal { self.openProgressiveWindow = nil }
                } else {
                    let windowFrames = self.emittedInitialWindow ? self.chunkFrames : self.initialChunkFrames
                    if self.tail.isEmpty { self.tailStart = start + Double(position) / 16_000 }
                    let count = min(windowFrames - self.tail.count, frameCount - position)
                    self.tail.append(contentsOf: UnsafeBufferPointer(start: data.advanced(by: position), count: count))
                    position += count
                    if self.tail.count == windowFrames {
                        self.jobs.append(.sealed(self.tail, self.tailStart))
                        self.emittedInitialWindow = true
                        self.tail = []
                        self.tail.reserveCapacity(self.chunkFrames)
                    }
                }
            }
            self.startWorkerIfNeededLocked()
            return true
        }
        if let rejected { self.fail(rejected) }
        return accepted
    }

    /// Closing is synchronous, then the finite tail and already accepted work are joined. A
    /// cancelled caller cannot release model residency while this consumer still owns inference.
    func finish() async throws {
        let task = self.lock.withLock { () -> Task<Void, Error> in
            if let finishTask { return finishTask }
            self.accepting = false
            if !self.tail.isEmpty, self.terminalError == nil {
                self.jobs.append(.sealed(self.tail, self.tailStart))
                self.tail = []
            }
            if let window = self.openProgressiveWindow, self.terminalError == nil {
                window.seal()
                if !self.openProgressiveScheduled { self.jobs.append(.progressive(window, self.openProgressiveStart)) }
                self.openProgressiveWindow = nil
            }
            self.startWorkerIfNeededLocked()
            let worker = self.worker
            let task = Task { [self] in
                // Caller cancellation cannot abandon already owned recognition or privacy tails.
                await worker?.value
                let priorError = self.lock.withLock { self.terminalError }
                do {
                    if let finalize, var batch = try await finalize() {
                        if priorError != nil { batch.isComplete = false }
                        if !batch.segments.isEmpty || !batch.speakers.isEmpty { try await self.checkpoint(batch) }
                    }
                } catch {
                    self.fail(error)
                    throw error
                }
                if let priorError { throw priorError }
            }
            self.finishTask = task
            return task
        }
        try await task.value
    }

    // Caller must hold lock. One worker serializes inference AND durable checkpoints.
    private func startWorkerIfNeededLocked() {
        guard self.worker == nil, !self.jobs.isEmpty, self.terminalError == nil else { return }
        self.worker = Task(priority: .userInitiated) { [self] in
            await self.consumeJobs()
        }
    }

    private func consumeJobs() async {
        while let job = self.lock.withLock({ () -> Job? in
            guard self.terminalError == nil, !self.jobs.isEmpty else {
                self.worker = nil
                return nil
            }
            let job = self.jobs.removeFirst()
            self.activeProgressiveWindow = job.progressiveWindow
            return job
        }) {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try Task.checkCancellation()
                let batch: MeetingPCMTranscriptBatch
                switch (self.recognition, job) {
                case (.sealed(let recognize), .sealed(let samples, let start)):
                    batch = try await recognize(samples, start)
                case (.progressive(_, let recognize), .progressive(let window, let start)):
                    batch = try await recognize(window, start)
                    guard window.consumedFinal else { throw MeetingMemoryAudioError.invalidPCM }
                default: throw MeetingMemoryAudioError.invalidPCM
                }
                try Task.checkCancellation()
                let recognized = ProcessInfo.processInfo.systemUptime
                try await self.checkpoint(batch)
                let pending = self.lock.withLock { () -> Int in
                    self.pendingFrames = max(0, self.pendingFrames - job.frameCount)
                    self.activeProgressiveWindow = nil
                    return self.pendingFrames
                }
                let checkpointMs = Int((ProcessInfo.processInfo.systemUptime - recognized) * 1000)
                let operationMs = Int((recognized - started) * 1000)
                // A growing-window callback also waits for future capture, unlike sealed ASR.
                let timingLabel = self.previewIntervalFrames == nil ? "inferenceMs" : "windowMs"
                self.diagnostic("window offset=\(job.start) frames=\(job.frameCount) \(timingLabel)=\(operationMs) checkpointMs=\(checkpointMs) pendingFrames=\(pending) budgetFrames=\(self.maximumPendingFrames)")
            } catch {
                self.fail(error)
                self.lock.withLock { self.activeProgressiveWindow = nil; self.worker = nil }
                return
            }
        }
    }

    private func fail(_ error: Error) {
        let pending = self.lock.withLock { () -> (Int, Int)? in
            guard self.terminalError == nil else { return nil }
            let state = (self.pendingFrames, self.jobs.count)
            self.terminalError = error
            self.accepting = false
            self.tail.removeAll(keepingCapacity: false)
            self.openProgressiveWindow?.cancel(error)
            self.activeProgressiveWindow?.cancel(error)
            self.jobs.forEach { $0.progressiveWindow?.cancel(error) }
            self.openProgressiveWindow = nil
            self.jobs.removeAll(keepingCapacity: false)
            self.pendingFrames = 0
            self.worker?.cancel()
            return state
        }
        if let pending {
            let kind: String
            switch error as? MeetingMemoryAudioError {
            case .overload: kind = "overload"
            case .invalidPCM: kind = "invalid_pcm"
            case .invalidBudget: kind = "invalid_budget"
            case .timelineDiscontinuity: kind = "timeline_discontinuity"
            case nil: kind = String(reflecting: type(of: error))
            }
            self.diagnostic("stopped errorKind=\(kind) pendingFrames=\(pending.0) queuedWindows=\(pending.1) budgetFrames=\(self.maximumPendingFrames)")
            self.failure(error)
        }
    }
}
