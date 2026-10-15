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
nonisolated struct MeetingNemotronSpeakerSegment: Equatable, Sendable {
    let slotIndex: Int
    let start: TimeInterval
    let end: TimeInterval
}

/// One fresh Nemotron diarizer state for exactly one analysis epoch.
nonisolated protocol MeetingNemotronDiarizerSession: Sendable {
    /// 16kHz mono epoch audio -> finalized speaker segments. Implementations may block on CoreML
    /// and are always awaited from a background context.
    func diarize(samples: [Float]) async throws -> [MeetingNemotronSpeakerSegment]
}

/// Hands out per-epoch diarizers. Every call must return entirely fresh streaming state; model
/// weights may be shared between instances. Slots never carry across epochs (plan §3).
nonisolated protocol MeetingNemotronDiarizerFactory: Sendable {
    func makeDiarizer(epoch: MeetingAnalysisEpochID) async throws -> any MeetingNemotronDiarizerSession
}

/// The attempt's prepared Parakeet ASR session, valid only inside the meeting preparation scope.
nonisolated protocol MeetingParakeetASRSession: Sendable {
    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming])
}

nonisolated struct MeetingNemotronPhaseResult: Sendable {
    var activity: [MeetingBackendSpeakerActivity] = []
    var failures: [MeetingAnalysisEpochID: String] = [:]
    var voiceSamples: [MeetingSpeakerVoiceSamples] = []
    var voiceProfiles: [MeetingSpeakerVoiceProfile] = []
}

nonisolated struct MeetingParakeetEpochOutput: Sendable {
    let epochID: MeetingAnalysisEpochID
    let text: String
    let words: [ASRWordTiming]
    let sampleRate: Double
    let sampleCount: Int
    let spanSamples: [MeetingMaterializedSpanSamples]
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
/// one local meeting model is resident at a time
/// (plan §6 D/E isolation). Concrete phase result types are deliberate: a generic scoped-closure
/// witness across the app/test module boundary is not ABI-stable under MainActor-by-default.
protocol MeetingParakeetNemotronRunning: Sendable {
    nonisolated var supportsProgressivePCMInput: Bool { get }
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
    nonisolated var supportsProgressivePCMInput: Bool { false }
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
