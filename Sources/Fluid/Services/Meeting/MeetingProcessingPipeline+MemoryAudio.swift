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
        recognize: @escaping @Sendable ([Float], TimeInterval) async throws -> MeetingPCMTranscriptBatch,
        checkpoint: @escaping @Sendable (MeetingPCMTranscriptBatch) async throws -> Void,
        finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)? = nil,
        diagnostic: @escaping @Sendable (String) -> Void = { DebugLogger.shared.info($0, source: "MeetingMemoryAudio") },
        failure: @escaping @Sendable (Error) -> Void
    ) throws -> any MeetingMemoryAudioConsuming {
        try MeetingPipelineMemoryAudioConsumer(chunkSeconds: chunkSeconds,
                                              maximumPendingSeconds: maximumPendingSeconds,
                                              recognize: recognize, checkpoint: checkpoint, finalize: finalize, diagnostic: diagnostic, failure: failure)
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

/// Bounded PCM transport underneath MeetingProcessingPipeline. The budget includes the input
/// tail, queued jobs AND in-flight recognition/checkpoint work. There is no audio file operation,
/// path, materializer or provider-selection switch anywhere in this consumer.
private final nonisolated class MeetingPipelineMemoryAudioConsumer: MeetingMemoryAudioConsuming, @unchecked Sendable {
    private struct Job: Sendable {
        var samples: [Float]
        let start: TimeInterval
    }

    private let lock = NSLock()
    private let chunkFrames: Int
    private let maximumPendingFrames: Int
    private let recognize: @Sendable ([Float], TimeInterval) async throws -> MeetingPCMTranscriptBatch
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

    init(chunkSeconds: Double, maximumPendingSeconds: Double,
         recognize: @escaping @Sendable ([Float], TimeInterval) async throws -> MeetingPCMTranscriptBatch,
         checkpoint: @escaping @Sendable (MeetingPCMTranscriptBatch) async throws -> Void,
         finalize: (@Sendable () async throws -> MeetingPCMTranscriptBatch?)?,
         diagnostic: @escaping @Sendable (String) -> Void,
         failure: @escaping @Sendable (Error) -> Void) throws {
        guard chunkSeconds.isFinite, maximumPendingSeconds.isFinite,
              chunkSeconds >= 0.25, chunkSeconds <= 30,
              maximumPendingSeconds >= chunkSeconds, maximumPendingSeconds <= 120 else {
            throw MeetingMemoryAudioError.invalidBudget
        }
        self.chunkFrames = Int((chunkSeconds * 16_000).rounded())
        self.maximumPendingFrames = Int((maximumPendingSeconds * 16_000).rounded())
        self.recognize = recognize
        self.checkpoint = checkpoint
        self.finalize = finalize
        self.failure = failure
        self.diagnostic = diagnostic
        self.tail.reserveCapacity(self.chunkFrames)
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
                if self.tail.isEmpty { self.tailStart = start + Double(position) / 16_000 }
                let count = min(self.chunkFrames - self.tail.count, frameCount - position)
                self.tail.append(contentsOf: UnsafeBufferPointer(start: data.advanced(by: position), count: count))
                position += count
                if self.tail.count == self.chunkFrames {
                    self.jobs.append(Job(samples: self.tail, start: self.tailStart))
                    self.tail = []
                    self.tail.reserveCapacity(self.chunkFrames)
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
                self.jobs.append(Job(samples: self.tail, start: self.tailStart))
                self.tail = []
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
            return self.jobs.removeFirst()
        }) {
            let started = ProcessInfo.processInfo.systemUptime
            do {
                try Task.checkCancellation()
                let batch = try await self.recognize(job.samples, job.start)
                try Task.checkCancellation()
                let recognized = ProcessInfo.processInfo.systemUptime
                try await self.checkpoint(batch)
                let pending = self.lock.withLock { () -> Int in
                    self.pendingFrames = max(0, self.pendingFrames - job.samples.count)
                    return self.pendingFrames
                }
                let checkpointMs = Int((ProcessInfo.processInfo.systemUptime - recognized) * 1000)
                let inferenceMs = Int((recognized - started) * 1000)
                self.diagnostic("window offset=\(job.start) frames=\(job.samples.count) inferenceMs=\(inferenceMs) checkpointMs=\(checkpointMs) pendingFrames=\(pending) budgetFrames=\(self.maximumPendingFrames)")
            } catch {
                self.fail(error)
                self.lock.withLock { self.worker = nil }
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
