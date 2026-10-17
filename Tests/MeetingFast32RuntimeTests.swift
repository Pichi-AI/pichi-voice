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
        try self.testCheckpointContinuation(config: config)
        print("PASS fast32 geometry, intervals, cancellation, frontend parity and exact checkpoint continuation with cache compression")
    }

    private struct SyntheticResult {
        let features: [[Float]]
        let probabilities: [Float]
        let state: Nemotron3StreamingState
        let segments: [MeetingNemotronSpeakerSegment]
        let checkpoint: Data?
    }

    /// Real frontend, real speaker-cache updater and interval compactor, with deterministic
    /// model outputs. No CoreML model/recording download or inference is needed.
    private static func syntheticRun(config: Nemotron3Config, samples: [Float], restoreAt: Int?) throws -> SyntheticResult {
        var frontend = Nemotron3StreamingFrontend(config: config)
        var state = Nemotron3StreamingState(config: config)
        let updater = Nemotron3StateUpdater(config: config, silenceEmbedding: Array(repeating: 0.125, count: 512))
        var intervals = MeetingFast32SpeakerIntervals(speakerCount: config.numSpeakers)
        var streamed = 0
        var featureTrace: [[Float]] = []
        var probabilities: [Float] = []
        var checkpointData: Data?

        func consume(_ chunk: (features: [Float], length: Int, leftOffset: Int, rightOffset: Int), final: Bool) throws {
            featureTrace.append(chunk.features)
            let seed = state.fifo.prefix(16).reduce(Float(0), +)
            let embeddings = (0..<(config.chunkEncFrames * config.preEncoderDims)).map { index in
                chunk.features[index % chunk.features.count] * 0.01 + seed * 0.001 + Float(index % 31) * 0.002
            }
            let predictions = (0..<(config.packedFrames * config.numSpeakers)).map { index -> Float in
                let slot = index % config.numSpeakers
                return slot == (index / config.numSpeakers / 12) % config.numSpeakers ? 0.91 : 0.07
            }
            let activeSlot = Int(abs(seed * 13)) % config.numSpeakers
            let highRes = (0..<(config.packedFrames * config.upsampleFactor * config.numSpeakers)).map { index -> Float in
                (index % config.numSpeakers == activeSlot) ? 0.93 : 0.04
            }
            let sub = config.subsamplingFactor
            var output = try updater.update(state: &state, chunkEmbeddings: embeddings,
                                            chunkEncLength: (chunk.length + sub - 1) / sub,
                                            predictions: predictions, highResPredictions: highRes,
                                            lc: (chunk.leftOffset + sub / 2) / sub,
                                            rc: (chunk.rightOffset + sub - 1) / sub)
            let remaining = frontend.melFramesComputed - streamed
            if final, output.frameCount > remaining {
                let keep = max(remaining, 0)
                output = .init(probabilities: Array(output.probabilities.prefix(keep * config.numSpeakers)),
                               frameCount: keep, numSpeakers: config.numSpeakers)
            }
            streamed += output.frameCount
            probabilities.append(contentsOf: output.probabilities)
            try intervals.append(probabilities: output.probabilities, frameCount: output.frameCount)
        }

        for start in stride(from: 0, to: samples.count, by: 16_000) {
            let end = min(samples.count, start + 16_000)
            frontend.append(Array(samples[start..<end]))
            while let chunk = frontend.nextChunk(final: false) { try consume(chunk, final: false) }
            if end == restoreAt {
                let snapshot = try Nemotron3Diarizer.StreamingSnapshot(config: config, state: state,
                                                                      frontend: frontend, streamedFrameCount: streamed)
                let payload = try MeetingFast32Checkpoint(sourceSampleCount: samples.count, sampleCursor: end,
                                                          diarizer: snapshot, intervals: intervals).encode(config: config)
                let restored = try MeetingFast32Checkpoint.decode(payload, config: config, sourceSampleCount: samples.count)
                frontend = try Nemotron3StreamingFrontend(config: config, snapshot: restored.diarizer.frontend,
                                                           sampleCursor: restored.sampleCursor)
                state = restored.diarizer.state
                streamed = restored.diarizer.streamedFrameCount
                intervals = restored.intervals
                checkpointData = payload
            }
        }
        while let chunk = frontend.nextChunk(final: true) { try consume(chunk, final: true) }
        return .init(features: featureTrace, probabilities: probabilities, state: state,
                     segments: intervals.finish(duration: Double(samples.count) / 16_000), checkpoint: checkpointData)
    }

    private static func testCheckpointContinuation(config: Nemotron3Config) throws {
        let samples = (0..<641_123).map { Float(sin(Double($0) * 0.027) * 0.4 + cos(Double($0) * 0.013) * 0.1) }
        let uninterrupted = try self.syntheticRun(config: config, samples: samples, restoreAt: nil)
        try require(uninterrupted.state.spkcacheCompressed, "Fixture crosses speaker-cache compression")
        var validPayload = Data()
        for cursor in [16_000, 80_000, 272_000, 528_000, samples.count] {
            let resumed = try self.syntheticRun(config: config, samples: samples, restoreAt: cursor)
            try require(resumed.features == uninterrupted.features, "Exact resumed frontend chunks at \(cursor)")
            try require(resumed.probabilities == uninterrupted.probabilities, "Exact resumed probabilities at \(cursor)")
            try require(resumed.state == uninterrupted.state, "Exact resumed FIFO/cache after compression at \(cursor)")
            try require(resumed.segments == uninterrupted.segments, "No duplicated/truncated resumed speaker intervals at \(cursor)")
            validPayload = resumed.checkpoint!
        }
        try require(validPayload.count < 2 * 1024 * 1024, "Bounded host/frontend snapshot")
        for payload in [Data(), Data(validPayload.prefix(validPayload.count / 2)),
                        Data(repeating: 0, count: MeetingFast32Checkpoint.maximumBytes + 1)] {
            do {
                _ = try MeetingFast32Checkpoint.decode(payload, config: config, sourceSampleCount: samples.count)
                throw NSError(domain: "ExpectedInvalidCheckpointRejection", code: 1)
            } catch let error as NSError where error.domain == "ExpectedInvalidCheckpointRejection" { throw error }
            catch { }
        }
        do {
            _ = try MeetingFast32Checkpoint.decode(validPayload, config: config, sourceSampleCount: samples.count + 1)
            throw NSError(domain: "ExpectedSourceMismatchRejection", code: 1)
        } catch Nemotron3Error.invalidState { }
        var differentConfig = config
        differentConfig.predScoreThreshold = 0.3
        do {
            _ = try MeetingFast32Checkpoint.decode(validPayload, config: differentConfig, sourceSampleCount: samples.count)
            throw NSError(domain: "ExpectedConfigMismatchRejection", code: 1)
        } catch Nemotron3Error.invalidState { }

        // Corrupt a same-size binary plist field to test schema-level validation as well
        // as decoding. Neither a malformed array nor a stale revision may be accepted.
        let original = try PropertyListSerialization.propertyList(from: validPayload, format: nil) as! [String: Any]
        for mutation in 0..<7 {
            var dictionary = original
            if mutation == 0 { dictionary["revision"] = "older-runtime" }
            if mutation == 1 { dictionary["sampleCursor"] = samples.count + 1 }
            if mutation == 2 {
                var diarizer = dictionary["diarizer"] as! [String: Any]
                var state = diarizer["state"] as! [String: Any]
                state["fifo"] = [Float(0)]
                diarizer["state"] = state
                dictionary["diarizer"] = diarizer
            }
            if mutation == 3 {
                var diarizer = dictionary["diarizer"] as! [String: Any]
                var frontend = diarizer["frontend"] as! [String: Any]
                var audio = frontend["audio"] as! [Any]
                audio[0] = Float.nan
                frontend["audio"] = audio
                diarizer["frontend"] = frontend
                dictionary["diarizer"] = diarizer
            }
            if mutation == 4 {
                var diarizer = dictionary["diarizer"] as! [String: Any]
                var state = diarizer["state"] as! [String: Any]
                state["fifo"] = Array(repeating: Float(0), count: config.fifoLen * config.preEncoderDims + 1)
                diarizer["state"] = state
                dictionary["diarizer"] = diarizer
            }
            if mutation == 5 {
                var intervals = dictionary["intervals"] as! [String: Any]
                intervals["openFrames"] = Array(repeating: 0, count: 9)
                dictionary["intervals"] = intervals
            }
            if mutation == 6 {
                var intervals = dictionary["intervals"] as! [String: Any]
                let one = ["slot": 0, "start": 0, "end": 20]
                intervals["segments"] = Array(repeating: one, count: 250_001)
                dictionary["intervals"] = intervals
            }
            let corrupted = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .binary, options: 0)
            do {
                _ = try MeetingFast32Checkpoint.decode(corrupted, config: config, sourceSampleCount: samples.count)
                throw NSError(domain: "ExpectedCorruptionRejection", code: 1)
            } catch Nemotron3Error.invalidState { }
            catch is DecodingError { }
        }
    }
}
