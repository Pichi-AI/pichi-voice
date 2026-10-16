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
}

/// Adapter for the split graph's actual host projection and high-resolution output contract.
/// Shared orchestration continues to consume MeetingNemotronDiarizerFactory.
final nonisolated class Fast32NemotronDiarizerFactory: MeetingNemotronDiarizerFactory, @unchecked Sendable {
    private let config: Nemotron3Config
    private let models: Nemotron3Models
    private let lock = NSLock()
    private var sessions: [Fast32NemotronDiarizerSession] = []

    init(config: Nemotron3Config, models: Nemotron3Models) {
        self.config = config
        self.models = models
    }

    func makeDiarizer(epoch _: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession {
        try Task.checkCancellation()
        let session = Fast32NemotronDiarizerSession(config: self.config, models: self.models)
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
private final nonisolated class Fast32NemotronDiarizerSession: MeetingResumableNemotronDiarizerSession, @unchecked Sendable {
    private var diarizer: Nemotron3Diarizer?
    private let config: Nemotron3Config

    init(config: Nemotron3Config, models: Nemotron3Models) {
        self.diarizer = Nemotron3Diarizer(config: config, models: models)
        self.config = config
    }

    func cleanup() { self.diarizer = nil }

    func diarize(source: any MeetingPCMReplaySource) async throws -> [MeetingNemotronSpeakerSegment] {
        guard let diarizer else { throw CancellationError() }
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
        guard let diarizer else { throw CancellationError() }
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

    mutating func finish(duration: TimeInterval) -> [MeetingNemotronSpeakerSegment] {
        for slot in self.openFrames.indices {
            if let start = self.openFrames[slot] { self.close(slot: slot, start: start, end: self.frames) }
        }
        return self.segments.compactMap {
            let start = Double($0.start) / 100
            let end = min(duration, Double($0.end) / 100)
            guard end > start else { return nil }
            return MeetingNemotronSpeakerSegment(slotIndex: $0.slot, start: start, end: end)
        }.sorted { $0.start == $1.start ? $0.slotIndex < $1.slotIndex : $0.start < $1.start }
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
