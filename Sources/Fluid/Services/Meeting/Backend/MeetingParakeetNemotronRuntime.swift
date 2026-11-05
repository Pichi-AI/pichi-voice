import Foundation

// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the narrowly scoped runtime
// capability the host injects into the composite backend. The backend owns orchestration —
// epoch order, materialization, unit construction, receipts; the runtime owns the model
// capabilities and nothing else. It cannot see the session store, arbitrary directories or global
// settings: the host binds it to the frozen request before the backend ever runs.
//
// Tests inject a fake implementation of `MeetingParakeetNemotronRunning`; nothing here reads the
// filesystem or touches CoreML by itself.

/// One speaker-active interval from a single Nemotron epoch run, in seconds from that epoch's
/// materialized audio start. Slot indices are Nemotron's own and are meaningful only inside the
/// epoch that produced them.
nonisolated struct MeetingNemotronSpeakerSegment: Codable, Equatable, Sendable {
    let slotIndex: Int
    let start: TimeInterval
    let end: TimeInterval
}

/// Read-only replay of the stopped recording. Audio remains owned by the capture archive;
/// callers decode bounded mono16k ranges and never materialize a whole meeting as Float PCM.
nonisolated protocol MeetingPCMReplaySource: Sendable {
    var totalSampleCount: Int { get }
    func readSamples(in range: Range<Int>) async throws -> [Float]
}

extension MeetingPCMReplaySource {
    /// Replay begins only after capture has joined. One model state receives every range,
    /// including ranges containing silence; neither speaker state nor time resets at a boundary.
    nonisolated func replay(_ consume: ([Float]) throws -> Void) async throws {
        let count = self.totalSampleCount
        guard count > 0 else { throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow }
        var offset = 0
        while offset < count {
            try Task.checkCancellation()
            let end = offset + min(16_000, count - offset)
            let samples = try await self.readSamples(in: offset..<end)
            guard samples.count == end - offset, samples.allSatisfy(\.isFinite) else {
                throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
            }
            try Task.checkCancellation()
            try consume(samples)
            offset = end
        }
        try Task.checkCancellation()
    }
}

/// One fresh Nemotron diarizer state for a complete track or one analysis epoch.
nonisolated protocol MeetingNemotronDiarizerSession: Sendable {
    /// 16kHz mono epoch audio -> finalized speaker segments. Implementations may block on CoreML
    /// and are always awaited from a background context.
    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment]
    /// Post-stop whole-track analysis with bounded decoded PCM and continuous speaker state.
    func diarize(source: any MeetingPCMReplaySource) async throws -> [MeetingNemotronSpeakerSegment]
}

extension MeetingNemotronDiarizerSession {
    nonisolated func diarize(source: any MeetingPCMReplaySource) async throws -> [MeetingNemotronSpeakerSegment] {
        // Preserve small injected fixtures without letting an old adapter accidentally
        // materialize an unbounded stopped recording. Production implements bounded replay.
        guard source.totalSampleCount > 0, source.totalSampleCount <= 320_000 else {
            throw MeetingPCMInputError.unsupportedRuntime
        }
        try Task.checkCancellation()
        let samples = try await source.readSamples(in: 0..<source.totalSampleCount)
        guard samples.count == source.totalSampleCount, samples.allSatisfy(\.isFinite) else {
            throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
        }
        try Task.checkCancellation()
        return try await self.diarize(samples: samples)
    }
}

/// Hands out per-epoch diarizers. Every call must return entirely fresh streaming state; model
/// weights may be shared between instances. Slots never carry across epochs (plan §3).
nonisolated protocol MeetingNemotronDiarizerFactory: Sendable {
    func makeDiarizer(epoch: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession
}

/// The attempt's prepared Parakeet ASR session, valid only inside the meeting preparation scope.
nonisolated protocol MeetingParakeetASRSession: Sendable {
    /// Optional growing-prefix work may be suppressed without deferring the sealed window.
    func allowsIntermediatePCMObservations() async -> Bool
    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming])
}

extension MeetingParakeetASRSession {
    nonisolated func allowsIntermediatePCMObservations() async -> Bool { true }
}

nonisolated struct MeetingNemotronPhaseResult: Sendable {
    var activity: [MeetingBackendSpeakerActivity] = []
    var failures: [MeetingAnalysisEpochID: String] = [:]
    var voiceSamples: [MeetingSpeakerVoiceSamples] = []
    var voiceProfiles: [MeetingSpeakerVoiceProfile] = []
    /// Optional identity rereads can fail while anonymous diarization/ASR remain usable.
    /// A complete competitor set is required before a full-evidence owner decision.
    var ownerEvidenceComplete = true
}

/// One bounded core whose provider could not supply usable word timing. Native segment
/// times remain native; an absent segmentation falls back only to this input core's range.
nonisolated struct MeetingUntimedASRChunk: Codable, Sendable {
    let sampleRange: Range<Int>
    let text: String
    let segmentTimings: [ASRSegmentTiming]
}

nonisolated struct MeetingParakeetEpochOutput: Sendable {
    let epochID: MeetingAnalysisEpochID
    let text: String
    let words: [ASRWordTiming]
    let segmentTimings: [ASRSegmentTiming]
    let sampleRate: Double
    let sampleCount: Int
    let spanSamples: [MeetingMaterializedSpanSamples]
    let untimedChunks: [MeetingUntimedASRChunk]

    init(epochID: MeetingAnalysisEpochID, text: String, words: [ASRWordTiming],
         segmentTimings: [ASRSegmentTiming] = [], sampleRate: Double, sampleCount: Int,
         spanSamples: [MeetingMaterializedSpanSamples], untimedChunks: [MeetingUntimedASRChunk] = []) {
        self.epochID = epochID
        self.text = text
        self.words = words
        self.segmentTimings = segmentTimings
        self.sampleRate = sampleRate
        self.sampleCount = sampleCount
        self.spanSamples = spanSamples
        self.untimedChunks = untimedChunks
    }
}

nonisolated struct MeetingParakeetPhaseResult: Sendable {
    var outputs: [MeetingParakeetEpochOutput] = []
    var failures: [MeetingAnalysisEpochID: String] = [:]
    /// Ownership transfers from a progressive ASR body to the subsequent speaker
    /// phase. Only that same physical window is retained, never another buffer.
    var boundedPCMSamples: [Float] = []
    /// Original consumed frame count when only an accepted prefix leaves ASR.
    /// The uncovered tail remains explicit without retaining a second PCM buffer.
    var boundedPCMSourceSampleCount: Int? = nil
}

/// The composite backend's runtime, one per attempt. `withNemotronDiarization` is the only owner
/// of Nemotron residency: weights load before the factory is handed out and are released before
/// it returns. `withPreparedASR` wraps the attempt's single `ASRService.withPreparedMeetingASR`
/// scope. Optional voice encoding runs between them. These phases never overlap, so at most
/// one local meeting model is resident at a time in the legacy offline route. The optional
/// prepared streaming scope deliberately retains one ASR and one speaker model while serializing
/// their native calls under the same outer attempt grant
/// (plan §6 D/E isolation). Concrete phase result types are deliberate: a generic scoped-closure
/// witness across the app/test module boundary is not ABI-stable under MainActor-by-default.
protocol MeetingParakeetNemotronRunning: Sendable {
    nonisolated func prepareIdleResources(configuration: MeetingFinalProcessingConfiguration) async throws -> (any MeetingIdlePreparedResource)?
    nonisolated func adoptIdleResources(_ resource: any MeetingIdlePreparedResource,
        configuration: MeetingFinalProcessingConfiguration) async throws
    nonisolated var supportsProgressivePCMInput: Bool { get }
    /// Optional continuous speaker processing. The caller owns one outer residency grant;
    /// the body must finish or cancel its joined worker before this resource scope returns.
    nonisolated var supportsStreamingPCMProcessing: Bool { get }
    nonisolated var supportsMultiTrackStreamingPCMProcessing: Bool { get }
    nonisolated func withPreparedStreamingPCM(
        trackID: MeetingAudioTrackID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        onProgress: @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void,
        body: @escaping @Sendable (any MeetingPreparedStreamingPCMProcessing) async throws -> Void
    ) async throws
    /// One prepared pair serves the bounded source set. Each source has its own acoustic
    /// state and clock; the caller joins all per-source commands before the body returns.
    nonisolated func withPreparedStreamingPCMTracks(
        trackIDs: [MeetingAudioTrackID], attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        onProgress: @escaping @Sendable (MeetingAudioTrackID, MeetingStreamingPCMObservation) async throws -> Void,
        body: @escaping @Sendable ([MeetingAudioTrackID: any MeetingPreparedStreamingPCMProcessing]) async throws -> Void
    ) async throws
    nonisolated var ownerVoiceProfileSnapshot: MeetingOwnerVoiceProfileSnapshot? { get }
    nonisolated func recognizePCM(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                                 trackID: MeetingAudioTrackID, attemptID: UUID,
                                 configuration: MeetingFinalProcessingConfiguration,
                                 preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingPCMTranscriptBatch
    nonisolated func recognizePCM(samples: [Float], offset: TimeInterval, trackID: MeetingAudioTrackID,
                                 attemptID: UUID, configuration: MeetingFinalProcessingConfiguration) async throws -> MeetingPCMTranscriptBatch
    /// A display-only speech observation after the ASR scope has drained, before attribution.
    /// The owner must apply privacy and generation checks; this batch is not a durable result.
    nonisolated func recognizePCM(samples: [Float], offset: TimeInterval, trackID: MeetingAudioTrackID,
                                 attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
                                 preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingPCMTranscriptBatch
    /// Capture is already stopped and ASR is drained. Reassign only speaker metadata on
    /// the accepted, privacy-protected transcript using one global recording analysis.
    nonisolated func diarizePCMRecording(
        source: any MeetingPCMReplaySource, transcript: MeetingPCMTranscriptBatch,
        trackID: MeetingAudioTrackID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration
    ) async throws -> MeetingPCMTranscriptBatch
    nonisolated func preparePCMResources(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration) async throws
    nonisolated func speakerVoiceProfiles(
        samples: [MeetingSpeakerVoiceSamples]
    ) async throws -> [MeetingSpeakerVoiceProfile]

    nonisolated func withNemotronDiarization(
        artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult

    nonisolated func withPreparedASR(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult
}

extension MeetingParakeetNemotronRunning {
    nonisolated func prepareIdleResources(configuration: MeetingFinalProcessingConfiguration) async throws -> (any MeetingIdlePreparedResource)? { nil }
    nonisolated func adoptIdleResources(_ resource: any MeetingIdlePreparedResource,
        configuration: MeetingFinalProcessingConfiguration) async throws { throw MeetingModelResidencyError.unsupportedProvider }
    nonisolated var supportsProgressivePCMInput: Bool { false }
    nonisolated var supportsStreamingPCMProcessing: Bool { false }
    nonisolated var supportsMultiTrackStreamingPCMProcessing: Bool { false }
    nonisolated func withPreparedStreamingPCM(
        trackID: MeetingAudioTrackID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        onProgress: @escaping @Sendable (MeetingStreamingPCMObservation) async throws -> Void,
        body: @escaping @Sendable (any MeetingPreparedStreamingPCMProcessing) async throws -> Void
    ) async throws {
        throw MeetingPCMInputError.unsupportedRuntime
    }
    nonisolated func withPreparedStreamingPCMTracks(
        trackIDs: [MeetingAudioTrackID], attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        onProgress: @escaping @Sendable (MeetingAudioTrackID, MeetingStreamingPCMObservation) async throws -> Void,
        body: @escaping @Sendable ([MeetingAudioTrackID: any MeetingPreparedStreamingPCMProcessing]) async throws -> Void
    ) async throws {
        // Existing injected and platform runtimes preserve their actual single-source
        // capability. A default implementation cannot silently discard a second track.
        guard trackIDs.count == 1, let trackID = trackIDs.first else {
            throw MeetingPCMInputError.unsupportedRuntime
        }
        try await self.withPreparedStreamingPCM(trackID: trackID, attemptID: attemptID,
            configuration: configuration, onProgress: { try await onProgress(trackID, $0) },
            body: { try await body([trackID: $0]) })
    }
    nonisolated var ownerVoiceProfileSnapshot: MeetingOwnerVoiceProfileSnapshot? { nil }

    nonisolated func recognizePCM(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                                 trackID: MeetingAudioTrackID, attemptID: UUID,
                                 configuration: MeetingFinalProcessingConfiguration,
                                 preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingPCMTranscriptBatch {
        throw MeetingPCMInputError.unsupportedRuntime
    }
    nonisolated func recognizePCM(samples: [Float], offset: TimeInterval, trackID: MeetingAudioTrackID,
                                 attemptID: UUID, configuration: MeetingFinalProcessingConfiguration) async throws -> MeetingPCMTranscriptBatch {
        throw MeetingPCMInputError.unsupportedRuntime
    }

    /// Existing injected runtimes keep their original final operation without claiming an
    /// early observation. Concrete adapters can implement the additive preview capability.
    nonisolated func recognizePCM(samples: [Float], offset: TimeInterval, trackID: MeetingAudioTrackID,
                                 attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
                                 preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingPCMTranscriptBatch {
        try await self.recognizePCM(samples: samples, offset: offset, trackID: trackID,
                                    attemptID: attemptID, configuration: configuration)
    }

    nonisolated func diarizePCMRecording(
        source: any MeetingPCMReplaySource, transcript: MeetingPCMTranscriptBatch,
        trackID: MeetingAudioTrackID, attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration
    ) async throws -> MeetingPCMTranscriptBatch {
        guard !configuration.speakerLabelsEnabled else { throw MeetingPCMInputError.unsupportedRuntime }
        return transcript
    }

    nonisolated func preparePCMResources(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration) async throws {
        throw MeetingModelResidencyError.unsupportedProvider
    }
    /// Existing injected runtimes without a voice encoder retain separate speaker identities.
    nonisolated func speakerVoiceProfiles(
        samples _: [MeetingSpeakerVoiceSamples]
    ) async throws -> [MeetingSpeakerVoiceProfile] { [] }
}

nonisolated enum MeetingPCMInputError: LocalizedError {
    case unsupportedRuntime
    var errorDescription: String? { PichiLocalization.text("The selected meeting runtime does not support in-memory audio.") }
}
