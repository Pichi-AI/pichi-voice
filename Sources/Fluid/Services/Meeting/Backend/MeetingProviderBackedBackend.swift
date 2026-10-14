import Foundation

nonisolated enum MeetingBackendDiarizationPolicy: Sendable {
    case required
    case ifInstalled
    case disabled
}

/// Adds a registered TranscriptionProvider to the upstream materialization, coverage and assembly
/// path. Optional Nemotron contributes measured speaker evidence independently of the ASR model.
@MainActor
final class MeetingProviderBackedBackend: MeetingTranscriptionBackend {
    let descriptor: MeetingBackendDescriptor
    var echoVerdictProvider: (any MeetingUnitEchoVerdictProviding)? { MeetingTextOverlapEchoVerdictProvider() }
    private let providerModelID: String
    private let runtimeFactory: MeetingParakeetNemotronRuntimeFactory
    private let modelLocator: any MeetingNemotronModelLocating
    private let materializer: any MeetingEpochAudioMaterializing
    private var composite: MeetingParakeetNemotronBackend?

    init(
        descriptor: MeetingBackendDescriptor,
        providerModelID: String,
        runtimeFactory: @escaping MeetingParakeetNemotronRuntimeFactory,
        modelLocator: any MeetingNemotronModelLocating = MeetingNemotronModelLocator(),
        materializer: any MeetingEpochAudioMaterializing = MeetingEpochAudioMaterializer()
    ) {
        self.descriptor = descriptor
        self.providerModelID = providerModelID
        self.runtimeFactory = runtimeFactory
        self.modelLocator = modelLocator
        self.materializer = materializer
    }

    func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode) throws {
        try self.descriptor.validatePCMInput(configuration: configuration, mode: mode)
        guard configuration.asrModel == self.providerModelID else {
            throw MeetingProviderOptionsError.unsupportedASRModel(configuration.asrModel)
        }
        _ = try MeetingProviderOptions.resolve(configuration)
    }

    func makePCMRuntime(_ request: MeetingBackendRequest) throws -> any MeetingParakeetNemotronRunning {
        try self.descriptor.validatePCMInput(request)
        try self.validatePCMInput(configuration: request.configuration, mode: request.session.mode)
        return try self.runtimeFactory(request)
    }

    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan {
        guard request.configuration.asrModel == self.providerModelID else {
            throw MeetingProviderOptionsError.unsupportedASRModel(request.configuration.asrModel)
        }
        let policy: MeetingBackendDiarizationPolicy
        #if arch(arm64)
        policy = request.configuration.diarizationFingerprint.hasPrefix("unavailable:") ? .disabled : .ifInstalled
        #else
        policy = .disabled
        #endif
        let composite = MeetingParakeetNemotronBackend(
            runtimeFactory: self.runtimeFactory,
            modelLocator: self.modelLocator,
            materializer: self.materializer,
            descriptor: self.descriptor,
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
            throw MeetingBackendError.planDisagreesWithRequest(backend: self.descriptor.id, defect: .attemptIdentity)
        }
        defer { self.composite = nil }
        return try await composite.execute(plan: plan, manifest: manifest, progress: progress)
    }
}
