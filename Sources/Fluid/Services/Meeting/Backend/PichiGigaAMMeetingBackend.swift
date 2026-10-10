import Foundation

nonisolated enum MeetingBackendDiarizationPolicy: Sendable {
    case required
    case ifInstalled
    case disabled
}

/// Reuses upstream materialization, coverage validation and speaker/timing assembly.
/// GigaAM replaces only ASR; optional Nemotron retains its own measured speaker evidence.
@MainActor
final class PichiGigaAMMeetingBackend: MeetingTranscriptionBackend {
    static let descriptor = MeetingBackendDescriptor(
        id: .gigaam,
        version: "1",
        execution: .local,
        supportedLanguageCodes: ["ru"],
        supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
        supportedFinalPrecisions: [.word, .utterance],
        resultContract: .canonicalEvidence,
        knownLimits: [
            "GigaAM is a Russian recognition model; other languages require another selected model.",
            "Word times come from CTC token frames. Text without usable word timings remains an utterance.",
            "Automatic speaker separation requires an installed Nemotron model and Apple Silicon.",
            "Without diarization, speaker identities remain unknown; microphone/application source tracks remain distinct.",
        ],
        analysisSampleRate: 16_000
    )

    var descriptor: MeetingBackendDescriptor { Self.descriptor }
    private let runtimeFactory: MeetingParakeetNemotronRuntimeFactory
    private let modelLocator: any MeetingNemotronModelLocating
    private let materializer: any MeetingEpochAudioMaterializing
    private var composite: MeetingParakeetNemotronBackend?

    init(
        runtimeFactory: @escaping MeetingParakeetNemotronRuntimeFactory,
        modelLocator: any MeetingNemotronModelLocating = MeetingNemotronModelLocator(),
        materializer: any MeetingEpochAudioMaterializing = MeetingEpochAudioMaterializer()
    ) {
        self.runtimeFactory = runtimeFactory
        self.modelLocator = modelLocator
        self.materializer = materializer
    }

    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
        guard request.configuration.asrModel == PichiMeetingProviderFactory.gigaamModelID else {
            throw MeetingProviderOptionsError.unsupportedASRModel(request.configuration.asrModel)
        }
        let policy: MeetingBackendDiarizationPolicy
        #if arch(arm64)
        policy = request.configuration.diarizationFingerprint
            == PichiMeetingProviderFactory.transcriptOnlyDiarizationFingerprint ? .disabled : .ifInstalled
        #else
        policy = .disabled
        #endif
        let composite = MeetingParakeetNemotronBackend(
            runtimeFactory: self.runtimeFactory,
            modelLocator: self.modelLocator,
            materializer: self.materializer,
            descriptor: Self.descriptor,
            diarizationPolicy: policy
        )
        let plan = try composite.plan(request)
        self.composite = composite
        return plan
    }

    func execute(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest?,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingBackendOutcome {
        guard let composite else {
            throw MeetingBackendError.planDisagreesWithRequest(backend: .gigaam, defect: .attemptIdentity)
        }
        defer { self.composite = nil }
        return try await composite.execute(plan: plan, manifest: manifest, progress: progress)
    }
}
