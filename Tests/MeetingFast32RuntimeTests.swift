import CoreML
import FluidAudio
import Foundation

@main
nonisolated struct MeetingFast32RuntimeTests {
    static func require(_ value: Bool, _ message: String) throws {
        guard value else { throw NSError(domain: "Fast32RuntimeTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }

    static func main() async throws {
        let config = Nemotron3Config.preset(named: "fast32-split-w8a8")!
        try require(config.splitGraph && config.packedFrames == 340 && config.chunkLen == 32, "Pinned split graph geometry")
        try require(MeetingFast32ComputePolicy.units(hasNeuralEngine: true) == .cpuAndNeuralEngine, "Prefer evaluated ANE route when available")
        try require(MeetingFast32ComputePolicy.units(hasNeuralEngine: false) == .cpuAndGPU, "A10X fallback preserves graph on CPU/GPU")
        var output = MeetingFast32SpeakerIntervals(speakerCount: 2)
        // Voice zero crosses a replay boundary; voice one overlaps and ends in the final tail.
        let first = (0..<30).flatMap { _ in [Float(0.9), Float(0.5)] }
        let second = (0..<30).flatMap { frame in [Float(frame < 10 ? 0.9 : 0), Float(0.9)] }
        try output.append(probabilities: first, frameCount: 30)
        try output.append(probabilities: second, frameCount: 30)
        let segments = output.finish(duration: 0.55)
        try require(segments == [.init(slotIndex: 0, start: 0, end: 0.4), .init(slotIndex: 1, start: 0.3, end: 0.55)], "Continuous slots, threshold, overlap and physical tail clipping")
        for bad in [[Float.nan], [Float.infinity], [Float(-0.1)], [Float(1.1)], []] {
            var invalid = MeetingFast32SpeakerIntervals(speakerCount: 1)
            do { try invalid.append(probabilities: bad, frameCount: 1); throw NSError(domain: "ExpectedRejection", code: 1) }
            catch MeetingParakeetNemotronRuntimeError.invalidPCMWindow { }
        }
        var short = MeetingFast32SpeakerIntervals(speakerCount: 1)
        try short.append(probabilities: Array(repeating: 1, count: 19), frameCount: 19)
        try require(short.finish(duration: 0.19).isEmpty, "Reject sub-200ms fragment")
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            var output = MeetingFast32SpeakerIntervals(speakerCount: 1)
            try output.append(probabilities: [1], frameCount: 1)
        }
        do { try await cancelled.value; throw NSError(domain: "ExpectedCancellation", code: 1) }
        catch is CancellationError { }

        // Compare model-free frontend chunk features to the pinned author's batch frontend.
        // Feed awkward, sub-second replay boundaries, including a final partial chunk.
        let samples = (0..<101_123).map { Float(sin(Double($0) * 0.027) * 0.4) }
        let mel = AudioMelSpectrogram()
        let (features, length, sequenceLength) = mel.computeFlatTransposed(audio: samples)
        var loader = Nemotron3FeatureLoader(config: config, featSeq: features, featLength: length, featSeqLength: sequenceLength)
        var expected: [([Float], Int)] = []
        while let chunk = loader.next() { expected.append((chunk.features, chunk.length)) }
        var frontend = Nemotron3StreamingFrontend(config: config)
        var actual: [([Float], Int)] = []
        for start in stride(from: 0, to: samples.count, by: 7_319) {
            frontend.append(Array(samples[start..<min(samples.count, start + 7_319)]))
            while let chunk = frontend.nextChunk(final: false) { actual.append((chunk.features, chunk.length)) }
        }
        while let chunk = frontend.nextChunk(final: true) { actual.append((chunk.features, chunk.length)) }
        try require(actual.count == expected.count && actual.count == 3, "Flush exactly all complete and partial chunks")
        for (actual, expected) in zip(actual, expected) {
            try require(actual.1 == expected.1 && actual.0.count == expected.0.count, "Streaming/batch feature shape parity")
            let delta = zip(actual.0, expected.0).map { abs($0 - $1) }.max() ?? 0
            try require(delta < 0.0002, "Streaming/batch feature values parity")
        }
        print("PASS fast32 geometry, segment continuity/overlap/tail, invalid outputs, short fragments, cancellation and model-free streaming parity")
    }
}
