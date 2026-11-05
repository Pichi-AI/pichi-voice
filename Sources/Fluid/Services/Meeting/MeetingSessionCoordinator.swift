import Combine
import CoreMedia
import Darwin
import Foundation

enum MeetingCoordinatorState: Equatable {
    case idle
    case preparing(MeetingSessionID)
    case recording(MeetingSessionID)
    case recordingDegraded(MeetingSessionID)
    case stopping(MeetingSessionID)
    case processing(MeetingSessionID, MeetingProcessingStage)
    case completed(MeetingSessionID)
    case interrupted(MeetingSessionID)
    case failed(MeetingSessionID?, MeetingSessionFailure)
}

struct MeetingAudioActivityLease: Equatable, Sendable {
    var id: UUID
}

@MainActor
protocol MeetingAudioActivityArbitrating: AnyObject {
    func acquireMeetingCapture() async throws -> MeetingAudioActivityLease
    func release(_ lease: MeetingAudioActivityLease) async
}

/// Matches ASRService's exclusive-activity lease API so the arbiter can depend on a protocol
/// instead of the concrete service (enables fakes in arbiter tests).
@MainActor
protocol ASRActivityLeasing: AnyObject {
    func acquireExclusiveActivity(_ activity: ASRExclusiveActivity) throws -> ASRActivityLease
    func acquireForegroundActivity(_ activity: ASRExclusiveActivity) async throws -> ASRActivityLease
    func releaseExclusiveActivity(_ lease: ASRActivityLease)
    func prepareMeetingAudioHandoff(_ lease: ASRActivityLease) async throws
    func completeMeetingAudioHandback(_ lease: ASRActivityLease) async
}


extension ASRActivityLeasing {
    func acquireForegroundActivity(_ activity: ASRExclusiveActivity) async throws -> ASRActivityLease {
        try Task.checkCancellation()
        return try self.acquireExclusiveActivity(activity)
    }
}

@MainActor
final class AudioActivityArbiter: MeetingAudioActivityArbitrating {
    private let asrServiceProvider: @MainActor () throws -> any ASRActivityLeasing
    private var meetingLease: MeetingAudioActivityLease?
    private var sharedActivityLease: ASRActivityLease?
    private weak var activeASRService: (any ASRActivityLeasing)?
    private var releaseTask: Task<Void, Never>?
    private var releaseTaskLease: MeetingAudioActivityLease?

    init(asrServiceProvider: @escaping @MainActor () throws -> any ASRActivityLeasing) {
        self.asrServiceProvider = asrServiceProvider
    }

    func acquireMeetingCapture() async throws -> MeetingAudioActivityLease {
        guard self.meetingLease == nil else { throw MeetingCoordinatorError.recordingAlreadyActive }
        let asrService = try self.asrServiceProvider()
        let sharedLease = try await asrService.acquireForegroundActivity(.meeting)
        let lease = MeetingAudioActivityLease(id: UUID())
        self.activeASRService = asrService
        self.sharedActivityLease = sharedLease
        self.meetingLease = lease
        do {
            try await asrService.prepareMeetingAudioHandoff(sharedLease)
            try Task.checkCancellation()
            guard self.meetingLease == lease,
                  self.sharedActivityLease == sharedLease
            else { throw CancellationError() }
            return lease
        } catch {
            if self.meetingLease == lease, self.sharedActivityLease == sharedLease {
                // Rollback retains the ASR lease until every partially-started handoff
                // operation is drained; only then can dictation or another meeting enter.
                await asrService.completeMeetingAudioHandback(sharedLease)
                self.activeASRService = nil
                self.sharedActivityLease = nil
                self.meetingLease = nil
            }
            throw error
        }
    }

    func release(_ lease: MeetingAudioActivityLease) async {
        if self.releaseTaskLease == lease, let releaseTask = self.releaseTask {
            await releaseTask.value
            return
        }
        guard self.meetingLease == lease else { return }
        let sharedActivityLease = self.sharedActivityLease
        let asrService = self.activeASRService
        let releaseTask = Task { @MainActor in
            if let sharedActivityLease {
                await asrService?.completeMeetingAudioHandback(sharedActivityLease)
            }
        }
        self.releaseTaskLease = lease
        self.releaseTask = releaseTask
        await releaseTask.value
        guard self.releaseTaskLease == lease else { return }
        if self.meetingLease == lease, self.sharedActivityLease == sharedActivityLease {
            self.activeASRService = nil
            self.sharedActivityLease = nil
            self.meetingLease = nil
        }
        self.releaseTask = nil
        self.releaseTaskLease = nil
    }
}

@MainActor
final class MeetingSessionCoordinator: ObservableObject {
    @Published private(set) var state: MeetingCoordinatorState = .idle
    @Published private(set) var activeSession: MeetingSession?
    @Published private(set) var latestCompletedSession: MeetingSession?
    @Published private(set) var trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth] = [:]
    @Published private(set) var liveTranscript: MeetingLiveTranscriptSnapshot = .empty
    @Published private(set) var pendingSpeech: MeetingPendingSpeechSnapshot = .empty
    /// Advances when a retention sweep commits an audio deletion. History projections reload on
    /// it instead of running their own sweep; healing alone changes no stored manifest.
    @Published private(set) var retentionSweepRevision = 0
    /// When live captions last heard words in the current recording. Nil without live captions.
    private(set) var lastLiveSpeechAt: Date?

    /// Sustained application-audio silence, in seconds, before the silence watchdog degrades the session.
    private static let silenceWatchdogThresholdSeconds: TimeInterval = 90
    /// How recently the microphone track must have had activity for the watchdog to treat it as "the
    /// user is talking into a silent meeting" rather than "nobody is in the meeting".
    private static let microphoneRecentActivityThresholdSeconds: TimeInterval = 15

    private let store: any MeetingSessionStoring
    private let capture: any MeetingCaptureControlling
    private let processing: any MeetingProcessingControlling
    private let audioArbiter: any MeetingAudioActivityArbitrating
    private let settings: SettingsStore
    private let locationResolver: (any MeetingLocationResolving)?
    private var locationTask: Task<Void, Never>?
    private var locationPreferenceObserver: AnyCancellable?
    private let defaultConfigurationResolver: (@MainActor (MeetingCaptureMode, String) async throws -> MeetingCaptureConfiguration)?
    private let redactorProvider: @MainActor () throws -> (any TranscriptTextRedacting)?
    private let preferredMicrophoneUID: @MainActor () -> String?

    private enum DegradeReason { case silence, sourceLoss, startupWriterFailure, sticky }

    private var degradeReason: DegradeReason?
    private var silenceWatchdogActive = false
    private var activityLease: MeetingAudioActivityLease?
    /// Reservation held from the public start entry point through every async start step.
    /// This closes the preflight/lease window where two starts could otherwise pass guards.
    private var startReservation: UUID? {
        willSet { if (newValue != nil) != (self.startReservation != nil) { self.objectWillChange.send() } }
    }

    private var liveTranscriptionCoordinator: MeetingLiveTranscriptionCoordinator?
    private var liveTranscriptionTeardownTask: Task<Void, Never>?
    private let livePrivacyPublication = MeetingLivePrivacyPublication()
    private var lastLiveSourceRevision: UInt64 = 0
    private var startupTrackHealth: [MeetingAudioTrackID: MeetingTrackHealth] = [:]
    private var startupWriterFailures: Set<MeetingAudioTrackID?> = []
    private var pendingSpeechCapture: MeetingPendingSpeechCapture?
    private var pendingSpeechTeardownTask: Task<Void, Never>?
    private let speechActivityModel: MeetingCaptureSpeechActivityWorker.Factory?
    private var pendingSpeechDiagnosticID: UUID?
    private var captureGeneration: UUID? {
        didSet {
            if self.captureGeneration != oldValue {
                self.locationTask?.cancel()
                self.logPendingSpeechState("generation_reset")
                self.lastLiveSourceRevision = 0
                if let pending = self.pendingSpeechCapture {
                    pending.stop()
                    let previous = self.pendingSpeechTeardownTask
                    self.pendingSpeechTeardownTask = Task { await previous?.value; await pending.stopAndWait() }
                }
                self.pendingSpeechCapture = nil
                self.pendingSpeech = .empty
                self.pendingSpeechDiagnosticID = nil
            }
        }
    }
    /// Capture events may be invalidated before a joined stop; its durable text drain still owns
    /// this token until recognition/privacy finalization and terminal persistence have completed.
    private var memoryCheckpointGeneration: UUID?
    private var operationGeneration: UUID?
    private var stopRequestedAt: (sessionID: MeetingSessionID, date: Date)?
    /// A joined capture can outlive the processing generation during termination. Retain
    /// only its immutable physical facts, never an older transcript/session snapshot.
    private var captureStopHandoff: (sessionID: MeetingSessionID, generation: UUID,
        result: MeetingCaptureStopResult?, failure: MeetingSessionFailure?)?

    private var stopTask: Task<MeetingSession, Error>? {
        willSet { if (newValue == nil) != (self.stopTask == nil) { self.objectWillChange.send() } }
    }

    private var interruptionTask: Task<Void, Never>? {
        willSet { if (newValue == nil) != (self.interruptionTask == nil) { self.objectWillChange.send() } }
    }

    private var terminationTask: Task<Void, Never>?
    private var retryTask: Task<MeetingSession, Error>? {
        willSet { if (newValue == nil) != (self.retryTask == nil) { self.objectWillChange.send() } }
    }

    private let persistence: MeetingSessionPersistenceQueue
    private var restoreTask: Task<Void, Never>?
    private var isDeleting = false {
        willSet { if newValue != self.isDeleting { self.objectWillChange.send() } }
    }

    private var isMutatingSession = false {
        willSet { if newValue != self.isMutatingSession { self.objectWillChange.send() } }
    }

    private var sweepPending = false
    private var isReadingRetentionSessions = false
    private var retentionReadWaiters: [CheckedContinuation<Void, Never>] = []
    private var retentionTimerTask: Task<Void, Never>?

    /// Only fields changed by participant reassignment, retained once per selected member.
    /// A batch is one transaction and one undo entry without copying transcript text or audio.
    private struct SpeakerAssignmentCorrection {
        let segmentID: MeetingTranscriptSegmentID
        let previousSpeakerID: SessionSpeakerID?
        let previousOverlap: MeetingTranscriptOverlap
        let previousAttributionState: MeetingTranscriptAttributionState?
        let previousSpeakerAttribution: MeetingTranscriptSpeakerAttribution?
        let previousLegacyInference: MeetingSpeakerAttributionInference?
        let previousUserSpeakerAssigned: Bool?
        let previousRevision: Int

        init(_ segment: MeetingTranscriptSegment) {
            self.segmentID = segment.id
            self.previousSpeakerID = segment.speakerID
            self.previousOverlap = segment.overlap
            self.previousAttributionState = segment.attributionState
            self.previousSpeakerAttribution = segment.speakerAttribution
            self.previousLegacyInference = segment.speakerAttributionInference
            self.previousUserSpeakerAssigned = segment.isUserSpeakerAssigned
            self.previousRevision = segment.revision
        }
    }

    private enum TranscriptCorrection {
        case editText(segmentID: MeetingTranscriptSegmentID, previousText: String, previousOriginalText: String?,
                      previousUserTextEdited: Bool?, previousPrivacyReplacement: Bool?, previousRevision: Int)
        case rename(speakerID: SessionSpeakerID, previousName: String, previousGeneratedNumber: Int?, previousCustomDisplayName: Bool?)
        case reassign([SpeakerAssignmentCorrection])
        case localUserRole([(speakerID: SessionSpeakerID, previousIsLocalUser: Bool,
                             previousName: String, previousGeneratedNumber: Int?, previousCustomDisplayName: Bool?,
                             previousIdentityIsProvisional: Bool?)])
        case nameUnknown(
            segmentID: MeetingTranscriptSegmentID,
            createdSpeakerID: SessionSpeakerID,
            previousOverlap: MeetingTranscriptOverlap,
            previousAttributionState: MeetingTranscriptAttributionState?,
            previousSpeakerAttribution: MeetingTranscriptSpeakerAttribution?,
            previousLegacyInference: MeetingSpeakerAttributionInference?,
            previousUserSpeakerAssigned: Bool?,
            previousRevision: Int
        )
        case merge(
            sourceID: SessionSpeakerID,
            targetID: SessionSpeakerID,
            movedSegments: [(id: MeetingTranscriptSegmentID, previousRevision: Int, previousSpeakerAttribution: MeetingTranscriptSpeakerAttribution?, previousLegacyInference: MeetingSpeakerAttributionInference?, previousUserSpeakerAssigned: Bool?)]
        )
        case renameBatch([(speakerID: SessionSpeakerID, previousName: String, previousGeneratedNumber: Int?, previousCustomDisplayName: Bool?)])

        case speakerEdits(previousSpeakers: [MeetingSessionSpeaker], assignments: [SpeakerAssignmentCorrection])

        var requiresTranscriptPrivacyPublication: Bool {
            switch self {
            case .editText: return true
            case .rename, .renameBatch, .reassign, .localUserRole, .nameUnknown, .merge, .speakerEdits: return false
            }
        }
    }

    private struct OwnedTranscriptCorrection {
        let ownership: MeetingProfileOwnership?
        let correction: TranscriptCorrection
    }

    private var correctionUndoStacks: [MeetingSessionID: [OwnedTranscriptCorrection]] = [:]
    private let prepareRecordingDependencies: @MainActor (Set<MeetingDiarizationDependency>) async throws -> Void
    private let validateRecordingModels: @MainActor () async throws -> Void
    private let validateFrozenRecordingConfiguration: @MainActor (MeetingFinalProcessingConfiguration) throws -> Void
    private let processingLogger: @MainActor (String) -> Void
    private static let correctionUndoStackCap = 50

    init(
        store: any MeetingSessionStoring,
        capture: any MeetingCaptureControlling,
        processing: any MeetingProcessingControlling,
        audioArbiter: any MeetingAudioActivityArbitrating,
        preferredMicrophoneUID: @escaping @MainActor () -> String? = { nil },
        speechActivityModel: MeetingCaptureSpeechActivityWorker.Factory? = nil,
        settings: SettingsStore = .shared,
        locationResolver: (any MeetingLocationResolving)? = nil,
        defaultConfigurationResolver: (@MainActor (MeetingCaptureMode, String) async throws -> MeetingCaptureConfiguration)? = nil,
        redactorProvider: @escaping @MainActor () throws -> (any TranscriptTextRedacting)? = { nil },
        validateRecordingModels: @escaping @MainActor () async throws -> Void = {},
        prepareRecordingDependencies: @escaping @MainActor (Set<MeetingDiarizationDependency>) async throws -> Void = { _ in },
        validateFrozenRecordingConfiguration: @escaping @MainActor (MeetingFinalProcessingConfiguration) throws -> Void = { _ in },
        processingLogger: @escaping @MainActor (String) -> Void = { DebugLogger.shared.info($0, source: "MeetingSessionCoordinator") }
    ) {
        self.store = store
        self.persistence = MeetingSessionPersistenceQueue(store: store)
        self.capture = capture
        self.processing = processing
        self.audioArbiter = audioArbiter
        self.speechActivityModel = speechActivityModel
        self.preferredMicrophoneUID = preferredMicrophoneUID
        self.settings = settings
        self.locationResolver = locationResolver
        self.defaultConfigurationResolver = defaultConfigurationResolver
        self.redactorProvider = redactorProvider
        self.validateRecordingModels = validateRecordingModels
        self.prepareRecordingDependencies = prepareRecordingDependencies
        self.validateFrozenRecordingConfiguration = validateFrozenRecordingConfiguration
        self.processingLogger = processingLogger
        self.locationPreferenceObserver = settings.objectWillChange.sink { [weak self] _ in
            Task { @MainActor [weak self] in
                guard let self, !self.settings.meetingLocationEnabled else { return }
                self.locationTask?.cancel()
            }
        }
    }

    var currentSession: MeetingSession? {
        self.activeSession ?? self.latestCompletedSession
    }

    var isRecording: Bool {
        switch self.state {
        case .recording, .recordingDegraded:
            return true
        default:
            return false
        }
    }

    var hasPendingStart: Bool {
        self.startReservation != nil
    }

    /// A recovery offer is not audio ownership. Only matching terminal states may
    /// be displaced; preparing/stopping and inconsistent states remain blocked.
    private var canBeginNewRecording: Bool {
        guard self.activityLease == nil else { return false }
        switch self.state {
        case .idle, .completed:
            return self.activeSession == nil
        case let .failed(id, _):
            return self.activeSession == nil ||
                (self.activeSession?.id == id && self.activeSession?.state == .failed)
        case let .interrupted(id):
            return self.activeSession == nil ||
                (self.activeSession?.id == id && self.activeSession?.state == .interrupted)
        case .preparing, .recording, .recordingDegraded, .stopping, .processing:
            return false
        }
    }

    var isProcessing: Bool {
        if case .processing = self.state { return true }
        return false
    }

    private var hasBlockingActivityTask: Bool {
        self.hasBlockingActivityTaskExceptStart || self.startReservation != nil
    }

    /// True when no capture/stop/interruption/termination/retry activity is in flight and the
    /// session isn't mid-transition — safe for the UI to offer delete/retry/record-again actions.
    var isQuiescent: Bool {
        guard !self.hasBlockingActivityTask,
              !self.isRecording,
              !self.isProcessing,
              !self.isDeleting,
              !self.isMutatingSession
        else { return false }
        switch self.state {
        case .preparing, .stopping:
            return false
        default:
            return true
        }
    }

    var elapsedTime: TimeInterval {
        guard let session = self.activeSession else { return 0 }
        // Freeze the visible timer immediately on Stop. The final persisted boundary is
        // supplied by capture after the audio runtime joins, not this UI request estimate.
        if self.state == .stopping(session.id), let request = self.stopRequestedAt, request.sessionID == session.id {
            return max(0, (session.endedAt ?? request.date).timeIntervalSince(session.startedAt))
        }
        return max(0, (session.endedAt ?? Date()).timeIntervalSince(session.startedAt))
    }

    var sourceDisplayName: String {
        self.currentSession?.audioSourceDisplayName ?? "Meeting audio"
    }

    var microphoneDisplayName: String {
        self.currentSession?.selectedMicrophone.displayName ?? "Microphone"
    }

    func defaultConfiguration(
        mode: MeetingCaptureMode,
        title: String
    ) async throws -> MeetingCaptureConfiguration {
        try await self.defaultConfiguration(mode: mode, title: title, preferredBundleIdentifier: nil, preferredWindowID: nil)
    }

    /// Used by the auto-detection Start path: `preferredBundleIdentifier` is the detected app.
    /// For selected-application scope, `requirePreferredApplication` requires that exact app.
    /// For system scope, detection is a start/title hint and cannot narrow the captured audio.
    /// `preferredWindowID` is threaded onto narrow identities when it still matches.
    /// SCK content and microphone identities are refreshed here rather than reused.
    func defaultConfiguration(
        mode: MeetingCaptureMode,
        title: String,
        preferredBundleIdentifier: String?,
        preferredWindowID: UInt32?,
        requirePreferredApplication: Bool = false
    ) async throws -> MeetingCaptureConfiguration {
        if let defaultConfigurationResolver { return try await defaultConfigurationResolver(mode, title) }
        #if os(macOS)
        // Freeze source intent and language before microphone/source discovery suspends.
        let defaults = self.settings.meetingRecordingDefaults
        let scope = defaults.effectiveApplicationAudioScope
        let languageCode = defaults.languageCode
            ?? PichiMeetingProviderFactory.defaultLanguageCode(for: self.settings.selectedSpeechModel.rawValue) ?? "ru"
        let storageMode: MeetingAudioStorageMode = self.settings.meetingSaveAudio ? .retainedFiles : .memoryOnly
        let speakerLabelsEnabled = self.settings.meetingSpeakerLabelsEnabled
        let speakerProcessingMode = self.settings.meetingSpeakerProcessingMode(for: mode)
        let piiRedactionEnabled = self.settings.meetingPIIRedactionEnabled
        let microphone = try await MeetingCaptureSourceCatalog.defaultMicrophone(
            preferredCoreAudioUID: self.preferredMicrophoneUID()
        )
        var application: MeetingApplicationIdentity?
        if mode == .onlineCall, scope == .selectedApplication {
            let applications = try await MeetingCaptureSourceCatalog.availableApplications()
            var resolved = try MeetingCaptureSourceCatalog.resolveApplication(
                from: applications,
                preferredBundleIdentifier: defaults.usesAutomaticApplication ? preferredBundleIdentifier : defaults.applicationBundleIdentifier,
                requirePreferredApplication: requirePreferredApplication || !defaults.usesAutomaticApplication
            )
            if let preferredWindowID, resolved.bundleIdentifier == preferredBundleIdentifier {
                resolved.windowID = preferredWindowID
            }
            application = resolved
        } else {
            application = nil
        }
        return MeetingCaptureConfiguration(
            mode: mode,
            title: title,
            languageCode: languageCode,
            application: application,
            applicationAudioScope: mode == .onlineCall ? scope : nil,
            microphone: microphone,
            timestampDefaultTitle: true,
            audioStorageMode: storageMode,
            speakerLabelsEnabled: speakerLabelsEnabled,
            speakerProcessingMode: speakerProcessingMode,
            piiRedactionEnabled: piiRedactionEnabled
        )
        #else
        throw MeetingProcessingError.modelUnavailable
        #endif
    }

    private nonisolated static func usesPCMProcessing(_ configuration: MeetingCaptureConfiguration) -> Bool {
        configuration.audioStorageMode == .memoryOnly || configuration.effectiveSpeakerProcessingMode == .streaming
    }

    private nonisolated static func usesPCMProcessing(_ session: MeetingSession) -> Bool {
        session.audioStorageMode == .memoryOnly || session.effectiveSpeakerProcessingMode == .streaming
    }

    private func prepareRecordingSpeakerResources(
        for descriptor: MeetingBackendDescriptor, configuration: MeetingFinalProcessingConfiguration
    ) async throws {
        if configuration.effectiveSpeakerProcessingMode == .streaming,
           PichiMeetingProviderFactory.registeredBackendDescriptor(for: configuration.asrModel)?.id == descriptor.id {
            try await PichiMeetingProviderFactory.prepareSpeakerResources(for: configuration)
        } else {
            try await self.prepareRecordingDependencies(descriptor.diarizationDependencies)
        }
    }

    @discardableResult
    func startRecording(configuration: MeetingCaptureConfiguration) async throws -> MeetingSession {
        return try await self.startRecording(configuration: configuration, passiveOffer: nil, resolvingSourceID: nil)
    }

    private func startRecording(
        configuration: MeetingCaptureConfiguration,
        passiveOffer: MeetingSession?,
        resolvingSourceID: MeetingSessionID?
    ) async throws -> MeetingSession {
        guard self.settings.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        guard self.startReservation == nil else { throw MeetingCoordinatorError.recordingAlreadyActive }
        guard !self.hasBlockingActivityTask,
              self.canBeginNewRecording, !self.isDeleting
        else { throw MeetingCoordinatorError.recordingAlreadyActive }
        let reservation = UUID()
        self.startReservation = reservation
        if DebugLogger.diagnosticsEnabled {
            DebugLogger.shared.info("captureID=\(reservation) phase=start_admitted uptimeMs=\(Int64(ProcessInfo.processInfo.systemUptime * 1000))", source: "MeetingCaptureStartup")
        }
        defer { if self.startReservation == reservation { self.startReservation = nil } }
        await self.ensureRestored()
        let passiveOffer = passiveOffer ?? self.activeSession.flatMap { offer in
            (offer.state == .interrupted || offer.state == .failed) ? offer : nil
        }
        return try await self.performStartRecording(
            configuration: configuration,
            passiveOffer: passiveOffer,
            resolvingSourceID: resolvingSourceID,
            reservation: reservation
        )
    }

    private func performStartRecording(
        configuration: MeetingCaptureConfiguration,
        passiveOffer: MeetingSession?,
        resolvingSourceID: MeetingSessionID?,
        reservation: UUID
    ) async throws -> MeetingSession {
        try Task.checkCancellation()
        guard self.settings.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        // The existing storage/admission owner resolves security policy for every
        // recording entry point before backend checks or microphone permission work.
        var configuration = configuration
        let persistencePolicy = try await self.store.prepareCapturePersistencePolicy()
        if persistencePolicy.requiresPIIRedaction {
            guard configuration.piiRedactionEnabled == true else {
                throw NSError(domain: "ProtectedRecording", code: 1, userInfo: [NSLocalizedDescriptionKey:
                    PichiLocalization.text("cloud.automatic.requiresPrivacy", defaultValue: "Turn on Data cleanup before recording with automatic protected delivery.")])
            }
        }
        if persistencePolicy.requiresEncryptedPersistence {
            configuration.audioStorageMode = .memoryOnly
            configuration.requiresEncryptedPersistence = true
        }
        try Task.checkCancellation()
        try configuration.validate()
        let selectedSpeechModel = self.settings.selectedSpeechModel
        let selectedModelID = selectedSpeechModel.rawValue
        let savedBackendID = self.settings.meetingTranscriptionBackendID
        let requestedBackendID = configuration.transcriptionBackendID.map(MeetingBackendID.init(rawValue:))
            ?? PichiMeetingProviderFactory.selectedBackendID(languageCode: configuration.languageCode,
                selectedModelID: selectedModelID, savedBackendID: savedBackendID)
        if configuration.transcriptionBackendID == nil,
           PichiMeetingProviderFactory.registeredLanguageCodes(for: selectedModelID) != nil {
            _ = try MeetingProviderOptions.resolve(MeetingFinalProcessingConfiguration(
                asrModel: selectedModelID,
                languageCode: configuration.languageCode,
                speakerLabelsEnabled: configuration.speakerLabelsEnabled ?? true,
                speakerProcessingMode: configuration.effectiveSpeakerProcessingMode
            ))
        }
        guard self.startReservation == reservation,
              self.activeSession?.id == passiveOffer?.id,
              !self.hasBlockingActivityTaskExceptStart,
              self.canBeginNewRecording, !self.isDeleting
        else {
            throw MeetingCoordinatorError.recordingAlreadyActive
        }
        guard !self.isMutatingSession else {
            throw MeetingCoordinatorError.maintenanceInProgress
        }

        // Reject unsupported strict input through the real backend factory before download
        // owners or microphone permission prompts run. Repeat after prompts in case selection
        // changed while they were open; final preparation still binds the exact session request.
        let initialDescriptor = try self.processing.validateRecordingInput(
            configuration: configuration, backendID: requestedBackendID)
        let validationSnapshot = PichiMeetingProviderFactory.validationConfiguration(
            backendID: requestedBackendID, languageCode: configuration.languageCode,
            preferredASRModel: selectedSpeechModel,
            diarizationEnabled: configuration.speakerLabelsEnabled ?? true,
            speakerProcessingMode: configuration.effectiveSpeakerProcessingMode)
        try initialDescriptor?.validateSpeakerProcessingMode(configuration: validationSnapshot, mode: configuration.mode)
        // Explicit registered requests require a preinstalled artifact. Capture its identity
        // before any dependency work or permission prompt and retain this exact snapshot.
        let explicitRecordingConfiguration: MeetingFinalProcessingConfiguration?
        if configuration.transcriptionBackendID != nil {
            let snapshot = try await PichiMeetingProviderFactory.frozenConfiguration(backendID: requestedBackendID,
                languageCode: configuration.languageCode, preferredASRModel: selectedSpeechModel,
                diarizationEnabled: configuration.speakerLabelsEnabled ?? true,
                speakerProcessingMode: configuration.effectiveSpeakerProcessingMode)
            let registeredOverride = PichiMeetingProviderFactory.registeredBackendDescriptor(for: snapshot.asrModel)?.id == requestedBackendID
            try PichiMeetingProviderFactory.validateRecordingConfiguration(snapshot,
                isAppleSilicon: CPUArchitecture.isAppleSilicon, requiresInstalledArtifact: registeredOverride,
                captureMode: configuration.mode)
            try self.validateFrozenRecordingConfiguration(snapshot)
            explicitRecordingConfiguration = snapshot
        } else { explicitRecordingConfiguration = nil }
        // Permission prompts are outside the exclusive audio lease. A prompt can remain
        // open indefinitely; reserving meeting audio first would unnecessarily block dictation.
        // This callback belongs to the ambient selected-ASR lifecycle. Explicit requests
        // are prepared by the existing requested-backend pipeline/runtime owners below.
        // Installed registered providers already have an owned preparation scope: the PCM
        // attempt or the optional live-caption worker, followed by frozen final processing.
        // Warming the ambient provider here would load it twice and delay microphone start.
        // Retained capture writes independently while optional live captions are preparing.
        // A missing installation still uses the existing download owner before admission.
        if configuration.transcriptionBackendID == nil,
           PichiMeetingProviderFactory.registeredModelsExistOnDisk(for: selectedModelID) != true {
            try await self.validateRecordingModels()
        }
        try Task.checkCancellation()
        guard self.settings.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        guard self.settings.selectedSpeechModel.rawValue == selectedModelID,
              self.settings.meetingTranscriptionBackendID == savedBackendID else { throw CancellationError() }
        let dependencyDescriptor = initialDescriptor
            ?? PichiMeetingProviderFactory.registeredBackendDescriptor(for: self.settings.selectedSpeechModel.rawValue)
        if configuration.speakerLabelsEnabled != false, let dependencyDescriptor,
           CPUArchitecture.isAppleSilicon || !dependencyDescriptor.allowsTranscriptOnlyOnUnsupportedHardware || Self.usesPCMProcessing(configuration) {
            try await self.prepareRecordingSpeakerResources(for: dependencyDescriptor,
                configuration: validationSnapshot)
        }
        try Task.checkCancellation()
        guard self.settings.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        guard self.settings.selectedSpeechModel.rawValue == selectedModelID,
              self.settings.meetingTranscriptionBackendID == savedBackendID else { throw CancellationError() }
        try await self.capture.preflightPermissions()
        try Task.checkCancellation()
        guard self.settings.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        guard self.settings.selectedSpeechModel.rawValue == selectedModelID,
              self.settings.meetingTranscriptionBackendID == savedBackendID else { throw CancellationError() }
        guard self.startReservation == reservation,
              self.activeSession?.id == passiveOffer?.id,
              !self.hasBlockingActivityTaskExceptStart,
              self.canBeginNewRecording, !self.isDeleting
        else {
            throw MeetingCoordinatorError.recordingAlreadyActive
        }
        guard !self.isMutatingSession else {
            throw MeetingCoordinatorError.maintenanceInProgress
        }

        let publicationConfiguration = configuration
        let recordingRedactor = configuration.piiRedactionEnabled == true ? try self.redactorProvider() : nil
        if configuration.piiRedactionEnabled == true {
            // Explicit meeting/input metadata is user-authored. Only recognized speech is
            // redacted; warming NER here would also delay microphone admission.
            guard recordingRedactor != nil else { throw MeetingPrivacyPublicationError.redactorUnavailable }
        }
        let lease = try await self.audioArbiter.acquireMeetingCapture()
        let recordingSessionID = UUID()
        let recordingModelID: String
        let recordingBackendID: MeetingBackendID
        let recordingASRConfiguration: MeetingFinalProcessingConfiguration
        let recordingLiveModelID: String
        let recordingLiveConfiguration: MeetingFinalProcessingConfiguration
        let recordingProfileOwnership: MeetingProfileOwnership?
        do {
            try Task.checkCancellation()
            guard self.settings.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
            guard self.startReservation == reservation,
                  self.activeSession?.id == passiveOffer?.id,
                  !self.hasBlockingActivityTaskExceptStart,
                  self.canBeginNewRecording, !self.isDeleting, !self.isMutatingSession
            else {
                throw CancellationError()
            }
            // Model installation and permission prompts run before the capture lease. Keep
            // their chosen model pinned; only freeze its installed artifact after preparation.
            guard self.settings.selectedSpeechModel.rawValue == selectedModelID,
              self.settings.meetingTranscriptionBackendID == savedBackendID else { throw CancellationError() }
            recordingModelID = selectedModelID
            recordingBackendID = requestedBackendID
            let admittedPCMDescriptor = try self.processing.validateRecordingInput(
                configuration: configuration, backendID: recordingBackendID)
            if configuration.speakerLabelsEnabled != false,
               let descriptor = admittedPCMDescriptor ?? PichiMeetingProviderFactory.registeredBackendDescriptor(for: recordingModelID),
               CPUArchitecture.isAppleSilicon || !descriptor.allowsTranscriptOnlyOnUnsupportedHardware || Self.usesPCMProcessing(configuration) {
                try await self.prepareRecordingSpeakerResources(for: descriptor,
                    configuration: validationSnapshot)
                try Task.checkCancellation()
            guard self.settings.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
                guard self.startReservation == reservation,
                      self.settings.selectedSpeechModel.rawValue == recordingModelID,
                      self.settings.meetingTranscriptionBackendID == savedBackendID,
                      self.terminationTask == nil, !self.isMutatingSession else { throw CancellationError() }
            }
            if let explicitRecordingConfiguration {
                recordingASRConfiguration = explicitRecordingConfiguration
            } else {
                recordingASRConfiguration = try await PichiMeetingProviderFactory.frozenConfiguration(
                    backendID: recordingBackendID,
                    languageCode: configuration.languageCode,
                    preferredASRModel: selectedSpeechModel,
                    diarizationEnabled: configuration.speakerLabelsEnabled ?? true,
                    speakerProcessingMode: configuration.effectiveSpeakerProcessingMode
                )
                guard self.startReservation == reservation,
                      self.settings.selectedSpeechModel.rawValue == recordingModelID,
                      self.settings.meetingTranscriptionBackendID == savedBackendID,
                      self.terminationTask == nil, !self.isMutatingSession else { throw CancellationError() }
            }
            _ = try MeetingProviderOptions.resolve(recordingASRConfiguration)
            try self.validateFrozenRecordingConfiguration(recordingASRConfiguration)
            recordingLiveModelID = PichiMeetingProviderFactory.liveModelID(backendID: recordingBackendID,
                configuration: recordingASRConfiguration, selectedModelID: recordingModelID)
            if !Self.usesPCMProcessing(configuration),
               recordingLiveModelID != recordingASRConfiguration.asrModel,
               case .buffered = MeetingLiveTranscriptionCoordinator.captionRoute(
                   languageCode: configuration.languageCode, modelID: recordingLiveModelID) {
                // The compatibility executor may not bind its ASR model. Preserve its existing
                // selected-model caption route, but freeze that provider before capture too.
                recordingLiveConfiguration = try await PichiMeetingProviderFactory.frozenConfiguration(
                    asrModel: recordingLiveModelID, languageCode: configuration.languageCode)
            } else { recordingLiveConfiguration = recordingASRConfiguration }
            try Task.checkCancellation()
            guard self.startReservation == reservation,
                  self.settings.selectedSpeechModel.rawValue == recordingModelID,
                  self.settings.meetingTranscriptionBackendID == savedBackendID,
                  self.terminationTask == nil, !self.isMutatingSession else { throw CancellationError() }
            recordingProfileOwnership = try await self.store.captureOwnership(for: recordingSessionID, configuration: configuration)
            guard self.startReservation == reservation, self.terminationTask == nil,
                  !Task.isCancelled else { throw CancellationError() }
        } catch {
            await self.store.cancelCaptureAdmission(for: recordingSessionID)
            await self.audioArbiter.release(lease)
            throw error
        }
        self.activityLease = lease
        let generation = UUID()
        self.captureStopHandoff = nil
        self.captureGeneration = generation
        self.degradeReason = nil
        self.silenceWatchdogActive = false
        self.operationGeneration = generation
        if passiveOffer != nil {
            self.activeSession = nil
            self.trackHealth = [:]
            self.state = .idle
        }
        let timebase = Self.makeTimebase()
        var session = MeetingSession(id: recordingSessionID, configuration: publicationConfiguration, timebase: timebase)
        session.profileOwnership = recordingProfileOwnership
        session.recordingBackendID = recordingBackendID.rawValue
        session.recordingASRModel = recordingASRConfiguration.asrModel
        session.recordingASRArtifactFingerprint = recordingASRConfiguration.asrArtifactFingerprint
        session.retention.retainAudioUntil = self.settings.meetingAudioRetentionPolicy
            .retainUntil(startedAt: session.startedAt)
        self.activeSession = session
        self.state = .preparing(session.id)
        self.startupTrackHealth.removeAll()
        self.startupWriterFailures.removeAll()
        defer { self.startupTrackHealth.removeAll() }
        var captureStarted = false
        var captureStartAttempted = false

        await self.pendingSpeechTeardownTask?.value
        self.pendingSpeechTeardownTask = nil
        let captureOrigin = MeetingLiveOriginBox()
        if configuration.mode == .onlineCall, Self.usesPCMProcessing(configuration) {
            let seconds = Double(timebase.startedHostTime) * Double(timebase.machTimebaseNumerator)
                / Double(timebase.machTimebaseDenominator) / 1_000_000_000
            _ = captureOrigin.establish(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
        }
        let liveTranscriptionCoordinator = MeetingLiveTranscriptionCoordinator(originBox: captureOrigin,
            onEmptyRecognition: { [weak self] source, start, end in
                CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                    MainActor.assumeIsolated {
                        guard let self, generation == self.captureGeneration,
                              let capture = self.pendingSpeechCapture else { return }
                        self.pendingSpeech = capture.acknowledgeEmptyRecognition(source: source, start: start, end: end)
                    }
                }
                CFRunLoopWakeUp(CFRunLoopGetMain())
            }) { [weak self] snapshot in
            // Common-modes trampoline, not the main dispatch queue: the queue is starved while the
            // user drags a window (event-tracking mode), which froze live captions mid-drag.
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue) {
                MainActor.assumeIsolated {
                    guard let self,
                          self.liveTranscriptionCoordinator != nil,
                          generation == self.captureGeneration,
                          snapshot.revision > self.lastLiveSourceRevision
                    else { return }
                    self.lastLiveSourceRevision = snapshot.revision
                    self.publishLiveTranscript(snapshot, generation: generation, redactor: recordingRedactor)
                }
            }
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let pendingDiagnosticID = UUID()
        self.pendingSpeechDiagnosticID = pendingDiagnosticID
        let pendingDiagnostics: (@Sendable (MeetingPendingSpeechProjection.DiagnosticEvent) -> Void)?
        if DebugLogger.diagnosticsEnabled {
            pendingDiagnostics = { event in
                DebugLogger.shared.logLazy(level: .debug, source: "MeetingPendingSpeech") {
                    "captureID=\(pendingDiagnosticID.uuidString) \(event.logFields)"
                }
            }
        } else { pendingDiagnostics = nil }
        await MeetingTimelineTrace.shared?.claimSession(session.id.uuidString)
        let pendingSpeechCapture = MeetingPendingSpeechCapture(originBox: captureOrigin,
            activityModel: self.speechActivityModel,
            activitySources: configuration.mode == .onlineCall ? [.you, .them] : [.you], diagnostics: pendingDiagnostics) { [weak self] snapshot in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.captureGeneration == generation,
                      self.pendingSpeechCapture != nil,
                      snapshot.revision > self.pendingSpeech.revision else {
                    self.logPendingSpeechState("capture_snapshot_rejected", incomingRevision: snapshot.revision,
                        incomingCaptureID: pendingDiagnosticID)
                    return
                }
                self.pendingSpeech = snapshot
                self.logPendingSpeechState("capture_snapshot_published", incomingRevision: snapshot.revision)
            }
        }
        MeetingTimelineTrace.shared?.record("capture_started", fields: ["sessionID": session.id.uuidString,
            "captureID": pendingDiagnosticID.uuidString, "vadConfigured": String(self.speechActivityModel != nil)])
        self.pendingSpeechCapture = pendingSpeechCapture
        self.pendingSpeech = MeetingPendingSpeechSnapshot(isCapturing: true)
        self.logPendingSpeechState("capture_started")
        self.liveTranscriptionCoordinator = liveTranscriptionCoordinator
        self.liveTranscript = .empty
        self.lastLiveSpeechAt = nil
        if !Self.usesPCMProcessing(configuration) {
        liveTranscriptionCoordinator.start(
            mode: configuration.mode,
            languageCode: configuration.languageCode,
            modelID: recordingLiveModelID,
            artifactFingerprint: recordingLiveConfiguration.asrArtifactFingerprint,
            configuration: recordingLiveConfiguration
        )
        }

        do {
            try await self.store.create(session)
            let sessionDirectory = try await self.store.sessionDirectory(for: session.id)
            guard self.startReservation == reservation,
                  self.operationGeneration == generation,
                  self.terminationTask == nil,
                  !Task.isCancelled
            else { throw CancellationError() }
            if Self.usesPCMProcessing(configuration) {
                self.memoryCheckpointGeneration = generation
                _ = try await self.processing.prepareMemoryAudio(
                    session: session, sessionDirectory: sessionDirectory, privacyRedactor: recordingRedactor, checkpoint: { [weak self] batch in
                    guard let self, self.memoryCheckpointGeneration == generation else { throw CancellationError() }
                    try await self.checkpointMemoryTranscript(batch, sessionID: session.id, generation: generation)
                }, trackPreview: { [weak self] kind, partial in
                    guard let self, self.memoryCheckpointGeneration == generation,
                          self.activeSession?.id == session.id else { throw CancellationError() }
                    let source: MeetingLiveSpeaker = kind == .microphone ? .you : .them
                    self.liveTranscript = self.liveTranscript.settingPartial(partial, for: source)
                    self.liveTranscript.revision += 1
                    self.liveTranscript.availability = .available
                    self.reconcilePendingSpeech()
                    // This is an accepted protected display value, not durable history or a
                    // rendered frame. Optional chaining also avoids metadata work when off.
                    MeetingTimelineTrace.shared?.record("protected_live_publication", fields: [
                        "sessionID": session.id.uuidString, "generation": generation.uuidString,
                        "stage": "pcm-protected-preview", "source": source == .you ? "you" : "them",
                        "transcriptRevision": String(self.liveTranscript.revision),
                        "partialPresent": String(self.liveTranscript.partials[source] != nil),
                        "partialID": self.liveTranscript.partials[source]?.id.uuidString ?? "unavailable",
                        "sourceStartSeconds": self.liveTranscript.partials[source].map { String($0.start) } ?? "unavailable",
                        "sourceEndSeconds": self.liveTranscript.partials[source]?.end.map { String($0) } ?? "unavailable",
                        "utf16Count": String(self.liveTranscript.partials[source]?.text.utf16.count ?? 0),
                        "publicationScope": "accepted-coordinator-assignment-not-render-frame"])
                }, trackConfidentlyNonSpeech: { [weak pendingSpeechCapture] kind, start, end in
                    await pendingSpeechCapture?.awaitConfidentNonSpeech(source: kind == .microphone ? .you : .them,
                        start: start, end: end) ?? false
                })
            }
            captureStartAttempted = true
            if DebugLogger.diagnosticsEnabled {
                DebugLogger.shared.info("captureID=\(reservation) phase=capture_requested uptimeMs=\(Int64(ProcessInfo.processInfo.systemUptime * 1000))", source: "MeetingCaptureStartup")
            }
            let startResult = try await self.capture.start(
                session: session,
                configuration: publicationConfiguration,
                sessionDirectory: sessionDirectory,
                eventHandler: { [weak self] event in
                    // Preserve failure/recovery emission order across the capture-to-main hop.
                    DispatchQueue.main.async { [weak self] in
                        self?.handleCaptureEvent(event, generation: generation)
                    }
                },
                liveAudioHandler: { [weak liveTranscriptionCoordinator, pendingSpeechCapture] kind, sampleBuffer in
                    pendingSpeechCapture.offer(kind: kind, sampleBuffer: sampleBuffer)
                    // The strict consumer already owns inference. Its tee supplies only scalar
                    // presentation activity, never another live recognizer or PCM queue.
                    if !Self.usesPCMProcessing(configuration) {
                        liveTranscriptionCoordinator?.offer(kind: kind, sampleBuffer: sampleBuffer)
                    }
                }
            )
            captureStarted = true
            if DebugLogger.diagnosticsEnabled {
                DebugLogger.shared.info("captureID=\(reservation) phase=capture_started uptimeMs=\(Int64(ProcessInfo.processInfo.systemUptime * 1000))", source: "MeetingCaptureStartup")
            }
            guard self.operationGeneration == generation, !Task.isCancelled else {
                throw CancellationError()
            }
            if let microphoneTrack = startResult.tracks.first(where: { $0.kind == .microphone }) {
                liveTranscriptionCoordinator.setMicrophoneCaptureMethod(microphoneTrack.captureMethod)
            }
            session.audioTracks = startResult.tracks
            for index in session.audioTracks.indices {
                if let health = self.startupTrackHealth[session.audioTracks[index].id] {
                    session.audioTracks[index].health = health
                }
            }
            self.startupTrackHealth.removeAll()
            // Capture can report its first writer failure before start() returns. Preserve that
            // one-shot event and the settled writer health instead of replacing them with the
            // original preparing snapshot.
            session.events = self.activeSession?.events ?? session.events
            if Self.usesPCMProcessing(configuration), let latest = self.activeSession {
                session.transcriptSegments = latest.transcriptSegments
                session.speakers = latest.speakers
                session.transcriptIsComplete = latest.transcriptIsComplete
            }
            if let firstPresentationTime = startResult.firstPresentationTime {
                session.timebase.firstPresentationTime = firstPresentationTime
            }
            let hasOtherDegradedTrack = session.audioTracks.contains {
                $0.health.status == .degraded && !self.startupWriterFailures.contains($0.id)
            }
            let startedDegraded = self.degradeReason != nil || hasOtherDegradedTrack || !self.startupWriterFailures.isEmpty
            session.state = startedDegraded ? .recordingDegraded : .recording
            if startedDegraded {
                self.degradeReason = hasOtherDegradedTrack ? .sticky : (self.degradeReason ?? .startupWriterFailure)
            }
            session.updatedAt = Date()
            self.activeSession = session
            self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
            self.state = startedDegraded ? .recordingDegraded(session.id) : .recording(session.id)
            try await self.store.save(session)
            guard self.startReservation == reservation,
                  self.operationGeneration == generation, !Task.isCancelled
            else {
                throw CancellationError()
            }
            if let resolvingSourceID {
                // Keep the start reservation held while serializing the explicit
                // Record Again resolution against queued corrections/deletes.
                await self.flushQueuedPersistence()
                guard self.startReservation == reservation,
                      self.operationGeneration == generation, !Task.isCancelled
                else {
                    throw CancellationError()
                }
                if var source = try? await self.store.load(id: resolvingSourceID) {
                    guard self.startReservation == reservation,
                          self.operationGeneration == generation, !Task.isCancelled
                    else {
                        throw CancellationError()
                    }
                    source.recoveryResolvedAt = Date()
                    source.updatedAt = Date()
                    do {
                        try await self.store.save(source)
                    } catch {
                        DebugLogger.shared.log("Record Again source resolution failed; previous audio remains recoverable: \(error)")
                    }
                }
            }
            guard self.startReservation == reservation,
                  self.operationGeneration == generation, !Task.isCancelled
            else {
                throw CancellationError()
            }
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
            self.beginLocationCapture(for: session, generation: generation)
            return session
        } catch {
            MeetingTimelineTrace.shared?.record("meeting_start_failed", fields: ["sessionID": session.id.uuidString])
            await MeetingTimelineTrace.shared?.finish()
            await self.tearDownLiveTranscription()
            if self.operationGeneration != generation {
                if captureStarted {
                    _ = try? await self.capture.stop(sessionID: session.id)
                }
                throw error
            }
            if captureStarted {
                do {
                    let stopResult = try await self.capture.stop(sessionID: session.id)
                    Self.apply(stopResult, to: &session)
                } catch let stopError {
                    if let partialResult = Self.partialStopResult(from: stopError) {
                        Self.apply(partialResult, to: &session)
                    } else {
                        await self.capture.shutdownForTermination()
                        session.endedAt = session.endedAt ?? Date()
                    }
                }
            }
            if let latestSession = self.activeSession, latestSession.id == session.id {
                session.events = latestSession.events
            }
            await self.finishMemoryCheckpointDrain(sessionID: session.id)
            self.mergeLatestMemoryCheckpoint(into: &session)
            let hasRecoverableAudio = Self.hasRecoverableAudio(session)
            let failureDomain: MeetingFailureDomain = captureStarted
                ? .persistence
                : (captureStartAttempted ? .capture : .persistence)
            let failure = Self.failure(
                from: error,
                domain: failureDomain,
                recoverable: hasRecoverableAudio
            )
            session.state = .failed
            session.failures.append(failure)
            session.updatedAt = Date()
            try? await self.store.save(session)
            self.activeSession = hasRecoverableAudio ? session : nil
            self.trackHealth = hasRecoverableAudio
                ? Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
                : [:]
            self.captureGeneration = nil
            self.degradeReason = nil
            self.operationGeneration = nil
            self.state = .failed(session.id, failure)
            await self.releaseActivityLease()
            if let passiveOffer,
               self.startReservation == reservation,
               self.terminationTask == nil,
               !hasRecoverableAudio,
               self.activeSession == nil
            {
                self.activeSession = passiveOffer
                self.trackHealth = Dictionary(uniqueKeysWithValues: passiveOffer.audioTracks.map { ($0.kind, $0.health) })
                self.state = passiveOffer.state == .interrupted
                    ? .interrupted(passiveOffer.id)
                    : .failed(passiveOffer.id, passiveOffer.failures.last ?? failure)
            }
            throw error
        }
    }

    private var hasBlockingActivityTaskExceptStart: Bool {
        self.stopTask != nil || self.interruptionTask != nil || self.terminationTask != nil || self.retryTask != nil
    }

    @discardableResult
    func stopAndTranscribe() async throws -> MeetingSession {
        // Close metadata publication before Stop takes any full session snapshot.
        self.locationTask?.cancel()
        if let stopTask = self.stopTask { return try await stopTask.value }
        guard let session = self.activeSession else { throw MeetingCoordinatorError.noActiveMeeting }
        guard self.interruptionTask == nil, self.terminationTask == nil else {
            throw MeetingCoordinatorError.activityInProgress
        }
        guard [.preparing, .recording, .recordingDegraded, .stopping].contains(session.state),
              let generation = self.operationGeneration
        else { throw MeetingCoordinatorError.activityInProgress }

        let task = Task { @MainActor [weak self] () throws -> MeetingSession in
            guard let self else { throw MeetingCoordinatorError.noActiveMeeting }
            return try await self.performStopAndTranscribe(generation: generation)
        }
        self.stopTask = task
        do {
            let session = try await task.value
            self.stopTask = nil
            return session
        } catch {
            self.stopTask = nil
            throw error
        }
    }

    @discardableResult
    func retryProcessing() async throws -> MeetingSession {
        guard let activeSession else { throw MeetingCoordinatorError.noRecoverableAudio }
        return try await self.retryProcessing(sessionID: activeSession.id)
    }

    @discardableResult
    func retryProcessing(sessionID: MeetingSessionID, languageCode: String? = nil) async throws -> MeetingSession {
        try await self.retryProcessing(sessionID: sessionID, languageCode: languageCode, restarting: false)
    }

    /// Explicitly discards only retained inference working state. The existing retry task owns
    /// the whole transition, so recording, deletion and another retry cannot race this reset.
    @discardableResult
    func restartProcessing(sessionID: MeetingSessionID) async throws -> MeetingSession {
        try await self.retryProcessing(sessionID: sessionID, languageCode: nil, restarting: true)
    }

    private func retryProcessing(sessionID: MeetingSessionID, languageCode: String?, restarting: Bool) async throws -> MeetingSession {
        guard self.retryTask == nil else { throw MeetingCoordinatorError.activityInProgress }
        let task = Task { @MainActor [weak self] () throws -> MeetingSession in
            guard let self else { throw MeetingCoordinatorError.noActiveMeeting }
            return try await self.performRetryProcessing(sessionID: sessionID, languageCode: languageCode, restarting: restarting)
        }
        self.retryTask = task
        do {
            let session = try await task.value
            self.retryTask = nil
            return session
        } catch {
            self.retryTask = nil
            throw error
        }
    }

    private func performRetryProcessing(sessionID: MeetingSessionID, languageCode: String?, restarting: Bool) async throws -> MeetingSession {
        let requestedLanguage: String?
        if let languageCode {
            guard let code = MeetingRetranscriptionLanguage.canonicalCode(languageCode) else {
                throw MeetingCoordinatorError.unsupportedRetranscriptionLanguage
            }
            requestedLanguage = code
        } else {
            requestedLanguage = nil
        }
        await self.ensureRestored()
        guard self.stopTask == nil,
              self.interruptionTask == nil,
              self.terminationTask == nil,
              !self.isProcessing,
              !self.isRecording,
              !self.isDeleting,
              self.startReservation == nil
        else { throw MeetingCoordinatorError.activityInProgress }
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }

        if self.activeSession?.id == sessionID {
            guard let session = self.activeSession, session.hasRetryableAudio else {
                throw MeetingCoordinatorError.noRecoverableAudio
            }
            try await self.resetRetainedCheckpointIfRequested(session: session, requestedLanguage: requestedLanguage, restarting: restarting)
            let retainedLanguage = Self.retainedCompletedLanguage(for: session) ?? session.languageCode
            let hadVisibleTranscript = Self.retainedCompletedLanguage(for: session) != nil
            var prepared = session
            prepared.languageCode = retainedLanguage
            self.activeSession = prepared
            return try await self.beginProcessingRetry(
                prepared,
                retainedLanguage: retainedLanguage,
                hadVisibleTranscript: hadVisibleTranscript,
                requestedLanguageCode: requestedLanguage ?? session.languageCode
            )
        }

        if let offer = self.activeSession {
            guard offer.state == .interrupted || offer.state == .failed else {
                throw MeetingCoordinatorError.activityInProgress
            }
        }

        guard let session = try await self.store.load(id: sessionID) else {
            throw MeetingCoordinatorError.noActiveMeeting
        }
        // Re-validate: another operation may have started while we awaited the load above.
        guard self.stopTask == nil,
              self.interruptionTask == nil,
              self.terminationTask == nil,
              !self.isProcessing,
              !self.isRecording,
              !self.isDeleting,
              self.startReservation == nil
        else { throw MeetingCoordinatorError.activityInProgress }
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }
        guard session.hasRetryableAudio else { throw MeetingCoordinatorError.noRecoverableAudio }
        try await self.resetRetainedCheckpointIfRequested(session: session, requestedLanguage: requestedLanguage, restarting: restarting)

        // Acquire before displacing/adopting so a throw here never strands activeSession mid-transition.
        if self.activityLease == nil {
            self.activityLease = try await self.audioArbiter.acquireMeetingCapture()
        }

        // Target is valid — only now displace the passive recovery offer it replaces.
        if var offer = self.activeSession {
            guard offer.state == .interrupted || offer.state == .failed else {
                throw MeetingCoordinatorError.activityInProgress
            }
            offer.recoveryResolvedAt = Date()
            offer.updatedAt = Date()
            try? await self.store.save(offer)
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
            guard self.terminationTask == nil else { throw MeetingCoordinatorError.activityInProgress }
            self.activeSession = nil
            self.trackHealth = [:]
            self.state = .idle
        }

        let retainedLanguage = Self.retainedCompletedLanguage(for: session) ?? session.languageCode
        let hadVisibleTranscript = Self.retainedCompletedLanguage(for: session) != nil
        var prepared = session
        prepared.languageCode = retainedLanguage
        self.activeSession = prepared
        self.trackHealth = Dictionary(uniqueKeysWithValues: prepared.audioTracks.map { ($0.kind, $0.health) })
        return try await self.beginProcessingRetry(
            prepared,
            retainedLanguage: retainedLanguage,
            hadVisibleTranscript: hadVisibleTranscript,
            requestedLanguageCode: requestedLanguage ?? session.languageCode
        )
    }

    private func resetRetainedCheckpointIfRequested(session: MeetingSession, requestedLanguage: String?, restarting: Bool) async throws {
        // A different language cannot resume inference pinned to the old configuration.
        // Keep the saved transcript and audio; only the admitted retry owns this reset.
        guard restarting || requestedLanguage != nil else { return }
        guard session.audioStorageMode == .retainedFiles, session.retention.audioDeletedAt == nil,
              let directory = try await self.store.existingSessionDirectory(for: session.id) else {
            throw MeetingCoordinatorError.noRecoverableAudio
        }
        try Task.checkCancellation()
        guard self.terminationTask == nil, !self.isDeleting, !self.isRecording, !self.isProcessing else {
            throw MeetingCoordinatorError.activityInProgress
        }
        let reset = Task.detached(priority: .utility) {
            try Task.checkCancellation()
            if !restarting, let requestedLanguage {
                let checkpoint = MeetingRetainedProcessingCheckpoint(sessionDirectory: directory)
                let inferenceLanguage = (try? checkpoint.retainedLanguageCode(session: session))
                    ?? session.processingAttempts.last(where: { $0.languageCode != nil })?.languageCode
                    ?? session.languageCode
                // Failed/cancelled language changes restore the old visible transcript but keep
                // the new inference pin. Resume that attempt, or reset when its language changes.
                guard requestedLanguage != inferenceLanguage else { return }
            }
            try Task.checkCancellation()
            try MeetingRetainedProcessingCheckpoint.remove(in: directory)
            let legacyCheckpoint = directory.appendingPathComponent("checkpoint.json")
            if FileManager.default.fileExists(atPath: legacyCheckpoint.path) {
                try FileManager.default.removeItem(at: legacyCheckpoint)
            }
        }
        try await withTaskCancellationHandler { try await reset.value } onCancel: { reset.cancel() }
        try Task.checkCancellation()
        guard self.terminationTask == nil else { throw CancellationError() }
    }

    /// Puts back the transcript that was already stored. A failed language change must not leave
    /// that transcript labeled with the language that did not finish, or hide it behind the failure screen.
    private func restoreStoredTranscript(_ session: inout MeetingSession, from inputSession: MeetingSession) {
        session.title = inputSession.title
        session.defaultTitleBase = inputSession.defaultTitleBase
        session.automaticTitle = inputSession.automaticTitle
        session.speakers = inputSession.speakers
        session.transcriptSegments = inputSession.transcriptSegments
        session.postProcessing = inputSession.postProcessing
        session.transcriptCoverageGaps = inputSession.transcriptCoverageGaps
        session.resultSidecarReference = inputSession.resultSidecarReference
        session.transcriptIsComplete = inputSession.transcriptIsComplete
        session.transcriptTimeDomain = inputSession.transcriptTimeDomain
    }

    /// Puts the pre-retry language back. Legacy meetings may have no attempt language at all, so the
    /// session language from before this run is the one that still labels the stored transcript.
    private func restoreRetainedLanguage(_ session: inout MeetingSession, retainedLanguage: String) {
        guard retainedLanguage != session.languageCode else { return }
        session.languageCode = retainedLanguage
    }

    private func publishRetryOutcome(_ session: MeetingSession, failure: MeetingSessionFailure?) {
        self.operationGeneration = nil
        if session.state == .completed {
            self.activeSession = nil
            self.latestCompletedSession = session
            self.state = .completed(session.id)
        } else if session.state == .interrupted {
            self.activeSession = session
            self.state = .interrupted(session.id)
        } else if let failure {
            self.activeSession = session
            self.state = .failed(session.id, failure)
        }
    }

    private func beginProcessingRetry(
        _ inputSession: MeetingSession,
        retainedLanguage: String,
        hadVisibleTranscript: Bool,
        requestedLanguageCode: String
    ) async throws -> MeetingSession {
        var session = inputSession
        if self.activityLease == nil {
            self.activityLease = try await self.audioArbiter.acquireMeetingCapture()
        }
        let generation = UUID()
        self.captureStopHandoff = nil
        self.operationGeneration = generation
        session.state = .processing
        self.state = .processing(session.id, .pending)
        // Close out zombie attempts left behind by a previous crash before starting a fresh one.
        let closedAt = Date()
        for index in session.processingAttempts.indices where session.processingAttempts[index].completedAt == nil {
            session.processingAttempts[index].completedAt = closedAt
            session.processingAttempts[index].errorCode = session.processingAttempts[index].errorCode ?? "interrupted"
        }
        // Record the language on the new attempt before the first save. A language change
        // otherwise leaves only the previous attempt's language, and persistence rejects the session.
        var attempt = Self.pendingProcessingAttempt()
        attempt.languageCode = requestedLanguageCode
        attempt.retainedTranscriptLanguageCode = hadVisibleTranscript ? retainedLanguage : nil
        session.processingAttempts.append(attempt)
        session.updatedAt = Date()
        self.activeSession = session
        try? await self.store.save(session)
        // Processing regenerates the transcript; only clear the undo stack once retry actually
        // proceeds so a lease/save failure above leaves the prior correction undoable.
        self.correctionUndoStacks[session.id] = nil
        return try await self.process(
            session,
            generation: generation,
            retainedLanguage: retainedLanguage,
            hadVisibleTranscript: hadVisibleTranscript,
            requestedLanguageCode: requestedLanguageCode
        )
    }

    func deleteSession(id: MeetingSessionID, expectedOwnership: MeetingProfileOwnership? = nil,
                       validating: (@Sendable (MeetingSession) throws -> Void)? = nil) async throws {
        await self.ensureRestored()
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }
        guard self.isQuiescent else { throw MeetingCoordinatorError.activityInProgress }
        self.isDeleting = true
        defer { self.isDeleting = false }
        await self.flushQueuedPersistence()
        try Task.checkCancellation()
        // Re-check: the flush await gives a racing operation a window to start.
        guard !self.hasBlockingActivityTask else { throw MeetingCoordinatorError.activityInProgress }
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }
        if let validating {
            guard let expectedOwnership else { throw CocoaError(.featureUnsupported) }
            try await self.store.delete(id: id, expectedOwnership: expectedOwnership, validating: validating)
        } else if let expectedOwnership { try await self.store.delete(id: id, expectedOwnership: expectedOwnership) }
        else { try await self.store.delete(id: id) }
        // Receipt-driven removal can target older history without changing the
        // current recording state. Reuse the existing retention refresh signal.
        self.retentionSweepRevision &+= 1
        self.correctionUndoStacks[id] = nil
        if self.activeSession?.id == id {
            self.activeSession = nil
            self.trackHealth = [:]
            self.state = .idle
        }
        if self.latestCompletedSession?.id == id {
            self.latestCompletedSession = nil
            if self.state == .completed(id) {
                self.state = .idle
            }
        }
    }

    @discardableResult
    func recordAgain(
        from sourceID: MeetingSessionID,
        configuration: MeetingCaptureConfiguration
    ) async throws -> MeetingSession {
        await self.ensureRestored()
        guard !self.hasBlockingActivityTask,
              !self.isProcessing,
              !self.isRecording,
              !self.isDeleting
        else { throw MeetingCoordinatorError.activityInProgress }
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.maintenanceInProgress }
        if let snapshot = self.activeSession, snapshot.id == sourceID {
            guard snapshot.state == .interrupted || snapshot.state == .failed else {
                throw MeetingCoordinatorError.activityInProgress
            }
            return try await self.recordAgainFromActiveOffer(snapshot, configuration: configuration)
        }
        return try await self.recordAgainFromHistory(sourceID: sourceID, configuration: configuration)
    }

    private func recordAgainFromActiveOffer(
        _ snapshot: MeetingSession,
        configuration: MeetingCaptureConfiguration
    ) async throws -> MeetingSession {
        return try await self.startRecording(
            configuration: configuration, passiveOffer: snapshot, resolvingSourceID: snapshot.id
        )
    }

    private func recordAgainFromHistory(
        sourceID: MeetingSessionID,
        configuration: MeetingCaptureConfiguration
    ) async throws -> MeetingSession {
        return try await self.startRecording(
            configuration: configuration, passiveOffer: nil, resolvingSourceID: sourceID
        )
    }

    // MARK: - Transcript corrections

    /// Gate → resolve → guard → mutate copy → save → commit (inverse pushed only after save).
    /// Active-slot targets also check the generations: closes the `.preparing` window that
    /// `!isProcessing && !isRecording` alone would miss.
    private func assertSafeToMutate(sessionID: MeetingSessionID) throws {
        guard !self.hasBlockingActivityTask, !self.isDeleting
        else { throw MeetingCoordinatorError.activityInProgress }
        if self.activeSession?.id == sessionID {
            guard self.captureGeneration == nil, self.operationGeneration == nil
            else { throw MeetingCoordinatorError.activityInProgress }
        } else if self.isProcessing, case let .processing(processingID, _) = self.state, processingID == sessionID {
            throw MeetingCoordinatorError.activityInProgress
        }
    }

    private func performCorrection(
        sessionID: MeetingSessionID,
        expectedOwnership: MeetingProfileOwnership? = nil,
        mutate: (inout MeetingSession) throws -> TranscriptCorrection
    ) async throws -> MeetingSession {
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.activityInProgress }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        await self.ensureRestored()
        await self.flushQueuedPersistence()

        var target = try await self.resolveSession(sessionID)

        // Re-check after the awaits above: another operation may have started while we waited.
        try self.assertSafeToMutate(sessionID: sessionID)
        try Task.checkCancellation()
        try Self.validateCorrectionOwnership(target, expected: expectedOwnership)

        let before = target
        let sourceOwnership = Self.correctionOwnership(before)
        let inverse = try mutate(&target)
        guard target != before else { return target }
        // Speaker identity/attribution changes preserve recognized text. Only actual text
        // changes own privacy preparation and publication, including edits after a cold launch.
        if target.piiRedactionEnabled == true, inverse.requiresTranscriptPrivacyPublication {
            target = try await self.redactedTranscriptCorrection(target)
        }
        try Task.checkCancellation()
        try self.assertSafeToMutate(sessionID: sessionID)
        try Self.validateCorrectionOwnership(target, expected: expectedOwnership)
        try await self.store.save(target)

        var stack = self.correctionUndoStacks[sessionID] ?? []
        stack.append(OwnedTranscriptCorrection(ownership: sourceOwnership, correction: inverse))
        if stack.count > Self.correctionUndoStackCap {
            stack.removeFirst(stack.count - Self.correctionUndoStackCap)
        }
        self.correctionUndoStacks[sessionID] = stack

        self.refreshSlots(with: target)
        return target
    }

    /// The mutation gate keeps corrections serial while the exact chosen privacy capability
    /// prepares and admits text. Termination can still invalidate this owner during an await.
    private func redactedTranscriptCorrection(_ session: MeetingSession) async throws -> MeetingSession {
        guard let redactor = try self.redactorProvider() else { throw MeetingPrivacyPublicationError.redactorUnavailable }
        let identity = redactor.checkpointIdentity
        try Task.checkCancellation()
        try await redactor.prepareForMeeting()
        try Task.checkCancellation()
        guard redactor.checkpointIdentity == identity else {
            throw MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration
        }
        try self.assertSafeToMutate(sessionID: session.id)
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedCopy(
            session: session, using: redactor, preservingPublicationArtifacts: true)
        try Task.checkCancellation()
        guard redactor.checkpointIdentity == identity else {
            throw MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration
        }
        try self.assertSafeToMutate(sessionID: session.id)
        return safe
    }

    private func resolveSession(_ id: MeetingSessionID) async throws -> MeetingSession {
        if let active = self.activeSession, active.id == id { return active }
        if let completed = self.latestCompletedSession, completed.id == id { return completed }
        if let loaded = try await self.store.loadTranscript(id: id) { return loaded }
        throw MeetingCoordinatorError.noActiveMeeting
    }

    private func refreshSlots(with session: MeetingSession) {
        if self.activeSession?.id == session.id { self.activeSession = session }
        if self.latestCompletedSession?.id == session.id { self.latestCompletedSession = session }
    }

    private static func correctionOwnership(_ session: MeetingSession) -> MeetingProfileOwnership? {
        // A facade never exposes an ownerless account manifest. Only actual guest mode may
        // normalize its legacy nil owner; synthetic/custom stores keep nil compatibility.
        session.profileOwnership ?? (PrivateProfileStorage.current.isGuest ? .guest : nil)
    }

    private static func validateCorrectionOwnership(_ session: MeetingSession, expected: MeetingProfileOwnership?) throws {
        guard expected == nil || self.correctionOwnership(session) == expected else { throw AccountError.staleOperation }
    }

    @discardableResult
    func editTranscriptText(sessionID: MeetingSessionID, segmentID: MeetingTranscriptSegmentID, text: String, expectedRevision: Int, expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID, expectedOwnership: expectedOwnership) { session in
            guard let index = session.transcriptSegments.firstIndex(where: { $0.id == segmentID }) else {
                throw MeetingDomainError.segmentNotFound
            }
            let previous = session.transcriptSegments[index]
            guard previous.revision == expectedRevision else { throw MeetingDomainError.staleTranscriptEdit }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { throw MeetingDomainError.emptyTranscriptText }
            let inverse = TranscriptCorrection.editText(
                segmentID: segmentID,
                previousText: previous.text,
                previousOriginalText: previous.originalText,
                previousUserTextEdited: previous.isUserTextEdited,
                previousPrivacyReplacement: previous.containsPrivacyReplacement,
                previousRevision: previous.revision
            )
            guard trimmed != previous.text else { return inverse }
            session.transcriptSegments[index].originalText = previous.originalText ?? previous.text
            session.transcriptSegments[index].isUserTextEdited = true
            session.transcriptSegments[index].text = trimmed
            session.transcriptSegments[index].revision += 1
            session.updatedAt = Date()
            return inverse
        }
    }

    @discardableResult
    func renameSpeaker(sessionID: MeetingSessionID, speakerID: SessionSpeakerID, to displayName: String, expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID, expectedOwnership: expectedOwnership) { session in
            let previous = session.speakers.first(where: { $0.id == speakerID })
            try session.renameSpeaker(id: speakerID, to: displayName)
            return .rename(speakerID: speakerID, previousName: previous?.displayName ?? "",
                           previousGeneratedNumber: previous?.generatedParticipantNumber,
                           previousCustomDisplayName: previous?.usesCustomDisplayName)
        }
    }

    @discardableResult
    func renameSpeakers(sessionID: MeetingSessionID, names: [SessionSpeakerID: String], expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID, expectedOwnership: expectedOwnership) { session in
            var applied: [(speakerID: SessionSpeakerID, previousName: String, previousGeneratedNumber: Int?, previousCustomDisplayName: Bool?)] = []
            for (speakerID, name) in names {
                guard let existing = session.speakers.first(where: { $0.id == speakerID }),
                      existing.mergedIntoSpeakerID == nil else { continue }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, trimmed != existing.displayName else { continue }
                try session.renameSpeaker(id: speakerID, to: trimmed)
                applied.append((speakerID, existing.displayName, existing.generatedParticipantNumber, existing.usesCustomDisplayName))
            }
            return .renameBatch(applied)
        }
    }

    /// Changes only this meeting's participant roster. It never enrolls a voice or changes
    /// a transcript member's native evidence, wording or participant identity.
    @discardableResult
    func setLocalUserSpeaker(
        sessionID: MeetingSessionID,
        speakerID: SessionSpeakerID?,
        expectedOwnership: MeetingProfileOwnership? = nil
    ) async throws -> MeetingSession {
        // This explicit user operation deliberately renumbers generated labels using its
        // own interface snapshot, independently of background attempts' frozen templates.
        let speakerNameFormat = PichiLocalization.text("Speaker %lld")
        return try await self.performCorrection(sessionID: sessionID, expectedOwnership: expectedOwnership) { session in
            let previous = session.speakers.map { speaker in
                (speakerID: speaker.id, previousIsLocalUser: speaker.isLocalUser,
                 previousName: speaker.displayName, previousGeneratedNumber: speaker.generatedParticipantNumber,
                 previousCustomDisplayName: speaker.usesCustomDisplayName,
                 previousIdentityIsProvisional: speaker.identityIsProvisional)
            }
            try session.setLocalUserSpeaker(id: speakerID, speakerNameFormat: speakerNameFormat)
            return .localUserRole(previous)
        }
    }

    @discardableResult
    func editSpeakers(sessionID: MeetingSessionID, edits: MeetingSpeakerEdits, expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID, expectedOwnership: expectedOwnership) { session in
            let merges = try edits.resolvedMerges()
            let previousSpeakers = session.speakers
            let assignments = session.transcriptSegments.compactMap { segment -> SpeakerAssignmentCorrection? in
                guard let speakerID = segment.speakerID, merges[speakerID] != nil else { return nil }
                return SpeakerAssignmentCorrection(segment)
            }
            for source in merges.keys.sorted(by: { $0.uuidString < $1.uuidString }) {
                if let target = merges[source] { try session.mergeSpeakers(source, into: target) }
            }
            for (speakerID, name) in edits.names {
                guard session.speakers.contains(where: { $0.id == speakerID && $0.mergedIntoSpeakerID == nil }) else { continue }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { continue }
                try session.renameSpeaker(id: speakerID, to: trimmed)
            }
            return .speakerEdits(previousSpeakers: previousSpeakers, assignments: assignments)
        }
    }

    @discardableResult
    func reassignSegment(
        sessionID: MeetingSessionID,
        segmentID: MeetingTranscriptSegmentID,
        to speakerID: SessionSpeakerID,
        expectedOwnership: MeetingProfileOwnership? = nil
    ) async throws -> MeetingSession {
        try await self.reassignSegments(sessionID: sessionID, segmentIDs: [segmentID], to: speakerID, expectedOwnership: expectedOwnership)
    }

    /// A readable paragraph can contain several native members. One participant choice owns
    /// one atomic save and inverse, even when the user explicitly selects several members.
    @discardableResult
    func reassignSegments(
        sessionID: MeetingSessionID,
        segmentIDs: [MeetingTranscriptSegmentID],
        to speakerID: SessionSpeakerID,
        expectedOwnership: MeetingProfileOwnership? = nil
    ) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID, expectedOwnership: expectedOwnership) { session in
            guard session.activeSpeakers.contains(where: { $0.id == speakerID }) else {
                throw MeetingDomainError.speakerNotFound
            }
            let indicesByID = Dictionary(uniqueKeysWithValues:
                session.transcriptSegments.enumerated().map { ($0.element.id, $0.offset) })
            var selectedIDs = Set<MeetingTranscriptSegmentID>()
            var selectedIndices: [Int] = []
            // Validate every requested identity before touching the mutation copy. Repeated
            // member IDs are naturally one selection rather than repeated revisions.
            for id in segmentIDs where selectedIDs.insert(id).inserted {
                guard let index = indicesByID[id] else { throw MeetingDomainError.segmentNotFound }
                selectedIndices.append(index)
            }
            guard !selectedIndices.isEmpty else { return .reassign([]) }
            let presentations = MeetingTranscriptExporter.speakerPresentations(in: session)
            var inverse: [SpeakerAssignmentCorrection] = []
            for index in selectedIndices {
                let previous = session.transcriptSegments[index]
                if session.reassignValidatedSegment(at: index, to: speakerID,
                    replacingReadingSpeakerID: presentations[previous.id]?.participantID) {
                    inverse.append(SpeakerAssignmentCorrection(previous))
                }
            }
            return .reassign(inverse)
        }
    }

    @discardableResult
    func nameUnknownSegment(
        sessionID: MeetingSessionID,
        segmentID: MeetingTranscriptSegmentID,
        displayName: String,
        expectedOwnership: MeetingProfileOwnership? = nil
    ) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID, expectedOwnership: expectedOwnership) { session in
            guard let segment = session.transcriptSegments.first(where: { $0.id == segmentID }) else {
                throw MeetingDomainError.segmentNotFound
            }
            let speakerID = try session.nameUnknownSegment(id: segmentID, displayName: displayName)
            return .nameUnknown(
                segmentID: segmentID,
                createdSpeakerID: speakerID,
                previousOverlap: segment.overlap,
                previousAttributionState: segment.attributionState,
                previousSpeakerAttribution: segment.speakerAttribution,
                previousLegacyInference: segment.speakerAttributionInference,
                previousUserSpeakerAssigned: segment.isUserSpeakerAssigned,
                previousRevision: segment.revision
            )
        }
    }

    @discardableResult
    func mergeSpeakers(sessionID: MeetingSessionID, source: SessionSpeakerID, into targetID: SessionSpeakerID, expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        try await self.performCorrection(sessionID: sessionID, expectedOwnership: expectedOwnership) { session in
            let movedSegments = session.transcriptSegments
                .filter { $0.speakerID == source }
                .map { (id: $0.id, previousRevision: $0.revision, previousSpeakerAttribution: $0.speakerAttribution, previousLegacyInference: $0.speakerAttributionInference, previousUserSpeakerAssigned: $0.isUserSpeakerAssigned) }
            try session.mergeSpeakers(source, into: targetID)
            return .merge(sourceID: source, targetID: targetID, movedSegments: movedSegments)
        }
    }

    @discardableResult
    func undoTranscriptCorrection(sessionID: MeetingSessionID, expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.activityInProgress }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        await self.ensureRestored()
        await self.flushQueuedPersistence()

        guard var stack = self.correctionUndoStacks[sessionID], let entry = stack.last else {
            throw MeetingCoordinatorError.noCorrectionToUndo
        }

        var target = try await self.resolveSession(sessionID)

        try self.assertSafeToMutate(sessionID: sessionID)
        try Task.checkCancellation()
        try Self.validateCorrectionOwnership(target, expected: expectedOwnership)
        guard Self.correctionOwnership(target) == entry.ownership else { throw AccountError.staleOperation }
        let correction = entry.correction
        stack.removeLast()

        guard Self.applyInverse(correction, to: &target) else {
            // Inverse target no longer exists: drop the stale entry, never save a no-op.
            self.correctionUndoStacks[sessionID] = stack
            throw MeetingCoordinatorError.noCorrectionToUndo
        }
        // Deliberate: undo bumps updatedAt like any other mutation rather than restoring the prior value.
        target.updatedAt = Date()

        do {
            if target.piiRedactionEnabled == true, correction.requiresTranscriptPrivacyPublication {
                target = try await self.redactedTranscriptCorrection(target)
            }
            try Task.checkCancellation()
            try self.assertSafeToMutate(sessionID: sessionID)
            guard Self.correctionOwnership(target) == entry.ownership else { throw AccountError.staleOperation }
            try await self.store.save(target)
        } catch {
            stack.append(entry)
            self.correctionUndoStacks[sessionID] = stack
            throw error
        }
        self.correctionUndoStacks[sessionID] = stack

        self.refreshSlots(with: target)
        return target
    }

    func canUndoCorrection(sessionID: MeetingSessionID) -> Bool {
        !(self.correctionUndoStacks[sessionID]?.isEmpty ?? true)
    }

    /// Not a transcript correction: does not push onto `correctionUndoStacks`.
    @discardableResult
    func renameSession(sessionID: MeetingSessionID, to title: String, expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.activityInProgress }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        await self.ensureRestored()
        await self.flushQueuedPersistence()

        var target = try await self.resolveSession(sessionID)

        try self.assertSafeToMutate(sessionID: sessionID)
        try Self.validateCorrectionOwnership(target, expected: expectedOwnership)

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw MeetingDomainError.emptyMeetingTitle }
        guard target.displayTitle != trimmed || target.automaticTitle != nil else { return target }

        let directory: URL?
        if let directoryOwner = expectedOwnership ?? target.profileOwnership {
            directory = try await self.store.loadExistingSource(id: sessionID, expectedOwnership: directoryOwner)?.directory
        } else {
            // Legacy ownerless guest mode has one root and no account fallback. Custom
            // ownerless stores retain their existing summary-migration compatibility.
            directory = try await self.store.existingSessionDirectory(for: sessionID)
        }
        if let directory {
            let snapshot = target
            try await Task.detached(priority: .utility) {
                try MeetingSavedSummary.migrateLegacySummaries(in: directory, for: snapshot)
            }.value
        }

        target.title = trimmed
        target.defaultTitleBase = nil
        target.automaticTitle = nil
        target.updatedAt = Date()
        try await self.store.save(target)

        self.refreshSlots(with: target)
        return target
    }

    // MARK: - Audio retention

    /// Manifest-first: cleared manifest saved before file removal, so a crash between the two
    /// leaves a leftover `tracks/` that the sweep heals. Undo stack survives (audio-independent).
    @discardableResult
    func deleteAudio(sessionID: MeetingSessionID, expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        guard !self.isMutatingSession else { throw MeetingCoordinatorError.activityInProgress }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        await self.ensureRestored()
        await self.flushQueuedPersistence()

        var target = try await self.resolveSession(sessionID)

        try self.assertSafeToMutate(sessionID: sessionID)
        try Self.validateCorrectionOwnership(target, expected: expectedOwnership)

        target = try await self.applyAudioDeletion(to: target, expectedOwnership: expectedOwnership)

        self.refreshSlots(with: target)
        return target
    }

    /// Shared by deleteAudio and the sweep — the sweep already holds the gate, so it must not
    /// call the public guard-throwing API.
    private func applyAudioDeletion(to inputTarget: MeetingSession, expectedOwnership: MeetingProfileOwnership? = nil) async throws -> MeetingSession {
        var target = inputTarget
        guard target.retention.audioDeletedAt == nil else { return target }
        for index in target.audioTracks.indices {
            target.audioTracks[index].chunks = []
        }
        target.retention.audioDeletedAt = Date()
        target.updatedAt = Date()
        if target.piiRedactionEnabled == true {
            guard let redactor = try self.redactorProvider() else { throw MeetingPrivacyPublicationError.redactorUnavailable }
            target = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: target, using: redactor, preservingPublicationArtifacts: true)
        }
        try await self.store.save(target)
        do {
            if let owner = expectedOwnership ?? target.profileOwnership {
                try await self.store.deleteAudioFiles(for: target.id, expectedOwnership: owner)
            } else {
                try await self.store.deleteAudioFiles(for: target.id)
            }
        } catch {
            DebugLogger.shared.warning(
                "Failed to remove audio files for \(target.id) after save; sweep will heal it later: \(error)",
                source: "MeetingSessionCoordinator"
            )
        }
        return target
    }

    private func releaseMutationGate() {
        self.isMutatingSession = false
        // A sweep re-armed during termination would race the app's exit.
        guard self.sweepPending else { return }
        self.sweepPending = false
        guard self.terminationTask == nil else { return }
        Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
    }

    /// Skips (pending) while another sweep or mutation is in flight; the releasing op reschedules it.
    /// Manifests are decoded before the mutation gate that Start and the other mutations check, so a
    /// long history does not hold them. The gate covers only revalidation, healing and deletion.
    func sweepExpiredAudio() async {
        guard !self.isMutatingSession, !self.isReadingRetentionSessions else {
            self.sweepPending = true
            return
        }
        self.isReadingRetentionSessions = true
        // A queued tail save landing after this read would hide a newly eligible session.
        await self.flushQueuedPersistence()

        let sessions: [MeetingSession]
        do {
            sessions = try await self.store.loadHistoryForMaintenance()
        } catch {
            self.finishRetentionRead()
            DebugLogger.shared.warning(
                "Retention sweep could not load sessions; leaving the current timer as-is: \(error)",
                source: "MeetingSessionCoordinator"
            )
            return
        }
        let maintenanceOwners = Dictionary(sessions.compactMap { session in
            session.profileOwnership.map { (session.id, $0) }
        }, uniquingKeysWith: { first, _ in first })
        var leftovers: [(id: MeetingSessionID, ownership: MeetingProfileOwnership?, leftover: LeftoverAudio)] = []
        for session in sessions {
            if let leftover = await self.leftoverAudio(for: session) {
                leftovers.append((session.id, session.profileOwnership, leftover))
            }
        }
        self.isReadingRetentionSessions = false
        let policy = self.settings.meetingAudioRetentionPolicy
        let now = Date()
        var nextDeadline: Date?
        var expiredIDs: [MeetingSessionID] = []
        for session in sessions where session.retention.audioDeletedAt == nil && Self.isSweepEligible(session) {
            guard let deadline = policy.deadline(endedAt: session.endedAt, startedAt: session.startedAt) else { continue }
            if deadline <= now {
                expiredIDs.append(session.id)
            } else if nextDeadline.map({ deadline < $0 }) ?? true {
                nextDeadline = deadline
            }
        }
        guard !leftovers.isEmpty || !expiredIDs.isEmpty else {
            self.scheduleRetentionTimer(nextDeadline: nextDeadline)
            self.finishRetentionRead()
            return
        }
        guard self.terminationTask == nil else { return }
        guard !self.isMutatingSession else {
            self.sweepPending = true
            return
        }
        guard self.startReservation == nil else {
            // Recording admission takes precedence over maintenance; a short re-arm finishes it.
            self.sweepPending = false
            self.scheduleRetentionTimer(nextDeadline: min(nextDeadline ?? .distantFuture, now.addingTimeInterval(60)))
            return
        }
        self.isMutatingSession = true
        defer { self.releaseMutationGate() }

        // A queued tail save landing after our deletes would resurrect the audio manifest.
        await self.flushQueuedPersistence()

        for (id, ownership, leftover) in leftovers where self.isSafeToSweep(sessionID: id) {
            switch leftover {
            case let .workingState(directory): try? MeetingRetainedProcessingCheckpoint.remove(in: directory)
            case .audioFiles:
                if let ownership { try? await self.store.deleteAudioFiles(for: id, expectedOwnership: ownership) }
                else { try? await self.store.deleteAudioFiles(for: id) }
            }
        }

        var deletedAudio = false
        for id in expiredIDs {
            guard self.isSafeToSweep(sessionID: id) else {
                // Contended, not expired: retry soon.
                nextDeadline = min(nextDeadline ?? .distantFuture, Date().addingTimeInterval(60))
                continue
            }
            // The decoded snapshot predates the gate. Delete only what is still expired now.
            let currentPolicy = self.settings.meetingAudioRetentionPolicy
            guard let session = try? await self.resolveSession(id),
                  maintenanceOwners[id].map({ $0.matchesPersistedOwner(session.profileOwnership) }) ?? true,
                  session.retention.audioDeletedAt == nil, Self.isSweepEligible(session),
                  let deadline = currentPolicy.deadline(endedAt: session.endedAt, startedAt: session.startedAt)
            else { continue }
            guard deadline <= Date() else {
                if nextDeadline.map({ deadline < $0 }) ?? true { nextDeadline = deadline }
                continue
            }

            do {
                let target = try await self.applyAudioDeletion(to: session, expectedOwnership: maintenanceOwners[id])
                self.refreshSlots(with: target)
                deletedAudio = true
            } catch {
                DebugLogger.shared.warning(
                    "Retention sweep failed for \(session.id): \(error)",
                    source: "MeetingSessionCoordinator"
                )
            }
        }

        if deletedAudio { self.retentionSweepRevision &+= 1 }
        self.scheduleRetentionTimer(nextDeadline: nextDeadline)
    }

    /// A request that arrived while manifests were being read runs once this read is finished.
    private func finishRetentionRead() {
        self.isReadingRetentionSessions = false
        let waiters = self.retentionReadWaiters
        self.retentionReadWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
        guard self.sweepPending, !self.isMutatingSession else { return }
        self.sweepPending = false
        guard self.terminationTask == nil else { return }
        Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
    }

    private enum LeftoverAudio {
        case workingState(URL)
        case audioFiles
    }

    /// Read-only. An empty recreated tracks directory alone is not crash residue. Working-state
    /// files can outlive tracks after interruption and must also trigger the existing cleanup.
    private func leftoverAudio(for session: MeetingSession) async -> LeftoverAudio? {
        let fullyCompleted = session.state == .completed && session.transcriptIsComplete == true
        guard session.retention.audioDeletedAt != nil || fullyCompleted else { return nil }
        let directory: URL?
        if let owner = session.profileOwnership {
            directory = try? await self.store.loadExistingSource(id: session.id, expectedOwnership: owner)?.directory
        } else { directory = try? await self.store.existingSessionDirectory(for: session.id) }
        guard let directory else { return nil }
        let hasWorkingState = (try? MeetingRetainedProcessingCheckpoint.hasWorkingState(in: directory)) ?? false
        if session.retention.audioDeletedAt == nil {
            // Completion is already durable. A crash before cache removal must not retain
            // sensitive working text indefinitely under a never-delete-audio policy.
            return hasWorkingState ? .workingState(directory) : nil
        }
        let tracksPath = directory.appendingPathComponent("tracks", isDirectory: true).path
        let hasAudio = (try? FileManager.default.contentsOfDirectory(atPath: tracksPath).isEmpty == false) ?? false
        let hasLegacyCheckpoint = FileManager.default.fileExists(atPath: directory.appendingPathComponent("checkpoint.json").path)
        return hasAudio || hasWorkingState || hasLegacyCheckpoint ? .audioFiles : nil
    }

    /// A quiescent active slot (resolved offer, parked completed session) is safe to sweep.
    private func isSafeToSweep(sessionID: MeetingSessionID) -> Bool {
        guard self.activeSession?.id == sessionID else { return true }
        return !self.hasBlockingActivityTask && !self.isProcessing && !self.isRecording && !self.isDeleting
    }

    private static func isSweepEligible(_ session: MeetingSession) -> Bool {
        switch session.state {
        case .completed:
            return true
        case .failed, .interrupted:
            // Dismissed wrecks don't keep audio forever; unresolved ones are never swept.
            return session.recoveryResolvedAt != nil
        default:
            return false
        }
    }

    /// Exposed for tests only: whether a future-deadline sweep is currently scheduled.
    var hasScheduledRetentionSweep: Bool {
        self.retentionTimerTask != nil
    }

    private func scheduleRetentionTimer(nextDeadline: Date?) {
        self.retentionTimerTask?.cancel()
        guard let nextDeadline else {
            self.retentionTimerTask = nil
            return
        }
        // Daily bound: protects the UInt64 conversion and self-heals miscomputed deadlines.
        let delaySeconds = min(max(0, nextDeadline.timeIntervalSinceNow), 86_400)
        self.retentionTimerTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(delaySeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            await self?.sweepExpiredAudio()
        }
    }

    /// False when the inverse's target no longer exists; caller must not save or re-push.
    private static func applyInverse(_ correction: TranscriptCorrection, to session: inout MeetingSession) -> Bool {
        switch correction {
        case let .editText(segmentID, previousText, previousOriginalText, previousUserTextEdited, previousPrivacyReplacement, previousRevision):
            guard let index = session.transcriptSegments.firstIndex(where: { $0.id == segmentID }) else { return false }
            session.transcriptSegments[index].text = previousText
            session.transcriptSegments[index].originalText = previousOriginalText
            session.transcriptSegments[index].isUserTextEdited = previousUserTextEdited
            session.transcriptSegments[index].containsPrivacyReplacement = previousPrivacyReplacement
            session.transcriptSegments[index].revision = previousRevision
            return true
        case let .rename(speakerID, previousName, previousGeneratedNumber, previousCustomDisplayName):
            guard let index = session.speakers.firstIndex(where: { $0.id == speakerID }) else { return false }
            session.speakers[index].displayName = previousName
            session.speakers[index].generatedParticipantNumber = previousGeneratedNumber
            session.speakers[index].usesCustomDisplayName = previousCustomDisplayName
            return true
        case let .localUserRole(entries):
            let indices = Dictionary(uniqueKeysWithValues: session.speakers.enumerated().map { ($0.element.id, $0.offset) })
            guard !entries.isEmpty, entries.allSatisfy({ indices[$0.speakerID] != nil }) else { return false }
            for entry in entries {
                guard let index = indices[entry.speakerID] else { return false }
                session.speakers[index].isLocalUser = entry.previousIsLocalUser
                session.speakers[index].displayName = entry.previousName
                session.speakers[index].generatedParticipantNumber = entry.previousGeneratedNumber
                session.speakers[index].usesCustomDisplayName = entry.previousCustomDisplayName
                session.speakers[index].identityIsProvisional = entry.previousIdentityIsProvisional
            }
            return true
        case let .reassign(entries):
            let indices = Dictionary(uniqueKeysWithValues: session.transcriptSegments.enumerated().map { ($0.element.id, $0.offset) })
            guard !entries.isEmpty, entries.allSatisfy({ indices[$0.segmentID] != nil }) else { return false }
            for entry in entries {
                guard let index = indices[entry.segmentID] else { return false }
                session.transcriptSegments[index].speakerID = entry.previousSpeakerID
                session.transcriptSegments[index].speakerAttribution = entry.previousSpeakerAttribution
                session.transcriptSegments[index].speakerAttributionInference = entry.previousLegacyInference
                session.transcriptSegments[index].overlap = entry.previousOverlap
                session.transcriptSegments[index].attributionState = entry.previousAttributionState
                session.transcriptSegments[index].isUserSpeakerAssigned = entry.previousUserSpeakerAssigned
                session.transcriptSegments[index].revision = entry.previousRevision
            }
            return true
        case let .nameUnknown(
            segmentID,
            createdSpeakerID,
            previousOverlap,
            previousAttributionState,
            previousSpeakerAttribution,
            previousLegacyInference,
            previousUserSpeakerAssigned,
            previousRevision
        ):
            guard let segmentIndex = session.transcriptSegments.firstIndex(where: { $0.id == segmentID }),
                  session.transcriptSegments[segmentIndex].speakerID == createdSpeakerID,
                  let speakerIndex = session.speakers.firstIndex(where: { $0.id == createdSpeakerID })
            else { return false }
            session.speakers.remove(at: speakerIndex)
            session.transcriptSegments[segmentIndex].speakerID = nil
            session.transcriptSegments[segmentIndex].speakerAttribution = previousSpeakerAttribution
            session.transcriptSegments[segmentIndex].speakerAttributionInference = previousLegacyInference
            session.transcriptSegments[segmentIndex].isUserSpeakerAssigned = previousUserSpeakerAssigned
            session.transcriptSegments[segmentIndex].overlap = previousOverlap
            session.transcriptSegments[segmentIndex].attributionState = previousAttributionState
            session.transcriptSegments[segmentIndex].revision = previousRevision
            return true
        case let .merge(sourceID, _, movedSegments):
            guard let index = session.speakers.firstIndex(where: { $0.id == sourceID }) else { return false }
            session.speakers[index].mergedIntoSpeakerID = nil
            let previousByID = Dictionary(uniqueKeysWithValues: movedSegments.map { ($0.id, $0) })
            for segmentIndex in session.transcriptSegments.indices {
                guard let previous = previousByID[session.transcriptSegments[segmentIndex].id] else { continue }
                session.transcriptSegments[segmentIndex].speakerID = sourceID
                session.transcriptSegments[segmentIndex].speakerAttribution = previous.previousSpeakerAttribution
                session.transcriptSegments[segmentIndex].speakerAttributionInference = previous.previousLegacyInference
                session.transcriptSegments[segmentIndex].isUserSpeakerAssigned = previous.previousUserSpeakerAssigned
                session.transcriptSegments[segmentIndex].revision = previous.previousRevision
            }
            return true
        case let .renameBatch(entries):
            var restored = false
            for entry in entries {
                guard let index = session.speakers.firstIndex(where: { $0.id == entry.speakerID }) else { continue }
                session.speakers[index].displayName = entry.previousName
                session.speakers[index].generatedParticipantNumber = entry.previousGeneratedNumber
                session.speakers[index].usesCustomDisplayName = entry.previousCustomDisplayName
                restored = true
            }
            return restored
        case let .speakerEdits(previousSpeakers, assignments):
            guard Set(session.speakers.map(\.id)) == Set(previousSpeakers.map(\.id)) else { return false }
            if !assignments.isEmpty, !Self.applyInverse(.reassign(assignments), to: &session) { return false }
            session.speakers = previousSpeakers
            return true
        }
    }

    func resetForNewMeeting() throws {
        guard !self.isRecording,
              !self.isProcessing,
              !self.hasBlockingActivityTask,
              !self.isDeleting
        else {
            throw MeetingCoordinatorError.activityInProgress
        }
        guard !self.isMutatingSession else {
            throw MeetingCoordinatorError.maintenanceInProgress
        }
        if var session = self.activeSession,
           session.state == .interrupted || session.state == .failed
        {
            session.recoveryResolvedAt = Date()
            session.updatedAt = Date()
            self.enqueuePersistence(session)
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
        }
        self.activeSession = nil
        self.trackHealth = [:]
        self.state = .idle
    }

    func ensureRestored() async {
        if let restoreTask {
            await restoreTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.restoreRecoverableSessionIfNeeded()
        }
        self.restoreTask = task
        await task.value
    }

    /// Clears only in-memory private projections. Stored recovery offers remain unchanged in
    /// their original profile; changing accounts must not dismiss or delete an unfinished meeting.
    func prepareForPrivateProfileTransition() async throws {
        guard isQuiescent else { throw MeetingCoordinatorError.activityInProgress }
        let timer = retentionTimerTask
        timer?.cancel(); await timer?.value; retentionTimerTask = nil; sweepPending = false
        if isReadingRetentionSessions {
            await withCheckedContinuation { retentionReadWaiters.append($0) }
        }
        locationTask?.cancel(); await locationTask?.value; locationTask = nil
        await restoreTask?.value
        await flushQueuedPersistence()
        guard isQuiescent else { throw MeetingCoordinatorError.activityInProgress }
        restoreTask = nil; activeSession = nil; latestCompletedSession = nil
        trackHealth = [:]; liveTranscript = .empty; pendingSpeech = .empty
        correctionUndoStacks.removeAll(); lastLiveSpeechAt = nil; captureStopHandoff = nil
        state = .idle
    }

    private func restoreRecoverableSessionIfNeeded() async {
        guard self.activeSession == nil else { return }
        let recoverable: [MeetingSession]
        do {
            recoverable = try await self.store.loadRecoverable()
        } catch {
            DebugLogger.shared.log("Meeting recovery scan failed; will retry next ensureRestored: \(error)")
            self.restoreTask = nil
            return
        }
        guard !recoverable.isEmpty else { return }

        var viable: [MeetingSession] = []
        for session in recoverable {
            if let restored = Self.restoringCompletedResult(session) {
                do { try await self.store.save(restored) } catch {
                    self.restoreTask = nil
                    DebugLogger.shared.log("Failed to persist retained meeting result for \(session.id): \(error)")
                }
                if self.latestCompletedSession.map({ $0.startedAt < restored.startedAt }) ?? true {
                    self.latestCompletedSession = restored
                }
                continue
            }
            let expectedKinds: Set<MeetingAudioTrackKind> = session.mode == .onlineCall
                ? [.applicationAudio, .microphone]
                : [.microphone]
            let hasExpectedTracks = Set(session.audioTracks.map(\.kind)) == expectedKinds
            if hasExpectedTracks, session.hasFinalizedAudio {
                viable.append(session)
                continue
            }
            // Non-viable sessions never occupy the active slot; a session already marked
            // .failed keeps its existing failure history instead of gaining a new one.
            if session.state == .failed {
                // Non-viable and already failed: nothing to offer now or later — resolve it
                // so it stops being rescanned. Audio stays on disk, reachable from history.
                if session.recoveryResolvedAt == nil {
                    var resolved = session
                    resolved.recoveryResolvedAt = Date()
                    resolved.updatedAt = Date()
                    try? await self.store.save(resolved)
                }
                continue
            }
            var failedSession = session
            failedSession.state = .failed
            if session.hasFinalizedAudio, failedSession.endedAt == nil {
                let backfilled = session.audioTracks
                    .compactMap(\.health.lastSampleAt)
                    .max() ?? session.updatedAt
                failedSession.endedAt = max(backfilled, session.startedAt)
            }
            let failure = Self.nonViableRecoveryFailure(for: session)
            if failedSession.failures.last?.code != failure.code {
                failedSession.failures.append(failure)
            }
            failedSession.updatedAt = Date()
            do { try await self.store.save(failedSession) } catch {
                DebugLogger.shared.log("Failed to persist non-viable recovery classification for \(session.id): \(error)")
            }
        }
        guard !viable.isEmpty else {
            if let completed = self.latestCompletedSession { self.state = .completed(completed.id) }
            return
        }

        guard let active = viable.sorted(by: { lhs, rhs in
            lhs.startedAt != rhs.startedAt
                ? lhs.startedAt < rhs.startedAt
                : lhs.id.uuidString < rhs.id.uuidString
        }).last else { return }

        for session in viable {
            guard session.id == active.id else {
                guard session.state != .interrupted, session.state != .failed else { continue }
                let updated = Self.markRecoverableInterrupted(session)
                do { try await self.store.save(updated) } catch {
                    DebugLogger.shared.log("Failed to persist deferred recovery for \(session.id): \(error)")
                }
                continue
            }
            if session.state == .failed,
               let failure = session.failures.last,
               failure.recoverable
            {
                // Preserve today's behavior: a failed-but-recoverable session is re-offered as-is.
                self.activeSession = session
                self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
                self.state = .failed(session.id, failure)
            } else {
                let updated = Self.markRecoverableInterrupted(session)
                try? await self.store.save(updated)
                self.activeSession = updated
                self.trackHealth = Dictionary(uniqueKeysWithValues: updated.audioTracks.map { ($0.kind, $0.health) })
                self.state = .interrupted(updated.id)
            }
        }
    }

    func shutdownForTermination() async {
        if let terminationTask = self.terminationTask {
            await terminationTask.value
            return
        }
        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performShutdownForTermination()
        }
        self.terminationTask = task
        await task.value
    }

    private func performShutdownForTermination() async {
        self.locationTask?.cancel()
        await self.locationTask?.value
        self.locationTask = nil
        // Invalidate a suspended permission/lease start before draining capture. Its
        // post-await ownership checks will then release any acquired lease and abort.
        self.startReservation = nil
        // Bounded: termination must never hang on a stuck mutation save.
        for _ in 0..<100 {
            guard self.isMutatingSession else { break }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        await self.restoreTask?.value
        let captureStopGeneration = self.operationGeneration ?? self.captureStopHandoff?.generation
        self.captureGeneration = nil
        self.degradeReason = nil
        self.operationGeneration = nil
        let stop = self.stopTask, interruption = self.interruptionTask, retry = self.retryTask
        stop?.cancel(); interruption?.cancel(); retry?.cancel()
        // Join the actual inference owners before a termination manifest or later cleanup can
        // claim the recording is idle. Cancellation never leaves a checkpoint writer detached.
        _ = try? await stop?.value
        await interruption?.value
        _ = try? await retry?.value

        guard var session = self.activeSession else {
            await self.flushQueuedPersistence()
            await self.capture.shutdownForTermination()
            await self.tearDownLiveTranscription()
            await self.releaseActivityLease()
            await MeetingTimelineTrace.shared?.finish()
            return
        }

        let wasCapturing = [.preparing, .recording, .recordingDegraded, .stopping].contains(session.state)
        if (wasCapturing || session.endedAt == nil),
           let joined = self.takeCaptureStopHandoff(sessionID: session.id, generation: captureStopGeneration) {
            Self.apply(joined.result, to: &session)
            if let failure = joined.failure { session.failures.append(failure) }
            // The capture owner has already joined and released this exact Stop. A second
            // stop would discard its facts by returning noActiveCapture.
            await self.capture.shutdownForTermination()
        } else if wasCapturing {
            self.state = .stopping(session.id)
            do {
                let stopResult = try await self.capture.stop(sessionID: session.id)
                Self.apply(stopResult, to: &session)
            } catch {
                if let partialResult = Self.partialStopResult(from: error) {
                    Self.apply(partialResult, to: &session)
                } else {
                    await self.capture.shutdownForTermination()
                    session.endedAt = session.endedAt ?? Date()
                }
                session.failures.append(Self.failure(from: error, domain: .capture, recoverable: true))
            }
        } else {
            await self.capture.shutdownForTermination()
        }
        await self.finishMemoryCheckpointDrain(sessionID: session.id)
        self.mergeLatestMemoryCheckpoint(into: &session)
        await self.tearDownLiveTranscription()

        let retainedResult = Self.restoringCompletedResult(session)
        session = retainedResult ?? session
        if retainedResult == nil { session.state = .interrupted }
        if !session.events.contains(where: { $0.kind == .appTermination }) {
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: .appTermination,
                trackID: nil,
                detail: wasCapturing
                    ? "Capture stopped at app termination; transcription is pending."
                    : retainedResult != nil
                    ? "Retranscription paused at app termination; the previous transcript was kept."
                    : "Transcription paused at app termination and will resume next launch."
            ))
        }
        if retainedResult == nil, Self.shouldQueuePendingAttempt(for: session) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        await self.flushQueuedPersistence()
        do {
            try await self.store.save(session)
        } catch MeetingSessionStoreError.sessionDeleted {
            // Deleted mid-shutdown: don't resurrect it as an interrupted offer.
            self.activeSession = nil
            self.trackHealth = [:]
            self.state = .idle
            await self.releaseActivityLease()
            await MeetingTimelineTrace.shared?.finish()
            return
        } catch {
            // Preserve today's behavior: reinstall as interrupted despite the save failure.
        }
        if session.state == .completed {
            self.activeSession = nil
            self.latestCompletedSession = session
            self.state = .completed(session.id)
        } else {
            self.activeSession = session
            self.state = .interrupted(session.id)
        }
        await self.releaseActivityLease()
        await MeetingTimelineTrace.shared?.finish()
    }

    private func performStopAndTranscribe(generation: UUID) async throws -> MeetingSession {
        let stopClock = ContinuousClock.now
        let profileBegan = MeetingPCMRuntimeDiagnostics.beginDetailed(.stopTotal)
        var profileSucceeded = false
        defer { MeetingPCMRuntimeDiagnostics.completedDetailed(.stopTotal, since: profileBegan, succeeded: profileSucceeded) }
        #if DEBUG && os(macOS)
        AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingCoordinator, queueRole: .mainControl, phase: .coordinatorStop)
        var diagnosticsStopSucceeded = false
        defer {
            AudioTopologyDiagnostics.record(
                .phaseEnd,
                owner: .meetingCoordinator,
                queueRole: .mainControl,
                phase: .coordinatorStop,
                status: diagnosticsStopSucceeded ? 0 : -1
            )
        }
        #endif
        guard self.operationGeneration == generation else { throw CancellationError() }
        guard var session = self.activeSession else { throw MeetingCoordinatorError.noActiveMeeting }
        if self.captureStopHandoff?.sessionID != session.id || self.captureStopHandoff?.generation != generation {
            self.captureStopHandoff = (session.id, generation, nil, nil)
        }
        self.stopRequestedAt = (session.id, Date())
        self.state = .stopping(session.id)
        session.state = .stopping
        session.updatedAt = Date()
        self.activeSession = session
        let storeBegan = MeetingPCMRuntimeDiagnostics.beginDetailed(.stopInitialStore)
        await self.flushQueuedPersistence()
        // Capture finalization takes priority over persistence availability.
        self.mergeLatestMemoryCheckpoint(into: &session)
        let persisted = (try? await self.store.save(session)) != nil
        MeetingPCMRuntimeDiagnostics.completedDetailed(.stopInitialStore, since: storeBegan, succeeded: persisted)

        let stopResult: MeetingCaptureStopResult
        do {
            let began = MeetingPCMRuntimeDiagnostics.beginDetailed(.captureStop)
            var succeeded = false
            defer { MeetingPCMRuntimeDiagnostics.completedDetailed(.captureStop, since: began, succeeded: succeeded) }
            #if DEBUG && os(macOS)
            AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingCoordinator, queueRole: .mainControl, phase: .captureStop)
            #endif
            stopResult = try await self.capture.stop(sessionID: session.id)
            self.preserveCaptureStopHandoff(stopResult, sessionID: session.id, generation: generation)
            succeeded = true
            #if DEBUG && os(macOS)
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingCoordinator, queueRole: .mainControl, phase: .captureStop)
            #endif
        } catch {
            #if DEBUG && os(macOS)
            AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingCoordinator, queueRole: .mainControl, phase: .captureStop, status: -1)
            #endif
            if let partial = Self.partialStopResult(from: error) {
                self.preserveCaptureStopHandoff(partial, sessionID: session.id, generation: generation,
                    failure: Self.failure(from: error, domain: .capture, recoverable: true))
            }
            await self.handleStopFailure(error, session: session, generation: generation)
            throw error
        }
        let teardownBegan = MeetingPCMRuntimeDiagnostics.beginDetailed(.liveTeardown)
        await self.tearDownLiveTranscription()
        MeetingPCMRuntimeDiagnostics.completedDetailed(.liveTeardown, since: teardownBegan)
        guard self.operationGeneration == generation else { throw CancellationError() }
        if Task.isCancelled {
            let stopped = MeetingCaptureError.captureStopFailed("Meeting processing was cancelled after capture stopped.", partialResult: stopResult)
            await self.handleStopFailure(stopped, session: session, generation: generation)
            throw CancellationError()
        }
        self.captureGeneration = nil
        self.degradeReason = nil
        self.mergeLatestMemoryCheckpoint(into: &session)
        self.memoryCheckpointGeneration = nil
        Self.apply(stopResult, to: &session)
        session.state = .processing
        session.processingAttempts.append(Self.pendingProcessingAttempt())
        session.updatedAt = Date()
        self.activeSession = session
        self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
        try? await self.store.save(session)
        let processed = try await self.process(
            session,
            generation: generation,
            retainedLanguage: session.languageCode,
            hadVisibleTranscript: false
        )
        profileSucceeded = true
        #if DEBUG && os(macOS)
        diagnosticsStopSucceeded = true
        #endif
        let elapsed = stopClock.duration(to: .now).components
        let milliseconds = Double(elapsed.seconds) * 1_000 + Double(elapsed.attoseconds) / 1_000_000_000_000_000
        self.processingLogger("Meeting stop_to_ready session=\(processed.id) mode=\(processed.effectiveSpeakerProcessingMode.rawValue) tracks=\(processed.audioTracks.count) elapsedMs=\(Int(milliseconds)) transcriptComplete=\(processed.transcriptIsComplete == true) resourcesHandedBack=true")
        return processed
    }

    private func mergeLatestMemoryCheckpoint(into session: inout MeetingSession) {
        guard Self.usesPCMProcessing(session), let latest = self.activeSession, latest.id == session.id else { return }
        // Checkpoint state is authoritative for the transcript and all session metadata.
        // Preserve only physical stop facts and terminal additions from this caller's copy.
        let capturedTracks = session.audioTracks
        let captureTimebase = session.timebase
        let endedAt = session.endedAt
        let state = session.state
        let events = session.events
        let failures = session.failures
        let wasIncomplete = session.transcriptIsComplete == false
        session = latest
        if wasIncomplete { session.transcriptIsComplete = false }
        if !capturedTracks.isEmpty { session.audioTracks = capturedTracks }
        if captureTimebase.firstPresentationTime != nil { session.timebase = captureTimebase }
        session.endedAt = endedAt ?? session.endedAt
        session.state = state
        let eventIDs = Set(session.events.map(\.id))
        session.events.append(contentsOf: events.filter { !eventIDs.contains($0.id) })
        let failureIDs = Set(session.failures.map(\.id))
        session.failures.append(contentsOf: failures.filter { !failureIDs.contains($0.id) })
    }

    private func finishMemoryCheckpointDrain(sessionID: MeetingSessionID) async {
        await self.processing.cancelMemoryAudio(sessionID: sessionID)
        self.memoryCheckpointGeneration = nil
    }

    private func publishLiveTranscript(_ snapshot: MeetingLiveTranscriptSnapshot, generation: UUID, redactor: (any TranscriptTextRedacting)?) {
        guard let redactor else {
            if snapshot.hasNewWords(since: self.liveTranscript) { self.lastLiveSpeechAt = Date() }
            self.liveTranscript = snapshot
            self.reconcilePendingSpeech()
            return
        }
        self.livePrivacyPublication.submit(snapshot, generation: generation, using: redactor,
            latestSnapshot: { [weak self] in
                guard let self, self.captureGeneration == generation else { return nil }
                return self.liveTranscriptionCoordinator?.latestSnapshot()
            }, publish: { [weak self] safe, generation in
                guard let self, self.liveTranscriptionCoordinator != nil,
                      self.liveTranscript.accepts(safe, generation: generation, activeGeneration: self.captureGeneration) else { return }
                if safe.hasNewWords(since: self.liveTranscript) { self.lastLiveSpeechAt = Date() }
                self.liveTranscript = safe
                self.reconcilePendingSpeech()
                if let trace = MeetingTimelineTrace.shared {
                    // Only accepted, privacy-filtered partials supply source metadata here.
                    // The two capture sources bound this metadata work independently of history.
                    for source in [MeetingLiveSpeaker.you, .them] {
                        guard let partial = self.liveTranscript.partials[source] else { continue }
                        trace.record("protected_live_publication", fields: [
                            "sessionID": self.activeSession?.id.uuidString ?? "unavailable",
                            "generation": generation.uuidString,
                            "stage": "redacted-live-snapshot", "source": source == .you ? "you" : "them",
                            "transcriptRevision": String(self.liveTranscript.revision), "partialPresent": "true",
                            "partialID": partial.id.uuidString, "sourceStartSeconds": String(partial.start),
                            "sourceEndSeconds": partial.end.map { String($0) } ?? "unavailable",
                            "utf16Count": String(partial.text.utf16.count),
                            "publicationScope": "accepted-coordinator-assignment-not-render-frame"])
                    }
                }
            }, failed: { [weak self] generation in
                guard let self, self.captureGeneration == generation else { return }
                self.handleCaptureEvent(.interrupted(kind: .captureStoppedUnexpectedly, trackID: nil,
                                                    detail: "Sensitive data redaction stopped. Recording was interrupted."), generation: generation)
            })
    }

    /// The durable protected transcript is the reading history, not an inference window.
    /// Construct the contextual projection away from the UI executor; only this already
    /// privacy-filtered value may be handed to the caption renderer.
    nonisolated static func protectedLiveHistory(session: MeetingSession, revision: UInt64,
                                 preview: MeetingLivePartial?, previewSource: MeetingLiveSpeaker = .you,
                                 otherPartials: [MeetingLiveSpeaker: MeetingLivePartial] = [:]) async throws -> MeetingLiveTranscriptSnapshot {
        let projection = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let reading = MeetingTranscriptExporter.speakerPresentations(in: session)
            var result = MeetingLiveTranscriptSnapshot.empty
            result.revision = revision
            let kinds = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.id, $0.kind) })
            result.partials = otherPartials
            result.utterances = session.transcriptSegments.enumerated().filter {
                !$0.element.isEcho && reading[$0.element.id] != nil
            }.sorted {
                ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
            }.map { _, segment in
                MeetingLiveUtterance(id: segment.id, speaker: kinds[segment.sourceTrackID] == .applicationAudio ? .them : .you, text: segment.text,
                    start: segment.start.seconds, end: segment.end.seconds,
                    participant: reading[segment.id])
            }
            let readablePreview = preview.flatMap { value in
                MeetingTranscriptSegment.textContainsLexicalContent(value.text) || value.containsPrivacyReplacement ? value : nil
            }
            result = result.settingPartial(readablePreview, for: previewSource)
            result.availability = .available
            try Task.checkCancellation()
            return result
        }
        return try await withTaskCancellationHandler {
            let result = try await projection.value
            try Task.checkCancellation()
            return result
        } onCancel: { projection.cancel() }
    }

    private func checkpointMemoryTranscript(_ batch: MeetingPCMTranscriptBatch, sessionID: UUID, generation: UUID) async throws {
        guard self.memoryCheckpointGeneration == generation, var session = self.activeSession, session.id == sessionID else { throw CancellationError() }
        if let track = batch.sourceTrack, !session.audioTracks.contains(where: { $0.id == track.id }) { session.audioTracks.append(track) }
        var indices = Dictionary(uniqueKeysWithValues: session.transcriptSegments.enumerated().map { ($0.element.id, $0.offset) })
        for segment in batch.segments {
            if let index = indices[segment.id] {
                if segment.revision >= session.transcriptSegments[index].revision { session.transcriptSegments[index] = segment }
            } else {
                indices[segment.id] = session.transcriptSegments.count
                session.transcriptSegments.append(segment)
            }
        }
        // Resolve against the latest protected word after insertions. Acoustic revisions
        // cannot replace its text, native times, redaction marker or user speaker aliases.
        for revision in batch.speakerRevisions {
            guard let index = indices[revision.segmentID] else {
                throw MeetingPCMTranscriptBatch.SpeakerRevisionFailure.identityMismatch
            }
            try revision.apply(to: &session.transcriptSegments[index])
        }
        session.speakers = batch.mergingSpeakers(into: session.speakers)
        session.transcriptTimeDomain = .meetingRelative
        session.transcriptIsComplete = (session.transcriptIsComplete ?? true) && batch.isComplete
        session.updatedAt = Date()
        self.activeSession = session
        await self.persistence.flush()
        guard self.memoryCheckpointGeneration == generation, let latest = self.activeSession,
              latest.id == sessionID else { throw CancellationError() }
        // Capture events can update coverage and state while queued persistence drains.
        // Save and project that latest owned snapshot, not this batch's pre-flush copy.
        session = latest
        try await self.store.save(session)
        guard self.memoryCheckpointGeneration == generation, self.activeSession?.id == sessionID else {
            throw CancellationError()
        }
        // Inference owns a bounded audio/context window. The UI owns the complete
        // protected reading history, so earlier participants do not disappear while
        // recording. Projection is pure and joined off the main actor.
        let revisionBeforeProjection = self.liveTranscript.revision
        var snapshot = try await Self.protectedLiveHistory(
            session: session, revision: revisionBeforeProjection + 1, preview: batch.livePreview,
            previewSource: batch.sourceTrack?.kind == .applicationAudio ? .them : .you,
            otherPartials: self.liveTranscript.partials)
        guard self.memoryCheckpointGeneration == generation, self.activeSession?.id == sessionID else {
            throw CancellationError()
        }
        // A newer safe preview may arrive while the pure reading projection runs.
        // Publishing durable history must not roll that preview or revision backward.
        if self.liveTranscript.revision > revisionBeforeProjection {
            snapshot.partials = self.liveTranscript.partials
        }
        snapshot.revision = self.liveTranscript.revision + 1
        self.liveTranscript = snapshot
        self.reconcilePendingSpeech()
        MeetingTimelineTrace.shared?.record("protected_publication", fields: ["sessionID": sessionID.uuidString,
            "transcriptRevision": String(snapshot.revision), "insertedWords": String(batch.segments.count),
            "revisedWords": String(batch.speakerRevisions.count),
            "protectedThroughSample": batch.protectedSourceThroughSample.map(String.init) ?? "unavailable"])
        // The strict runtime acknowledges a physical source prefix only after ASR,
        // attribution and privacy have admitted it. Publish that protected history
        // first; acoustic progress or a provisional preview cannot retire waves.
        if let through = batch.protectedSourceThroughSample,
           let track = batch.sourceTrack,
           self.activeSession?.audioTracks.contains(where: { $0.id == track.id }) == true,
           let capture = self.pendingSpeechCapture {
            self.pendingSpeech = capture.acknowledgeProtectedSource(
                source: track.kind == .microphone ? .you : .them, throughSample: through, transcriptRevision: snapshot.revision)
        }
    }

    private func reconcilePendingSpeech() {
        guard let capture = self.pendingSpeechCapture else { return }
        self.pendingSpeech = capture.reconcile(visible: self.liveTranscript)
        self.logPendingSpeechState("caption_snapshot_published")
    }

    /// Capture event time before the logger queue runs. Only bounded IDs, timings
    /// and character counts are retained by the asynchronous diagnostic closure.
    private func logPendingSpeechState(_ event: String, incomingRevision: UInt64? = nil,
                                       incomingCaptureID: UUID? = nil) {
        guard DebugLogger.diagnosticsEnabled else { return }
        let uptime = ProcessInfo.processInfo.systemUptime
        let captureID = self.pendingSpeechDiagnosticID?.uuidString ?? "none"
        let incomingID = incomingCaptureID?.uuidString ?? captureID
        let generation = self.captureGeneration?.uuidString ?? "none"
        let pendingRevision = self.pendingSpeech.revision
        let pendingIDs = self.pendingSpeech.tokens.map(\.id)
        let transcriptRevision = self.liveTranscript.revision
        let rowCount = self.liveTranscript.utterances.count
        let rows = self.liveTranscript.utterances.suffix(8).map {
            (id: $0.id, start: $0.start, end: $0.end,
             incomplete: $0.hasIncompleteTextCoverage, characters: $0.text.utf16.count)
        }
        let partials = self.liveTranscript.partials.values.prefix(2).map {
            (id: $0.id, start: $0.start, end: $0.end, characters: $0.text.utf16.count)
        }
        DebugLogger.shared.logLazy(level: .debug, source: "MeetingPendingSpeech") {
            func time(_ value: TimeInterval?) -> String { value.map { String(format: "%.6f", $0) } ?? "none" }
            let rowFields = rows.map {
                "\($0.id.uuidString):\(time($0.start))-\(time($0.end)):utf16=\($0.characters):incomplete=\($0.incomplete)"
            }.joined(separator: ",")
            let partialFields = partials.map {
                "\($0.id.uuidString):\(time($0.start))-\(time($0.end)):utf16=\($0.characters)"
            }.joined(separator: ",")
            return "event=\(event) eventUptime=\(time(uptime)) captureID=\(captureID) incomingCaptureID=\(incomingID) "
                + "generation=\(generation) incomingRevision=\(incomingRevision.map(String.init) ?? "none") "
                + "pendingRevision=\(pendingRevision) transcriptRevision=\(transcriptRevision) rowCount=\(rowCount) "
                + "pendingIDs=[\(pendingIDs.map(String.init).joined(separator: ","))] recentRows=[\(rowFields)] partials=[\(partialFields)]"
        }
    }

    private func process(
        _ inputSession: MeetingSession,
        generation: UUID,
        retainedLanguage: String,
        hadVisibleTranscript: Bool,
        requestedLanguageCode: String? = nil
    ) async throws -> MeetingSession {
        let diagnosticStarted = ContinuousClock.now
        var diagnosticStage = MeetingProcessingStage.pending
        var diagnosticOutcome = "failed"
        var diagnosticFailure: MeetingSessionFailure?
        defer {
            let elapsed = diagnosticStarted.duration(to: .now).components
            let elapsedMs = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
            var line = "Meeting processing outcome=\(diagnosticOutcome) session=\(inputSession.id) stage=\(diagnosticStage.rawValue) elapsedMs=\(elapsedMs)"
            if let failure = diagnosticFailure, inputSession.piiRedactionEnabled != true {
                // One bounded line; never add meeting titles, transcripts or audio contents.
                let detail = String(failure.message.prefix(512)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                let code = String(failure.code.prefix(128)).replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
                line += " errorCode=\(code) detail=\(detail)"
            }
            self.processingLogger(line)
        }
        #if DEBUG && os(macOS)
        AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingCoordinator, queueRole: .mainControl, phase: .processing)
        var diagnosticsProcessingSucceeded = false
        defer {
            AudioTopologyDiagnostics.record(
                .phaseEnd,
                owner: .meetingCoordinator,
                queueRole: .mainControl,
                phase: .processing,
                status: diagnosticsProcessingSucceeded ? 0 : -1
            )
        }
        #endif
        var session = inputSession
        do {
            let sessionDirectory = try await self.store.sessionDirectory(for: session.id)
            var processingSession = session
            processingSession.languageCode = requestedLanguageCode ?? session.languageCode
            let result = try await self.processing.process(
                session: processingSession,
                sessionDirectory: sessionDirectory
            ) { [weak self] stage in
                guard self?.operationGeneration == generation else { return }
                diagnosticStage = stage
                self?.updateProcessingStage(stage, generation: generation)
            }
            guard self.operationGeneration == generation,
                  !Task.isCancelled || result.postProcessing != nil
            else {
                throw CancellationError()
            }
            session.languageCode = processingSession.languageCode
            var completedAttempt = result.attempt
            if requestedLanguageCode != nil { completedAttempt.languageCode = processingSession.languageCode }
            completedAttempt.retainedTranscriptLanguageCode = nil
            session.speakers = result.speakers
            session.transcriptSegments = result.segments
            session.postProcessing = result.postProcessing
            session.transcriptCoverageGaps = result.coverageGaps.isEmpty ? nil : result.coverageGaps
            // Canonical attempts carry a sidecar that was already written and read-back verified
            // by the pipeline; legacy attempts leave this nil. The reference only becomes durable
            // with the session save below, and the checkpoint survives until that save succeeds.
            session.resultSidecarReference = result.resultSidecarReference
            let discardedMemoryPCM = session.audioStorageMode == .memoryOnly && session.transcriptIsComplete == false
                && session.events.contains(where: { $0.kind == .writerBackpressure })
            session.transcriptIsComplete = (result.resultSidecarReference != nil || Self.usesPCMProcessing(session))
                ? result.isComplete && !discardedMemoryPCM
                : nil
            if result.resultSidecarReference != nil || Self.usesPCMProcessing(session) {
                session.transcriptTimeDomain = .meetingRelative
            }
            session.processingAttempts.removeAll {
                $0.completedAt == nil && $0.id != result.attempt.id
            }
            if let index = session.processingAttempts.lastIndex(where: { $0.id == result.attempt.id }) {
                session.processingAttempts[index] = completedAttempt
            } else {
                session.processingAttempts.append(completedAttempt)
            }
            if !result.skippedChunkIDs.isEmpty {
                session.events.append(MeetingSessionEvent(
                    id: UUID(),
                    occurredAt: Date(),
                    kind: .writerFailure,
                    trackID: nil,
                    detail: "\(result.skippedChunkIDs.count) audio chunk(s) could not be read and were skipped."
                ))
                let skipped = Set(result.skippedChunkIDs)
                for trackIndex in session.audioTracks.indices {
                    for chunkIndex in session.audioTracks[trackIndex].chunks.indices
                        where skipped.contains(session.audioTracks[trackIndex].chunks[chunkIndex].id)
                    {
                        session.audioTracks[trackIndex].chunks[chunkIndex].finalizationState = .failed
                    }
                }
            }
            if !result.coverageGaps.isEmpty {
                let excludedSeconds = result.coverageGaps.reduce(0.0) { total, gap in
                    total + max(0, gap.end - gap.start)
                }
                let allUnprotectedMicrophone = result.coverageGaps.allSatisfy {
                    $0.reason == .unprotectedMicrophone
                }
                let allMicrophoneAdmission = result.coverageGaps.allSatisfy {
                    $0.reason == .unprotectedMicrophone || $0.reason == .inadmissibleCaptureEra
                }
                session.events.append(MeetingSessionEvent(
                    id: UUID(),
                    occurredAt: Date(),
                    kind: .transcriptCoverageIncomplete,
                    trackID: result.coverageGaps.first?.trackID,
                    detail: allUnprotectedMicrophone
                        ? String(
                            format: "%.1f seconds of unprotected microphone audio were excluded from the transcript.",
                            excludedSeconds
                        )
                        : allMicrophoneAdmission
                        ? String(
                            format: "%.1f seconds of microphone audio were excluded because capture admission was not verified.",
                            excludedSeconds
                        )
                        : String(
                            format: "%.1f seconds of meeting audio have no transcript coverage.",
                            excludedSeconds
                        )
                ))
            }
            if !result.isComplete, result.coverageGaps.isEmpty {
                session.events.append(MeetingSessionEvent(
                    id: UUID(),
                    occurredAt: Date(),
                    kind: .transcriptCoverageIncomplete,
                    trackID: nil,
                    detail: "Some recognized text could not be safely placed on the meeting timeline."
                ))
            }
            session.state = .completed
            session = await MeetingAutomaticNaming.applyingInBackground(to: session)
            guard self.operationGeneration == generation,
                  !Task.isCancelled || result.postProcessing != nil else { throw CancellationError() }
            session.updatedAt = Date()
            do {
                let began = MeetingPCMRuntimeDiagnostics.beginDetailed(.resultPersist)
                var succeeded = false
                defer { MeetingPCMRuntimeDiagnostics.completedDetailed(.resultPersist, since: began,
                    samples: session.transcriptSegments.count, succeeded: succeeded) }
                await self.flushQueuedPersistence()
                guard self.operationGeneration == generation,
                      !Task.isCancelled || result.postProcessing != nil else { throw CancellationError() }
                try await self.store.save(session)
                succeeded = true
            }
            guard self.operationGeneration == generation,
                  !Task.isCancelled || result.postProcessing != nil else { throw CancellationError() }
            let publishBegan = MeetingPCMRuntimeDiagnostics.beginDetailed(.resultPublish)
            self.removeCheckpoint(sessionDirectory: sessionDirectory, removeRetainedState: result.isComplete)
            self.activeSession = nil
            self.latestCompletedSession = session
            self.state = .completed(session.id)
            self.operationGeneration = nil
            await self.releaseActivityLease()
            MeetingPCMRuntimeDiagnostics.completedDetailed(.resultPublish, since: publishBegan)
            MeetingTimelineTrace.shared?.record("meeting_processing_completed", fields: ["sessionID": session.id.uuidString,
                "isComplete": String(result.isComplete)])
            await MeetingTimelineTrace.shared?.finish()
            diagnosticOutcome = "completed"
            diagnosticStage = .completed
            // afterTranscription policy deletes here; sweep failures are logged, never affect this result.
            Task { @MainActor [weak self] in await self?.sweepExpiredAudio() }
            #if DEBUG && os(macOS)
            diagnosticsProcessingSucceeded = true
            #endif
            return session
        } catch {
            MeetingTimelineTrace.shared?.record("meeting_processing_failed", fields: ["sessionID": session.id.uuidString,
                "cancelled": String(error is CancellationError)])
            await MeetingTimelineTrace.shared?.finish()
            if error is CancellationError { diagnosticOutcome = "cancelled" }
            guard self.operationGeneration == generation else {
                diagnosticOutcome = "superseded"
                throw error
            }
            if error is CancellationError {
                self.restoreStoredTranscript(&session, from: inputSession)
                if requestedLanguageCode != nil, let lastIndex = session.processingAttempts.indices.last {
                    session.processingAttempts[lastIndex].errorCode = "cancelled"
                    session.processingAttempts[lastIndex].completedAt = Date()
                }
                self.restoreRetainedLanguage(&session, retainedLanguage: retainedLanguage)
                session.state = hadVisibleTranscript ? .completed : .interrupted
                session.updatedAt = Date()
                await self.flushQueuedPersistence()
                try? await self.store.save(session)
                self.publishRetryOutcome(session, failure: nil)
                await self.releaseActivityLease()
                throw error
            }
            let failure = Self.failure(from: error, domain: .processing, recoverable: true)
            diagnosticFailure = failure
            // A failed completed-session save must not durably publish a sidecar or overwrite the
            // last saved transcript under `.failed`. The verified new sidecar remains unreferenced
            // for retry/journal reconciliation.
            self.restoreStoredTranscript(&session, from: inputSession)
            if let lastIndex = session.processingAttempts.indices.last {
                session.processingAttempts[lastIndex].errorCode = failure.code
                session.processingAttempts[lastIndex].completedAt = Date()
            }
            session.failures.append(failure)
            self.restoreRetainedLanguage(&session, retainedLanguage: retainedLanguage)
            session.state = hadVisibleTranscript ? .completed : .failed
            session.updatedAt = Date()
            await self.flushQueuedPersistence()
            try? await self.store.save(session)
            self.publishRetryOutcome(session, failure: hadVisibleTranscript ? nil : failure)
            await self.releaseActivityLease()
            throw error
        }
    }

    private func updateProcessingStage(_ stage: MeetingProcessingStage, generation: UUID) {
        guard self.operationGeneration == generation, var session = self.activeSession else { return }
        session.state = .processing
        if let lastIndex = session.processingAttempts.indices.last {
            session.processingAttempts[lastIndex].stage = stage
        }
        session.updatedAt = Date()
        self.activeSession = session
        self.state = .processing(session.id, stage)
        self.enqueuePersistence(session)
    }

    private func handleCaptureEvent(_ event: MeetingCaptureEvent, generation: UUID) {
        guard self.captureGeneration == generation, var session = self.activeSession else { return }
        var requiresPersistence = true
        self.liveTranscriptionCoordinator?.recordComparisonCaptureEvent(event)
        switch event {
        case let .audioComparisonProbeStarted(probe):
            self.liveTranscriptionCoordinator?.attachComparisonProbe(probe)
            return // Diagnostic-only: no recording, persistence, navigation or transcript writes.
        case let .microphoneEchoProtectionChanged(protection):
            let kind: MeetingInterruptionKind = protection == .unfiltered ? .echoFilteringUnavailable : .echoFilteringRestored
            if session.events.last(where: { $0.kind == .echoFilteringUnavailable || $0.kind == .echoFilteringRestored })?.kind == kind {
                return
            }
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: kind,
                trackID: nil,
                detail: protection.transcriptWarning
            ))
        case let .trackHealth(trackID, health):
            if health.status == .healthy {
                self.startupWriterFailures.remove(trackID)
            }
            guard let index = session.audioTracks.firstIndex(where: { $0.id == trackID }) else {
                if session.state == .preparing {
                    self.startupTrackHealth[trackID] = health
                }
                return
            }
            let previousHealth = session.audioTracks[index].health
            let previousState = session.state
            var health = health
            let kind = session.audioTracks[index].kind
            let watchdogTripped = kind == .applicationAudio && health.status != .degraded
                && (health.silentForSeconds ?? 0) >= Self.silenceWatchdogThresholdSeconds
                && (self.trackHealth[.microphone]?.silentForSeconds).map {
                    $0 < Self.microphoneRecentActivityThresholdSeconds
                } == true
            if kind == .applicationAudio {
                self.silenceWatchdogActive = watchdogTripped
            }
            if watchdogTripped {
                health.status = .degraded
                health.detail = "No meeting audio is being captured while your microphone is active."
            }
            session.audioTracks[index].health = health
            self.trackHealth[kind] = health
            if health.status == .degraded {
                session.state = .recordingDegraded
                self.state = .recordingDegraded(session.id)
                if watchdogTripped {
                    self.degradeReason = self.degradeReason ?? .silence
                } else if !self.startupWriterFailures.contains(trackID) {
                    self.degradeReason = .sticky
                }
            } else if session.state == .recordingDegraded,
                      self.degradeReason == .startupWriterFailure,
                      self.startupWriterFailures.isEmpty,
                      !session.audioTracks.contains(where: { $0.health.status == .degraded })
            {
                session.state = .recording
                self.state = .recording(session.id)
                self.degradeReason = nil
            } else if kind == .applicationAudio, session.state == .recordingDegraded,
                      self.degradeReason == .silence,
                      (health.silentForSeconds ?? 0) < Self.silenceWatchdogThresholdSeconds,
                      !session.audioTracks.contains(where: { $0.id != trackID && $0.health.status == .degraded })
            {
                session.state = .recording
                self.state = .recording(session.id)
                self.degradeReason = nil
            }
            // Meter, sample timestamps and silence duration remain current in memory and UI.
            // Saving the growing transcript for every capture tick can keep flush() waiting
            // indefinitely. Durable capture transitions still save immediately; canonical,
            // chunk and terminal saves include the latest complete health snapshot.
            requiresPersistence = previousHealth.status != health.status
                || previousHealth.detail != health.detail
                || previousHealth.droppedSampleCount != health.droppedSampleCount
                || previousState != session.state
        case let .chunkFinalized(trackID, chunk, format):
            guard let index = session.audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
            if !session.audioTracks[index].chunks.contains(where: { $0.id == chunk.id }) {
                session.audioTracks[index].chunks.append(chunk)
            }
            session.audioTracks[index].format = format
            if let currentFirstPresentationTime = session.timebase.firstPresentationTime {
                session.timebase.firstPresentationTime = min(currentFirstPresentationTime, chunk.presentationStart)
            } else {
                session.timebase.firstPresentationTime = chunk.presentationStart
            }
        case let .captureMethodChanged(trackID, method, ack):
            // Resumed after this lands, before the upgrade opens the gate. Downgrades pass `ack: nil`.
            defer { ack?.resume() }
            guard let index = session.audioTracks.firstIndex(where: { $0.id == trackID }) else { return }
            session.audioTracks[index].captureMethod = method
            if session.audioTracks[index].kind == .microphone {
                self.liveTranscriptionCoordinator?.setMicrophoneCaptureMethod(method)
                self.liveTranscriptionCoordinator?.resetMicrophoneUtterance()
            }
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: .microphoneChanged,
                trackID: trackID,
                detail: "Microphone capture switched to \(method.rawValue)."
            ))
            // Only clear degradation this change plausibly caused — never a sticky one.
            if session.state == .recordingDegraded,
               self.degradeReason == nil || self.degradeReason == .sourceLoss || self.degradeReason == .silence,
               !session.audioTracks.contains(where: { $0.health.status == .degraded })
            {
                session.state = .recording
                self.state = .recording(session.id)
                self.degradeReason = nil
            }
        case let .interrupted(kind, trackID, detail):
            if session.state == .preparing {
                switch kind {
                case .writerFailure:
                    self.startupWriterFailures.insert(trackID)
                    if let trackID {
                        var health = self.startupTrackHealth[trackID] ?? .waiting
                        health.status = .degraded
                        health.detail = detail
                        self.startupTrackHealth[trackID] = health
                    }
                case .sourceLost:
                    self.degradeReason = self.degradeReason ?? .sourceLoss
                case .sourceRecovered:
                    if self.degradeReason == .sourceLoss { self.degradeReason = nil }
                case .voiceProcessingDeclined:
                    break
                default:
                    self.degradeReason = .sticky
                }
            }
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: kind,
                trackID: trackID,
                detail: detail
            ))
            Self.markDiscardedMemoryCaptureIncomplete(&session, event: kind)
            if kind == .captureStoppedUnexpectedly {
                session.state = .interrupted
                self.state = .interrupted(session.id)
                session.updatedAt = Date()
                self.activeSession = session
                self.captureGeneration = nil
                self.degradeReason = nil
                self.operationGeneration = nil
                self.enqueuePersistence(session)
                self.beginUnexpectedStop(sessionID: session.id, generation: generation)
                return
            } else if kind == .sourceRecovered, session.state == .recordingDegraded,
                      self.degradeReason == .sourceLoss
            {
                if !self.startupWriterFailures.isEmpty {
                    self.degradeReason = .startupWriterFailure
                } else if !session.audioTracks.contains(where: { $0.health.status == .degraded }) {
                    session.state = .recording
                    self.state = .recording(session.id)
                    self.degradeReason = nil
                } else if self.silenceWatchdogActive,
                          !session.audioTracks.contains(where: { $0.kind != .applicationAudio && $0.health.status == .degraded })
                {
                    self.degradeReason = .silence
                }
            } else if kind != .sourceRecovered, kind != .voiceProcessingDeclined,
                      session.state == .recording || session.state == .recordingDegraded
            {
                session.state = .recordingDegraded
                self.state = .recordingDegraded(session.id)
                if kind == .sourceLost, self.degradeReason != .sticky {
                    self.degradeReason = .sourceLoss
                } else {
                    self.degradeReason = .sticky
                }
            }
        }
        session.updatedAt = Date()
        self.activeSession = session
        // startRecording persists the settled tracks and any startup events together. Queuing
        // a preparing snapshot here could overwrite that newer state after start returns.
        if requiresPersistence, session.state != .preparing {
            self.enqueuePersistence(session)
        }
    }

    private func beginUnexpectedStop(sessionID: MeetingSessionID, generation: UUID) {
        guard self.interruptionTask == nil, self.terminationTask == nil else { return }
        if self.captureStopHandoff?.sessionID != sessionID || self.captureStopHandoff?.generation != generation {
            self.captureStopHandoff = (sessionID, generation, nil, nil)
        }
        self.interruptionTask = Task { @MainActor [weak self] in
            await self?.finishUnexpectedStop(sessionID: sessionID, generation: generation)
        }
    }

    private func finishUnexpectedStop(sessionID: MeetingSessionID, generation: UUID) async {
        guard var session = self.activeSession, session.id == sessionID else {
            self.interruptionTask = nil
            return
        }
        do {
            let stopResult = try await self.capture.stop(sessionID: sessionID)
            self.preserveCaptureStopHandoff(stopResult, sessionID: sessionID, generation: generation)
            Self.apply(stopResult, to: &session)
        } catch {
            if let partialResult = Self.partialStopResult(from: error) {
                self.preserveCaptureStopHandoff(partialResult, sessionID: sessionID, generation: generation,
                    failure: Self.failure(from: error, domain: .capture, recoverable: true))
                Self.apply(partialResult, to: &session)
            } else {
                await self.capture.shutdownForTermination()
                session.endedAt = session.endedAt ?? Date()
            }
            session.failures.append(Self.failure(from: error, domain: .capture, recoverable: true))
        }
        await self.finishMemoryCheckpointDrain(sessionID: session.id)
        self.mergeLatestMemoryCheckpoint(into: &session)
        await self.tearDownLiveTranscription()
        guard self.terminationTask == nil, !Task.isCancelled else { return }

        session.state = .interrupted
        if Self.shouldQueuePendingAttempt(for: session) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        await self.flushQueuedPersistence()
        try? await self.store.save(session)
        self.activeSession = session
        self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
        self.state = .interrupted(session.id)
        await self.releaseActivityLease()
        MeetingTimelineTrace.shared?.record("meeting_capture_interrupted", fields: ["sessionID": session.id.uuidString])
        await MeetingTimelineTrace.shared?.finish()
        self.interruptionTask = nil
    }

    private func handleStopFailure(
        _ error: Error,
        session inputSession: MeetingSession,
        generation: UUID
    ) async {
        guard self.operationGeneration == generation else { return }
        var session = inputSession
        self.captureGeneration = nil
        self.degradeReason = nil
        self.operationGeneration = nil
        if let partialResult = Self.partialStopResult(from: error) {
            Self.apply(partialResult, to: &session)
        } else {
            await self.capture.shutdownForTermination()
            session.endedAt = session.endedAt ?? Date()
        }
        await self.finishMemoryCheckpointDrain(sessionID: session.id)
        self.mergeLatestMemoryCheckpoint(into: &session)
        await self.tearDownLiveTranscription()
        let failure = Self.failure(from: error, domain: .capture, recoverable: true)
        session.failures.append(failure)
        session.events.append(MeetingSessionEvent(
            id: UUID(),
            occurredAt: Date(),
            kind: .captureStoppedUnexpectedly,
            trackID: nil,
            detail: error.localizedDescription
        ))
        session.state = .interrupted
        if Self.shouldQueuePendingAttempt(for: session) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        await self.flushQueuedPersistence()
        try? await self.store.save(session)
        self.activeSession = session
        self.trackHealth = Dictionary(uniqueKeysWithValues: session.audioTracks.map { ($0.kind, $0.health) })
        self.state = .interrupted(session.id)
        await self.releaseActivityLease()
        MeetingTimelineTrace.shared?.record("meeting_stop_failed", fields: ["sessionID": session.id.uuidString])
        await MeetingTimelineTrace.shared?.finish()
    }

    private func enqueuePersistence(_ session: MeetingSession) {
        self.persistence.enqueue(session)
    }

    private func flushQueuedPersistence() async {
        await self.persistence.flush()
    }

    /// Must complete before any code path that calls into `processing.process`, so both live
    /// engines' CoreML models are released before the batch pipeline's `ensureAsrReady()` loads.
    private func tearDownLiveTranscription() async {
        self.locationTask?.cancel()
        await self.locationTask?.value
        self.locationTask = nil
        if let pending = self.liveTranscriptionTeardownTask {
            await pending.value
            return
        }
        // Close callback admission before suspension. A queued update must not
        // start new privacy work while the canceled worker is being joined.
        let coordinator = self.liveTranscriptionCoordinator
        self.liveTranscriptionCoordinator = nil
        self.logPendingSpeechState("capture_teardown")
        let pendingCapture = self.pendingSpeechCapture
        pendingCapture?.stop()
        let pendingCleanup = self.pendingSpeechTeardownTask
        self.pendingSpeechCapture = nil
        self.pendingSpeech = .empty
        self.pendingSpeechDiagnosticID = nil
        let publication = self.livePrivacyPublication
        let cleanup = Task { @MainActor in
            await pendingCleanup?.value
            await pendingCapture?.stopAndWait()
            self.pendingSpeechTeardownTask = nil
            await publication.stop()
            await coordinator?.stop()
        }
        self.liveTranscriptionTeardownTask = cleanup
        await cleanup.value
        self.liveTranscriptionTeardownTask = nil
        self.liveTranscript = .empty
    }

    /// Optional metadata uses the existing authoritative snapshot and save queue. It never
    /// owns audio, blocks admission, changes a custom title or publishes after Stop.
    private func beginLocationCapture(for session: MeetingSession, generation: UUID) {
        guard session.mode == .inRoom, self.settings.meetingLocationEnabled,
              let resolver = self.locationResolver else { return }
        // Session creation precedes native/model startup and can be much earlier than
        // actual capture. Freshness is measured from this newly admitted location request.
        let requestedAt = Date()
        let selected = PichiLocalization.language
        let languages = [selected] + PichiInterfaceLanguage.allCases.filter { $0 != selected }
        let previous = self.locationTask
        previous?.cancel()
        self.locationTask = Task { @MainActor [weak self] in
            await previous?.value
            guard !Task.isCancelled, self?.settings.meetingLocationEnabled == true else { return }
            let location = await resolver.locate(startedAt: requestedAt, languages: languages)
            guard !Task.isCancelled, let self, let location,
                  self.captureGeneration == generation, self.isRecording, self.settings.meetingLocationEnabled,
                  var current = self.activeSession, current.id == session.id else { return }
            current.location = location
            current.updatedAt = Date()
            self.activeSession = current
            self.enqueuePersistence(current)
        }
    }

    private func releaseActivityLease() async {
        guard let lease = self.activityLease else { return }
        #if DEBUG && os(macOS)
        AudioTopologyDiagnostics.record(.phaseBegin, owner: .meetingCoordinator, queueRole: .mainControl, phase: .activityLease)
        defer { AudioTopologyDiagnostics.record(.phaseEnd, owner: .meetingCoordinator, queueRole: .mainControl, phase: .activityLease) }
        #endif
        await self.audioArbiter.release(lease)
        self.activityLease = nil
    }

    /// Only called after the completed session save succeeds; on failure the checkpoint stays so a
    /// retry can resume from it.
    private func removeCheckpoint(sessionDirectory: URL, removeRetainedState: Bool) {
        do { if removeRetainedState { try MeetingRetainedProcessingCheckpoint.remove(in: sessionDirectory) } }
        catch {
            DebugLogger.shared.warning("Failed to remove retained meeting processing state after completion.",
                                       source: "MeetingSessionCoordinator")
        }
        let url = sessionDirectory.appendingPathComponent("checkpoint.json", isDirectory: false)
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        do {
            try FileManager.default.removeItem(at: url)
        } catch {
            DebugLogger.shared.warning(
                "Failed to remove meeting checkpoint after completion: \(error)",
                source: "MeetingSessionCoordinator"
            )
        }
    }

    private static func makeTimebase() -> MeetingTimebaseMetadata {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return MeetingTimebaseMetadata(
            startedHostTime: mach_absolute_time(),
            machTimebaseNumerator: info.numer,
            machTimebaseDenominator: info.denom,
            firstPresentationTime: nil
        )
    }

    private static func pendingProcessingAttempt() -> MeetingProcessingAttempt {
        MeetingProcessingAttempt(
            id: UUID(),
            startedAt: Date(),
            completedAt: nil,
            stage: .pending,
            pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: nil,
            asrModel: nil,
            diarizationModel: nil,
            lastCompletedTrackID: nil,
            errorCode: nil
        )
    }

    /// A rejected PCM block has no replay source in strict memory-only capture. A final
    /// accepted batch can be complete locally while this captured session still has a hole.
    private static func markDiscardedMemoryCaptureIncomplete(
        _ session: inout MeetingSession, event: MeetingInterruptionKind
    ) {
        guard event == .writerBackpressure, session.audioStorageMode == .memoryOnly else { return }
        session.transcriptIsComplete = false
    }

    private func preserveCaptureStopHandoff(
        _ result: MeetingCaptureStopResult, sessionID: MeetingSessionID, generation: UUID,
        failure: MeetingSessionFailure? = nil
    ) {
        guard self.activeSession?.id == sessionID, let owner = self.captureStopHandoff,
              owner.sessionID == sessionID, owner.generation == generation else { return }
        self.captureStopHandoff = (sessionID, generation, result, owner.failure ?? failure)
    }

    private func takeCaptureStopHandoff(sessionID: MeetingSessionID, generation: UUID?)
        -> (result: MeetingCaptureStopResult, failure: MeetingSessionFailure?)? {
        guard self.activeSession?.id == sessionID, let owner = self.captureStopHandoff,
              owner.sessionID == sessionID, owner.generation == generation,
              let result = owner.result else { return nil }
        self.captureStopHandoff = nil
        return (result, owner.failure)
    }

    private static func apply(_ stopResult: MeetingCaptureStopResult, to session: inout MeetingSession) {
        session.audioTracks = stopResult.tracks
        session.endedAt = stopResult.stoppedAt
        session.timebase.firstPresentationTime = self.firstPresentationTime(in: stopResult.tracks)
    }

    private static func partialStopResult(from error: Error) -> MeetingCaptureStopResult? {
        guard let captureError = error as? MeetingCaptureError else { return nil }
        switch captureError {
        case let .captureStopFailed(_, partialResult):
            return partialResult
        default:
            return nil
        }
    }

    private static func shouldQueuePendingAttempt(for session: MeetingSession) -> Bool {
        session.hasFinalizedAudio
            && !session.processingAttempts.contains(where: { $0.completedAt == nil })
    }

    private static func nonViableRecoveryFailure(for session: MeetingSession) -> MeetingSessionFailure {
        let hasAudio = session.hasFinalizedAudio
        let message: String
        if session.audioTracks.isEmpty {
            message = "Recording never started — no audio was captured."
        } else if hasAudio {
            message = "Some tracks are missing, but captured audio was preserved."
        } else {
            message = "No finalized audio survived."
        }
        return Self.failure(
            from: MeetingCoordinatorError.noRecoverableAudio,
            domain: .persistence,
            recoverable: hasAudio,
            message: message
        )
    }

    private static func markRecoverableInterrupted(_ inputSession: MeetingSession) -> MeetingSession {
        var session = inputSession
        let previousState = session.state
        session.state = .interrupted
        if session.endedAt == nil {
            session.endedAt = session.audioTracks
                .compactMap(\.health.lastSampleAt)
                .max() ?? session.updatedAt
        }
        if previousState != .interrupted {
            session.events.append(MeetingSessionEvent(
                id: UUID(),
                occurredAt: Date(),
                kind: .captureStoppedUnexpectedly,
                trackID: nil,
                detail: previousState == .processing
                    ? AppBrand.text("FluidVoice restarted before transcription completed.")
                    : AppBrand.text("FluidVoice restarted before capture finalized.")
            ))
        }
        if Self.shouldQueuePendingAttempt(for: session) {
            session.processingAttempts.append(Self.pendingProcessingAttempt())
        }
        session.updatedAt = Date()
        return session
    }

    private static func hasRecoverableAudio(_ session: MeetingSession) -> Bool {
        session.endedAt != nil && session.hasFinalizedAudio
    }

    private static func firstPresentationTime(in tracks: [MeetingAudioTrack]) -> MeetingMediaTime? {
        tracks.flatMap(\.chunks).map(\.presentationStart).min()
    }

    private static func failure(
        from error: Error,
        domain: MeetingFailureDomain,
        recoverable: Bool,
        message: String? = nil
    ) -> MeetingSessionFailure {
        let nsError = error as NSError
        return MeetingSessionFailure(
            id: UUID(),
            occurredAt: Date(),
            domain: domain,
            code: "\(nsError.domain).\(nsError.code)",
            message: message ?? error.localizedDescription,
            recoverable: recoverable
        )
    }
}

private extension MeetingSessionCoordinator {
    nonisolated static func retainedCompletedLanguage(for session: MeetingSession) -> String? {
        guard !session.transcriptSegments.isEmpty else { return nil }
        if session.state == .completed { return session.languageCode }
        if let completed = session.processingAttempts.last(where: {
            $0.stage == .completed && $0.completedAt != nil && $0.errorCode == nil && $0.languageCode != nil
        })?.languageCode { return completed }
        return session.processingAttempts.reversed().compactMap(\.retainedTranscriptLanguageCode).first
    }

    nonisolated static func restoringCompletedResult(_ input: MeetingSession) -> MeetingSession? {
        guard [.processing, .interrupted].contains(input.state),
              let language = retainedCompletedLanguage(for: input)
        else { return nil }
        var session = input
        session.languageCode = language
        session.state = .completed
        let now = Date()
        for index in session.processingAttempts.indices where session.processingAttempts[index].completedAt == nil {
            session.processingAttempts[index].completedAt = now
            session.processingAttempts[index].errorCode = session.processingAttempts[index].errorCode ?? "interrupted"
        }
        session.updatedAt = now
        return session
    }
}

enum MeetingCoordinatorError: LocalizedError {
    case featureDisabled
    case recordingAlreadyActive
    case noActiveMeeting
    case noRecoverableAudio
    case activityInProgress
    case dictationActive
    case noCorrectionToUndo
    case maintenanceInProgress
    case unsupportedRetranscriptionLanguage

    var errorDescription: String? {
        switch self {
        case .featureDisabled:
            return "Enable FluidMeet in Settings to record a meeting."
        case .recordingAlreadyActive:
            return "Another meeting recording is already active."
        case .noActiveMeeting:
            return "There is no active meeting."
        case .noRecoverableAudio:
            return "This meeting has no finalized audio to retry."
        case .activityInProgress:
            return "Stop the active meeting activity first."
        case .dictationActive:
            return "Stop dictation before starting a meeting recording."
        case .noCorrectionToUndo:
            return "There is nothing to undo."
        case .maintenanceInProgress:
            return AppBrand.text("FluidVoice is tidying up meeting storage. Try again in a moment.")
        case .unsupportedRetranscriptionLanguage:
            return String(localized: "Choose a language the meeting transcription model supports.")
        }
    }
}
