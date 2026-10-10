import Foundation

private nonisolated struct PichiPreparedMeetingASRSession: MeetingParakeetASRSession, @unchecked Sendable {
    let asrService: ASRService
    let provider: any TranscriptionProvider

    func transcribeWithTimings(
        _ samples: [Float]
    ) async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) {
        try await self.asrService.transcribeMeetingSamplesWithTimings(samples, provider: self.provider)
    }
}

/// ASR works on both supported Mac architectures. Existing Nemotron capabilities are reused on
/// Apple Silicon only, and their residency is drained before the pinned GigaAM provider loads.
final nonisolated class PichiGigaAMMeetingRuntime: MeetingParakeetNemotronRunning {
    private let asrServiceProvider: @MainActor () -> ASRService
    private let diarizationRuntime: MeetingParakeetNemotronRuntime

    init(
        asrServiceProvider: @escaping @MainActor () -> ASRService,
        modelLocator: any MeetingNemotronModelLocating = MeetingNemotronModelLocator()
    ) {
        self.asrServiceProvider = asrServiceProvider
        self.diarizationRuntime = MeetingParakeetNemotronRuntime(
            asrServiceProvider: asrServiceProvider,
            modelLocator: modelLocator
        )
    }

    func withNemotronDiarization(
        artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult
    ) async throws -> MeetingNemotronPhaseResult {
        try await self.diarizationRuntime.withNemotronDiarization(artifact: artifact, body)
    }

    func speakerVoiceProfiles(samples: [MeetingSpeakerVoiceSamples]) async throws -> [MeetingSpeakerVoiceProfile] {
        try await self.diarizationRuntime.speakerVoiceProfiles(samples: samples)
    }

    func withPreparedASR(
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult
    ) async throws -> MeetingParakeetPhaseResult {
        let asrService = await self.asrServiceProvider()
        return try await asrService.withPreparedMeetingASR(
            attemptID: attemptID,
            configuration: configuration
        ) { provider in
            let session = PichiPreparedMeetingASRSession(asrService: asrService, provider: provider)
            let work = Task.detached(priority: .userInitiated) { try await body(session) }
            return try await withTaskCancellationHandler {
                try await work.value
            } onCancel: {
                work.cancel()
            }
        }
    }
}
