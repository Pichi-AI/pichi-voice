import Foundation

// Minimal compile context for testing the actual protocol's existential dispatch and
// compatibility default, independently of the app, CoreML, audio and model weights.
nonisolated struct ASRTranscriptionResult: Sendable { let text: String }
nonisolated struct ASRWordTiming: Sendable {}
nonisolated struct MeetingAnalysisEpochID: Hashable, Sendable {}
nonisolated struct MeetingBackendSpeakerActivity: Sendable {}
nonisolated struct MeetingSpeakerVoiceSamples: Sendable {}
nonisolated struct MeetingSpeakerVoiceProfile: Sendable {}
nonisolated struct MeetingMaterializedSpanSamples: Sendable {}
nonisolated struct MeetingNemotronModelArtifact: Sendable {}
nonisolated struct MeetingFinalProcessingConfiguration: Sendable {}
nonisolated struct MeetingPCMTranscriptBatch: Sendable { let text: String }
typealias MeetingAudioTrackID = UUID
nonisolated enum MeetingModelResidencyError: Error { case unsupportedProvider }
nonisolated enum PichiLocalization { static func text(_ key: String) -> String { key } }
private enum Refusal: Error { case observer }
private actor Counter {
    private(set) var calls = 0
    func increment() { calls += 1 }
}
private nonisolated struct LegacyRuntime: MeetingParakeetNemotronRunning {
    let counter: Counter
    func recognizePCM(samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
                      configuration: MeetingFinalProcessingConfiguration) async throws -> MeetingPCMTranscriptBatch {
        await counter.increment(); return .init(text: "synthetic-final")
    }
    func withNemotronDiarization(artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult) async throws -> MeetingNemotronPhaseResult {
        throw MeetingModelResidencyError.unsupportedProvider
    }
    func withPreparedASR(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult) async throws -> MeetingParakeetPhaseResult {
        throw MeetingModelResidencyError.unsupportedProvider
    }
}
private nonisolated struct PreviewRuntime: MeetingParakeetNemotronRunning {
    let legacy: LegacyRuntime
    func recognizePCM(samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
                      configuration: MeetingFinalProcessingConfiguration) async throws -> MeetingPCMTranscriptBatch {
        try await legacy.recognizePCM(samples: samples, offset: offset, trackID: trackID,
                                     attemptID: attemptID, configuration: configuration)
    }
    func recognizePCM(samples: [Float], offset: TimeInterval, trackID: UUID, attemptID: UUID,
                      configuration: MeetingFinalProcessingConfiguration,
                      preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingPCMTranscriptBatch {
        let value = try await legacy.recognizePCM(samples: samples, offset: offset, trackID: trackID,
                                                 attemptID: attemptID, configuration: configuration)
        if let preview { try await preview(value) }
        return value
    }
    func withNemotronDiarization(artifact: MeetingNemotronModelArtifact,
        _ body: @escaping @Sendable (any MeetingNemotronDiarizerFactory) async throws -> MeetingNemotronPhaseResult) async throws -> MeetingNemotronPhaseResult {
        throw MeetingModelResidencyError.unsupportedProvider
    }
    func withPreparedASR(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
        body: @escaping @Sendable (any MeetingParakeetASRSession) async throws -> MeetingParakeetPhaseResult) async throws -> MeetingParakeetPhaseResult {
        throw MeetingModelResidencyError.unsupportedProvider
    }
}
@main
struct MeetingPCMPreviewContractTests {
    private static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw NSError(domain: "PCMPreviewContracts", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
    }
    static func main() async throws {
        let calls = Counter(); let observations = Counter()
        let legacy = LegacyRuntime(counter: calls)
        let compatibility: any MeetingParakeetNemotronRunning = legacy
        let final = try await compatibility.recognizePCM(samples: [0], offset: 0, trackID: UUID(), attemptID: UUID(),
            configuration: .init(), preview: { _ in await observations.increment() })
        try require(final.text == "synthetic-final", "Compatibility preserves the original final result")
        try require(await calls.calls == 1, "Compatibility must call the existing operation exactly once")
        try require(await observations.calls == 0, "A legacy fake must not invent an early canonical observation")
        print("PASS existing runtime compatibility")
        let extended: any MeetingParakeetNemotronRunning = PreviewRuntime(legacy: legacy)
        _ = try await extended.recognizePCM(samples: [0], offset: 0, trackID: UUID(), attemptID: UUID(),
            configuration: .init(), preview: { value in
                try require(value.text == "synthetic-final", "Observer receives the implementation's result")
                await observations.increment()
            })
        try require(await calls.calls == 2, "Explicit witness must run one operation")
        try require(await observations.calls == 1, "Existential dispatch must reach the explicit preview witness")
        print("PASS explicit existential preview witness")
        do {
            _ = try await extended.recognizePCM(samples: [0], offset: 0, trackID: UUID(), attemptID: UUID(),
                configuration: .init(), preview: { _ in throw Refusal.observer })
            throw NSError(domain: "UnexpectedObserverSuccess", code: 1)
        } catch Refusal.observer { }
        try require(await calls.calls == 3, "A refused observer must not trigger a second ASR operation")
        print("PASS observer refusal propagation")
        print("3 PCM preview protocol contract tests passed")
    }
}
