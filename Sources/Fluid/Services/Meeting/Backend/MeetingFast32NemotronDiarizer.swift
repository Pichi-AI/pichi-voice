import Foundation
#if arch(arm64)

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
private final nonisolated class Fast32NemotronDiarizerSession: MeetingNemotronDiarizerSession, @unchecked Sendable {
    private var diarizer: Nemotron3Diarizer?
    private let speakerCount: Int

    init(config: Nemotron3Config, models: Nemotron3Models) {
        self.diarizer = Nemotron3Diarizer(config: config, models: models)
        self.speakerCount = config.numSpeakers
    }

    func cleanup() { self.diarizer = nil }

    func diarize(source: any MeetingPCMReplaySource) async throws -> [MeetingNemotronSpeakerSegment] {
        guard let diarizer else { throw CancellationError() }
        diarizer.reset()
        defer { diarizer.reset() }
        var intervals = MeetingFast32SpeakerIntervals(speakerCount: self.speakerCount)
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
#endif

/// Kept independent of CoreML for tail, threshold, boundary and cancellation tests.
nonisolated struct MeetingFast32SpeakerIntervals {
    private var openFrames: [Int?]
    private var segments: [MeetingNemotronSpeakerSegment] = []
    private var frames = 0

    init(speakerCount: Int = 8) { self.openFrames = Array(repeating: nil, count: speakerCount) }

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
            self.segments.append(.init(slotIndex: slot, start: Double(start) / 100, end: Double(end) / 100))
        }
        self.openFrames[slot] = nil
    }

    mutating func finish(duration: TimeInterval) -> [MeetingNemotronSpeakerSegment] {
        for slot in self.openFrames.indices {
            if let start = self.openFrames[slot] { self.close(slot: slot, start: start, end: self.frames) }
        }
        return self.segments.compactMap {
            let end = min(duration, $0.end)
            guard end > $0.start else { return nil }
            return MeetingNemotronSpeakerSegment(slotIndex: $0.slotIndex, start: $0.start, end: end)
        }.sorted { $0.start == $1.start ? $0.slotIndex < $1.slotIndex : $0.start < $1.start }
    }
}
