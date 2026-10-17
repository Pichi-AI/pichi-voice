// Adapted from FluidInference/FluidAudio 82eb4c1e0ab67e1c7d8de5092aa42a8f74cbd7b8.
// Apache-2.0. See Resources/Notices/FluidAudio-Nemotron3.txt.
// Changes: app isolation, local-only loading, joined cancellation, bounded streaming snapshots.
#if arch(arm64)
import FluidAudio
import Accelerate
import Foundation

/// Streaming 8-speaker diarizer backed by NVIDIA's Nemotron 3 Diarization.
///
/// Processes audio in fixed 80 ms-frame chunks through the CoreML forward pass and applies
/// NeMo's async speaker-cache/FIFO update host-side. Output is per-frame speaker activity
/// probability at 10 ms resolution, speaker slots ordered by first arrival.
///
/// - Important: This class is **not** thread-safe.
public nonisolated final class Nemotron3Diarizer {

    public let config: Nemotron3Config
    private let models: Nemotron3Models
    private let updater: Nemotron3StateUpdater
    private var state: Nemotron3StreamingState
    private let logger = AppLogger(category: "Nemotron3Diarizer")
    /// Snapshot once per diarizer. Diagnostic settings never change a running attempt.
    private let detailedProfileEnabled: Bool
    private var profileSummaryEmitted = false

    // Streaming (audio-in) state - see `appendAudio`.
    private var frontend: Nemotron3StreamingFrontend
    private var streamFinished = false
    /// 10 ms output frames emitted so far by the streaming path.
    public private(set) var streamedFrameCount = 0

    /// Monotonic active wall time, excluding gaps between public calls. Streaming
    /// counters/timers are opt-in; processComplete retains its existing always-on profile.
    /// Exclusive top-level stages are append, mel, chunkSlice, inference, stateUpdate,
    /// and outputAppend. Inference contains inputPrep + predict + readback; inputPrep
    /// contains projection + packing; predict contains first + retry prediction.
    /// finishFlush is an inclusive subset of totalSeconds, not another additive stage.
    /// This is host-observed latency, not GPU device execution/utilization time.
    public struct PipelineProfile: Sendable, Encodable {
        public var appendSeconds: Double = 0
        public var melSeconds: Double = 0
        public var chunkSliceSeconds: Double = 0
        public var inferenceSeconds: Double = 0
        public var inputPrepSeconds: Double = 0
        public var predictSeconds: Double = 0
        public var readbackSeconds: Double = 0
        public var projectionSeconds: Double = 0
        public var packingSeconds: Double = 0
        public var firstPredictionSeconds: Double = 0
        public var retryPredictionSeconds: Double = 0
        public var stateUpdateSeconds: Double = 0
        public var outputAppendSeconds: Double = 0
        public var totalSeconds: Double = 0
        public var finishFlushSeconds: Double = 0
        public var chunkCount: Int = 0
        public var failedChunkCount: Int = 0
        public var flushChunkCount: Int = 0
        public var appendCallCount: Int = 0
        public var bufferedCallCount: Int = 0
        public var inputSampleCount: Int = 0
        public var melFrameCount: Int = 0
        public var outputFrameCount: Int = 0
        public var restoredSampleCursor: Int = 0
        public var restoredFrameCursor: Int = 0
        public var backingFallbackCount: Int = 0
        public var detailedRowsEmitted: Int = 0
        public var detailedRowsSuppressed: Int = 0
        /// Chunks skipped by VAD gating (no speech in the chunk's core window).
        public var skippedChunks: Int = 0

        /// Limit diagnostic output without retaining per-chunk samples in memory.
        /// Aggregate counters continue over the entire stream after the row limit.
        mutating func admitChunkRow() -> Bool {
            guard detailedRowsEmitted < 2_000 else {
                detailedRowsSuppressed += 1
                return false
            }
            detailedRowsEmitted += 1
            return true
        }

        mutating func add(_ output: Nemotron3Models.Output) {
            inputPrepSeconds += output.inputPrepSeconds
            predictSeconds += output.predictSeconds
            readbackSeconds += output.readbackSeconds
            projectionSeconds += output.projectionSeconds
            packingSeconds += output.packingSeconds
            firstPredictionSeconds += output.firstPredictionSeconds
            retryPredictionSeconds += output.retryPredictionSeconds
            backingFallbackCount += output.backingFallbackCount
        }
    }

    /// Streaming is cumulative since reset/restore when detailed profiling is enabled.
    /// Reset/restore clears diagnostic counters; they never enter an inference checkpoint.
    public private(set) var lastProfile = PipelineProfile()

    static func detailedProfileRequested(environment: [String: String]) -> Bool {
        environment["PICHI_MEETING_DETAILED_PROFILE"] == "1"
    }

    public init(config: Nemotron3Config, models: Nemotron3Models) {
        self.config = config
        self.models = models
        self.updater = Nemotron3StateUpdater(config: config, silenceEmbedding: models.silenceEmbedding)
        self.state = Nemotron3StreamingState(config: config)
        self.frontend = Nemotron3StreamingFrontend(config: config)
        self.detailedProfileEnabled = Self.detailedProfileRequested(environment: ProcessInfo.processInfo.environment)
    }

    public func reset() {
        // A caller's defer may reset after cancellation outside runChunks. Preserve a
        // bounded partial summary before dropping diagnostic counters, never model state.
        if detailedProfileEnabled, !profileSummaryEmitted, lastProfile.appendCallCount > 0 {
            emitProfile(event: "summary", outcome: "resetBeforeFinish")
        }
        state = Nemotron3StreamingState(config: config)
        frontend.reset()
        streamFinished = false
        streamedFrameCount = 0
        lastProfile = PipelineProfile()
        profileSummaryEmitted = false
    }

    /// Captured only between completed streaming steps. Model weights and scratch CoreML
    /// tensors are excluded; the complete host state and frontend tail remain exact.
    nonisolated struct StreamingSnapshot: Codable, Sendable {
        let configuration: Data
        let state: Nemotron3StreamingState
        let frontend: Nemotron3StreamingFrontend.Snapshot
        let streamedFrameCount: Int

        init(config: Nemotron3Config, state: Nemotron3StreamingState,
             frontend: Nemotron3StreamingFrontend, streamedFrameCount: Int) throws {
            self.configuration = try Self.configurationSignature(config)
            self.state = state
            self.frontend = frontend.snapshot()
            self.streamedFrameCount = streamedFrameCount
        }

        private static func configurationSignature(_ config: Nemotron3Config) throws -> Data {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(config)
        }

        func validate(config: Nemotron3Config, sampleCursor: Int) throws {
            guard self.configuration == (try Self.configurationSignature(config)),
                  self.state.spkcache.count == config.spkcacheLen * config.preEncoderDims,
                  self.state.spkcachePreds.count == config.spkcacheLen * config.numSpeakers,
                  self.state.fifo.count == config.fifoLen * config.preEncoderDims,
                  self.state.fifoPreds.count == config.fifoLen * config.numSpeakers,
                  (0...config.spkcacheLen).contains(self.state.spkcacheLength),
                  (0...config.fifoLen).contains(self.state.fifoLength),
                  self.state.spkcache.allSatisfy(\.isFinite),
                  self.state.fifo.allSatisfy(\.isFinite),
                  self.state.spkcachePreds.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  self.state.fifoPreds.allSatisfy({ $0.isFinite && (0...1).contains($0) }),
                  self.streamedFrameCount >= 0,
                  self.streamedFrameCount == self.frontend.nextCoreMel else {
                throw Nemotron3Error.invalidState("Incompatible streaming checkpoint")
            }
            try self.frontend.validate(config: config, sampleCursor: sampleCursor)
        }
    }

    func streamingSnapshot() throws -> StreamingSnapshot {
        guard !self.streamFinished else { throw Nemotron3Error.invalidState("Checkpoint after stream finish") }
        return try StreamingSnapshot(config: self.config, state: self.state, frontend: self.frontend,
                                     streamedFrameCount: self.streamedFrameCount)
    }

    func restoreStreamingSnapshot(_ snapshot: StreamingSnapshot, sampleCursor: Int) throws {
        try snapshot.validate(config: self.config, sampleCursor: sampleCursor)
        let restoredFrontend = try Nemotron3StreamingFrontend(config: self.config, snapshot: snapshot.frontend,
                                                              sampleCursor: sampleCursor)
        self.state = snapshot.state
        self.frontend = restoredFrontend
        self.streamedFrameCount = snapshot.streamedFrameCount
        self.streamFinished = false
        self.lastProfile = PipelineProfile()
        if self.detailedProfileEnabled {
            self.lastProfile.restoredSampleCursor = sampleCursor
            self.lastProfile.restoredFrameCursor = snapshot.streamedFrameCount
        }
        self.profileSummaryEmitted = false
    }

    /// Process a complete audio buffer (16 kHz mono) and return per-frame speaker
    /// probabilities at 10 ms resolution, [frames * 8] flattened.
    /// Process a complete audio buffer.
    ///
    /// - Parameters:
    ///   - audio: 16 kHz mono samples.
    ///   - speechMask: Optional per-10 ms-frame speech mask (e.g. from `VadManager`).
    ///     Chunks whose core window contains no `true` frame skip inference entirely and
    ///     emit zero probabilities; streaming state does not advance across them (the
    ///     skipped region behaves like a pause in the stream). Callers should pre-pad
    ///     speech regions (~1 s) to protect onsets/offsets.
    public func processComplete(
        _ audio: [Float], speechMask: [Bool]? = nil
    ) throws -> (probabilities: [Float], frameCount: Int) {
        reset()
        var profile = PipelineProfile()
        let t0 = ProcessInfo.processInfo.systemUptime

        var tStage = ProcessInfo.processInfo.systemUptime
        let mel = AudioMelSpectrogram()
        let (featSeq, featLength, featSeqLength) = mel.computeFlatTransposed(audio: audio)
        profile.melSeconds = ProcessInfo.processInfo.systemUptime - tStage
        profile.inputSampleCount = audio.count
        profile.melFrameCount = featLength

        var total = [Float]()
        total.reserveCapacity(featLength * config.numSpeakers)

        var loader = Nemotron3FeatureLoader(
            config: config, featSeq: featSeq, featLength: featLength, featSeqLength: featSeqLength)
        let sub = config.subsamplingFactor
        var coreStart = 0
        // Each chunk's prediction allocates IOSurface-backed output arrays; without a
        // per-iteration autorelease drain, long ANE-route runs exhaust the IOSurface
        // pool after a few thousand calls (issue #752 failure class).
        while try autoreleasepool(invoking: { () -> Bool in
            try Task.checkCancellation()
            tStage = ProcessInfo.processInfo.systemUptime
            guard let chunk = loader.next() else { return false }
            profile.chunkSliceSeconds += ProcessInfo.processInfo.systemUptime - tStage

            // VAD gate: emit zeros for speech-free chunks without running the model or
            // advancing state. Output frame count must match the normal path exactly.
            let coreEnd = min(coreStart + config.chunkLen * sub, featLength)
            if let speechMask {
                let lo = min(coreStart, speechMask.count)
                let hi = min(coreEnd, speechMask.count)
                let hasSpeech = lo < hi && speechMask[lo..<hi].contains(true)
                if !hasSpeech {
                    let lcEnc = (chunk.leftOffset + sub / 2) / sub
                    let rcEnc = (chunk.rightOffset + sub - 1) / sub
                    let encLen = (chunk.length + sub - 1) / sub
                    let chunkFrames = min(
                        max(encLen - lcEnc, 0), config.chunkEncFrames - lcEnc - rcEnc)
                    total.append(
                        contentsOf: repeatElement(
                            0, count: chunkFrames * config.upsampleFactor * config.numSpeakers))
                    profile.skippedChunks += 1
                    coreStart = coreEnd
                    return true
                }
            }
            coreStart = coreEnd

            tStage = ProcessInfo.processInfo.systemUptime
            let out =
                config.splitGraph
                ? try models.runSplit(
                    chunk: chunk.features, chunkLength: chunk.length, state: state, config: config,
                    detailedProfile: detailedProfileEnabled)
                : try models.run(
                    chunk: chunk.features, chunkLength: chunk.length, state: state, config: config,
                    detailedProfile: detailedProfileEnabled)
            profile.inferenceSeconds += ProcessInfo.processInfo.systemUptime - tStage
            profile.add(out)

            tStage = ProcessInfo.processInfo.systemUptime
            let result = try updater.update(
                state: &state,
                chunkEmbeddings: out.chunkEmbeddings,
                chunkEncLength: out.chunkLength,
                predictions: out.predictions,
                highResPredictions: out.highResPredictions,
                lc: (chunk.leftOffset + sub / 2) / sub,
                rc: (chunk.rightOffset + sub - 1) / sub
            )
            profile.stateUpdateSeconds += ProcessInfo.processInfo.systemUptime - tStage

            tStage = ProcessInfo.processInfo.systemUptime
            total.append(contentsOf: result.probabilities)
            profile.outputAppendSeconds += ProcessInfo.processInfo.systemUptime - tStage
            profile.chunkCount += 1
            return true
        }) {}

        // NeMo trims to ceil(mel_frames / output_subsampling_factor); output factor is 1 (10 ms).
        let outputFrames = min(featSeqLength, total.count / config.numSpeakers)
        profile.totalSeconds = ProcessInfo.processInfo.systemUptime - t0
        profile.outputFrameCount = outputFrames
        lastProfile = profile
        if detailedProfileEnabled { emitProfile(event: "batchSummary", outcome: "completed") }
        return (Array(total[0..<(outputFrames * config.numSpeakers)]), outputFrames)
    }

    // MARK: - Streaming (audio in)

    /// Buffer 16 kHz mono samples for the streaming path. Call `processBufferedAudio()`
    /// afterwards to run every chunk the buffered audio completes.
    ///
    /// The streaming path is frame-exact with `processComplete` on the same audio: mel
    /// frames are computed with their full STFT context and the chunk cadence mirrors
    /// `Nemotron3FeatureLoader`. A chunk runs once `latencySeconds` of audio past its
    /// start is available.
    public func appendAudio(_ samples: [Float]) {
        precondition(!streamFinished, "appendAudio after finishStream; call reset() first")
        let start = detailedProfileEnabled ? ProcessInfo.processInfo.systemUptime : 0
        frontend.append(samples)
        if detailedProfileEnabled {
            let duration = ProcessInfo.processInfo.systemUptime - start
            lastProfile.appendSeconds += duration
            lastProfile.totalSeconds += duration
            lastProfile.appendCallCount += 1
            lastProfile.inputSampleCount += samples.count
        }
    }

    /// Run every chunk the buffered audio completes and return their results in order.
    /// Each result covers `chunkSeconds` of audio at 10 ms per frame.
    public func processBufferedAudio() throws -> [Nemotron3ChunkResult] {
        do {
            return try runChunks(final: false)
        } catch {
            if detailedProfileEnabled {
                emitProfile(event: "summary", outcome: error is CancellationError ? "cancelled" : "failed")
            }
            throw error
        }
    }

    /// Flush the tail: pads the stream like `processComplete` does, runs the remaining
    /// (possibly short) chunks, and trims the output to the audio's exact frame count.
    /// The diarizer keeps its speaker state afterwards; call `reset()` before a new stream.
    public func finishStream() throws -> [Nemotron3ChunkResult] {
        guard !streamFinished else { return [] }
        streamFinished = true
        do {
            let results = try runChunks(final: true)
            if detailedProfileEnabled { emitProfile(event: "summary", outcome: "completed", final: true) }
            return results
        } catch {
            if detailedProfileEnabled {
                emitProfile(event: "summary", outcome: error is CancellationError ? "cancelled" : "failed", final: true)
            }
            throw error
        }
    }

    private func runChunks(final: Bool) throws -> [Nemotron3ChunkResult] {
        let start = detailedProfileEnabled ? ProcessInfo.processInfo.systemUptime : 0
        let previousTotal = lastProfile.totalSeconds
        if detailedProfileEnabled { lastProfile.bufferedCallCount += 1 }
        defer {
            if detailedProfileEnabled {
                let duration = ProcessInfo.processInfo.systemUptime - start
                lastProfile.totalSeconds = previousTotal + duration
                if final { lastProfile.finishFlushSeconds += duration }
            }
        }
        var results: [Nemotron3ChunkResult] = []
        while true {
            let chunk = frontend.nextChunk(final: final, measure: detailedProfileEnabled)
            if detailedProfileEnabled {
                lastProfile.melSeconds += frontend.lastProfile.melSeconds
                lastProfile.chunkSliceSeconds += frontend.lastProfile.chunkSliceSeconds
                lastProfile.melFrameCount = frontend.melFramesComputed
            }
            guard let chunk else { break }
            try Task.checkCancellation()
            var result = try autoreleasepool {
                try step(
                    chunkFeatures: chunk.features, chunkMelLength: chunk.length,
                    leftOffsetMel: chunk.leftOffset, rightOffsetMel: chunk.rightOffset)
            }
            // Trim the tail chunk to the audio's exact 10 ms frame count (mirrors
            // `processComplete`'s ceil(mel_frames) trim).
            let outputStart = detailedProfileEnabled ? ProcessInfo.processInfo.systemUptime : 0
            let remaining = frontend.melFramesComputed - streamedFrameCount
            if final, result.frameCount > remaining {
                let keep = max(remaining, 0)
                result = Nemotron3ChunkResult(
                    probabilities: Array(result.probabilities[0..<(keep * config.numSpeakers)]),
                    frameCount: keep, numSpeakers: config.numSpeakers)
            }
            streamedFrameCount += result.frameCount
            results.append(result)
            if detailedProfileEnabled {
                lastProfile.outputAppendSeconds += ProcessInfo.processInfo.systemUptime - outputStart
                lastProfile.outputFrameCount += result.frameCount
                if final { lastProfile.flushChunkCount += 1 }
                lastProfile.totalSeconds = previousTotal + ProcessInfo.processInfo.systemUptime - start
                if lastProfile.admitChunkRow() { emitProfile(event: "chunk", outcome: "completed", final: final) }
            }
        }
        return results
    }

    /// Run one streaming step from raw mel features.
    ///
    /// - Parameters:
    ///   - chunkFeatures: Mel features [frames * 128] for lc+core+rc mel frames.
    ///   - chunkMelLength: Valid mel frames in `chunkFeatures`.
    ///   - leftOffsetMel: Mel frames of left context included at the start.
    ///   - rightOffsetMel: Mel frames of right context included at the end.
    public func step(
        chunkFeatures: [Float],
        chunkMelLength: Int,
        leftOffsetMel: Int,
        rightOffsetMel: Int
    ) throws -> Nemotron3ChunkResult {
        let inferenceStart = detailedProfileEnabled ? ProcessInfo.processInfo.systemUptime : 0
        var inferenceCompleted = false
        defer {
            if detailedProfileEnabled, !inferenceCompleted {
                lastProfile.inferenceSeconds += ProcessInfo.processInfo.systemUptime - inferenceStart
                lastProfile.failedChunkCount += 1
            }
        }
        let out =
            config.splitGraph
            ? try models.runSplit(
                chunk: chunkFeatures, chunkLength: chunkMelLength, state: state, config: config,
                detailedProfile: detailedProfileEnabled)
            : try models.run(
                chunk: chunkFeatures, chunkLength: chunkMelLength, state: state, config: config,
                detailedProfile: detailedProfileEnabled)
        inferenceCompleted = true
        if detailedProfileEnabled {
            lastProfile.inferenceSeconds += ProcessInfo.processInfo.systemUptime - inferenceStart
            lastProfile.add(out)
        }
        let sub = config.subsamplingFactor
        let lcEnc = (leftOffsetMel + sub / 2) / sub  // round()
        let rcEnc = (rightOffsetMel + sub - 1) / sub  // ceil()
        let updateStart = detailedProfileEnabled ? ProcessInfo.processInfo.systemUptime : 0
        var updateCompleted = false
        defer {
            if detailedProfileEnabled {
                lastProfile.stateUpdateSeconds += ProcessInfo.processInfo.systemUptime - updateStart
                if !updateCompleted { lastProfile.failedChunkCount += 1 }
            }
        }
        let result = try updater.update(
            state: &state,
            chunkEmbeddings: out.chunkEmbeddings,
            chunkEncLength: out.chunkLength,
            predictions: out.predictions,
            highResPredictions: out.highResPredictions,
            lc: lcEnc,
            rc: rcEnc
        )
        updateCompleted = true
        if detailedProfileEnabled { lastProfile.chunkCount += 1 }
        return result
    }

    /// Fixed, numeric/categorical schema only. No transcript, speaker identity, path,
    /// audio samples, probabilities, embeddings or error descriptions enter these rows.
    private func emitProfile(event: String, outcome: String, final: Bool = false) {
        struct Row: Encodable {
            let nemotron3DetailedProfile: Int
            let event: String
            let outcome: String
            let final: Bool
            let uptimeSeconds: Double
            let inputSampleCursor: Int
            let outputFrameCursor: Int
            let melFrameCursor: Int
            let splitGraph: Bool
            let profile: PipelineProfile
        }
        let row = Row(nemotron3DetailedProfile: 1, event: event, outcome: outcome, final: final,
                      uptimeSeconds: ProcessInfo.processInfo.systemUptime,
                      inputSampleCursor: lastProfile.restoredSampleCursor + lastProfile.inputSampleCount,
                      outputFrameCursor: lastProfile.restoredFrameCursor + lastProfile.outputFrameCount,
                      melFrameCursor: lastProfile.melFrameCount,
                      splitGraph: config.splitGraph, profile: lastProfile)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        if let data = try? encoder.encode(row), let line = String(data: data, encoding: .utf8) {
            logger.info(line)
        }
        if event != "chunk" { profileSummaryEmitted = true }
    }

    /// Convert frame probabilities into arrival-ordered speaker segments.
    public static func segments(
        probabilities: [Float], frameCount: Int, numSpeakers: Int = 8,
        threshold: Float = 0.5, frameSeconds: Float = 0.01, minDurationSeconds: Float = 0.2
    ) -> [Nemotron3Segment] {
        var result: [Nemotron3Segment] = []
        for spk in 0..<numSpeakers {
            var start: Int? = nil
            for frame in 0...frameCount {
                let active = frame < frameCount && probabilities[frame * numSpeakers + spk] > threshold
                if active, start == nil {
                    start = frame
                } else if !active, let s0 = start {
                    let dur = Float(frame - s0) * frameSeconds
                    if dur >= minDurationSeconds {
                        result.append(
                            Nemotron3Segment(
                                speakerIndex: spk,
                                startSeconds: Float(s0) * frameSeconds,
                                endSeconds: Float(frame) * frameSeconds))
                    }
                    start = nil
                }
            }
        }
        return result.sorted { $0.startSeconds < $1.startSeconds }
    }
}

// MARK: - Feature Loader

/// Chunk iterator over a mel feature sequence, mirroring NeMo's `streaming_feat_loader`:
/// fixed core stride, left context of 0 (all shipped profiles), right context shrinking at
/// the tail so trailing audio is still emitted.
public nonisolated struct Nemotron3FeatureLoader {
    private let lcMel: Int
    private let rcMel: Int
    private let coreMel: Int
    private let melFeatures: Int
    private let capacityMel: Int

    private let featSeq: [Float]
    private let featLength: Int
    private let featSeqLength: Int

    private var startFeat = 0

    public init(config: Nemotron3Config, featSeq: [Float], featLength: Int, featSeqLength: Int) {
        self.lcMel = config.chunkLeftContext * config.subsamplingFactor
        self.rcMel = config.chunkRightContext * config.subsamplingFactor
        self.coreMel = config.chunkLen * config.subsamplingFactor
        self.melFeatures = config.melFeatures
        self.capacityMel = config.chunkMelFrames
        self.featSeq = featSeq
        self.featLength = featLength
        self.featSeqLength = featSeqLength
    }

    public mutating func next() -> (features: [Float], length: Int, leftOffset: Int, rightOffset: Int)? {
        guard startFeat < featLength else { return nil }
        let leftOffset = min(lcMel, startFeat)
        let endFeat = min(startFeat + coreMel, featLength)
        let rightOffset = min(rcMel, featLength - endFeat)

        let startIdx = (startFeat - leftOffset) * melFeatures
        let endIdx = (endFeat + rightOffset) * melFeatures
        var features = Array(featSeq[startIdx..<endIdx])
        // Zero-pad to the model's fixed mel capacity.
        if features.count < capacityMel * melFeatures {
            features.append(contentsOf: repeatElement(0, count: capacityMel * melFeatures - features.count))
        }
        let frames = endFeat + rightOffset - (startFeat - leftOffset)
        let length = max(min(featSeqLength - startFeat + leftOffset, frames), 0)

        startFeat = endFeat
        return (features, length, leftOffset, rightOffset)
    }
}

// MARK: - Streaming Frontend

/// Audio-in front end for the streaming path: incremental mel extraction that is
/// frame-exact with center-padded batch extraction, plus the chunk cadence of
/// `Nemotron3FeatureLoader`. Model-free so the cadence and framing are unit-testable.
nonisolated struct Nemotron3StreamingFrontend {
    private let config: Nemotron3Config
    /// Pre-emphasis is applied here, before padding, so the extractor runs without it.
    private let mel = AudioMelSpectrogram(preemph: 0)
    private let preemph = Float(0.97)

    private var audio: [Float] = []
    /// Absolute sample index of `audio[0]`.
    private var audioStart = 0
    private var samplesReceived = 0

    private var melCache: [Float] = []
    /// Absolute mel-frame index of `melCache`'s first frame.
    private var melCacheStart = 0
    private(set) var melFramesComputed = 0
    private var nextCoreMel = 0
    /// Only the latest call, never accumulated or serialized in the exact checkpoint.
    struct Profile: Equatable {
        var melSeconds: Double = 0
        var chunkSliceSeconds: Double = 0
    }
    private(set) var lastProfile = Profile()

    init(config: Nemotron3Config) {
        self.config = config
    }

    /// Audio and mel retain only the unfinished chunk's bounded context. The absolute
    /// cursors are needed for pre-emphasis, STFT centering and the next model chunk.
    nonisolated struct Snapshot: Codable, Sendable {
        let audio: [Float]
        let audioStart: Int
        let samplesReceived: Int
        let melCache: [Float]
        let melCacheStart: Int
        let melFramesComputed: Int
        let nextCoreMel: Int

        private enum CodingKeys: String, CodingKey {
            case audio, audioStart, samplesReceived, melCache, melCacheStart, melFramesComputed, nextCoreMel
        }

        init(frontend: Nemotron3StreamingFrontend) {
            self.audio = frontend.audio
            self.audioStart = frontend.audioStart
            self.samplesReceived = frontend.samplesReceived
            self.melCache = frontend.melCache
            self.melCacheStart = frontend.melCacheStart
            self.melFramesComputed = frontend.melFramesComputed
            self.nextCoreMel = frontend.nextCoreMel
        }

        init(from decoder: Decoder) throws {
            guard let config = decoder.userInfo[Nemotron3StreamingState.checkpointConfigurationKey] as? Nemotron3Config else {
                throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath,
                                                        debugDescription: "Missing checkpoint configuration"))
            }
            let container = try decoder.container(keyedBy: CodingKeys.self)
            self.audio = try MeetingDiarizerCheckpointDecoding.array(Float.self, from: container, forKey: .audio,
                                                                    maximumCount: 16_000)
            self.melCache = try MeetingDiarizerCheckpointDecoding.array(Float.self, from: container, forKey: .melCache,
                                                                       maximumCount: (config.chunkMelFrames + 100) * config.melFeatures)
            self.audioStart = try container.decode(Int.self, forKey: .audioStart)
            self.samplesReceived = try container.decode(Int.self, forKey: .samplesReceived)
            self.melCacheStart = try container.decode(Int.self, forKey: .melCacheStart)
            self.melFramesComputed = try container.decode(Int.self, forKey: .melFramesComputed)
            self.nextCoreMel = try container.decode(Int.self, forKey: .nextCoreMel)
        }

        func validate(config: Nemotron3Config, sampleCursor: Int) throws {
            let half = AudioMelSpectrogram(preemph: 0).nFFT / 2
            let expectedFrames = sampleCursor >= half ? (sampleCursor - half) / 160 + 1 : 0
            let lcMel = config.chunkLeftContext * config.subsamplingFactor
            let maximumPendingFrames = config.chunkMelFrames + 100
            guard sampleCursor >= 0, self.samplesReceived == sampleCursor,
                  (0...sampleCursor).contains(self.audioStart),
                  self.audio.count == sampleCursor - self.audioStart, self.audio.count <= 16_000,
                  self.melFramesComputed == expectedFrames,
                  (0...expectedFrames).contains(self.nextCoreMel),
                  self.nextCoreMel % (config.chunkLen * config.subsamplingFactor) == 0,
                  self.melCacheStart == max(0, self.nextCoreMel - lcMel),
                  self.melCacheStart <= self.melFramesComputed,
                  self.melFramesComputed - self.melCacheStart <= maximumPendingFrames,
                  self.melCache.count == (self.melFramesComputed - self.melCacheStart) * config.melFeatures,
                  self.audio.allSatisfy(\.isFinite), self.melCache.allSatisfy(\.isFinite) else {
                throw Nemotron3Error.invalidState("Invalid streaming frontend checkpoint")
            }
            // Require exactly the history retained by computeMel, rather than accepting
            // a shorter finite tail that would silently alter the resumed STFT features.
            let expectedAudioStart = min(max(0, expectedFrames * 160 - half - 1), sampleCursor)
            guard self.audioStart == expectedAudioStart else {
                throw Nemotron3Error.invalidState("Incomplete streaming frontend history")
            }
        }
    }

    func snapshot() -> Snapshot {
        Snapshot(frontend: self)
    }

    init(config: Nemotron3Config, snapshot: Snapshot, sampleCursor: Int) throws {
        try snapshot.validate(config: config, sampleCursor: sampleCursor)
        self.config = config
        self.audio = snapshot.audio
        self.audioStart = snapshot.audioStart
        self.samplesReceived = snapshot.samplesReceived
        self.melCache = snapshot.melCache
        self.melCacheStart = snapshot.melCacheStart
        self.melFramesComputed = snapshot.melFramesComputed
        self.nextCoreMel = snapshot.nextCoreMel
    }

    mutating func reset() {
        audio.removeAll(keepingCapacity: true)
        audioStart = 0
        samplesReceived = 0
        melCache.removeAll(keepingCapacity: true)
        melCacheStart = 0
        melFramesComputed = 0
        nextCoreMel = 0
        lastProfile = Profile()
    }

    mutating func append(_ samples: [Float]) {
        audio.append(contentsOf: samples)
        samplesReceived += samples.count
    }

    /// The next chunk in `Nemotron3FeatureLoader` layout, or nil when the buffered audio
    /// does not complete one. With `final`, the stream is right-padded like center-mode
    /// extraction and the trailing (short) chunks are emitted.
    mutating func nextChunk(
        final: Bool, measure: Bool = false
    ) -> (features: [Float], length: Int, leftOffset: Int, rightOffset: Int)? {
        let melStart = measure ? ProcessInfo.processInfo.systemUptime : 0
        computeMel(final: final)
        let sliceStart = measure ? ProcessInfo.processInfo.systemUptime : 0
        if measure { lastProfile.melSeconds = sliceStart - melStart }
        else { lastProfile = Profile() }
        defer {
            if measure { lastProfile.chunkSliceSeconds = ProcessInfo.processInfo.systemUptime - sliceStart }
        }
        let sub = config.subsamplingFactor
        let lcMel = config.chunkLeftContext * sub
        let rcMel = config.chunkRightContext * sub
        let coreMel = config.chunkLen * sub
        let total = melFramesComputed
        let coreStart = nextCoreMel
        if final {
            guard coreStart < total else { return nil }
        } else {
            guard coreStart + coreMel + rcMel <= total else { return nil }
        }
        let leftOffset = min(lcMel, coreStart)
        let endFeat = min(coreStart + coreMel, total)
        let rightOffset = min(rcMel, total - endFeat)
        let frames = endFeat + rightOffset - (coreStart - leftOffset)

        let lo = (coreStart - leftOffset - melCacheStart) * config.melFeatures
        var features = Array(melCache[lo..<(lo + frames * config.melFeatures)])
        let capacity = config.chunkMelFrames * config.melFeatures
        if features.count < capacity {
            features.append(contentsOf: repeatElement(0, count: capacity - features.count))
        }

        nextCoreMel = endFeat
        let drop = nextCoreMel - lcMel - melCacheStart
        if drop > 0 {
            melCache.removeFirst(drop * config.melFeatures)
            melCacheStart += drop
        }
        return (features, frames, leftOffset, rightOffset)
    }

    /// Extend the mel cache with every frame whose STFT window is fully available;
    /// `final` zero-pads the right edge exactly like center-mode extraction.
    private mutating func computeMel(final: Bool) {
        let hop = 160
        let half = mel.nFFT / 2
        let received = samplesReceived
        let target: Int
        if final {
            // Center-padded frame count: 1 + (N + 2*half - win) / hop.
            target = received > 0 ? 1 + (received + 2 * half - 400) / hop : 0
        } else {
            target = received >= half ? (received - half) / hop + 1 : 0
        }
        let done = melFramesComputed
        guard target > done else { return }

        // Frame f is centered on sample f*hop; its window spans ±half around it. Like the
        // batch path, pre-emphasize the received samples only, so the zero padding on both
        // edges stays zero rather than picking up a -preemph * x[N-1] spike.
        let sliceStart = done * hop - half
        let sliceEnd = (target - 1) * hop + half
        var slice = [Float](repeating: 0, count: sliceEnd - sliceStart)
        let copyStart = max(sliceStart, 0)
        let copyEnd = min(sliceEnd, received)
        if copyEnd > copyStart {
            let count = copyEnd - copyStart
            let src = copyStart - audioStart
            slice.withUnsafeMutableBufferPointer { dst in
                audio.withUnsafeBufferPointer { buf in
                    let out = dst.baseAddress!.advanced(by: copyStart - sliceStart)
                    let input = buf.baseAddress!.advanced(by: src)
                    var negPreemph = -preemph
                    if src > 0 {
                        // y[n] = x[n] - preemph * x[n-1], seeded from the retained history sample.
                        vDSP_vsma(input - 1, 1, &negPreemph, input, 1, out, 1, vDSP_Length(count))
                    } else {
                        // Stream start: x[-1] is the zero pad.
                        out[0] = input[0]
                        if count > 1 {
                            vDSP_vsma(input, 1, &negPreemph, input + 1, 1, out + 1, 1, vDSP_Length(count - 1))
                        }
                    }
                }
            }
        }

        let (frames, _, _) = mel.computeFlatTransposed(
            audio: slice, paddingMode: .prePadded, expectedFrameCount: target - done)
        melCache.append(contentsOf: frames[0..<((target - done) * config.melFeatures)])
        melFramesComputed = target

        // Keep one sample of pre-emphasis history plus the half window behind the next frame.
        // In the final flush the last frames' windows extend past the received audio (right
        // zero-padding), so the trim point can exceed what is buffered: clamp to `received`.
        let keepFrom = min(max(0, target * hop - half - 1), received)
        if keepFrom > audioStart {
            audio.removeFirst(keepFrom - audioStart)
            audioStart = keepFrom
        }
    }
}
#endif
