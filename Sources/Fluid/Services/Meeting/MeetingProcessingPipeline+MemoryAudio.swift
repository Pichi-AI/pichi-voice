@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// True requires complete, measured non-speech coverage on the original capture clock.
/// Missing, stale or uncertain activity evidence must return false and preserve recognition.
typealias MeetingConfidentNonSpeechQuery = @Sendable (TimeInterval, TimeInterval) async -> Bool
typealias MeetingTrackConfidentNonSpeechQuery = @Sendable (MeetingAudioTrackKind, TimeInterval, TimeInterval) async -> Bool

extension MeetingProcessingPipeline {
    /// PCM input is another input capability of the existing pipeline, not another meeting
    /// coordinator or model installer. Selection, residency, canonical assembly and storage are
    /// owned by the injected operations that the pipeline freezes before capture starts.
    nonisolated static func makeMemoryAudioConsumer(
        chunkSeconds: Double = 12,
        maximumPendingSeconds: Double = 60,
        initialChunkSeconds: Double? = nil,
        sourceTimeline: MeetingPCMSourceTimeline? = nil,
        recognize: @escaping @Sendable ([Float], TimeInterval) async throws -> MeetingPCMTranscriptBatch,
        checkpoint: @escaping @Sendable (MeetingPCMTranscriptBatch) async throws -> Void,
        didProcessWindow: (@Sendable (MeetingPCMWindowProcessingFeedback) async throws -> Void)? = nil,
        finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)? = nil,
        diagnostic: @escaping @Sendable (String) -> Void = { DebugLogger.shared.info($0, source: "MeetingMemoryAudio") },
        failure: @escaping @Sendable (Error) -> Void
    ) throws -> any MeetingMemoryAudioConsuming {
        try MeetingPipelineMemoryAudioConsumer(chunkSeconds: chunkSeconds,
                                              maximumPendingSeconds: maximumPendingSeconds,
                                              initialChunkSeconds: initialChunkSeconds,
                                              sourceTimeline: sourceTimeline,
                                              recognition: .sealed(recognize), checkpoint: checkpoint, didProcessWindow: didProcessWindow,
                                              finalize: finalize, diagnostic: diagnostic, failure: failure)
    }

    /// The same bounded transport can start one recognizer while an attribution window is
    /// still growing. The recognizer owns its accumulator and joins each inference before
    /// appending the next delta. Frames leave the pending budget after inference releases PCM;
    /// the sole worker still joins the durable checkpoint before starting the next window.
    nonisolated static func makeProgressiveMemoryAudioConsumer(
        chunkSeconds: Double = 12,
        maximumPendingSeconds: Double = 60,
        initialPreviewSeconds: Double = 3,
        previewIntervalSeconds: Double = 3,
        confidentlyNonSpeech: MeetingConfidentNonSpeechQuery? = nil,
        pauseEndpointSilenceSeconds: Double? = nil,
        sourceTimeline: MeetingPCMSourceTimeline? = nil,
        recognize: @escaping @Sendable (MeetingPCMProgressiveWindow, TimeInterval) async throws -> MeetingPCMTranscriptBatch,
        checkpoint: @escaping @Sendable (MeetingPCMTranscriptBatch) async throws -> Void,
        didProcessWindow: (@Sendable (MeetingPCMWindowProcessingFeedback) async throws -> Void)? = nil,
        finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)? = nil,
        diagnostic: @escaping @Sendable (String) -> Void = { DebugLogger.shared.info($0, source: "MeetingMemoryAudio") },
        failure: @escaping @Sendable (Error) -> Void
    ) throws -> any MeetingMemoryAudioConsuming {
        try MeetingPipelineMemoryAudioConsumer(chunkSeconds: chunkSeconds,
                                              maximumPendingSeconds: maximumPendingSeconds,
                                              initialChunkSeconds: initialPreviewSeconds,
                                              confidentlyNonSpeech: confidentlyNonSpeech,
                                              pauseEndpointSilenceSeconds: pauseEndpointSilenceSeconds,
                                              sourceTimeline: sourceTimeline,
                                              recognition: .progressive(intervalSeconds: previewIntervalSeconds, recognize),
                                              checkpoint: checkpoint, didProcessWindow: didProcessWindow,
                                              finalize: finalize, diagnostic: diagnostic, failure: failure)
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

/// Scalar scheduling feedback after protected checkpoint/projection has joined. The transport
/// has released this window's PCM. The remaining charged count describes its admission budget,
/// never elapsed waiting age or capture-to-visible latency.
nonisolated struct MeetingPCMWindowProcessingFeedback: Sendable {
    let sourceStartSample: Int
    let sourceFrameCount: Int
    let chargedPendingFrames: Int
    let maximumPendingFrames: Int
}

/// Ownership of the delta moves to the single worker. `totalFrames` describes the growing
/// window, not the delta length. A final empty delta seals a previously delivered prefix.
nonisolated struct MeetingPCMWindowUpdate: Sendable {
    /// The sole worker clears the transferred delta after appending it, before
    /// awaiting inference. This prevents retaining both delta and accumulator.
    var samples: [Float]
    let totalFrames: Int
    let isFinal: Bool
    /// Present only when complete measured quiet coverage sealed this exact delivered prefix.
    /// Stop and fixed-size boundaries do not establish speech endpoint evidence.
    let speechBoundarySample: Int?
}

/// A single growing PCM window, used only underneath the existing memory transport. It holds
/// newly accepted deltas while inference owns an immutable prefix. `next` coalesces every
/// available delta and transfers its array storage; it never copies the full prior prefix.
nonisolated final class MeetingPCMProgressiveWindow: @unchecked Sendable {
    private let lock = NSLock()
    private let initialFrames: Int
    private let intervalFrames: Int
    private let nonSpeechQuery: MeetingConfidentNonSpeechQuery?
    private let pauseEndpointSilenceFrames: Int?
    private let sealAtSpeechBoundary: (@Sendable (MeetingPCMProgressiveWindow, Int, TimeInterval) -> Bool)?
    private var pending: [Float] = []
    private var acceptedFrames = 0
    private var deliveredFrames = 0
    private var deliveredAny = false
    private var sealed = false
    private var deliveredFinal = false
    private var speechBoundarySample: Int?
    private var terminalError: Error?
    private var waiter: CheckedContinuation<MeetingPCMWindowUpdate?, Error>?

    fileprivate init(initialFrames: Int, intervalFrames: Int,
                     confidentlyNonSpeech: MeetingConfidentNonSpeechQuery? = nil,
                     pauseEndpointSilenceFrames: Int? = nil,
                     pending: [Float] = [],
                     sealAtSpeechBoundary: (@Sendable (MeetingPCMProgressiveWindow, Int, TimeInterval) -> Bool)? = nil) {
        self.initialFrames = initialFrames
        self.intervalFrames = intervalFrames
        self.nonSpeechQuery = confidentlyNonSpeech
        self.pauseEndpointSilenceFrames = pauseEndpointSilenceFrames
        self.sealAtSpeechBoundary = sealAtSpeechBoundary
        self.pending = pending
        self.acceptedFrames = pending.count
    }

    func confidentlyNonSpeech(start: TimeInterval, end: TimeInterval) async -> Bool {
        guard !Task.isCancelled, start.isFinite, end.isFinite, start >= 0, end > start else { return false }
        guard self.lock.withLock({ self.terminalError == nil }) else { return false }
        guard let nonSpeechQuery else { return false }
        let result = await nonSpeechQuery(start, end)
        return !Task.isCancelled && self.lock.withLock({ self.terminalError == nil }) && result
    }

    var usesPauseEndpoint: Bool { self.pauseEndpointSilenceFrames != nil }

    /// The recognizer calls this sequentially after consuming a nonfinal update. Evidence
    /// covers the entire trailing pause through that immutable prefix, including its right
    /// edge. Capture can keep appending while the query awaits; the consumer atomically moves
    /// all not-yet-delivered suffix PCM to the next window before sealing this exact prefix.
    func sealAtSpeechBoundaryIfConfident(totalFrames: Int, offset: TimeInterval) async -> Bool {
        guard let silenceFrames = self.pauseEndpointSilenceFrames,
              let sealAtSpeechBoundary, totalFrames >= silenceFrames,
              offset.isFinite, offset >= 0, !Task.isCancelled,
              self.lock.withLock({ self.canSealDeliveredPrefixLocked(totalFrames) }) else { return false }
        let end = offset + Double(totalFrames) / 16_000
        guard await self.confidentlyNonSpeech(start: end - Double(silenceFrames) / 16_000, end: end),
              !Task.isCancelled else { return false }
        return sealAtSpeechBoundary(self, totalFrames, offset)
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

    /// Caller holds the consumer lock, preserving its existing consumer-to-window lock order.
    /// Moving this array transfers suffix ownership without copying the delivered prefix.
    fileprivate func detachSuffixAndSeal(totalFrames: Int, boundarySample: Int) -> [Float]? {
        self.lock.withLock {
            guard self.canSealDeliveredPrefixLocked(totalFrames) else { return nil }
            let suffix = self.pending
            self.pending = []
            self.acceptedFrames = totalFrames
            self.sealed = true
            self.speechBoundarySample = boundarySample
            return suffix
        }
    }

    private func canSealDeliveredPrefixLocked(_ totalFrames: Int) -> Bool {
        self.terminalError == nil && !self.sealed && !self.deliveredFinal
            && self.deliveredAny && self.deliveredFrames == totalFrames && self.waiter == nil
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
        let update = MeetingPCMWindowUpdate(samples: self.pending, totalFrames: self.acceptedFrames,
                                           isFinal: self.sealed, speechBoundarySample: self.speechBoundarySample)
        self.pending = []
        self.deliveredAny = true
        self.deliveredFrames = self.acceptedFrames
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
/// tail, queued jobs AND in-flight recognition. A checkpoint retains only text, and remains
/// serialized with recognition. The default 60-second ceiling is 3,840,000 PCM bytes, regardless
/// of meeting duration, allowing short native model/IO stalls without an expanding queue.
/// There is no audio file operation,
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
    private let nonSpeechQuery: MeetingConfidentNonSpeechQuery?
    private let sourceTimeline: MeetingPCMSourceTimeline?
    private let pauseEndpointSilenceFrames: Int?
    private var openProgressiveWindow: MeetingPCMProgressiveWindow?
    private var openProgressiveStart: TimeInterval = 0
    private var openProgressiveScheduled = false
    private var activeProgressiveWindow: MeetingPCMProgressiveWindow?
    private let checkpoint: @Sendable (MeetingPCMTranscriptBatch) async throws -> Void
    private let didProcessWindow: (@Sendable (MeetingPCMWindowProcessingFeedback) async throws -> Void)?
    private let finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)?
    private let failure: @Sendable (Error) -> Void
    private let diagnostic: @Sendable (String) -> Void
    private var accepting = true
    private var terminalError: Error?
    private var tail: [Float] = []
    private var tailStart: TimeInterval = 0
    private var jobs: [Job] = []
    private var pendingFrames = 0
    private var peakPendingFrames = 0
    // Source offsets share the admitted PCM clock, including after fractional pause splits.
    // Converting once avoids accumulating seconds just below an already closed sample prefix.
    private var acceptedSourceFrames = 0
    private var expectedPTS: CMTime?
    private var worker: Task<Void, Never>?
    private var finishTask: Task<Void, Error>?

    var rejectionReason: String? {
        self.lock.withLock { (self.terminalError as? MeetingMemoryAudioError)?.localizedDescription }
    }

    init(chunkSeconds: Double, maximumPendingSeconds: Double, initialChunkSeconds: Double?,
         confidentlyNonSpeech: MeetingConfidentNonSpeechQuery? = nil,
         pauseEndpointSilenceSeconds: Double? = nil,
         sourceTimeline: MeetingPCMSourceTimeline? = nil,
         recognition: Recognition,
         checkpoint: @escaping @Sendable (MeetingPCMTranscriptBatch) async throws -> Void,
         didProcessWindow: (@Sendable (MeetingPCMWindowProcessingFeedback) async throws -> Void)? = nil,
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
        self.sourceTimeline = sourceTimeline
        if let sourceTimeline, let confidentlyNonSpeech {
            self.nonSpeechQuery = { start, end in
                guard let mapped = sourceTimeline.mapInterval(start: start, end: end) else { return false }
                return await confidentlyNonSpeech(mapped.start, mapped.end)
            }
        } else { self.nonSpeechQuery = confidentlyNonSpeech }
        if let silence = pauseEndpointSilenceSeconds {
            guard silence.isFinite, silence >= 0.25, silence <= chunkSeconds else {
                throw MeetingMemoryAudioError.invalidBudget
            }
            self.pauseEndpointSilenceFrames = Int((silence * 16_000).rounded(.up))
        } else {
            self.pauseEndpointSilenceFrames = nil
        }
        switch recognition {
        case .sealed: self.previewIntervalFrames = nil
        case .progressive(let interval, _):
            guard interval.isFinite, interval >= 0.25, interval <= chunkSeconds else {
                throw MeetingMemoryAudioError.invalidBudget
            }
            self.previewIntervalFrames = Int((interval * 16_000).rounded())
        }
        self.checkpoint = checkpoint
        self.didProcessWindow = didProcessWindow
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
            if self.sourceTimeline == nil, let expectedPTS, abs(CMTimeGetSeconds(pts - expectedPTS)) > 1.0 / 16_000 {
                rejected = MeetingMemoryAudioError.timelineDiscontinuity
                return false
            }
            guard frameCount <= Int.max - self.acceptedSourceFrames else {
                rejected = MeetingMemoryAudioError.invalidPCM
                return false
            }
            let sourceStartFrame = self.acceptedSourceFrames
            guard (0..<frameCount).allSatisfy({ data[$0].isFinite }) else {
                rejected = MeetingMemoryAudioError.invalidPCM
                return false
            }
            if let sourceTimeline {
                do {
                    if try sourceTimeline.record(sourceStartSample: sourceStartFrame, frameCount: frameCount,
                        presentationTime: CMTimeGetSeconds(pts),
                        clockMapping: MeetingCaptureClockMetadata.read(from: sampleBuffer)?.mapping) {
                        self.sealSourceBoundaryLocked()
                    }
                } catch {
                    rejected = error
                    return false
                }
            }
            self.expectedPTS = pts + CMTime(value: Int64(frameCount), timescale: 16_000)
            self.acceptedSourceFrames += frameCount
            self.pendingFrames += frameCount
            self.peakPendingFrames = max(self.peakPendingFrames, self.pendingFrames)
            var position = 0
            while position < frameCount {
                if let intervalFrames = self.previewIntervalFrames {
                    if self.openProgressiveWindow == nil {
                        self.openProgressiveWindow = self.makeProgressiveWindow(intervalFrames: intervalFrames)
                        self.openProgressiveStart = Double(sourceStartFrame + position) / 16_000
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
                    if self.tail.isEmpty { self.tailStart = Double(sourceStartFrame + position) / 16_000 }
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

    /// Called with the transport lock held. A measured source gap is an ASR boundary,
    /// not acoustic silence. The next job retains the contiguous compact inference clock.
    private func sealSourceBoundaryLocked() {
        if let window = self.openProgressiveWindow {
            window.seal()
            if !self.openProgressiveScheduled { self.jobs.append(.progressive(window, self.openProgressiveStart)) }
            self.openProgressiveWindow = nil
            self.openProgressiveScheduled = false
        }
        if !self.tail.isEmpty {
            self.jobs.append(.sealed(self.tail, self.tailStart))
            self.tail = []
            self.emittedInitialWindow = true
        }
    }

    // Only the consumer mutates capture window ownership. Endpointing adds no worker or
    // per-packet task, and every suffix frame remains charged to the same pending budget.
    private func makeProgressiveWindow(intervalFrames: Int, pending: [Float] = []) -> MeetingPCMProgressiveWindow {
        MeetingPCMProgressiveWindow(initialFrames: self.initialChunkFrames,
            intervalFrames: intervalFrames, confidentlyNonSpeech: self.nonSpeechQuery,
            pauseEndpointSilenceFrames: self.pauseEndpointSilenceFrames, pending: pending,
            sealAtSpeechBoundary: { [weak self] window, frames, offset in
                self?.sealDeliveredSpeechBoundary(window: window, frames: frames, offset: offset) ?? false
            })
    }

    private func sealDeliveredSpeechBoundary(window: MeetingPCMProgressiveWindow, frames: Int, offset: TimeInterval) -> Bool {
        self.lock.withLock {
            guard self.accepting, self.terminalError == nil,
                  self.openProgressiveWindow === window, self.openProgressiveStart == offset,
                  let intervalFrames = self.previewIntervalFrames else { return false }
            let boundarySample = Int((offset * 16_000).rounded()) + frames
            guard let suffix = window.detachSuffixAndSeal(totalFrames: frames,
                boundarySample: boundarySample) else { return false }
            self.openProgressiveWindow = nil
            self.openProgressiveScheduled = false
            if !suffix.isEmpty {
                let successor = self.makeProgressiveWindow(intervalFrames: intervalFrames, pending: suffix)
                self.openProgressiveWindow = successor
                self.openProgressiveStart = Double(boundarySample) / 16_000
                if suffix.count >= self.initialChunkFrames {
                    self.jobs.append(.progressive(successor, self.openProgressiveStart))
                    self.openProgressiveScheduled = true
                }
            }
            return true
        }
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
                        if !batch.segments.isEmpty || !batch.speakers.isEmpty || !batch.speakerRevisions.isEmpty
                            || batch.protectedSourceThroughSample != nil || !batch.protectedSourceIntervals.isEmpty {
                            try await self.checkpoint(batch)
                        }
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

    /// This async scope ends before checkpoint IO starts, so no Job, PCM array or
    /// progressive window remains retained by the worker while it saves text.
    private func recognizeNextJob() async throws -> (batch: MeetingPCMTranscriptBatch, start: TimeInterval, frames: Int, elapsed: Int)? {
        guard let job = self.lock.withLock({ () -> Job? in
            guard self.terminalError == nil, !self.jobs.isEmpty else {
                self.worker = nil
                return nil
            }
            let job = self.jobs.removeFirst()
            self.activeProgressiveWindow = job.progressiveWindow
            return job
        }) else { return nil }
        let started = ProcessInfo.processInfo.systemUptime
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
        return (batch, job.start, job.frameCount, Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
    }

    private func consumeJobs() async {
        do {
            while let result = try await self.recognizeNextJob() {
                self.lock.withLock {
                    self.pendingFrames = max(0, self.pendingFrames - result.frames)
                    self.activeProgressiveWindow = nil
                }
                try Task.checkCancellation()
                let recognized = ProcessInfo.processInfo.systemUptime
                try await self.checkpoint(result.batch)
                let checkpointMs = Int((ProcessInfo.processInfo.systemUptime - recognized) * 1000)
                let pending = self.lock.withLock { (self.pendingFrames, self.peakPendingFrames) }
                try await self.didProcessWindow?(.init(sourceStartSample: Int((result.start * 16_000).rounded()),
                    sourceFrameCount: result.frames, chargedPendingFrames: pending.0,
                    maximumPendingFrames: self.maximumPendingFrames))
                // A growing-window callback also waits for future capture, unlike sealed ASR.
                let timingLabel = self.previewIntervalFrames == nil ? "inferenceMs" : "windowMs"
                self.diagnostic("window offset=\(result.start) frames=\(result.frames) \(timingLabel)=\(result.elapsed) checkpointMs=\(checkpointMs) pendingFrames=\(pending.0) peakPendingFrames=\(pending.1) budgetFrames=\(self.maximumPendingFrames)")
            }
        } catch {
            self.fail(error)
            self.lock.withLock { self.activeProgressiveWindow = nil; self.worker = nil }
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

/// The recording owns its RAM archive independently of optional live recognition. A slow or
/// failed recognizer can catch up after Stop without stopping capture or losing accepted audio.
/// Only archive/PCM errors reject capture. This does not create a file fallback.
final nonisolated class MeetingArchivedMemoryAudioConsumer: MeetingMemoryAudioConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private let archive: MeetingMemoryAudioArchive
    private let speech: any MeetingMemoryAudioConsuming
    private var accepting = true
    private var rejectedSpeech = false
    private var archiveFailure: Error?
    private var expectedPTS: CMTime?
    private var finishing: Task<Void, Error>?

    init(archive: MeetingMemoryAudioArchive, speech: any MeetingMemoryAudioConsuming) {
        self.archive = archive
        self.speech = speech
    }

    var requiresSpeechReplay: Bool { self.lock.withLock { self.rejectedSpeech } }
    var rejectionReason: String? { self.lock.withLock { self.archiveFailure?.localizedDescription } }

    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        self.lock.withLock {
            guard self.accepting, self.archiveFailure == nil else { return false }
            do {
                let frames = CMSampleBufferGetNumSamples(sampleBuffer)
                let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
                guard frames > 0, frames <= 65_536, pts.isNumeric, pts >= .zero,
                      let description = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let contract = try? MeetingPCMFormatContract(formatDescription: description),
                      contract.sampleRate == 16_000, contract.channelCount == 1,
                      let copied = MeetingLiveSampleCopy.copy(sampleBuffer),
                      let data = copied.buffer.floatChannelData?[0] else { throw MeetingMemoryAudioError.invalidPCM }
                if let expectedPTS, abs(CMTimeGetSeconds(pts - expectedPTS)) > 1.0 / 16_000 {
                    throw MeetingMemoryAudioError.timelineDiscontinuity
                }
                try self.archive.append(UnsafeBufferPointer(start: data, count: Int(copied.buffer.frameLength)))
                self.expectedPTS = pts + CMTime(value: Int64(frames), timescale: 16_000)
                if !self.rejectedSpeech, !self.speech.enqueue(sampleBuffer) { self.rejectedSpeech = true }
                return true
            } catch {
                self.archiveFailure = error
                self.accepting = false
                return false
            }
        }
    }

    func finish() async throws {
        let task = self.lock.withLock { () -> Task<Void, Error> in
            if let finishing { return finishing }
            self.accepting = false
            let task = Task { [self] in
                do { try self.archive.seal() }
                catch { self.lock.withLock { self.archiveFailure = self.archiveFailure ?? error } }
                // Join inference even when archive sealing failed. An ASR/privacy failure
                // requests a fresh, complete replay after Stop, never raw-text publication.
                do { try await self.speech.finish() }
                catch { self.lock.withLock { self.rejectedSpeech = true } }
                if let failure = self.lock.withLock({ self.archiveFailure }) { throw failure }
            }
            self.finishing = task
            return task
        }
        try await task.value
    }
}
