import Foundation
#if arch(arm64)
import CoreML

nonisolated enum MeetingFast32ComputePolicy {
    static var preferredUnits: MLComputeUnits {
        self.units(hasNeuralEngine: MLComputeDevice.allComputeDevices.contains {
            if case .neuralEngine = $0 { return true }
            return false
        })
    }

    static func units(hasNeuralEngine: Bool) -> MLComputeUnits {
        hasNeuralEngine ? .cpuAndNeuralEngine : .cpuAndGPU
    }

    /// A diagnostic comparison never changes the normal device policy or persisted settings.
    static func diagnosticUnits(preferred: MLComputeUnits, environment: [String: String]) -> MLComputeUnits {
        environment["PICHI_MEETING_DETAILED_PROFILE"] == "1"
            && environment["PICHI_MEETING_PROFILE_COMPUTE_UNITS"] == "cpuOnly" ? .cpuOnly : preferred
    }
}

/// Adapter for the split graph's actual host projection and high-resolution output contract.
/// Shared orchestration continues to consume MeetingNemotronDiarizerFactory.
final nonisolated class Fast32NemotronDiarizerFactory: MeetingNemotronDiarizerFactory, @unchecked Sendable {
    private let config: Nemotron3Config
    private let models: Nemotron3Models
    private let profileLogSink: (@Sendable (String) -> Void)?
    private let lock = NSLock()
    private var sessions: [Fast32NemotronDiarizerSession] = []

    init(
        config: Nemotron3Config, models: Nemotron3Models,
        profileLogSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.config = config
        self.models = models
        self.profileLogSink = profileLogSink
    }

    func makeDiarizer(epoch _: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession {
        try Task.checkCancellation()
        let session = Fast32NemotronDiarizerSession(
            config: self.config, models: self.models, profileLogSink: self.profileLogSink)
        self.lock.withLock { self.sessions.append(session) }
        return session
    }

    func cleanup() {
        let sessions = self.lock.withLock {
            let sessions = self.sessions
            self.sessions.removeAll()
            return sessions
        }
        for session in sessions { session.cleanup() }
    }
}

/// Serial per-track state. Only the current chunk's probabilities are retained. Speaker
/// intervals accumulate as compact metadata; raw audio and mel history remain bounded.
private final nonisolated class Fast32NemotronDiarizerSession: MeetingResumableNemotronDiarizerSession, MeetingIncrementalNemotronDiarizerSession, @unchecked Sendable {
    private var diarizer: Nemotron3Diarizer?
    private let config: Nemotron3Config
    private enum Mode { case unused, replay, streaming, finished, failed, cleaned }
    private let operation = NSCondition()
    private var mode = Mode.unused
    private var busy = false
    private var closing = false
    private var clock = MeetingIncrementalDiarizationClock()
    private var streamingIntervals: MeetingFast32SpeakerIntervals
    private static let maximumRetainedIntervals = 16_384

    init(
        config: Nemotron3Config, models: Nemotron3Models,
        profileLogSink: (@Sendable (String) -> Void)? = nil
    ) {
        self.diarizer = Nemotron3Diarizer(config: config, models: models, profileLogSink: profileLogSink)
        self.config = config
        self.streamingIntervals = MeetingFast32SpeakerIntervals(speakerCount: config.numSpeakers)
    }

    /// Factory cleanup normally follows its joined body. The condition also protects an
    /// accidental racing retirement: an admitted native call keeps its model until it ends.
    func cleanup() {
        self.operation.lock()
        self.closing = true
        while self.busy { self.operation.wait() }
        self.diarizer = nil
        self.streamingIntervals = MeetingFast32SpeakerIntervals(speakerCount: self.config.numSpeakers)
        self.mode = .cleaned
        self.operation.unlock()
    }

    func cleanupStreaming() async {
        // Waiting for a synchronous CoreML prediction must not block the caller's actor.
        await Task.detached { self.cleanup() }.value
    }

    private func begin(streaming: Bool) throws -> Nemotron3Diarizer {
        try self.operation.withLock {
            guard !self.closing, let diarizer else { throw MeetingIncrementalDiarizationError.closed }
            guard !self.busy else { throw MeetingIncrementalDiarizationError.concurrentOperation }
            if streaming {
                guard self.mode == .unused || self.mode == .streaming else {
                    throw self.mode == .finished ? MeetingIncrementalDiarizationError.alreadyFinished : .closed
                }
                self.mode = .streaming
            } else {
                guard self.mode == .unused else { throw MeetingIncrementalDiarizationError.closed }
                self.mode = .replay
            }
            self.busy = true
            return diarizer
        }
    }

    private func end(mode: Mode) {
        self.operation.withLock {
            self.mode = mode
            self.busy = false
            self.operation.broadcast()
        }
    }

    func appendStreaming(_ samples: [Float], sourceStartSample: Int) async throws -> MeetingIncrementalDiarizationUpdate {
        try Task.checkCancellation()
        let diarizer = try self.begin(streaming: true)
        var terminalMode = Mode.streaming
        defer { self.end(mode: terminalMode) }
        try self.clock.validateAppend(sampleCount: samples.count, sourceStartSample: sourceStartSample)
        guard samples.allSatisfy(\.isFinite) else { throw MeetingIncrementalDiarizationError.invalidInput }
        do {
            try Task.checkCancellation()
            try autoreleasepool {
                diarizer.appendAudio(samples)
                for chunk in try diarizer.processBufferedAudio() {
                    try self.appendStreamingChunk(chunk)
                }
            }
            try self.clock.accept(sampleCount: samples.count, sourceStartSample: sourceStartSample,
                                  outputFrameCount: diarizer.streamedFrameCount)
            try Task.checkCancellation()
            return self.streamingUpdate()
        } catch {
            // A native call may already have consumed part of the input. This state cannot be
            // retried under the same cursor. Cancellation joins it before retirement.
            terminalMode = .failed
            throw error
        }
    }

    func finishStreaming(totalSamples: Int) async throws -> MeetingIncrementalDiarizationUpdate {
        try Task.checkCancellation()
        let diarizer = try self.begin(streaming: true)
        var terminalMode = Mode.streaming
        defer { self.end(mode: terminalMode) }
        try self.clock.validateFinish(totalSamples: totalSamples)
        do {
            if totalSamples > 0 {
                for chunk in try autoreleasepool(invoking: { try diarizer.finishStream() }) {
                    try self.appendStreamingChunk(chunk)
                }
            }
            try self.clock.finish(totalSamples: totalSamples, outputFrameCount: diarizer.streamedFrameCount)
            terminalMode = .finished
            try Task.checkCancellation()
            return self.streamingUpdate()
        } catch {
            terminalMode = .failed
            throw error
        }
    }

    func discardActivity(beforeSample: Int) async throws {
        try Task.checkCancellation()
        // Acknowledgement after finalization is useful while its final snapshot is consumed.
        try self.operation.withLock {
            guard !self.closing, self.mode == .streaming || self.mode == .finished else {
                throw MeetingIncrementalDiarizationError.closed
            }
            guard !self.busy else { throw MeetingIncrementalDiarizationError.concurrentOperation }
            try self.clock.discard(beforeSample: beforeSample)
            // Keep a crossing/open voice's original anchor. Snapshot clipping handles an
            // acknowledgement in the middle of a 10 ms frame without moving acoustic time.
            self.streamingIntervals.discard(beforeFrame: beforeSample / 160)
        }
    }

    private func appendStreamingChunk(_ chunk: Nemotron3ChunkResult) throws {
        try self.streamingIntervals.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
        guard self.streamingIntervals.retainedIntervalCount <= Self.maximumRetainedIntervals else {
            throw MeetingIncrementalDiarizationError.activityCapacityExceeded
        }
    }

    private func streamingUpdate() -> MeetingIncrementalDiarizationUpdate {
        .init(activity: self.streamingIntervals.snapshot(
            duration: Double(self.clock.processedThroughSample) / 16_000,
            startingAt: Double(self.clock.retainedFromSample) / 16_000),
              acceptedThroughSample: self.clock.acceptedThroughSample,
              processedThroughSample: self.clock.processedThroughSample,
              retainedFromSample: self.clock.retainedFromSample, isFinal: self.clock.isFinal)
    }

    func diarize(source: any MeetingPCMReplaySource) async throws -> [MeetingNemotronSpeakerSegment] {
        try Task.checkCancellation()
        let diarizer = try self.begin(streaming: false)
        defer { self.end(mode: .unused) }
        diarizer.reset()
        defer { diarizer.reset() }
        var intervals = MeetingFast32SpeakerIntervals(speakerCount: self.config.numSpeakers)
        try await source.replay { samples in
            try Task.checkCancellation()
            try autoreleasepool {
                diarizer.appendAudio(samples)
                for chunk in try diarizer.processBufferedAudio() {
                    try intervals.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
                }
            }
        }
        try Task.checkCancellation()
        for chunk in try autoreleasepool(invoking: { try diarizer.finishStream() }) {
            try intervals.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
        }
        try Task.checkCancellation()
        return intervals.finish(duration: Double(source.totalSampleCount) / 16_000)
    }

    func diarize(
        source: any MeetingPCMReplaySource, restoring: Data?,
        checkpoint: @escaping @Sendable (Data) async throws -> Void
    ) async throws -> [MeetingNemotronSpeakerSegment] {
        try Task.checkCancellation()
        let diarizer = try self.begin(streaming: false)
        defer { self.end(mode: .unused) }
        let count = source.totalSampleCount
        guard count > 0 else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
        diarizer.reset()
        defer { diarizer.reset() }
        var intervals = MeetingFast32SpeakerIntervals(speakerCount: self.config.numSpeakers)
        var offset = 0
        if let restoring {
            do {
                let state = try MeetingFast32Checkpoint.decode(restoring, config: self.config, sourceSampleCount: count)
                try diarizer.restoreStreamingSnapshot(state.diarizer, sampleCursor: state.sampleCursor)
                intervals = state.intervals
                offset = state.sampleCursor
            } catch { throw MeetingDiarizerCheckpointError.invalidCheckpoint }
        }
        var lastCheckpoint = offset
        while offset < count {
            try Task.checkCancellation()
            let end = offset + min(16_000, count - offset)
            let samples = try await source.readSamples(in: offset..<end)
            guard samples.count == end - offset, samples.allSatisfy(\.isFinite) else {
                throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
            }
            try Task.checkCancellation()
            try autoreleasepool {
                diarizer.appendAudio(samples)
                for chunk in try diarizer.processBufferedAudio() {
                    try intervals.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
                }
            }
            offset = end
            // Commit only after both model state and emitted intervals consumed the same
            // input prefix. A failed/terminated write leaves the previous prefix intact.
            if offset - lastCheckpoint >= 80_000 || offset == count {
                try Task.checkCancellation()
                let state = MeetingFast32Checkpoint(sourceSampleCount: count, sampleCursor: offset,
                                                     diarizer: try diarizer.streamingSnapshot(), intervals: intervals)
                let payload = try state.encode(config: self.config)
                try await checkpoint(payload)
                lastCheckpoint = offset
            }
        }
        // The last checkpoint intentionally precedes final padding. Restoring that state
        // redoes only the tail flush and cannot duplicate already emitted intervals.
        try Task.checkCancellation()
        for chunk in try autoreleasepool(invoking: { try diarizer.finishStream() }) {
            try intervals.append(probabilities: chunk.probabilities, frameCount: chunk.frameCount)
        }
        try Task.checkCancellation()
        return intervals.finish(duration: Double(count) / 16_000)
    }

    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment] {
        try await self.diarize(source: BufferedReplaySource(samples: samples))
    }

    private struct BufferedReplaySource: MeetingPCMReplaySource {
        let samples: [Float]
        var totalSampleCount: Int { self.samples.count }
        func readSamples(in range: Range<Int>) async throws -> [Float] {
            try Task.checkCancellation()
            return Array(self.samples[range])
        }
    }
}

/// The binary plist preserves Float bit values and stores the bounded frontend/cache
/// together with compact interval metadata. Artifact and audio-content digests are bound
/// by the durable owner outside this model adapter.
nonisolated struct MeetingFast32Checkpoint: Codable, Sendable {
    static let maximumBytes = 16 * 1024 * 1024
    static let runtimeRevision = "nemotron3-streaming-v1-82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8"
    let revision: String
    let sourceSampleCount: Int
    let sampleCursor: Int
    let diarizer: Nemotron3Diarizer.StreamingSnapshot
    let intervals: MeetingFast32SpeakerIntervals

    init(sourceSampleCount: Int, sampleCursor: Int, diarizer: Nemotron3Diarizer.StreamingSnapshot,
         intervals: MeetingFast32SpeakerIntervals) {
        self.revision = Self.runtimeRevision
        self.sourceSampleCount = sourceSampleCount
        self.sampleCursor = sampleCursor
        self.diarizer = diarizer
        self.intervals = intervals
    }

    private func validate(config: Nemotron3Config, sourceSampleCount: Int) throws {
        guard self.revision == Self.runtimeRevision,
              sourceSampleCount > 0, self.sourceSampleCount == sourceSampleCount,
              (0...sourceSampleCount).contains(self.sampleCursor) else {
            throw Nemotron3Error.invalidState("Incompatible recording checkpoint")
        }
        try self.diarizer.validate(config: config, sampleCursor: self.sampleCursor)
        try self.intervals.validate(speakerCount: config.numSpeakers, frameCount: self.diarizer.streamedFrameCount)
    }

    func encode(config: Nemotron3Config) throws -> Data {
        try self.validate(config: config, sourceSampleCount: self.sourceSampleCount)
        let encoder = PropertyListEncoder()
        encoder.outputFormat = .binary
        let data = try encoder.encode(self)
        guard data.count <= Self.maximumBytes else { throw Nemotron3Error.invalidState("Checkpoint exceeds size limit") }
        return data
    }

    static func decode(_ data: Data, config: Nemotron3Config, sourceSampleCount: Int) throws -> Self {
        guard !data.isEmpty, data.count <= Self.maximumBytes else {
            throw Nemotron3Error.invalidState("Invalid checkpoint size")
        }
        let decoder = PropertyListDecoder()
        decoder.userInfo[Nemotron3StreamingState.checkpointConfigurationKey] = config
        let checkpoint = try decoder.decode(Self.self, from: data)
        try checkpoint.validate(config: config, sourceSampleCount: sourceSampleCount)
        return checkpoint
    }
}
#endif

/// Kept independent of CoreML for tail, threshold, boundary and cancellation tests.
nonisolated struct MeetingFast32SpeakerIntervals: Codable, Sendable {
    private struct Segment: Codable, Sendable {
        let slot: Int
        let start: Int
        let end: Int
    }
    private var openFrames: [Int?]
    private var segments: [Segment] = []
    private var frames = 0

    var retainedIntervalCount: Int { self.segments.count + self.openFrames.compactMap { $0 }.count }

    init(speakerCount: Int = 8) { self.openFrames = Array(repeating: nil, count: speakerCount) }

    private enum CodingKeys: String, CodingKey { case openFrames, segments, frames }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.openFrames = try MeetingDiarizerCheckpointDecoding.array(Int?.self, from: container,
                                                                     forKey: .openFrames, maximumCount: 8)
        self.segments = try MeetingDiarizerCheckpointDecoding.array(Segment.self, from: container,
                                                                   forKey: .segments, maximumCount: 250_000)
        self.frames = try container.decode(Int.self, forKey: .frames)
    }

    mutating func append(probabilities: [Float], frameCount: Int) throws {
        guard frameCount >= 0, frameCount <= 4_096,
              probabilities.count == frameCount * self.openFrames.count,
              probabilities.allSatisfy({ $0.isFinite && $0 >= 0 && $0 <= 1 }) else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        try Task.checkCancellation()
        for frame in 0..<frameCount {
            for slot in self.openFrames.indices {
                let active = probabilities[frame * self.openFrames.count + slot] > 0.5
                if active, self.openFrames[slot] == nil { self.openFrames[slot] = self.frames + frame }
                if !active, let start = self.openFrames[slot] {
                    self.close(slot: slot, start: start, end: self.frames + frame)
                }
            }
        }
        self.frames += frameCount
    }

    private mutating func close(slot: Int, start: Int, end: Int) {
        if end - start >= 20 {
            self.segments.append(.init(slot: slot, start: start, end: end))
        }
        self.openFrames[slot] = nil
    }

    /// Read without finalizing any open voice. Its true anchor survives preview and eviction,
    /// so a later chunk extends the same slot rather than manufacturing a new speaking turn.
    func snapshot(duration: TimeInterval, startingAt minimum: TimeInterval = 0) -> [MeetingNemotronSpeakerSegment] {
        guard duration.isFinite, minimum.isFinite, duration >= minimum, minimum >= 0 else { return [] }
        var retained = self.segments
        for slot in self.openFrames.indices {
            if let start = self.openFrames[slot], self.frames - start >= 20 {
                retained.append(.init(slot: slot, start: start, end: self.frames))
            }
        }
        return retained.compactMap {
            let start = max(minimum, Double($0.start) / 100)
            let end = min(duration, Double($0.end) / 100)
            guard end > start else { return nil }
            return MeetingNemotronSpeakerSegment(slotIndex: $0.slot, start: start, end: end)
        }.sorted { $0.start == $1.start ? $0.slotIndex < $1.slotIndex : $0.start < $1.start }
    }

    mutating func discard(beforeFrame: Int) {
        self.segments.removeAll { $0.end <= beforeFrame }
    }

    mutating func finish(duration: TimeInterval) -> [MeetingNemotronSpeakerSegment] {
        for slot in self.openFrames.indices {
            if let start = self.openFrames[slot] { self.close(slot: slot, start: start, end: self.frames) }
        }
        return self.snapshot(duration: duration)
    }

    func validate(speakerCount: Int, frameCount: Int) throws {
        guard self.openFrames.count == speakerCount, self.frames == frameCount, frameCount >= 0,
              self.openFrames.allSatisfy({ $0.map { (0...frameCount).contains($0) } ?? true }),
              self.segments.count <= 250_000,
              self.segments.allSatisfy({ (0..<speakerCount).contains($0.slot) && $0.start >= 0
                  && $0.start <= frameCount && $0.end >= $0.start
                  && $0.end <= frameCount && $0.end - $0.start >= 20 }) else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
    }
}
