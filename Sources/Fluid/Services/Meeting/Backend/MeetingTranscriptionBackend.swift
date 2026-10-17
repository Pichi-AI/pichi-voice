import Foundation
#if os(iOS)
import Darwin
#endif

// Stage A of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the contract that sits *beneath*
// the existing pipeline. `MeetingProcessingControlling` and `TranscriptionProvider` are unchanged;
// `MeetingProcessingPipeline` keeps owning selection, checkpoints and final publication and now
// dispatches the transcription work itself through one of these backends.
//
// Stage A deliberately ships only two dispatch shapes: the legacy compatibility wrapper (which
// returns today's `MeetingProcessingResult` unchanged) and validation of the canonical final
// evidence introduced here for Stage C. No unified provider adapter and no assembler exist yet.

/// Stable, string-backed backend identity. Compiled factories only — never a dynamic plugin name.
nonisolated struct MeetingBackendID: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    /// Compatibility/rollback backend for sessions that explicitly select the pre-composite path.
    static let legacyCompatibility = MeetingBackendID(rawValue: "legacy-compatibility-v1")

    /// Local Parakeet TDT v2 ASR + Nemotron-3 diarization composite.
    static let parakeetNemotron = MeetingBackendID(rawValue: "local-parakeet-tdt-v2-nemotron-3-v1")

    /// Single source of truth for new meeting-processing attempts. Keep explicit stored selections
    /// untouched; this value applies only when no preference has been recorded.
    static let productionDefault: MeetingBackendID = .parakeetNemotron

    var description: String {
        self.rawValue
    }
}

nonisolated enum MeetingBackendExecutionLocality: String, Codable, Sendable {
    case local
    case hosted
}

/// Which output shape a backend's `execute` returns. This is the dispatch discriminator: the
/// pipeline builds and hands over an analysis manifest only to canonical backends, and accepts
/// only the declared outcome shape back (plan §6, milestones A vs C2b2).
nonisolated enum MeetingBackendResultContract: String, Codable, Sendable {
    /// The unchanged in-pipeline workflow returns today's `MeetingProcessingResult` directly.
    /// It receives no manifest and does no sidecar work.
    case legacyResult
    /// Canonical backends receive the product-owned, validated `MeetingAnalysisManifest` before
    /// execute and return `MeetingCanonicalResultBundle`: final evidence plus per-span receipts.
    case canonicalEvidence
}

/// Identity/version, platform reach, execution locality, supported final precision, track topology
/// and the limits a caller must not assume away.
nonisolated enum MeetingDiarizationDependency: String, Hashable, Sendable {
    case speakerSeparation
    case voiceMatching
}

/// Recorded chunks and bounded in-memory input are separate admissions. A file executor is
/// never substituted for strict microphone PCM merely because its ASR provider accepts samples.
nonisolated enum MeetingBackendInputKind: String, Hashable, Sendable {
    case recordedChunks
    /// One microphone stream of bounded mono 16kHz windows, with canonical transcript assembly.
    case boundedMicrophonePCM
}

/// Capture privacy and deployment reach are separate from the ASR configuration identity.
/// `nil` physical identity covers desktop, Simulator and unresolved hardware; it does not
/// authorize extrapolating a measured failure to an entire chip or device generation.
nonisolated struct MeetingPCMAdmissionContext: Equatable, Sendable {
    let physicalDeviceModel: String?
    let operatingSystemVersion: String
    let piiRedactionEnabled: Bool

    static func current(piiRedactionEnabled: Bool) -> Self {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        var physicalDeviceModel: String?
        #if os(iOS) && !targetEnvironment(simulator)
        var system = utsname()
        if uname(&system) == 0 {
            physicalDeviceModel = withUnsafeBytes(of: system.machine) { bytes in
                String(decoding: bytes.prefix(while: { $0 != 0 }), as: UTF8.self)
            }
        }
        #endif
        return Self(physicalDeviceModel: physicalDeviceModel,
                    operatingSystemVersion: "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)",
                    piiRedactionEnabled: piiRedactionEnabled)
    }
}

/// One measured unsupported strict-input combination, owned by the registered backend.
/// Artifact identity prevents a CPU failure for one export from banning other exports.
nonisolated struct MeetingPCMAdmissionRestriction: Equatable, Sendable {
    let physicalDeviceModel: String
    let operatingSystemVersion: String
    let asrArtifactFingerprint: String
    let speakerLabelsEnabled: Bool
    let piiRedactionEnabled: Bool
    let modelDisplayName: String
    let alternativeModelDisplayName: String

    func matches(configuration: MeetingFinalProcessingConfiguration, context: MeetingPCMAdmissionContext) -> Bool {
        context.physicalDeviceModel == self.physicalDeviceModel
            && context.operatingSystemVersion == self.operatingSystemVersion
            && configuration.asrArtifactFingerprint == self.asrArtifactFingerprint
            && configuration.speakerLabelsEnabled == self.speakerLabelsEnabled
            && context.piiRedactionEnabled == self.piiRedactionEnabled
    }

    var localizedDescription: String {
        PichiLocalization.format(
            "%@ with speaker identification and sensitive data redaction can be stopped by the system in the background on this iPad. For recording without saving audio, select %@ in Voice Engine settings.",
            self.modelDisplayName, self.alternativeModelDisplayName
        )
    }
}

/// Registered scheduling preference for display observations inside one physical
/// attribution window. It changes cadence, never PCM ownership or the budget.
nonisolated struct MeetingPCMObservationPolicy: Equatable, Sendable {
    let initialSeconds: Double
    let intervalSeconds: Double
}

nonisolated struct MeetingBackendDescriptor: Equatable, Sendable {
    let id: MeetingBackendID
    let version: String
    let execution: MeetingBackendExecutionLocality
    let supportedLanguageCodes: Set<String>
    let supportedTrackKinds: Set<MeetingAudioTrackKind>
    /// Which final text-unit precisions this backend is allowed to emit. A backend that only
    /// produces utterances must not be read as producing words: no synthetic word times exist.
    let supportedFinalPrecisions: Set<MeetingTextUnitPrecision>
    /// The declared output contract. The pipeline enforces it in both directions: a legacy
    /// backend never receives a manifest, and an outcome case other than the declared one is a
    /// typed failure, never a silent reinterpretation.
    let resultContract: MeetingBackendResultContract
    let supportedInputs: Set<MeetingBackendInputKind>
    let pcmAdmissionRestrictions: [MeetingPCMAdmissionRestriction]
    let pcmObservationPolicy: MeetingPCMObservationPolicy?
    /// Human-readable, non-exhaustive statements of what this backend cannot guarantee.
    let knownLimits: [String]
    /// The backend's real analysis/resample rate, when it has one. The pipeline records it on the
    /// analysis manifest; `nil` leaves sample-rate conversion explicitly unknown (plan §3).
    let analysisSampleRate: Double?
    let diarizationDependencies: Set<MeetingDiarizationDependency>
    let allowsTranscriptOnlyOnUnsupportedHardware: Bool

    init(
        id: MeetingBackendID,
        version: String,
        execution: MeetingBackendExecutionLocality,
        supportedLanguageCodes: Set<String>,
        supportedTrackKinds: Set<MeetingAudioTrackKind>,
        supportedFinalPrecisions: Set<MeetingTextUnitPrecision>,
        resultContract: MeetingBackendResultContract,
        knownLimits: [String],
        analysisSampleRate: Double? = nil,
        diarizationDependencies: Set<MeetingDiarizationDependency> = [],
        allowsTranscriptOnlyOnUnsupportedHardware: Bool = false,
        supportedInputs: Set<MeetingBackendInputKind> = [.recordedChunks],
        pcmAdmissionRestrictions: [MeetingPCMAdmissionRestriction] = [],
        pcmObservationPolicy: MeetingPCMObservationPolicy? = nil
    ) {
        self.id = id
        self.version = version
        self.execution = execution
        self.supportedLanguageCodes = supportedLanguageCodes
        self.supportedTrackKinds = supportedTrackKinds
        self.supportedFinalPrecisions = supportedFinalPrecisions
        self.resultContract = resultContract
        self.supportedInputs = supportedInputs
        self.pcmAdmissionRestrictions = pcmAdmissionRestrictions
        self.pcmObservationPolicy = pcmObservationPolicy
        self.knownLimits = knownLimits
        self.analysisSampleRate = analysisSampleRate
        self.diarizationDependencies = diarizationDependencies
        self.allowsTranscriptOnlyOnUnsupportedHardware = allowsTranscriptOnlyOnUnsupportedHardware
    }

    /// Pure admission: no runtime, artifact preparation, file reads or microphone access. The
    /// strict capture path has one source, so admitting an online two-source topology would lose
    /// a track rather than provide the file backend's semantics.
    func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode) throws {
        guard self.supportedInputs.contains(.boundedMicrophonePCM) else {
            throw MeetingBackendError.unsupportedInput(backend: self.id, input: .boundedMicrophonePCM)
        }
        guard self.resultContract == .canonicalEvidence else {
            throw MeetingBackendError.outcomeContractMismatch(backend: self.id, declared: self.resultContract)
        }
        guard self.analysisSampleRate == 16_000, !self.supportedFinalPrecisions.isEmpty else {
            throw MeetingBackendError.unsupportedInput(backend: self.id, input: .boundedMicrophonePCM)
        }
        if let policy = self.pcmObservationPolicy {
            guard policy.initialSeconds.isFinite, policy.intervalSeconds.isFinite,
                  (0.25...12).contains(policy.initialSeconds),
                  (0.25...12).contains(policy.intervalSeconds) else {
                throw MeetingBackendError.unsupportedInput(backend: self.id, input: .boundedMicrophonePCM)
            }
        }
        guard self.supportedLanguageCodes.contains(configuration.languageCode) else {
            throw MeetingBackendError.unsupportedLanguage(backend: self.id, languageCode: configuration.languageCode)
        }
        guard mode == .inRoom, self.supportedTrackKinds.contains(.microphone) else {
            throw MeetingBackendError.unsupportedTrackTopology(backend: self.id)
        }
    }

    func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode,
                          admissionContext: MeetingPCMAdmissionContext) throws {
        try self.validatePCMInput(configuration: configuration, mode: mode)
        if let restriction = self.pcmAdmissionRestrictions.first(where: { $0.matches(configuration: configuration, context: admissionContext) }) {
            throw MeetingBackendError.unsupportedPCMConfiguration(backend: self.id, restriction: restriction)
        }
    }

    func validatePCMInput(_ request: MeetingBackendRequest, admissionContext: MeetingPCMAdmissionContext? = nil) throws {
        try self.validatePCMInput(configuration: request.configuration, mode: request.session.mode)
        guard request.configuration.languageCode == request.session.languageCode else {
            throw MeetingBackendError.unsupportedLanguage(backend: self.id, languageCode: request.session.languageCode)
        }
        guard request.session.audioStorageMode == .memoryOnly,
              request.session.audioTracks.count <= 1,
              request.session.audioTracks.allSatisfy({ $0.kind == .microphone && $0.chunks.isEmpty }) else {
            throw MeetingBackendError.unsupportedTrackTopology(backend: self.id)
        }
        try self.validatePCMInput(configuration: request.configuration, mode: request.session.mode,
            admissionContext: admissionContext ?? .current(piiRedactionEnabled: request.session.piiRedactionEnabled == true))
    }
}

/// Immutable per-attempt input. No global settings reads and no arbitrary session-directory access
/// are granted beyond the recorded session's own directory.
///
/// `Equatable` is load-bearing, not a convenience: the host binds its injected capabilities to one
/// exact request value and compares the whole thing — session snapshot and configuration included —
/// rather than spot-checking a directory or a session identifier.
nonisolated struct MeetingBackendRequest: Equatable, Sendable {
    let attemptID: UUID
    let session: MeetingSession
    let sessionDirectory: URL
    let configuration: MeetingFinalProcessingConfiguration
    let privacyFingerprint: String?

    init(attemptID: UUID, session: MeetingSession, sessionDirectory: URL,
         configuration: MeetingFinalProcessingConfiguration, privacyFingerprint: String? = nil) {
        self.attemptID = attemptID; self.session = session; self.sessionDirectory = sessionDirectory
        self.configuration = configuration; self.privacyFingerprint = privacyFingerprint
    }
}

/// Immutable result of `plan(_:)`, produced before any model work. It also carries the scope that
/// returned evidence is validated against: a backend may not report text for a track or chunk that
/// was never planned.
nonisolated struct MeetingBackendPlan: Sendable {
    let backendID: MeetingBackendID
    let backendVersion: String
    let attemptID: UUID
    let request: MeetingBackendRequest
    let trackKindsByID: [MeetingAudioTrackID: MeetingAudioTrackKind]
    let chunkIDsByTrackID: [MeetingAudioTrackID: Set<MeetingAudioChunkID>]
    let declaredFinalPrecisions: Set<MeetingTextUnitPrecision>
    let resultContract: MeetingBackendResultContract

    /// Plans over the session's finalized chunks only; provisional chunks are not planned work.
    init(request: MeetingBackendRequest, descriptor: MeetingBackendDescriptor) {
        let plannedTracks = request.session.audioTracks.filter {
            descriptor.supportedTrackKinds.contains($0.kind)
        }
        self.backendID = descriptor.id
        self.backendVersion = descriptor.version
        self.attemptID = request.attemptID
        self.request = request
        self.trackKindsByID = Dictionary(
            plannedTracks.map { ($0.id, $0.kind) },
            uniquingKeysWith: { first, _ in first }
        )
        self.chunkIDsByTrackID = Dictionary(
            plannedTracks.map { track in
                (track.id, Set(track.chunks.filter { $0.finalizationState == .finalized }.map(\.id)))
            },
            uniquingKeysWith: { first, _ in first }
        )
        self.declaredFinalPrecisions = descriptor.supportedFinalPrecisions
        self.resultContract = descriptor.resultContract
    }

    /// `plan(_:)` is backend code, so what it returns is re-checked against the request the host
    /// froze and the descriptor the host selected — before `execute` runs and before any audio is
    /// read. Identity fields must match exactly; scope may narrow but never widen, so a plan can
    /// never name a track or chunk the caller did not hand in.
    func agreementDefect(
        with request: MeetingBackendRequest,
        descriptor: MeetingBackendDescriptor
    ) -> MeetingBackendPlanDefect? {
        guard self.backendID == descriptor.id else { return .backendIdentity }
        guard self.backendVersion == descriptor.version else { return .backendVersion }
        guard self.attemptID == request.attemptID else { return .attemptIdentity }
        guard self.request == request else { return .request }
        guard self.declaredFinalPrecisions.isSubset(of: descriptor.supportedFinalPrecisions) else {
            return .precisionScope
        }
        guard self.resultContract == descriptor.resultContract else { return .resultContract }

        let sessionTracks = Dictionary(
            request.session.audioTracks.map { ($0.id, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        for (trackID, kind) in self.trackKindsByID {
            guard let track = sessionTracks[trackID],
                  track.kind == kind,
                  descriptor.supportedTrackKinds.contains(kind)
            else { return .trackScope }
        }
        guard Set(self.chunkIDsByTrackID.keys) == Set(self.trackKindsByID.keys) else {
            return .chunkScope
        }
        for (trackID, chunkIDs) in self.chunkIDsByTrackID {
            guard let track = sessionTracks[trackID] else { return .chunkScope }
            // Provisional chunks are not planned work, so they are not a legal source either.
            let finalized = Set(track.chunks.filter { $0.finalizationState == .finalized }.map(\.id))
            guard chunkIDs.isSubset(of: finalized) else { return .chunkScope }
        }
        return nil
    }
}

/// Which part of a returned plan contradicted the host's request or the selected descriptor.
nonisolated enum MeetingBackendPlanDefect: String, Equatable, Sendable {
    case backendIdentity
    case backendVersion
    case attemptIdentity
    case request
    case trackScope
    case chunkScope
    case precisionScope
    case resultContract
}

/// What a canonical (`canonicalEvidence` contract) backend hands back: the final text evidence
/// plus the per-span coverage receipts the assembler reconciles against the analysis manifest.
/// Receipts are backend self-reports; they are not authoritative until the assembler tiles them
/// against the manifest (plan §4).
nonisolated struct MeetingCanonicalResultBundle: Equatable, Sendable {
    let evidence: MeetingFinalTranscriptEvidence
    let coverageReceipts: [MeetingSpanCoverageReceipt]
    /// Ephemeral confirmed identity only. Owner embeddings never enter Codable evidence.
    var confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken> = []
}

/// What a backend hands back.
///
/// `legacyCompatibility` is the explicit temporary Stage A path called out by the plan (§6, "A may
/// wrap the existing final times as an explicit temporary compatibility path"). It is not evidence:
/// it is today's already-assembled product result passing through unchanged. `canonicalEvidence`
/// is the canonical contract: the pipeline validates and assembles the bundle through the
/// product-owned `MeetingTranscriptAssembler` and persists its result sidecar before returning.
nonisolated enum MeetingBackendOutcome: Sendable {
    case legacyCompatibility(MeetingProcessingResult)
    case canonicalEvidence(MeetingCanonicalResultBundle)
}

/// Executes the legacy in-pipeline workflow. Owned by `MeetingProcessingPipeline` and injected, so
/// the legacy adapter can run the unchanged algorithm without reimplementing any part of it.
typealias MeetingLegacyBackendExecutor = @MainActor (
    MeetingBackendRequest,
    @escaping @MainActor (MeetingProcessingStage) -> Void
) async throws -> MeetingProcessingResult

/// Creates the composite backend's runtime for one attempt. Owned by `MeetingProcessingPipeline`
/// and bound to the exact frozen request — like the legacy executor, honouring a different request
/// would transcribe audio this call never authorized.
typealias MeetingParakeetNemotronRuntimeFactory = @MainActor (
    MeetingBackendRequest
) throws -> any MeetingParakeetNemotronRunning

/// Host-provided capabilities a registered factory may use. Stage A grants the legacy executor;
/// Stage E adds the composite runtime factory. The default factory throws: a context built without
/// it (tests of the legacy path) must never silently hand out a runtime.
@MainActor
struct MeetingBackendHostContext {
    let legacyExecutor: MeetingLegacyBackendExecutor
    let parakeetNemotronRuntimeFactory: MeetingParakeetNemotronRuntimeFactory

    init(
        legacyExecutor: @escaping MeetingLegacyBackendExecutor,
        parakeetNemotronRuntimeFactory: @escaping MeetingParakeetNemotronRuntimeFactory = { _ in
            throw MeetingBackendError.runtimeUnavailable(backend: .parakeetNemotron)
        }
    ) {
        self.legacyExecutor = legacyExecutor
        self.parakeetNemotronRuntimeFactory = parakeetNemotronRuntimeFactory
    }
}

@MainActor
protocol MeetingTranscriptionBackend: AnyObject {
    var descriptor: MeetingBackendDescriptor { get }
    /// A canonical backend explicitly opts into an echo-evidence source; unknown backends remain
    /// fail-closed. This avoids inferring signal capabilities from a model identifier.
    var echoVerdictProvider: (any MeetingUnitEchoVerdictProviding)? { get }

    /// Validates compatibility and freezes an immutable plan. Runs before any model load.
    func plan(_ request: MeetingBackendRequest) throws -> MeetingBackendPlan

    /// Pure strict-input validation, before any resource preparation. Implementations also
    /// validate their immutable provider options; the default rejects file-only backends.
    func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode) throws

    /// Additive context admission retains existing backend-specific validation overrides.
    func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode,
                          admissionContext: MeetingPCMAdmissionContext) throws

    /// The selected backend owns strict PCM dispatch through the same registered runtime. The
    /// host capability is bound to this exact request, as it is for the file executor.
    func makePCMRuntime(_ request: MeetingBackendRequest) throws -> any MeetingParakeetNemotronRunning

    /// `manifest` is the product-owned, already validated analysis manifest built from the frozen
    /// plan, present exactly when the descriptor declares the canonical evidence contract. Legacy
    /// backends always receive `nil` and must run exactly as before.
    func execute(
        plan: MeetingBackendPlan,
        manifest: MeetingAnalysisManifest?,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void
    ) async throws -> MeetingBackendOutcome
}

extension MeetingTranscriptionBackend {
    var echoVerdictProvider: (any MeetingUnitEchoVerdictProviding)? { nil }

    func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode) throws {
        throw MeetingBackendError.unsupportedInput(backend: self.descriptor.id, input: .boundedMicrophonePCM)
    }

    func validatePCMInput(configuration: MeetingFinalProcessingConfiguration, mode: MeetingCaptureMode,
                          admissionContext: MeetingPCMAdmissionContext) throws {
        try self.descriptor.validatePCMInput(configuration: configuration, mode: mode, admissionContext: admissionContext)
        try self.validatePCMInput(configuration: configuration, mode: mode)
    }

    func makePCMRuntime(_ request: MeetingBackendRequest) throws -> any MeetingParakeetNemotronRunning {
        throw MeetingBackendError.unsupportedInput(backend: self.descriptor.id, input: .boundedMicrophonePCM)
    }
}

nonisolated enum MeetingBackendError: LocalizedError, Equatable, Sendable {
    case unknownBackend(MeetingBackendID)
    case backendDescriptorMismatch(backend: MeetingBackendID)
    case unsupportedInput(backend: MeetingBackendID, input: MeetingBackendInputKind)
    case unsupportedPCMConfiguration(backend: MeetingBackendID, restriction: MeetingPCMAdmissionRestriction)
    /// A registered factory produced a backend whose descriptor claims a different identity than the
    /// one that was requested. Selection would otherwise be a lie: the caller asked for one backend
    /// and a different one would run, carrying its own limits and precisions.
    case backendIdentityMismatch(requested: MeetingBackendID, produced: MeetingBackendID)
    /// A backend invoked the host's legacy executor with a request other than the one the host froze
    /// for this call. Honouring it would transcribe audio this call never authorized.
    case legacyExecutorRequestMismatch(backend: MeetingBackendID)
    /// A backend asked the host for a runtime against a request other than the one the host froze
    /// for this call.
    case hostCapabilityRequestMismatch(backend: MeetingBackendID)
    /// The host context carries no runtime factory for this backend (a test context built only for
    /// the legacy path), so the capability cannot be handed out at all.
    case runtimeUnavailable(backend: MeetingBackendID)
    /// A backend's own plan contradicts the request or the descriptor it was selected under.
    case planDisagreesWithRequest(backend: MeetingBackendID, defect: MeetingBackendPlanDefect)
    case unsupportedLanguage(backend: MeetingBackendID, languageCode: String)
    case unsupportedTrackTopology(backend: MeetingBackendID)
    /// A backend's outcome case contradicts the result contract its descriptor declared — for
    /// example a legacy-contract backend returning canonical evidence. The pipeline never
    /// reinterprets one shape as the other.
    case outcomeContractMismatch(backend: MeetingBackendID, declared: MeetingBackendResultContract)

    var errorDescription: String? {
        switch self {
        case let .unknownBackend(id):
            return "Meeting transcription backend \"\(id.rawValue)\" is not available."
        case let .backendDescriptorMismatch(backend):
            return PichiLocalization.format("Meeting backend \"%@\" produced capabilities different from its registration.", backend.rawValue)
        case let .unsupportedInput(backend, input):
            return PichiLocalization.format("Meeting backend \"%@\" does not support %@ input.", backend.rawValue, input.rawValue)
        case let .unsupportedPCMConfiguration(_, restriction):
            return restriction.localizedDescription
        case let .backendIdentityMismatch(requested, produced):
            return "Meeting backend \"\(requested.rawValue)\" resolved to a backend identifying "
                + "itself as \"\(produced.rawValue)\"."
        case let .legacyExecutorRequestMismatch(backend):
            return "Meeting backend \"\(backend.rawValue)\" asked to process a different recording "
                + "than the one this attempt was given."
        case let .hostCapabilityRequestMismatch(backend):
            return "Meeting backend \"\(backend.rawValue)\" asked for a runtime against a different "
                + "recording than the one this attempt was given."
        case let .runtimeUnavailable(backend):
            return "Meeting backend \"\(backend.rawValue)\" has no runtime available in this context."
        case let .planDisagreesWithRequest(backend, defect):
            return "Meeting backend \"\(backend.rawValue)\" returned a plan that disagrees with "
                + "this attempt (\(defect.rawValue))."
        case let .unsupportedLanguage(backend, languageCode):
            return "Meeting backend \"\(backend.rawValue)\" cannot transcribe language \(languageCode)."
        case let .unsupportedTrackTopology(backend):
            return "Meeting backend \"\(backend.rawValue)\" cannot process this session's audio tracks."
        case let .outcomeContractMismatch(backend, declared):
            return "Meeting backend \"\(backend.rawValue)\" returned an outcome that does not match "
                + "its declared \(declared.rawValue) result contract."
        }
    }
}
