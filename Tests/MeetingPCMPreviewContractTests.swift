import Foundation

// Minimal compile context for testing the actual protocol's existential dispatch and
// compatibility default, independently of the app, CoreML, audio and model weights.
nonisolated protocol MeetingIdlePreparedResource: Sendable {}
nonisolated struct ASRTranscriptionResult: Sendable { let text: String }
nonisolated struct ASRWordTiming: Sendable {}
nonisolated struct ASRSegmentTiming: Codable, Sendable {}
nonisolated struct MeetingOwnerVoiceProfileSnapshot: Sendable {}
nonisolated struct MeetingAnalysisEpochID: Hashable, Sendable {}
nonisolated struct MeetingBackendSpeakerActivity: Sendable {}
nonisolated struct MeetingSpeakerVoiceSamples: Sendable {}
nonisolated struct MeetingSpeakerVoiceProfile: Sendable {}
nonisolated struct MeetingMaterializedSpanSamples: Sendable {}
nonisolated struct MeetingNemotronModelArtifact: Sendable {}
nonisolated struct MeetingFinalProcessingConfiguration: Sendable { var speakerLabelsEnabled = false }
nonisolated struct MeetingPCMProgressiveWindow: Sendable {}
nonisolated struct MeetingStreamingPCMObservation: Sendable {}
nonisolated protocol MeetingPreparedStreamingPCMProcessing: Sendable {}
nonisolated struct MeetingPCMTranscriptBatch: Sendable { let text: String }
typealias MeetingAudioTrackID = UUID
nonisolated enum MeetingModelResidencyError: Error { case unsupportedProvider }
nonisolated enum MeetingParakeetNemotronRuntimeError: Error { case invalidPCMWindow }
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
private nonisolated struct ProgressiveRuntime: MeetingParakeetNemotronRunning {
    let legacy: LegacyRuntime
    var supportsProgressivePCMInput: Bool { true }
    func recognizePCM(window: MeetingPCMProgressiveWindow, offset: TimeInterval, trackID: UUID,
                      attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
                      preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingPCMTranscriptBatch {
        let result = try await legacy.recognizePCM(samples: [], offset: offset, trackID: trackID,
            attemptID: attemptID, configuration: configuration)
        if let preview { try await preview(result) }
        return result
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
        try require(!compatibility.supportsProgressivePCMInput, "An old injected runtime does not gain progressive support")
        do {
            _ = try await compatibility.recognizePCM(window: .init(), offset: 0, trackID: UUID(),
                attemptID: UUID(), configuration: .init(), preview: nil)
            throw NSError(domain: "UnexpectedProgressiveSuccess", code: 1)
        } catch MeetingPCMInputError.unsupportedRuntime { }
        try require(await calls.calls == 3, "Unsupported progressive input cannot call the legacy operation")
        print("PASS progressive compatibility fails closed")
        try require(!compatibility.supportsStreamingPCMProcessing, "Old runtimes must not claim a continuous speaker scope")
        do {
            try await compatibility.withPreparedStreamingPCM(trackID: UUID(), attemptID: UUID(), configuration: .init(),
                onProgress: { _ in await observations.increment() }, body: { _ in await calls.increment() })
            throw NSError(domain: "UnexpectedStreamingSuccess", code: 1)
        } catch MeetingPCMInputError.unsupportedRuntime { }
        try require(await calls.calls == 3, "Unsupported prepared streaming cannot enter the resource body")
        print("PASS streaming compatibility fails closed")
        let progressive: any MeetingParakeetNemotronRunning = ProgressiveRuntime(legacy: legacy)
        try require(progressive.supportsProgressivePCMInput, "The concrete runtime owns capability admission")
        let progressiveFinal = try await progressive.recognizePCM(window: .init(), offset: 0, trackID: UUID(),
            attemptID: UUID(), configuration: .init(), preview: { _ in await observations.increment() })
        try require(progressiveFinal.text == "synthetic-final", "Progressive existential dispatch preserves output")
        try require(await calls.calls == 4, "Progressive witness must run one operation")
        try require(await observations.calls == 2, "Progressive witness must publish its observation")
        print("PASS explicit existential progressive witness")
        print("6 PCM preview protocol contract tests passed")
    }
}
