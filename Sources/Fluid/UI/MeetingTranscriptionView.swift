import AppKit
import AVFoundation
import Combine
import CoreGraphics
import SwiftUI

nonisolated struct MeetingApplicationOption: Identifiable, Equatable, Sendable {
    let id: String
    let identity: MeetingApplicationIdentity

    init(identity: MeetingApplicationIdentity) {
        self.identity = identity
        self.id = "\(identity.bundleIdentifier)-\(identity.processID ?? 0)"
    }
}

extension [MeetingApplicationOption] {
    /// The usual meeting sources first, then the rest with background helpers last.
    @MainActor
    var pickerSections: (usual: [MeetingApplicationOption], others: [MeetingApplicationOption]) {
        MeetingAppRegistry.pickerSections(
            self,
            bundleIdentifier: { $0.identity.bundleIdentifier },
            name: { $0.identity.displayName },
            isBackgroundItem: { option in
                option.identity.processID.flatMap { NSRunningApplication(processIdentifier: $0) }?.activationPolicy != .regular
            }
        )
    }
}

struct MeetingMicrophoneOption: Identifiable, Equatable {
    let id: String
    let identity: MeetingMicrophoneIdentity

    init(identity: MeetingMicrophoneIdentity) {
        self.identity = identity
        self.id = identity.captureDeviceID
    }
}

struct MeetingTranscriptionSetupDraft: Equatable {
    var mode: MeetingCaptureMode = .onlineCall
    var title: String = Self.defaultTitle(mode: .onlineCall, applicationDisplayName: nil)
    var selectedApplicationID: String?
    /// Stable intent survives source refreshes; the process ID is resolved before admission.
    var selectedApplicationBundleIdentifier: String?
    var applicationAudioScope: MeetingApplicationAudioScope = .systemAudio
    var usesAutomaticApplication = true
    var applicationSelectionWasEdited = false
    var selectedMicrophoneID: String?
    /// Once true, the default title stops following the selected application/mode.
    var languageCode: String
    var titleWasEdited = false
    var autoDetectEnabled: Bool
    var browserDetectionEnabled: Bool

    init(settings: SettingsStore = .shared) {
        self.init(
            defaults: settings.meetingRecordingDefaults,
            autoDetectEnabled: settings.meetingAutoDetectEnabled,
            browserDetectionEnabled: settings.meetingAutoDetectBrowserEnabled,
            fallbackLanguageCode: PichiMeetingProviderFactory.defaultLanguageCode(for: settings.selectedSpeechModel.rawValue) ?? "ru"
        )
    }

    init(
        defaults: MeetingRecordingDefaults,
        autoDetectEnabled: Bool,
        browserDetectionEnabled: Bool,
        fallbackLanguageCode: String
    ) {
        self.autoDetectEnabled = autoDetectEnabled
        self.browserDetectionEnabled = browserDetectionEnabled
        self.languageCode = defaults.languageCode
            ?? fallbackLanguageCode
        self.mode = defaults.mode
        self.applicationAudioScope = defaults.effectiveApplicationAudioScope
        self.title = Self.defaultTitle(mode: defaults.mode, applicationDisplayName: nil)
        self.usesAutomaticApplication = defaults.usesAutomaticApplication
        self.selectedApplicationBundleIdentifier = defaults.usesAutomaticApplication ? nil : defaults.applicationBundleIdentifier
        self.selectedApplicationID = nil
        // Left unset here: selectPreferredMicrophone decides once identities load.
        self.selectedMicrophoneID = nil
    }

    mutating func chooseApplication(_ application: MeetingApplicationIdentity?) {
        self.applicationSelectionWasEdited = true
        self.applicationAudioScope = .selectedApplication
        self.usesAutomaticApplication = application == nil
        self.selectedApplicationID = application.map { MeetingApplicationOption(identity: $0).id }
        self.selectedApplicationBundleIdentifier = application?.bundleIdentifier
    }

    mutating func chooseSystemAudio() {
        self.applicationSelectionWasEdited = true
        self.applicationAudioScope = .systemAudio
        self.usesAutomaticApplication = false
        self.selectedApplicationID = nil
        self.selectedApplicationBundleIdentifier = nil
    }

    mutating func refreshApplicationSelection(
        from identities: [MeetingApplicationIdentity],
        automaticTarget: MeetingAutoDetector.ResolvedTarget?
    ) {
        guard self.applicationAudioScope == .selectedApplication else { self.selectedApplicationID = nil; return }
        let options = identities.map(MeetingApplicationOption.init)
        if self.usesAutomaticApplication {
            self.selectedApplicationID = options.first {
                $0.identity.bundleIdentifier == automaticTarget?.bundleIdentifier && $0.identity.processID == automaticTarget?.pid
            }?.id
        } else if !options.contains(where: { $0.id == self.selectedApplicationID }) {
            self.selectedApplicationID = options.first {
                $0.identity.bundleIdentifier == self.selectedApplicationBundleIdentifier
            }?.id
        }
    }

    func resolvedRecordingApplication(
        from identities: [MeetingApplicationIdentity],
        automaticTarget: MeetingAutoDetector.ResolvedTarget?
    ) throws -> MeetingApplicationIdentity? {
        if self.mode == .onlineCall, self.applicationAudioScope == .systemAudio { return nil }
        let selected = identities.first { MeetingApplicationOption(identity: $0).id == self.selectedApplicationID }
        if self.mode == .onlineCall, self.usesAutomaticApplication {
            guard let selected, let automaticTarget,
                  selected.bundleIdentifier == automaticTarget.bundleIdentifier,
                  selected.processID == automaticTarget.pid else { throw MeetingCaptureError.applicationNotSelected }
        }
        return try MeetingCaptureSourceCatalog.resolveRecordingApplication(
            mode: self.mode,
            usesAutomaticApplication: self.usesAutomaticApplication,
            selectedApplication: selected,
            automaticTarget: automaticTarget,
            applications: identities
        )
    }

    func recordingDefaults(
        microphone: MeetingMicrophoneIdentity,
        applications: [MeetingApplicationIdentity]
    ) throws -> MeetingRecordingDefaults {
        let application = applications.first { MeetingApplicationOption(identity: $0).id == self.selectedApplicationID }
        if self.mode == .onlineCall, self.applicationAudioScope == .selectedApplication, !self.usesAutomaticApplication, application == nil {
            throw MeetingCaptureError.applicationNotSelected
        }
        let savedApplication = self.mode == .onlineCall && self.applicationAudioScope == .selectedApplication && !self.usesAutomaticApplication ? application : nil
        return MeetingRecordingDefaults(
            isConfigured: true,
            mode: self.mode,
            applicationBundleIdentifier: savedApplication?.bundleIdentifier,
            applicationDisplayName: savedApplication?.displayName,
            applicationAudioScope: self.mode == .onlineCall ? self.applicationAudioScope : nil,
            microphoneCaptureDeviceID: microphone.captureDeviceID,
            microphoneCoreAudioUID: microphone.coreAudioUID,
            microphoneRole: .unknown,
            languageCode: self.languageCode
        )
    }

    static func defaultTitle(mode: MeetingCaptureMode, applicationDisplayName: String?) -> String {
        guard mode == .onlineCall else { return PichiLocalization.text("In-room meeting") }
        guard let applicationDisplayName, !applicationDisplayName.isEmpty else { return PichiLocalization.text("Meeting") }
        return PichiLocalization.format("%@ call", applicationDisplayName)
    }

    func applyingSource(to previous: MeetingRecordingDefaults, application: MeetingApplicationIdentity?) -> MeetingRecordingDefaults {
        var defaults = previous
        defaults.isConfigured = true
        defaults.mode = self.mode
        // In-person capture is mic-only; keep the prior online source as a profile preference.
        if self.mode == .inRoom { return defaults }
        defaults.applicationAudioScope = self.mode == .onlineCall ? self.applicationAudioScope : nil
        if self.mode != .onlineCall || self.applicationAudioScope == .systemAudio || self.usesAutomaticApplication {
            defaults.applicationBundleIdentifier = nil
            defaults.applicationDisplayName = nil
        } else {
            let bundleIdentifier = application?.bundleIdentifier ?? self.selectedApplicationBundleIdentifier
            defaults.applicationBundleIdentifier = bundleIdentifier
            defaults.applicationDisplayName = application?.displayName
                ?? (previous.applicationBundleIdentifier == bundleIdentifier ? previous.applicationDisplayName : nil)
        }
        return defaults
    }
}

struct MeetingSetupReadiness: Equatable {
    var isCheckingSources: Bool
    var meetingAudioStatus: String
    var meetingAudioReady: Bool
    var microphoneStatus: String
    var microphoneReady: Bool
    var modelStatus: String
    var modelReady: Bool
    var storageStatus: String
    var storageReady: Bool
    var activityStatus: String
    var activityReady: Bool
    var showMicrophoneSettingsAction: Bool
    var showScreenRecordingSettingsAction: Bool
    var blockingMessage: String?

    static let checking = Self(
        isCheckingSources: true,
        meetingAudioStatus: "Checking…",
        meetingAudioReady: false,
        microphoneStatus: "Checking…",
        microphoneReady: false,
        modelStatus: "Available after recording",
        modelReady: false,
        storageStatus: "Checking…",
        storageReady: false,
        activityStatus: "Checking…",
        activityReady: false,
        showMicrophoneSettingsAction: false,
        showScreenRecordingSettingsAction: false,
        blockingMessage: "Checking recording access and sources."
    )
}

/// Registers only this meeting's saved corrections with the window's native Undo command.
@MainActor
final class MeetingCorrectionUndoRegistration: ObservableObject {
    private weak var manager: UndoManager?
    private var sessionID: MeetingSessionID?
    private var isEnabled = false
    private var action: (@MainActor () async -> Bool)?
    private var task: Task<Void, Never>?
    private var generation = UUID()

    func refresh(manager: UndoManager?, sessionID: MeetingSessionID, isEnabled: Bool, action: @escaping @MainActor () async -> Bool) {
        if self.manager !== manager || self.sessionID != sessionID { self.detach() }
        self.manager = manager
        self.sessionID = sessionID
        self.isEnabled = isEnabled
        self.action = action
        if self.task == nil { self.install() }
    }

    func detach() {
        self.manager?.removeAllActions(withTarget: self)
        self.manager = nil
        self.sessionID = nil
        self.action = nil
        self.isEnabled = false
        self.generation = UUID()
        // An authorized save may finish after navigation, but must never register Undo in
        // the next meeting or another page. Do not cancel persistence mid-write.
        self.task = nil
    }

    private func install() {
        guard let manager = self.manager else { return }
        manager.removeAllActions(withTarget: self)
        guard self.isEnabled else { return }
        manager.beginUndoGrouping()
        manager.registerUndo(withTarget: self) { $0.performUndo() }
        manager.setActionName(PichiLocalization.text("Meeting Correction"))
        manager.endUndoGrouping()
    }

    private func performUndo() {
        guard self.isEnabled, self.task == nil, let action = self.action else { return }
        let generation = self.generation
        self.task = Task { @MainActor in
            let hasMore = await action()
            guard self.generation == generation else { return }
            self.task = nil
            self.isEnabled = self.isEnabled && hasMore
            // Register after the async save, outside UndoManager's undo callback. This is
            // another correction to undo, not a redo. A failed save remains retryable.
            self.install()
        }
    }
}

/// Owns only this view's transient payloads and readers, never the capture/coordinator lifetime.
@MainActor
private final class MeetingViewPrivateProjection: ObservableObject, PrivateProfileTransitionParticipant {
    struct Stamp {
        let profile: PrivateProfileSnapshot
        let revision: UUID
        let epoch: UUID
    }

    @Published var setupDraft = MeetingTranscriptionSetupDraft(settings: .shared)
    @Published var setupDraftBeforeEditing = MeetingTranscriptionSetupDraft(settings: .shared)
    @Published var pendingBackupSetupRefresh = false
    @Published var draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
    @Published var isShowingMeetingSettings = false
    @Published var actionErrorMessage: String?
    @Published var selectedHistorySessionID: MeetingSessionID?
    @Published var resumedSummarySession: MeetingSession?
    @Published var pendingDeleteSession: MeetingSession?
    @Published var pendingDeleteAudioSession: MeetingSession?
    @Published var renameSessionID: MeetingSessionID?
    @Published var renameSource: MeetingSession?
    @Published var renameDraft = ""
    @Published var searchText = ""
    private var epoch = UUID()
    private var tasks: [UUID: Task<Void, Never>] = [:]
    private var panel: NSSavePanel?

    init() { PrivateProfileService.shared.register(self) }

    func capture() -> Stamp? {
        let service = PrivateProfileService.shared
        let profile = PrivateProfileStorage.current
        guard service.isPrivateDataVisible, !service.isTransitioning,
              PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(profile) else { return nil }
        return Stamp(profile: profile, revision: service.projectionRevision, epoch: epoch)
    }

    func accepts(_ stamp: Stamp?) -> Bool {
        guard let stamp, !Task.isCancelled else { return false }
        let service = PrivateProfileService.shared
        return stamp.epoch == epoch && stamp.revision == service.projectionRevision &&
            service.isPrivateDataVisible && !service.isTransitioning &&
            PrivateProfileStorage.acceptsNewWork && PrivateProfileStorage.isReadable(stamp.profile) &&
            PrivateProfileStorage.current == stamp.profile
    }

    func run(_ operation: @escaping @MainActor (Stamp) async -> Void) {
        guard let stamp = capture() else { return }
        let id = UUID()
        tasks[id] = Task { @MainActor in
            defer { self.tasks.removeValue(forKey: id) }
            guard self.accepts(stamp) else { return }
            await operation(stamp)
        }
    }

    func result<Value: Sendable>(_ operation: @escaping @MainActor (Stamp) async -> Value?) async -> Value? {
        guard let stamp = capture() else { return nil }
        let id = UUID()
        let task = Task { @MainActor in
            guard self.accepts(stamp) else { return Optional<Value>.none }
            return await operation(stamp)
        }
        // The wrapper propagates cancellation and joins the typed child before source replacement.
        tasks[id] = Task {
            await withTaskCancellationHandler { _ = await task.value } onCancel: { task.cancel() }
        }
        defer { tasks.removeValue(forKey: id) }
        let value = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        return accepts(stamp) ? value : nil
    }

    func retainPanel(_ panel: NSSavePanel) { self.panel = panel }
    func releasePanel() { panel = nil }

    func clearPayloads() {
        selectedHistorySessionID = nil; resumedSummarySession = nil
        pendingDeleteSession = nil; pendingDeleteAudioSession = nil
        renameSessionID = nil; renameSource = nil; renameDraft = ""; searchText = ""; actionErrorMessage = nil
        isShowingMeetingSettings = false; pendingBackupSetupRefresh = false
        draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
        // Clear private titles and unsaved settings without writing into any profile's defaults.
        setupDraft = MeetingTranscriptionSetupDraft(settings: .shared)
        setupDraft.title = MeetingTranscriptionSetupDraft.defaultTitle(mode: setupDraft.mode, applicationDisplayName: nil)
        setupDraft.titleWasEdited = false
        setupDraftBeforeEditing = setupDraft
    }

    func prepareForPrivateProfileTransition() async throws {
        epoch = UUID()
        panel?.cancel(nil); panel = nil
        clearPayloads()
        let owned = Array(tasks.values)
        for task in owned { task.cancel() }
        for task in owned { await task.value }
        clearPayloads()
    }
}

struct MeetingTranscriptionView: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator
    @ObservedObject var asrService: ASRService
    @ObservedObject private var appServices = AppServices.shared
    @StateObject private var privateState = MeetingViewPrivateProjection()
    @ObservedObject private var profileService = PrivateProfileService.shared
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var summaryActivity = MeetingSummaryActivityCoordinator.shared
    let onOpenVoiceEngine: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale
    @Environment(\.accessibilityReduceMotion) private var accessibilityReduceMotion

    @State private var cachedSystemDefaultMicrophoneUID: String?
    /// Which tab the settings sheet opens on; set just before it is shown.
    @State private var meetingSettingsInitialSection: MeetingSettingsSection = .recording
    @State private var applications: [MeetingApplicationOption] = []
    @State private var microphones: [MeetingMicrophoneOption] = []
    @State private var isRefreshingSources = false
    @State private var isStarting = false
    @State private var isStopping = false
    @State private var isRetrying = false
    @State private var cachedMicrophoneStatus: AVAuthorizationStatus = .notDetermined
    @State private var cachedScreenCaptureAccess = false
    @State private var screenPermissionGuideID: UUID?
    @State private var cachedModelReady = false
    @State private var cachedSpeakerModelReady = false
    @State private var modelReadinessRevision = 0
    @State private var cachedStorageStatus: MeetingStorageStatus = .checking
    @State private var cachedStorageReady = false
    @ObservedObject var historySnapshot: MeetingHistorySnapshot
    // Reopen history on each visit; narrow-window selection must not hide it permanently.
    @State private var isMeetingHistoryVisible = true

    init(
        coordinator: MeetingSessionCoordinator,
        asrService: ASRService,
        historySnapshot: MeetingHistorySnapshot,
        onOpenVoiceEngine: @escaping () -> Void
    ) {
        self.coordinator = coordinator
        self.asrService = asrService
        self.historySnapshot = historySnapshot
        self.onOpenVoiceEngine = onOpenVoiceEngine
    }

    var body: some View {
        let projection = self.privateState.capture()
        let activeSessionID = self.coordinator.activeSession?.id
        self.meetingPresentation(projection: projection, activeSessionID: activeSessionID)
        .sheet(isPresented: self.$privateState.isShowingMeetingSettings) {
            self.recordingSettingsSheet(projection: projection)
        }
        .alert(
            "Delete Meeting?",
            isPresented: self.deleteMeetingIsPresented
        ) {
            self.deleteMeetingActions(projection: projection)
        } message: {
            Text("The recording and transcript will be permanently deleted from this Mac.")
        }
        .alert(
            "Delete Audio?",
            isPresented: self.deleteAudioIsPresented
        ) {
            self.deleteAudioActions(projection: projection)
        } message: {
            Text("The transcript stays; the audio files are deleted from this Mac.")
        }
        .onDisappear {
            if let requestID = self.screenPermissionGuideID {
                PermissionDragGuideController.shared.dismiss(requestID: requestID)
                self.screenPermissionGuideID = nil
            }
        }
    }

    private func meetingHeader(projection: MeetingViewPrivateProjection.Stamp?, geometry: GeometryProxy) -> MeetingTranscriptionHeader {
        MeetingTranscriptionHeader(
            state: self.canvasState,
            isMeetingHistoryVisible: self.isMeetingHistoryVisible,
            isSummaryRunning: self.summaryActivity.selectionLock != nil,
            onNewMeeting: { if self.privateState.accepts(projection) { self.startNewMeeting(hideHistory: geometry.size.width < 900) } },
            onOpenMeetingSettings: { if self.privateState.accepts(projection) { self.openMeetingSettings() } },
            onToggleMeetingHistory: { if self.privateState.accepts(projection) { self.toggleMeetingHistory() } }
        )
    }

    private func meetingCanvas(projection: MeetingViewPrivateProjection.Stamp?, activeSessionID: MeetingSessionID?) -> MeetingTranscriptionCanvas {
        MeetingTranscriptionCanvas(
            setupDraft: self.$privateState.setupDraft,
            state: self.canvasState,
            pendingSpeech: self.profileService.isPrivateDataVisible ? self.coordinator.pendingSpeech : .empty,
            microphoneMuteState: self.coordinator.microphoneMuteState,
            onToggleMicrophone: self.coordinator.isMicrophoneControlPending ? nil : {
                Task { await self.coordinator.toggleMicrophoneRecording(expectedSessionID: activeSessionID) }
            },
            applications: self.applications,
            microphones: self.microphones,
            readiness: self.readiness,
            errorMessage: self.privateState.actionErrorMessage,
            onStart: { if self.privateState.accepts(projection) { self.startRecording() } },
            onStop: { self.stopAndTranscribe(expectedSessionID: activeSessionID) },
            onRetrySession: { if self.privateState.accepts(projection) { self.retryProcessingSession(id: $0.id, languageCode: MeetingRetranscriptionLanguage.failedAttemptLanguage(for: $0)) } },
            onRestartSession: { if self.privateState.accepts(projection) { self.retryProcessingSession(id: $0.id, restarting: true) } },
            onRetranscribe: { if self.privateState.accepts(projection) { self.retryProcessingSession(id: $0, languageCode: $1) } },
            onRevealAudio: { if self.privateState.accepts(projection) { self.revealCapturedAudio($0) } },
            onRecordAgain: { if self.privateState.accepts(projection) { self.recordAgain($0) } },
            onCopyTranscript: { if self.privateState.accepts(projection) { self.copyTranscript($0, includeEchoes: $1) } },
            onExportTranscript: { if self.privateState.accepts(projection) { self.exportTranscript($0, format: $1, includeEchoes: $2) } },
            onReassignSegments: { if self.privateState.accepts(projection) { self.reassignSegments(source: $0, segmentIDs: $1, to: $2) } },
            onEditTranscriptSegment: { source, segmentID, text, revision in
                guard self.privateState.accepts(projection) else { return nil }
                return await self.editTranscriptSegment(source: source, segmentID: segmentID, text: text, revision: revision)
            },
            onNameUnknownSegment: { if self.privateState.accepts(projection) { self.nameUnknownSegment(source: $0, segmentID: $1, displayName: $2) } },
            onUndoCorrection: { source in
                guard self.privateState.accepts(projection) else { return false }
                return await self.undoTranscriptCorrection(source: source)
            },
            onRenameSession: { if self.privateState.accepts(projection) { self.renameMeetingSession(source: $0, to: $1) } },
            onAssignSpeakers: { source, edits in
                guard self.privateState.accepts(projection) else { return nil }
                return await self.assignSpeakers(source: source, edits: edits)
            },
            canUndoCorrection: { self.privateState.accepts(projection) && self.coordinator.canUndoCorrection(sessionID: $0) },
            isQuiescent: self.coordinator.isQuiescent && self.summaryActivity.selectionLock == nil,
            onRepairSetup: self.repairRecordingSetup,
            onEditSetup: self.openMeetingSettings,
            isRetrying: self.isRetrying,
            onCloseSelection: self.closeCanvasAction.map { action in
                { if self.privateState.accepts(projection) { action() } }
            },
            summaryASRService: self.asrService,
            onOpenIntegrations: self.openMeetingIntegrations,
            onSetLocalUserSpeaker: { if self.privateState.accepts(projection) { self.setLocalUserSpeaker(source: $0, speakerID: $1) } }
        )
    }

    private func meetingHistoryInspector(projection: MeetingViewPrivateProjection.Stamp?, geometry: GeometryProxy) -> MeetingHistoryInspector {
        MeetingHistoryInspector(
            privateState: self.privateState,
            sessions: self.profileService.isPrivateDataVisible ? self.historySnapshot.sessions : [],
            selectedSessionID: Binding(
                get: { self.privateState.selectedHistorySessionID },
                set: {
                    if self.privateState.accepts(projection), self.canBrowseMeetingHistory, self.summaryActivity.selectionLock == nil {
                        self.privateState.selectedHistorySessionID = $0
                        if geometry.size.width < 900 { self.isMeetingHistoryVisible = false }
                    }
                }
            ),
            errorMessage: self.historySnapshot.errorMessage,
            isLoading: !self.historySnapshot.hasLoaded,
            isQuiescent: self.coordinator.isQuiescent,
            onRefresh: { self.privateState.run { _ in await self.loadMeetingHistory() } },
            onRetry: { id in
                if self.privateState.accepts(projection) {
                    let source = self.historySnapshot.sessions.first { $0.id == id }
                    self.retryProcessingSession(id: id, languageCode: source.flatMap(MeetingRetranscriptionLanguage.failedAttemptLanguage(for:)))
                }
            },
            onRevealAudio: { if self.privateState.accepts(projection) { self.revealCapturedAudio($0) } },
            onExportAudio: { if self.privateState.accepts(projection) { self.exportAudio($0) } },
            onExportTranscript: { if self.privateState.accepts(projection) { self.exportTranscript($0, format: $1, includeEchoes: false) } },
            onDeleteAudioRequest: { if self.privateState.accepts(projection) { self.privateState.pendingDeleteAudioSession = $0 } },
            onDeleteRequest: { if self.privateState.accepts(projection) { self.privateState.pendingDeleteSession = $0 } },
            onRename: { if self.privateState.accepts(projection) { self.renameMeetingSession(source: $0, to: $1) } },
            onRecordAgain: { if self.privateState.accepts(projection) { self.recordAgain($0) } },
            onOpenIntegrations: self.openMeetingIntegrations
        )
    }

    @ViewBuilder
    private func concealedCaptureControls(activeSessionID: MeetingSessionID?) -> some View {
        if !self.profileService.isPrivateDataVisible {
            // Conceal transcript and history while the admitted recording keeps its
            // original writer. Its stop control must survive logout without private text.
            switch self.coordinator.state {
            case .recording, .recordingDegraded:
                Button("Stop & Transcribe") { self.stopAndTranscribe(expectedSessionID: activeSessionID) }
                    .font(self.theme.typography.body)
                    .disabled(self.isStopping)
            default:
                EmptyView()
            }
        }
    }

    private func meetingLayout(projection: MeetingViewPrivateProjection.Stamp?, activeSessionID: MeetingSessionID?) -> some View {
        GeometryReader { geometry in
            VStack(spacing: 0) {
                self.meetingHeader(projection: projection, geometry: geometry)
                .padding(.horizontal, FluidPageLayout.inset)
                .padding(.vertical, 12)
                Divider()

                ZStack(alignment: .trailing) {
                    self.meetingCanvas(projection: projection, activeSessionID: activeSessionID)
                    .padding(.trailing, self.isMeetingHistoryVisible && geometry.size.width >= 900 ? 272 : 0)
                    .allowsHitTesting(!self.isMeetingHistoryVisible || geometry.size.width >= 900)
                    .accessibilityHidden(self.isMeetingHistoryVisible && geometry.size.width < 900)

                    if self.isMeetingHistoryVisible {
                        if geometry.size.width < 900 {
                            Button {
                                self.isMeetingHistoryVisible = false
                            } label: {
                                self.theme.palette.windowBackground.opacity(0.65)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Close meeting history")
                        }
                        self.meetingHistoryInspector(projection: projection, geometry: geometry)
                        .frame(width: min(272, geometry.size.width))
                        .disabled(self.summaryActivity.selectionLock != nil)
                        .help(self.summaryActivity.selectionLock == nil ? PichiLocalization.text("Meeting history") : PichiLocalization.text("Finish or cancel the summary before switching meetings."))
                        .overlay(alignment: .leading) {
                            Rectangle()
                                .fill(self.theme.palette.separator)
                                .frame(width: 1)
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        .transition(.move(edge: .trailing).combined(with: .opacity))
                    }
                }
            }
            .opacity(self.profileService.isPrivateDataVisible ? 1 : 0)
            .allowsHitTesting(self.profileService.isPrivateDataVisible)
            .disabled(!self.profileService.isPrivateDataVisible)
            .accessibilityHidden(!self.profileService.isPrivateDataVisible)
            .overlay {
                self.concealedCaptureControls(activeSessionID: activeSessionID)
            }
        }
    }

    private func meetingPresentation(projection: MeetingViewPrivateProjection.Stamp?, activeSessionID: MeetingSessionID?) -> some View {
        self.meetingLayout(projection: projection, activeSessionID: activeSessionID)
        .background(self.theme.palette.contentBackground)
        .onChange(of: self.profileService.projectionRevision) { _, _ in self.privateState.clearPayloads() }
        .clipped()
        .onAppear { self.reattachActiveSummary() }
        .onChange(of: self.appServices.activeMeetingSummarySession?.id) { _, _ in self.reattachActiveSummary() }
        .task { self.prepareMeetingPresentation() }
        .onChange(of: self.settings.selectedSpeechModel) { _, _ in
            guard self.privateState.capture() != nil else { return }
            if self.settings.meetingRecordingDefaults.languageCode == nil, self.coordinator.isQuiescent {
                self.privateState.setupDraft.languageCode = PichiMeetingProviderFactory.defaultLanguageCode(for: self.settings.selectedSpeechModel.rawValue) ?? "ru"
            }
            self.privateState.run { _ in await self.refreshModelReadiness() }
        }
        .onChange(of: self.privateState.setupDraft.mode) { _, _ in
            self.privateState.run { _ in await self.refreshSources(requestPermissions: false) }
            self.regenerateDefaultTitleIfNeeded()
        }
        .onReceive(NotificationCenter.default.publisher(for: .settingsBackupDidRestore)) { _ in
            guard self.privateState.capture() != nil else { return }
            self.privateState.pendingBackupSetupRefresh = true
            self.applyPendingBackupSetupRefresh()
        }
        .onChange(of: self.canRefreshSetupAfterBackupRestore) { _, canRefresh in
            if canRefresh { self.applyPendingBackupSetupRefresh() }
        }
        .onChange(of: self.privateState.setupDraft.selectedApplicationID) { _, _ in
            self.regenerateDefaultTitleIfNeeded()
        }
        .onChange(of: self.privateState.setupDraft.applicationAudioScope) { _, _ in
            self.selectPreferredApplication(from: self.applications.map(\.identity))
            self.regenerateDefaultTitleIfNeeded()
        }
        .onChange(of: self.privateState.setupDraft.usesAutomaticApplication) { _, automatic in
            guard automatic, self.privateState.setupDraft.applicationAudioScope == .selectedApplication else { return }
            self.selectPreferredApplication(from: self.applications.map(\.identity))
        }
        .onChange(of: self.appServices.meetingAutomaticTarget) { _, _ in
            guard self.privateState.setupDraft.applicationAudioScope == .selectedApplication, self.privateState.setupDraft.usesAutomaticApplication, !self.privateState.isShowingMeetingSettings,
                  self.coordinator.isQuiescent, !self.isStarting else { return }
            self.selectPreferredApplication(from: self.applications.map(\.identity))
            self.privateState.run { _ in await self.refreshSources(requestPermissions: false) }
        }
        .onChange(of: self.coordinator.latestCompletedSession?.id) { _, _ in
            self.privateState.run { _ in await self.loadMeetingHistory() }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            self.refreshMeetingPresentationOnActivation()
        }
    }

    private func recordingSettingsSheet(projection: MeetingViewPrivateProjection.Stamp?) -> some View {
        MeetingRecordingSettingsSheet(
            draft: self.$privateState.setupDraft,
            retentionPolicy: self.$privateState.draftMeetingAudioRetentionPolicy,
            applications: self.applications,
            microphones: self.microphones,
            readiness: self.readiness,
            isFirstSetup: !SettingsStore.shared.meetingRecordingDefaults.isConfigured,
            onRefreshSources: self.refreshSourcesFromUserAction,
            onOpenMicrophoneSettings: { Self.openMicrophoneSettings() },
            onOpenScreenRecordingSettings: { self.openScreenRecordingSettings() },
            onOpenVoiceEngine: self.onOpenVoiceEngine,
            onCancel: self.cancelMeetingSettings,
            onSave: { if self.privateState.accepts(projection) { self.saveMeetingSettings() } },
            onModelImported: { self.privateState.run { _ in await self.refreshModelReadiness() } },
            initialSection: self.meetingSettingsInitialSection
        )
        .background(FluidSheetOutsideDismiss(onCancel: self.cancelMeetingSettings))
        .interactiveDismissDisabled()
    }

    private var deleteMeetingIsPresented: Binding<Bool> {
        Binding(
                        get: { self.privateState.pendingDeleteSession != nil },
                        set: { if !$0 { self.privateState.pendingDeleteSession = nil } }
                    )
    }

    private var deleteAudioIsPresented: Binding<Bool> {
        Binding(
                        get: { self.privateState.pendingDeleteAudioSession != nil },
                        set: { if !$0 { self.privateState.pendingDeleteAudioSession = nil } }
                    )
    }

    @ViewBuilder
    private func deleteMeetingActions(projection: MeetingViewPrivateProjection.Stamp?) -> some View {
        Button("Cancel", role: .cancel) { self.privateState.pendingDeleteSession = nil }
        Button("Delete", role: .destructive) {
            if self.privateState.accepts(projection), let source = self.privateState.pendingDeleteSession { self.deleteSession(source: source) }
        }
    }

    @ViewBuilder
    private func deleteAudioActions(projection: MeetingViewPrivateProjection.Stamp?) -> some View {
        Button("Cancel", role: .cancel) { self.privateState.pendingDeleteAudioSession = nil }
        Button("Delete Audio", role: .destructive) {
            if self.privateState.accepts(projection), let source = self.privateState.pendingDeleteAudioSession { self.deleteAudio(source: source) }
        }
    }

    // Keep owned lifecycle tasks outside the large SwiftUI expression so each
    // async-let scope is type-checked independently of the view's modifier chain.
    private func prepareMeetingPresentation() {
        self.privateState.run { _ in
            if CPUArchitecture.isAppleSilicon && !self.isRegisteredMeetingProviderSelected {
                MeetingDiarizationModelStore.shared.prepareInBackground()
            }
            async let sources: Void = self.refreshSources(requestPermissions: false)
            if self.isMeetingHistoryVisible {
                await self.loadMeetingHistory()
            }
            await sources
        }
    }

    private func refreshMeetingPresentationOnActivation() {
        self.privateState.run { _ in
            async let sources: Void = self.refreshSources(requestPermissions: false)
            if self.isMeetingHistoryVisible {
                await self.loadMeetingHistory()
            }
            await sources
        }
    }

    private var canvasState: MeetingTranscriptionCanvasState {
        guard self.profileService.isPrivateDataVisible else { return .setup(isStarting: false, recentSession: nil) }
        // A live summary owns a frozen session even when history has not loaded yet.
        // Reopening Meet must expose its progress and cancellation despite the lock.
        if let active = self.appServices.activeMeetingSummarySession { return .result(active) }
        if let selectedHistorySession, self.canBrowseMeetingHistory {
            switch selectedHistorySession.state {
            case .failed:
                let message = selectedHistorySession.failures.last?.message ?? PichiLocalization.text("This meeting failed.")
                return .failed(session: selectedHistorySession, message: message)
            case .interrupted:
                let message = selectedHistorySession.endedAt != nil && !selectedHistorySession.processingAttempts.isEmpty
                    ? "Transcription was interrupted. Captured audio is ready to retry."
                    : "Recording was interrupted. Captured audio has been preserved on this Mac."
                return .failed(session: selectedHistorySession, message: message)
            default:
                return .result(selectedHistorySession)
            }
        }

        switch self.coordinator.state {
        case .idle:
            return .setup(isStarting: self.isStarting, recentSession: self.coordinator.latestCompletedSession)
        case .preparing:
            return .setup(isStarting: true, recentSession: self.coordinator.latestCompletedSession)
        case .recording, .recordingDegraded:
            guard let session = self.coordinator.activeSession else {
                return .failed(session: nil, message: "The active meeting could not be loaded.")
            }
            if self.isStopping {
                return .stopping(session: session, trackHealth: self.coordinator.trackHealth, liveTranscript: self.coordinator.liveTranscript)
            }
            return .recording(session: session, trackHealth: self.coordinator.trackHealth, liveTranscript: self.coordinator.liveTranscript)
        case .stopping:
            guard let session = self.coordinator.activeSession else {
                return .failed(session: nil, message: "The meeting is stopping, but its session could not be loaded.")
            }
            return .stopping(session: session, trackHealth: self.coordinator.trackHealth, liveTranscript: self.coordinator.liveTranscript)
        case let .processing(_, stage):
            guard let session = self.coordinator.activeSession else {
                return .failed(session: nil, message: "The meeting is processing, but its session could not be loaded.")
            }
            return .processing(session: session, stage: stage)
        case .completed:
            guard let session = self.coordinator.latestCompletedSession else {
                return .failed(session: nil, message: "The completed transcript could not be loaded.")
            }
            return .result(session)
        case .interrupted:
            let session = self.coordinator.activeSession
            let message = session?.endedAt != nil && session?.processingAttempts.isEmpty == false
                ? "Transcription was interrupted. Captured audio is ready to retry."
                : "Recording was interrupted. Captured audio has been preserved on this Mac."
            return .failed(
                session: session,
                message: message
            )
        case let .failed(_, failure):
            return .failed(session: self.coordinator.activeSession, message: failure.message)
        }
    }

    static func summarySessionSelection(active: MeetingSession?, selectedID: MeetingSessionID?,
                                        history: [MeetingSession], resumed: MeetingSession?) -> MeetingSession? {
        if let active, !active.isLocalContentConcealed { return active }
        guard let selectedID else { return nil }
        return history.first(where: { $0.id == selectedID && !$0.isLocalContentConcealed })
            ?? (resumed?.id == selectedID && resumed?.isLocalContentConcealed == false ? resumed : nil)
    }

    private var selectedHistorySession: MeetingSession? {
        Self.summarySessionSelection(active: self.appServices.activeMeetingSummarySession,
            selectedID: self.privateState.selectedHistorySessionID, history: self.historySnapshot.sessions,
            resumed: self.privateState.resumedSummarySession)
    }

    private func reattachActiveSummary() {
        guard self.privateState.capture() != nil else { return }
        guard let session = self.appServices.activeMeetingSummarySession, !session.isLocalContentConcealed else { return }
        self.privateState.resumedSummarySession = session
        self.privateState.selectedHistorySessionID = session.id
        self.isMeetingHistoryVisible = false
    }

    /// Closing a history selection returns to whatever is underneath; closing the just-finished
    /// meeting's own result/failure returns to the new-meeting screen.
    private var closeCanvasAction: (() -> Void)? {
        guard self.summaryActivity.selectionLock == nil else { return nil }
        if self.privateState.selectedHistorySessionID != nil {
            return {
                guard self.summaryActivity.selectionLock == nil else { return }
                self.privateState.selectedHistorySessionID = nil
            }
        }
        switch self.coordinator.state {
        case .completed, .failed, .interrupted:
            return { self.startNewMeeting() }
        default:
            return nil
        }
    }

    private var canBrowseMeetingHistory: Bool {
        switch self.coordinator.state {
        case .idle, .completed, .interrupted, .failed:
            return true
        case .preparing, .recording, .recordingDegraded, .stopping, .processing:
            return false
        }
    }

    private var effectiveCaptureMode: MeetingCaptureMode {
        self.privateState.setupDraft.mode
    }

    private var readiness: MeetingSetupReadiness {
        let microphoneStatus = self.cachedMicrophoneStatus
        let microphoneReady = microphoneStatus == .authorized
        let applicationResolved = self.privateState.setupDraft.applicationAudioScope == .systemAudio || (try? self.privateState.setupDraft.resolvedRecordingApplication(
            from: self.applications.map(\.identity),
            automaticTarget: self.appServices.meetingAutomaticTarget
        )) != nil
        let meetingAudioReady = self.privateState.setupDraft.mode == .inRoom || (applicationResolved && self.cachedScreenCaptureAccess)
        let modelReady = self.cachedModelReady
        let conflictingActivity = self.asrService.activeExclusiveActivity
        let activityReady = conflictingActivity == nil

        let microphoneStatusText: String
        switch microphoneStatus {
        case .authorized:
            microphoneStatusText = self.microphones.isEmpty ? PichiLocalization.text("No microphone found") : PichiLocalization.text("Ready")
        case .notDetermined:
            microphoneStatusText = PichiLocalization.text("Access required")
        case .denied:
            microphoneStatusText = PichiLocalization.text("Access denied")
        case .restricted:
            microphoneStatusText = PichiLocalization.text("Access restricted")
        @unknown default:
            microphoneStatusText = PichiLocalization.text("Access unavailable")
        }

        let blockingMessage: String?
        if self.isRefreshingSources {
            blockingMessage = PichiLocalization.text("Checking recording access and sources.")
        } else if let conflictingActivity {
            blockingMessage = PichiLocalization.format("Wait for the active %@ to finish.", PichiLocalization.text(conflictingActivity.displayName))
        } else if microphoneStatus == .restricted {
            blockingMessage = PichiLocalization.text("Microphone access is restricted by system policy.")
        } else if !microphoneReady {
            blockingMessage = PichiLocalization.text("Allow microphone access, then refresh sources.")
        } else if self.microphones.isEmpty {
            blockingMessage = PichiLocalization.text("Connect a microphone, then refresh sources.")
        } else if self.privateState.setupDraft.mode == .onlineCall && !self.cachedScreenCaptureAccess {
            blockingMessage = PichiLocalization.text("Allow Screen & System Audio access, then refresh sources.")
        } else if self.privateState.setupDraft.mode == .onlineCall && !applicationResolved {
            blockingMessage = self.privateState.setupDraft.usesAutomaticApplication
                ? PichiLocalization.text("No call was detected. Choose its app under Change, or choose In person for microphone-only recording.")
                : PichiLocalization.text("The selected meeting app is unavailable. Open it and refresh sources, or choose another app under Change.")
        } else if !self.cachedStorageReady {
            let trackCount = MeetingPCMStoragePolicy.trackCount(for: self.effectiveCaptureMode)
            blockingMessage = PichiLocalization.format("Free at least %@ of storage before recording.", MeetingPCMStoragePolicy.requiredFreeSpaceDescription(trackCount: trackCount))
        } else if !CPUArchitecture.isAppleSilicon
            && (!self.isRegisteredMeetingProviderSelected || self.settings.selectedSpeechModel.requiresAppleSilicon) {
            blockingMessage = PichiLocalization.text("Select a compatible meeting model for Intel.")
        } else {
            blockingMessage = nil
        }

        return MeetingSetupReadiness(
            isCheckingSources: self.isRefreshingSources,
            meetingAudioStatus: meetingAudioReady ? PichiLocalization.text("Ready")
                : (self.cachedScreenCaptureAccess ? PichiLocalization.text("Source unavailable") : PichiLocalization.text("Access required")),
            meetingAudioReady: meetingAudioReady,
            microphoneStatus: microphoneStatusText,
            microphoneReady: microphoneReady && !self.microphones.isEmpty,
            modelStatus: self.isRegisteredMeetingProviderSelected
                ? (modelReady
                    ? (self.cachedSpeakerModelReady
                        ? PichiLocalization.format("%@ and speaker model installed", self.settings.selectedSpeechModel.displayName)
                        : PichiLocalization.format("%@ installed · automatic speaker separation unavailable", self.settings.selectedSpeechModel.displayName))
                    : PichiLocalization.format("Import %@ in Voice Engine before transcription", self.settings.selectedSpeechModel.displayName))
                : (modelReady ? PichiLocalization.text("Speaker model installed · transcription prepares after Stop") : PichiLocalization.text("Speaker model downloads before transcription")),
            modelReady: modelReady,
            storageStatus: self.cachedStorageStatus.text(language: PichiInterfaceLanguage(rawValue: self.interfaceLocale.identifier) ?? .russian),
            storageReady: self.cachedStorageReady,
            activityStatus: conflictingActivity.map { PichiLocalization.format("Wait for %@", PichiLocalization.text($0.displayName)) } ?? PichiLocalization.text("Ready"),
            activityReady: activityReady,
            showMicrophoneSettingsAction: microphoneStatus == .denied,
            showScreenRecordingSettingsAction: self.privateState.setupDraft.mode == .onlineCall && !self.cachedScreenCaptureAccess,
            blockingMessage: blockingMessage
        )
    }

    private var isRegisteredMeetingProviderSelected: Bool {
        PichiMeetingProviderFactory.registeredLanguageCodes(for: self.settings.selectedSpeechModel.rawValue) != nil
    }

    private func refreshSourcesFromUserAction() {
        self.privateState.run { _ in await self.refreshSources(requestPermissions: true) }
    }

    @MainActor
    private func refreshModelReadiness() async {
        guard let stamp = self.privateState.capture() else { return }
        self.modelReadinessRevision += 1
        let revision = self.modelReadinessRevision
        let selectedModelID = self.settings.selectedSpeechModel.rawValue
        let registered = PichiMeetingProviderFactory.registeredBackendDescriptor(for: selectedModelID) != nil
        let requiresAppleSilicon = self.settings.selectedSpeechModel.requiresAppleSilicon
        let (ready, speakerReady) = await Task.detached(priority: .utility) {
            let speakerReady = CPUArchitecture.isAppleSilicon && (try? MeetingNemotronModelLocator().locate()) != nil
            let providerReady = registered ? (await PichiMeetingProviderFactory.registeredModelsExistOnDisk(for: selectedModelID) ?? false) : speakerReady
            return (providerReady && (!requiresAppleSilicon || CPUArchitecture.isAppleSilicon), speakerReady)
        }.value
        // An older check must not overwrite an import completion's newer result.
        guard self.privateState.accepts(stamp), self.modelReadinessRevision == revision,
              self.settings.selectedSpeechModel.rawValue == selectedModelID else { return }
        self.cachedModelReady = ready
        self.cachedSpeakerModelReady = speakerReady
    }

    @MainActor
    private func refreshSources(requestPermissions: Bool) async {
        guard let stamp = self.privateState.capture() else { return }
        guard !self.isRefreshingSources else { return }
        self.isRefreshingSources = true
        await self.refreshModelReadiness()
        guard self.privateState.accepts(stamp) else { self.isRefreshingSources = false; return }
        self.refreshCachedReadiness()
        defer {
            self.refreshCachedReadiness()
            self.isRefreshingSources = false
        }

        self.privateState.actionErrorMessage = nil

        if requestPermissions, AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined {
            _ = await Self.requestMicrophoneAccess()
            guard self.privateState.accepts(stamp) else { return }
        }

        if AVCaptureDevice.authorizationStatus(for: .audio) == .authorized {
            let snapshot = await MeetingCaptureSourceCatalog.microphoneSnapshot()
            guard self.privateState.accepts(stamp) else { return }
            let identities = snapshot.identities
            self.cachedSystemDefaultMicrophoneUID = snapshot.defaultCoreAudioUID
            self.microphones = identities.map(MeetingMicrophoneOption.init)
            self.selectPreferredMicrophone(from: identities, systemDefaultUID: snapshot.defaultCoreAudioUID)
        } else {
            self.microphones = []
            self.privateState.setupDraft.selectedMicrophoneID = nil
        }

        guard self.privateState.setupDraft.mode == .onlineCall else { return }

        if requestPermissions, !CGPreflightScreenCaptureAccess() {
            _ = CGRequestScreenCaptureAccess()
        }

        guard CGPreflightScreenCaptureAccess() else {
            self.applications = []
            self.privateState.setupDraft.selectedApplicationID = nil
            return
        }

        do {
            let identities = try await MeetingCaptureSourceCatalog.availableApplications()
            guard self.privateState.accepts(stamp) else { return }
            self.applications = identities.map(MeetingApplicationOption.init)
            self.selectPreferredApplication(from: identities)
        } catch {
            guard self.privateState.accepts(stamp) else { return }
            self.applications = []
            self.privateState.setupDraft.selectedApplicationID = nil
            self.privateState.actionErrorMessage = error.localizedDescription
        }
    }

    /// Keeps the title following the selected app/mode until the user types their own.
    private func regenerateDefaultTitleIfNeeded() {
        guard self.privateState.capture() != nil else { return }
        guard !self.privateState.setupDraft.titleWasEdited else { return }
        let applicationName = self.applications.first(where: { $0.id == self.privateState.setupDraft.selectedApplicationID })?.identity.displayName
        self.privateState.setupDraft.title = MeetingTranscriptionSetupDraft.defaultTitle(
            mode: self.privateState.setupDraft.mode,
            applicationDisplayName: applicationName
        )
    }

    private func resetDraftTitleToDefault() {
        self.privateState.setupDraft.titleWasEdited = false
        self.regenerateDefaultTitleIfNeeded()
    }

    private func selectPreferredMicrophone(
        from identities: [MeetingMicrophoneIdentity],
        systemDefaultUID: String?
    ) {
        if let selectedID = self.privateState.setupDraft.selectedMicrophoneID,
           identities.contains(where: { $0.captureDeviceID == selectedID })
        {
            return
        }

        let defaults = SettingsStore.shared.meetingRecordingDefaults
        let savedMicrophone = defaults.savedMicrophone(in: identities)
        let preferredInputUID = SettingsStore.shared.preferredInputDeviceUID
        // Default preselection follows the system's current input, not the remembered device.
        let selection = MeetingMicrophonePreselection.select(
            identities: identities,
            savedDeviceID: savedMicrophone?.captureDeviceID,
            savedRole: defaults.microphoneRole,
            systemDefaultUID: systemDefaultUID,
            preferredInputUID: preferredInputUID,
            systemDefaultCaptureID: nil
        )
        self.privateState.setupDraft.selectedMicrophoneID = selection.deviceID
    }

    private func selectPreferredApplication(from identities: [MeetingApplicationIdentity]) {
        self.privateState.setupDraft.refreshApplicationSelection(from: identities, automaticTarget: self.appServices.meetingAutomaticTarget)
    }

    private func startRecording() {
        guard let stamp = self.privateState.capture() else { return }
        guard !self.isStarting else { return }
        if self.privateState.setupDraft.mode == .onlineCall,
           self.privateState.setupDraft.applicationAudioScope == .selectedApplication,
           self.privateState.setupDraft.selectedApplicationID == nil {
            MeetingRecordingSourcePromptController.shared.handleShortcut(microphoneID: self.privateState.setupDraft.selectedMicrophoneID)
            return
        }
        let readiness = self.readiness
        guard readiness.activityReady,
              readiness.storageReady,
              readiness.microphoneReady,
              readiness.meetingAudioReady,
              let configuration = self.captureConfiguration,
              let recordingDefaults = try? self.privateState.setupDraft.recordingDefaults(
                  microphone: configuration.microphone,
                  applications: self.applications.map(\.identity)
              )
        else {
            self.privateState.actionErrorMessage = readiness.blockingMessage.map(PichiLocalization.text) ?? PichiLocalization.text("Finish meeting setup before recording.")
            return
        }
        self.isStarting = true
        self.privateState.actionErrorMessage = nil
        let defaultsBeforeStart = self.settings.meetingRecordingDefaults

        Task {
            defer { self.isStarting = false }
            guard self.privateState.accepts(stamp) else { return }
            do {
                _ = try await self.coordinator.startRecording(configuration: configuration)
                guard self.privateState.accepts(stamp) else { return }
                // A restore or another window's settings change supersedes this older start.
                if !self.privateState.pendingBackupSetupRefresh, self.settings.meetingRecordingDefaults == defaultsBeforeStart {
                    self.settings.meetingRecordingDefaults = recordingDefaults
                }
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private var captureConfiguration: MeetingCaptureConfiguration? {
        let title = self.privateState.setupDraft.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty,
              let microphoneOption = self.microphones.first(where: { $0.id == self.privateState.setupDraft.selectedMicrophoneID })
        else {
            return nil
        }

        var microphone = microphoneOption.identity
        microphone.role = .unknown

        let application: MeetingApplicationIdentity?
        do {
            application = try self.privateState.setupDraft.resolvedRecordingApplication(
                from: self.applications.map(\.identity),
                automaticTarget: self.appServices.meetingAutomaticTarget
            )
        } catch { return nil }

        let configuration = MeetingCaptureConfiguration(
            mode: self.privateState.setupDraft.mode,
            title: title,
            languageCode: self.privateState.setupDraft.languageCode,
            platform: application.map {
                MeetingPlatformProfile(identifier: $0.bundleIdentifier, displayName: $0.displayName)
            },
            application: application,
            applicationAudioScope: self.privateState.setupDraft.mode == .onlineCall ? self.privateState.setupDraft.applicationAudioScope : nil,
            microphone: microphone,
            timestampDefaultTitle: !self.privateState.setupDraft.titleWasEdited
        )
        return self.settings.applyingMeetingRecordingPreferences(to: configuration)
    }

    private func stopAndTranscribe(expectedSessionID: MeetingSessionID?) {
        guard let expectedSessionID, self.coordinator.activeSession?.id == expectedSessionID else { return }
        let stamp = self.privateState.capture()
        guard !self.isStopping else { return }
        self.isStopping = true
        self.privateState.actionErrorMessage = nil
        // Stop is an explicit "show me my meeting"; a stale sidebar pick must not hijack the outcome.
        self.privateState.selectedHistorySessionID = nil
        Task {
            defer { self.isStopping = false }
            guard self.coordinator.activeSession?.id == expectedSessionID else { return }
            do {
                _ = try await self.coordinator.stopAndTranscribe()
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func retryProcessingSession(id: MeetingSessionID, restarting: Bool = false, languageCode: String? = nil) {
        guard let stamp = self.privateState.capture() else { return }
        guard !self.isRetrying, self.summaryActivity.selectionLock == nil else { return }
        self.isRetrying = true
        self.privateState.actionErrorMessage = nil
        self.privateState.selectedHistorySessionID = nil
        Task {
            defer { self.isRetrying = false }
            guard self.privateState.accepts(stamp) else { return }
            do {
                if restarting {
                    _ = try await self.coordinator.restartProcessing(sessionID: id)
                } else {
                    _ = try await self.coordinator.retryProcessing(sessionID: id, languageCode: languageCode)
                }
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
            guard self.privateState.accepts(stamp) else { return }
            await self.loadMeetingHistory()
        }
    }

    private func reassignSegments(source: MeetingSession, segmentIDs: [MeetingTranscriptSegmentID], to speakerID: SessionSpeakerID) {
        self.privateState.actionErrorMessage = nil
        self.privateState.run { stamp in
            do {
                let saved = try await self.coordinator.reassignSegments(sessionID: source.id, segmentIDs: segmentIDs, to: speakerID, expectedOwnership: source.profileOwnership ?? .guest)
                guard self.privateState.accepts(stamp) else { return }
                self.historySnapshot.applyCommitted(saved)
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func setLocalUserSpeaker(source: MeetingSession, speakerID: SessionSpeakerID?) {
        guard self.coordinator.isQuiescent, self.summaryActivity.selectionLock == nil else { return }
        self.privateState.actionErrorMessage = nil
        self.privateState.run { stamp in
            do {
                _ = try await self.coordinator.setLocalUserSpeaker(sessionID: source.id, speakerID: speakerID, expectedOwnership: source.profileOwnership ?? .guest)
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
            guard self.privateState.accepts(stamp) else { return }
            await self.loadMeetingHistory()
        }
    }

    private func nameUnknownSegment(
        source: MeetingSession,
        segmentID: MeetingTranscriptSegmentID,
        displayName: String
    ) {
        self.privateState.actionErrorMessage = nil
        self.privateState.run { stamp in
            do {
                let saved = try await self.coordinator.nameUnknownSegment(
                    sessionID: source.id,
                    segmentID: segmentID,
                    displayName: displayName, expectedOwnership: source.profileOwnership ?? .guest
                )
                guard self.privateState.accepts(stamp) else { return }
                self.historySnapshot.applyCommitted(saved)
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func editTranscriptSegment(source: MeetingSession, segmentID: MeetingTranscriptSegmentID, text: String, revision: Int) async -> String? {
        await self.privateState.result { stamp in
            do {
                let saved = try await self.coordinator.editTranscriptText(sessionID: source.id, segmentID: segmentID, text: text, expectedRevision: revision, expectedOwnership: source.profileOwnership ?? .guest)
                guard self.privateState.accepts(stamp) else { return nil }
                self.historySnapshot.applyCommitted(saved)
                return nil
            } catch {
                return self.privateState.accepts(stamp) ? error.localizedDescription : nil
            }
        }
    }

    private func assignSpeakers(source: MeetingSession, edits: MeetingSpeakerEdits) async -> String? {
        await self.privateState.result { stamp in
            self.privateState.actionErrorMessage = nil
            do {
                let saved = try await self.coordinator.editSpeakers(sessionID: source.id, edits: edits, expectedOwnership: source.profileOwnership ?? .guest)
                guard self.privateState.accepts(stamp) else { return nil }
                self.historySnapshot.applyCommitted(saved)
                return nil
            } catch {
                return self.privateState.accepts(stamp) ? error.localizedDescription : nil
            }
        }
    }

    private func renameMeetingSession(source: MeetingSession, to title: String) {
        self.privateState.actionErrorMessage = nil
        self.privateState.run { stamp in
            do {
                let saved = try await self.coordinator.renameSession(sessionID: source.id, to: title, expectedOwnership: source.profileOwnership ?? .guest)
                guard self.privateState.accepts(stamp) else { return }
                self.historySnapshot.applyCommitted(saved)
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func undoTranscriptCorrection(source: MeetingSession) async -> Bool {
        await self.privateState.result { stamp in
            self.privateState.actionErrorMessage = nil
            do {
                let saved = try await self.coordinator.undoTranscriptCorrection(sessionID: source.id, expectedOwnership: source.profileOwnership ?? .guest)
                guard self.privateState.accepts(stamp) else { return nil }
                self.historySnapshot.applyCommitted(saved)
            } catch {
                guard self.privateState.accepts(stamp) else { return nil }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
            return self.coordinator.canUndoCorrection(sessionID: source.id)
        } ?? false
    }

    private func deleteSession(source: MeetingSession) {
        guard self.summaryActivity.selectionLock == nil else { return }
        self.privateState.pendingDeleteSession = nil
        self.privateState.actionErrorMessage = nil
        self.privateState.run { stamp in
            do {
                try await self.coordinator.deleteSession(id: source.id, expectedOwnership: source.profileOwnership ?? .guest)
                guard self.privateState.accepts(stamp) else { return }
                if self.privateState.selectedHistorySessionID == source.id { self.privateState.selectedHistorySessionID = nil }
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
            guard self.privateState.accepts(stamp) else { return }
            await self.loadMeetingHistory()
        }
    }

    private func deleteAudio(source: MeetingSession) {
        guard self.summaryActivity.selectionLock == nil else { return }
        self.privateState.pendingDeleteAudioSession = nil
        self.privateState.actionErrorMessage = nil
        self.privateState.run { stamp in
            do {
                _ = try await self.coordinator.deleteAudio(sessionID: source.id, expectedOwnership: source.profileOwnership ?? .guest)
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
            guard self.privateState.accepts(stamp) else { return }
            await self.loadMeetingHistory()
        }
    }

    private func recordAgain(_ session: MeetingSession) {
        guard !session.isLocalContentConcealed else { return }
        guard let stamp = self.privateState.capture() else { return }
        guard self.summaryActivity.selectionLock == nil else { return }
        guard let configuration = self.recordAgainConfiguration(from: session) else { return }
        self.privateState.actionErrorMessage = nil
        Task {
            guard self.privateState.accepts(stamp) else { return }
            do {
                _ = try await self.coordinator.recordAgain(from: session.id, configuration: configuration)
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.selectedHistorySessionID = nil
                self.resetDraftTitleToDefault()
                await self.loadMeetingHistory()
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = error.localizedDescription
            }
        }
    }

    private func recordAgainConfiguration(from session: MeetingSession) -> MeetingCaptureConfiguration? {
        guard let microphone = self.resolvedMicrophone(for: session) else {
            self.privateState.actionErrorMessage = PichiLocalization.text("microphone unavailable")
            return nil
        }
        var application: MeetingApplicationIdentity?
        if session.mode == .onlineCall, session.effectiveApplicationAudioScope == .selectedApplication {
            guard let bundleIdentifier = session.capturedApplication?.bundleIdentifier,
                  let resolved = self.applications.first(where: { $0.identity.bundleIdentifier == bundleIdentifier })
            else {
                self.privateState.actionErrorMessage = PichiLocalization.text("app not running")
                return nil
            }
            application = resolved.identity
        }
        let configuration = MeetingCaptureConfiguration(
            mode: session.mode,
            title: session.defaultTitleBase ?? session.title,
            languageCode: session.languageCode,
            platform: session.platform,
            application: application,
            applicationAudioScope: session.applicationAudioScope,
            microphone: microphone,
            timestampDefaultTitle: session.defaultTitleBase != nil
        )
        return self.settings.applyingMeetingRecordingPreferences(to: configuration)
    }

    private func resolvedMicrophone(for session: MeetingSession) -> MeetingMicrophoneIdentity? {
        if let coreAudioUID = session.selectedMicrophone.coreAudioUID,
           let match = self.microphones.first(where: { $0.identity.coreAudioUID == coreAudioUID })
        {
            var identity = match.identity
            identity.role = .unknown
            return identity
        }
        guard let match = self.microphones.first(where: { $0.identity.captureDeviceID == session.selectedMicrophone.captureDeviceID }) else {
            return nil
        }
        var identity = match.identity
        identity.role = .unknown
        return identity
    }

    private func revealCapturedAudio(_ session: MeetingSession) {
        guard !session.isLocalContentConcealed else { return }
        self.privateState.run { stamp in
            do {
                // Reload fresh: the passed-in session may predate a since-completed audio deletion.
                let loaded = try await MeetingSessionStore.shared.loadExistingSource(id: session.id,
                    expectedOwnership: session.profileOwnership ?? .guest)
                guard self.privateState.accepts(stamp) else { return }
                guard let source = loaded else {
                    self.privateState.actionErrorMessage = PichiLocalization.text("Captured audio could not be revealed: recording no longer on disk.")
                    return
                }
                let freshSession = source.session
                guard !freshSession.isLocalContentConcealed,
                      freshSession.retention.audioDeletedAt == nil,
                      freshSession.hasFinalizedAudio
                else {
                    self.privateState.actionErrorMessage = PichiLocalization.text("Captured audio could not be revealed: audio for this recording has been deleted.")
                    return
                }
                let directory = source.directory
                guard let firstAudioURL = MeetingAudioPresentation.firstPlaybackURL(
                    in: freshSession,
                    directory: directory
                ) else {
                    self.privateState.actionErrorMessage = PichiLocalization.text("Captured audio is still preparing or is no longer available on disk.")
                    return
                }
                NSWorkspace.shared.activateFileViewerSelecting([firstAudioURL])
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = PichiLocalization.format("Captured audio could not be revealed: %@", error.localizedDescription)
            }
        }
    }

    private func exportAudio(_ session: MeetingSession) {
        guard !session.isLocalContentConcealed else { return }
        guard let projection = self.privateState.capture() else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = PichiLocalization.text("Choose")
        self.privateState.retainPanel(panel)
        defer { self.privateState.releasePanel() }
        guard panel.runModal() == .OK, self.privateState.accepts(projection), let destinationFolder = panel.url else { return }

        self.privateState.actionErrorMessage = nil
        self.privateState.run { stamp in
            do {
                // Reload fresh: the passed-in session may predate a since-completed audio deletion.
                let loaded = try await MeetingSessionStore.shared.loadExistingSource(id: session.id,
                    expectedOwnership: session.profileOwnership ?? .guest)
                guard self.privateState.accepts(stamp) else { return }
                guard let source = loaded else {
                    self.privateState.actionErrorMessage = PichiLocalization.text("Export failed: recording no longer on disk.")
                    return
                }
                let freshSession = source.session
                guard !freshSession.isLocalContentConcealed,
                      freshSession.retention.audioDeletedAt == nil,
                      freshSession.hasFinalizedAudio
                else {
                    self.privateState.actionErrorMessage = PichiLocalization.text("Export failed: audio for this recording has been deleted.")
                    return
                }
                let sourceDirectory = source.directory
                let profile = stamp.profile
                // The shared exporter is joined, including its detached worker. Its final move
                // currently has no cancellation gate; per-file reads still refuse a concealed owner.
                try await Self.exportAudioFiles(of: freshSession, from: sourceDirectory, into: destinationFolder) { source, destination in
                    guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.current == profile else { throw CancellationError() }
                    try FileManager.default.copyItem(at: source, to: destination)
                }
            } catch {
                guard self.privateState.accepts(stamp) else { return }
                self.privateState.actionErrorMessage = PichiLocalization.format("Export failed: %@", error.localizedDescription)
            }
        }
    }

    nonisolated static func exportAudioFiles(
        of session: MeetingSession, from sourceDirectory: URL, into destinationFolder: URL,
        copyItem: @escaping @Sendable (URL, URL) throws -> Void = { try FileManager.default.copyItem(at: $0, to: $1) }
    ) async throws {
        try await MeetingAudioExporter.exportAudioFiles(of: session, from: sourceDirectory, into: destinationFolder, copyItem: copyItem)
    }

    private nonisolated static func sanitizedExportName(_ title: String) -> String {
        MeetingAudioExporter.sanitizedExportName(title)
    }

    private func toggleMeetingHistory() {
        let willShowHistory = !self.isMeetingHistoryVisible
        withAnimation(self.accessibilityReduceMotion ? nil : .easeInOut(duration: 0.2)) {
            self.isMeetingHistoryVisible.toggle()
        }
        if willShowHistory, self.historySnapshot.sessions.isEmpty {
            self.privateState.run { _ in await self.loadMeetingHistory() }
        }
    }

    private func startNewMeeting(hideHistory: Bool = false) {
        guard self.privateState.capture() != nil else { return }
        guard self.summaryActivity.selectionLock == nil else { return }
        do {
            try self.coordinator.resetForNewMeeting()
            self.privateState.selectedHistorySessionID = nil
            if hideHistory { self.isMeetingHistoryVisible = false }
            self.selectPreferredApplication(from: self.applications.map(\.identity))
            self.resetDraftTitleToDefault()
            self.privateState.actionErrorMessage = nil
        } catch {
            self.privateState.actionErrorMessage = error.localizedDescription
        }
    }

    @MainActor
    private func loadMeetingHistory() async {
        guard let stamp = self.privateState.capture() else { return }
        await self.historySnapshot.refresh()
        guard self.privateState.accepts(stamp), self.historySnapshot.errorMessage == nil else { return }
        if let selectedHistorySessionID = self.privateState.selectedHistorySessionID,
           !self.historySnapshot.sessions.contains(where: { $0.id == selectedHistorySessionID }),
           self.privateState.resumedSummarySession?.id != selectedHistorySessionID
        {
            self.privateState.selectedHistorySessionID = nil
        }
    }

    // Restore updates future setup only; a running meeting and an open editing sheet
    // keep their draft until the existing activity/dismissal events reach a safe point.
    private var canRefreshSetupAfterBackupRestore: Bool {
        self.coordinator.isQuiescent && !self.isStarting && !self.isStopping &&
            !self.isRetrying && !self.isRefreshingSources && !self.privateState.isShowingMeetingSettings
    }

    private func applyPendingBackupSetupRefresh() {
        guard self.privateState.pendingBackupSetupRefresh, self.canRefreshSetupAfterBackupRestore else { return }
        self.privateState.pendingBackupSetupRefresh = false
        var restoredDraft = MeetingTranscriptionSetupDraft(settings: .shared)
        if self.privateState.setupDraft.titleWasEdited {
            restoredDraft.title = self.privateState.setupDraft.title
            restoredDraft.titleWasEdited = true
        }
        self.privateState.setupDraft = restoredDraft
        self.selectPreferredMicrophone(
            from: self.microphones.map(\.identity),
            systemDefaultUID: self.cachedSystemDefaultMicrophoneUID
        )
        self.selectPreferredApplication(from: self.applications.map(\.identity))
        self.regenerateDefaultTitleIfNeeded()
        self.privateState.setupDraft.applicationSelectionWasEdited = false
        self.privateState.setupDraftBeforeEditing = self.privateState.setupDraft
        self.privateState.draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
    }

    private func finishRestoredMeetingSettingsIfPending() -> Bool {
        guard self.privateState.pendingBackupSetupRefresh else { return false }
        // A backup imported in another window supersedes this older sheet. Closing
        // it must not write its stale language/mode over the restored preferences.
        self.privateState.isShowingMeetingSettings = false
        self.applyPendingBackupSetupRefresh()
        return true
    }

    /// Opens FluidMeet settings on the Integrations tab, from a meeting's More menu.
    private func openMeetingIntegrations() {
        self.openMeetingSettings(section: .integrations)
    }

    private func openMeetingSettings() {
        self.openMeetingSettings(section: .recording)
    }

    private func openMeetingSettings(section: MeetingSettingsSection) {
        guard self.privateState.capture() != nil else { return }
        self.meetingSettingsInitialSection = section
        self.privateState.setupDraft.autoDetectEnabled = SettingsStore.shared.meetingAutoDetectEnabled
        self.privateState.setupDraft.browserDetectionEnabled = SettingsStore.shared.meetingAutoDetectBrowserEnabled
        self.privateState.setupDraft.applicationSelectionWasEdited = false
        self.privateState.setupDraftBeforeEditing = self.privateState.setupDraft
        self.privateState.draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
        self.privateState.isShowingMeetingSettings = true
    }

    private func repairRecordingSetup() {
        if self.readiness.showMicrophoneSettingsAction {
            Self.openMicrophoneSettings()
        } else if self.readiness.showScreenRecordingSettingsAction {
            self.openScreenRecordingSettings()
        } else {
            self.openMeetingSettings()
        }
    }

    private func cancelMeetingSettings() {
        if self.finishRestoredMeetingSettingsIfPending() { return }
        self.privateState.setupDraft = self.privateState.setupDraftBeforeEditing
        self.privateState.draftMeetingAudioRetentionPolicy = SettingsStore.shared.meetingAudioRetentionPolicy
        self.privateState.isShowingMeetingSettings = false
        self.privateState.run { _ in await self.refreshSources(requestPermissions: false) }
    }

    private func saveMeetingSettings() {
        if self.finishRestoredMeetingSettingsIfPending() { return }
        guard let microphone = self.microphones.first(where: { $0.id == self.privateState.setupDraft.selectedMicrophoneID }) else {
            self.privateState.actionErrorMessage = PichiLocalization.text("Choose an available microphone before saving.")
            return
        }

        // Persist explicit intent by stable bundle; Automatic clears the saved manual source.
        let settings = SettingsStore.shared
        do {
            settings.meetingRecordingDefaults = try self.privateState.setupDraft.recordingDefaults(
                microphone: microphone.identity,
                applications: self.applications.map(\.identity)
            )
        } catch {
            self.privateState.actionErrorMessage = PichiLocalization.text("Choose an available audio source or Automatic before saving.")
            return
        }

        if self.privateState.setupDraft.applicationSelectionWasEdited,
           self.privateState.setupDraft.mode == .onlineCall,
           self.privateState.setupDraft.applicationAudioScope == .selectedApplication,
           !self.privateState.setupDraft.usesAutomaticApplication,
           let application = self.applications.first(where: { $0.id == self.privateState.setupDraft.selectedApplicationID }) {
            settings.meetingRecentApplication = application.identity
        }
        let previousRetentionPolicy = settings.meetingAudioRetentionPolicy
        settings.meetingAutoDetectEnabled = self.privateState.setupDraft.autoDetectEnabled
        settings.meetingAutoDetectBrowserEnabled = self.privateState.setupDraft.browserDetectionEnabled
        settings.meetingAudioRetentionPolicy = self.privateState.draftMeetingAudioRetentionPolicy
        if previousRetentionPolicy != self.privateState.draftMeetingAudioRetentionPolicy {
            self.privateState.run { _ in await self.coordinator.sweepExpiredAudio() }
        }

        self.privateState.setupDraft.applicationSelectionWasEdited = false
        self.privateState.setupDraftBeforeEditing = self.privateState.setupDraft
        self.privateState.actionErrorMessage = nil
        self.privateState.isShowingMeetingSettings = false
        self.selectPreferredApplication(from: self.applications.map(\.identity))
        // Import is applied immediately inside the sheet; Save must rediscover the installed
        // model even when no source selection changed and no app-activation event follows.
        self.privateState.run { _ in await self.refreshSources(requestPermissions: false) }
    }

    private func copyTranscript(_ session: MeetingSession, includeEchoes: Bool) {
        guard !session.isLocalContentConcealed, self.privateState.capture() != nil else { return }
        let text = MeetingTranscriptExporter.text(for: session, includeEchoes: includeEchoes)
        guard !text.isEmpty else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func exportTranscript(_ session: MeetingSession, format: MeetingTranscriptExportFormat, includeEchoes: Bool) {
        guard !session.isLocalContentConcealed else { return }
        guard let projection = self.privateState.capture() else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(Self.sanitizedExportName(session.displayTitle)).\(format.fileExtension)"
        panel.message = AppBrand.text("Exported transcripts are outside FluidVoice's retention controls and may be indexed or synced by other apps.")
        self.privateState.retainPanel(panel)
        defer { self.privateState.releasePanel() }
        guard panel.runModal() == .OK, self.privateState.accepts(projection), let url = panel.url else { return }
        self.privateState.actionErrorMessage = nil
        do {
            let data: Data
            switch format {
            case .text: data = Data(MeetingTranscriptExporter.text(for: session, includeEchoes: includeEchoes).utf8)
            case .markdown: data = Data(MeetingTranscriptExporter.markdown(for: session, includeEchoes: includeEchoes).utf8)
            case .json: data = try MeetingTranscriptExporter.json(for: session)
            }
            try data.write(to: url, options: .atomic)
        } catch {
            self.privateState.actionErrorMessage = PichiLocalization.format("Export failed: %@", error.localizedDescription)
        }
    }

    private static func requestMicrophoneAccess() async -> Bool {
        await withCheckedContinuation { continuation in
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                continuation.resume(returning: granted)
            }
        }
    }

    private static func openMicrophoneSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")
        else { return }
        NSWorkspace.shared.open(url)
    }

    private func openScreenRecordingSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture")
        else { return }
        self.screenPermissionGuideID = PermissionDragGuideController.shared.present(
            instruction: PichiLocalization.format("Drag %@ into the Screen & System Audio Recording list as shown", Bundle.main.fluidAppDisplayName),
            settingsPaneURL: url,
            isGranted: { CGPreflightScreenCaptureAccess() },
            onGranted: { [self] in
                self.screenPermissionGuideID = nil
                self.refreshCachedReadiness()
                self.privateState.run { _ in await self.refreshSources(requestPermissions: false) }
            }
        )
    }

    private func refreshCachedReadiness() {
        self.cachedMicrophoneStatus = AVCaptureDevice.authorizationStatus(for: .audio)
        self.cachedScreenCaptureAccess = CGPreflightScreenCaptureAccess()
        let storage = Self.storageReadiness(trackCount: MeetingPCMStoragePolicy.trackCount(for: self.effectiveCaptureMode))
        self.cachedStorageStatus = storage.status
        self.cachedStorageReady = storage.ready
    }

    private static func storageReadiness(trackCount: Int) -> (status: MeetingStorageStatus, ready: Bool) {
        guard let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first,
            let capacity = try? applicationSupport.resourceValues(
                forKeys: [.volumeAvailableCapacityForImportantUsageKey]
            ).volumeAvailableCapacityForImportantUsage
        else {
            return (.unavailable, false)
        }
        let requiredBytes = MeetingPCMStoragePolicy.requiredFreeBytes(trackCount: trackCount)
        return (.available(bytes: capacity), capacity >= requiredBytes)
    }
}

/// Capacity is captured once for readiness; its presentation follows the interface locale.
nonisolated enum MeetingStorageStatus: Equatable, Sendable {
    case checking, unavailable
    case available(bytes: Int64)

    func text(language: PichiInterfaceLanguage = PichiLocalization.language, bundle: Bundle = .main) -> String {
        switch self {
        case .checking: return PichiLocalization.text("Checking…", language: language, bundle: bundle)
        case .unavailable: return PichiLocalization.text("Storage availability unavailable", language: language, bundle: bundle)
        case let .available(bytes):
            let size = bytes.formatted(.byteCount(style: .file).locale(language.locale))
            return PichiLocalization.format("%@ available", language: language, bundle: bundle, arguments: [size])
        }
    }
}

enum MeetingTranscriptExportFormat {
    case text
    case markdown
    case json

    var fileExtension: String {
        switch self {
        case .text: return "txt"
        case .markdown: return "md"
        case .json: return "json"
        }
    }
}

enum MeetingTranscriptionCanvasState {
    case setup(isStarting: Bool, recentSession: MeetingSession?)
    case recording(
        session: MeetingSession,
        trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth],
        liveTranscript: MeetingLiveTranscriptSnapshot
    )
    case stopping(
        session: MeetingSession,
        trackHealth: [MeetingAudioTrackKind: MeetingTrackHealth],
        liveTranscript: MeetingLiveTranscriptSnapshot
    )
    case processing(session: MeetingSession, stage: MeetingProcessingStage)
    case result(MeetingSession)
    case failed(session: MeetingSession?, message: String)
}

struct MeetingTranscriptionCanvas: View {
    @Binding var setupDraft: MeetingTranscriptionSetupDraft

    let state: MeetingTranscriptionCanvasState
    var pendingSpeech: MeetingPendingSpeechSnapshot = .empty
    var microphoneMuteState: MeetingMicrophoneMuteState = .notApplicable
    var onToggleMicrophone: (() -> Void)? = nil
    let applications: [MeetingApplicationOption]
    let microphones: [MeetingMicrophoneOption]
    let readiness: MeetingSetupReadiness
    let errorMessage: String?
    let onStart: () -> Void
    let onStop: () -> Void
    let onRetrySession: (MeetingSession) -> Void
    var onRestartSession: ((MeetingSession) -> Void)? = nil
    var onRetranscribe: (MeetingSessionID, String) -> Void = { _, _ in }
    let onRevealAudio: (MeetingSession) -> Void
    let onRecordAgain: (MeetingSession) -> Void
    let onCopyTranscript: (MeetingSession, Bool) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat, Bool) -> Void
    let onReassignSegments: (MeetingSession, [MeetingTranscriptSegmentID], SessionSpeakerID) -> Void
    var onEditTranscriptSegment: (MeetingSession, MeetingTranscriptSegmentID, String, Int) async -> String? = { _, _, _, _ in PichiLocalization.text("Transcript editing is unavailable.") }
    let onNameUnknownSegment: (MeetingSession, MeetingTranscriptSegmentID, String) -> Void
    let onUndoCorrection: (MeetingSession) async -> Bool
    let onRenameSession: (MeetingSession, String) -> Void
    let onAssignSpeakers: (MeetingSession, MeetingSpeakerEdits) async -> String?
    let canUndoCorrection: (MeetingSessionID) -> Bool
    let isQuiescent: Bool
    let onRepairSetup: () -> Void
    var onEditSetup: (() -> Void)? = nil
    let isRetrying: Bool
    let onCloseSelection: (() -> Void)?
    var summaryASRService: ASRService? = nil
    var onOpenIntegrations: (() -> Void)? = nil
    var onSetLocalUserSpeaker: ((MeetingSession, SessionSpeakerID?) -> Void)? = nil

    @Environment(\.theme) private var theme

    /// Recording renders outside the ScrollView so the live captions card can fill the height;
    /// its transcript list is its own scroller, and nested scrolling would fight it.
    private var fillsCanvasHeight: Bool {
        switch self.state {
        case .recording, .stopping, .result: true
        default: false
        }
    }

    var body: some View {
        Group {
            if self.fillsCanvasHeight {
                self.canvasContent
                    .frame(maxWidth: 820)
                    .padding(self.theme.metrics.spacing.lg * 2)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            } else {
                ScrollView {
                    self.canvasContent
                        .frame(maxWidth: 720)
                        .padding(self.theme.metrics.spacing.lg * 2)
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.windowBackground)
    }

    private var concealedSettledSession: MeetingSession? {
        switch state {
        case .result(let session) where session.isLocalContentConcealed: return session
        case .failed(let session, _) where session?.isLocalContentConcealed == true: return session
        default: return nil
        }
    }

    @ViewBuilder
    private var canvasContent: some View {
        Group {
            if let session = concealedSettledSession {
                VStack(alignment: .leading, spacing: theme.metrics.spacing.lg) {
                    MeetingLocalContentConcealmentView()
                    DesktopCloudRecordingStatusView(sessionID: session.id,
                        publication: AppServices.shared.cloudPublication, account: AppServices.shared.accountSession,
                        profiles: .shared, showsActions: false)
                }
            } else {
                switch self.state {
                case let .setup(isStarting, recentSession):
                    MeetingSetupCanvas(
                        draft: self.$setupDraft,
                        applications: self.applications,
                        readiness: self.readiness,
                        isStarting: isStarting,
                        errorMessage: self.errorMessage,
                        recentSession: recentSession?.isLocalContentConcealed == false ? recentSession : nil,
                        onStart: self.onStart,
                        onRepairSetup: self.onRepairSetup,
                        onEditSetup: self.onEditSetup ?? self.onRepairSetup
                    )
                case let .recording(session, trackHealth, liveTranscript):
                    MeetingRecordingCanvas(
                        session: session,
                        trackHealth: trackHealth,
                        liveTranscript: liveTranscript,
                        pendingSpeech: self.pendingSpeech,
                        microphoneMuteState: self.microphoneMuteState,
                        onToggleMicrophone: self.onToggleMicrophone,
                        isStopping: false,
                        onStop: self.onStop
                    )
                case let .stopping(session, trackHealth, liveTranscript):
                    MeetingRecordingCanvas(
                        session: session,
                        trackHealth: trackHealth,
                        liveTranscript: liveTranscript,
                        pendingSpeech: self.pendingSpeech,
                        microphoneMuteState: self.microphoneMuteState,
                        isStopping: true,
                        onStop: self.onStop
                    )
                case let .processing(session, stage):
                    MeetingProcessingCanvas(session: session, stage: stage)
                case let .result(session):
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
                        DesktopCloudRecordingStatusView(sessionID: session.id,
                            publication: AppServices.shared.cloudPublication,
                            account: AppServices.shared.accountSession, profiles: .shared)
                        if let errorMessage, !errorMessage.isEmpty {
                            Label(PichiLocalization.text(errorMessage), systemImage: "exclamationmark.triangle.fill")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.theme.palette.warning)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: 760, alignment: .leading)
                                .frame(maxWidth: .infinity, alignment: .center)
                                .accessibilityIdentifier("meeting-result-action-error")
                        }
                        if PichiMeetingProviderFactory.isTranscriptOnlyDiarizationFingerprint(session.processingAttempts.last?.diarizationModel) {
                            Label("Automatic speaker separation was unavailable. Source tracks and transcript timing are preserved.", systemImage: "person.crop.circle.badge.questionmark")
                                .font(self.theme.typography.bodySmall)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .fixedSize(horizontal: false, vertical: true)
                                .accessibilityIdentifier("meeting-speaker-separation-unavailable")
                        }
                        MeetingResultCanvas(
                            session: session,
                            isQuiescent: self.isQuiescent,
                            canUndo: self.canUndoCorrection(session.id),
                            onCopyTranscript: self.onCopyTranscript,
                            onExportTranscript: self.onExportTranscript,
                            onReassignSegments: { segmentIDs, speakerID in
                                self.onReassignSegments(session, segmentIDs, speakerID)
                            },
                            onEditTranscriptSegment: { segmentID, text, revision in
                                await self.onEditTranscriptSegment(session, segmentID, text, revision)
                            },
                            onNameUnknownSegment: { segmentID, name in
                                self.onNameUnknownSegment(session, segmentID, name)
                            },
                            onUndo: { await self.onUndoCorrection(session) },
                            onRenameSession: { title in self.onRenameSession(session, title) },
                            onRetranscribe: { languageCode in self.onRetranscribe(session.id, languageCode) },
                            onAssignSpeakers: { names in await self.onAssignSpeakers(session, names) },
                            onClose: self.onCloseSelection,
                            summaryASRService: self.summaryASRService,
                            isRetranscribing: self.isRetrying,
                            onOpenIntegrations: self.onOpenIntegrations,
                            onSetLocalUserSpeaker: self.onSetLocalUserSpeaker.map { callback in
                                { speakerID in callback(session, speakerID) }
                            }
                        )
                    }
                case let .failed(session, message):
                    MeetingFailureCanvas(
                        session: session,
                        message: self.errorMessage ?? message,
                        isRetrying: self.isRetrying,
                        onRetrySession: self.onRetrySession,
                        onRestartSession: self.onRestartSession,
                        onRevealAudio: self.onRevealAudio,
                        onRecordAgain: self.onRecordAgain,
                        onClose: self.onCloseSelection
                    )
                }
            }
        }
    }
}

struct MeetingPageActionAvailability: Equatable {
    let showsNewMeeting: Bool
    let canStartNewMeeting: Bool
    let canEditSetup: Bool

    init(state: MeetingTranscriptionCanvasState, isSummaryRunning: Bool) {
        switch state {
        case .result, .failed:
            self.showsNewMeeting = true
            self.canEditSetup = true
        case let .setup(isStarting, _):
            self.showsNewMeeting = false
            self.canEditSetup = !isStarting
        case .recording, .stopping, .processing:
            self.showsNewMeeting = false
            self.canEditSetup = false
        }
        self.canStartNewMeeting = self.showsNewMeeting && !isSummaryRunning
    }
}

private struct MeetingTranscriptionHeader: View {
    let state: MeetingTranscriptionCanvasState
    let isMeetingHistoryVisible: Bool
    let isSummaryRunning: Bool
    let onNewMeeting: () -> Void
    let onOpenMeetingSettings: () -> Void
    let onToggleMeetingHistory: () -> Void
    @Environment(\.fluidPageToolbarVisible) private var isPageVisible

    var body: some View {
        let availability = MeetingPageActionAvailability(state: self.state, isSummaryRunning: self.isSummaryRunning)
        FluidGlassControlGroup {
            HStack(spacing: 12) {
                if availability.showsNewMeeting {
                    Button(action: self.onNewMeeting) {
                        Label("Meeting Home", systemImage: "house")
                    }
                    .fluidGlassAction()
                    .disabled(!availability.canStartNewMeeting)
                    .keyboardShortcut("n", modifiers: .command)
                    .help(self.isSummaryRunning ? PichiLocalization.text("Finish or cancel the summary before returning to Meeting Home") : PichiLocalization.text("Return to Meeting Home"))
                    .accessibilityHint("Return to Meeting Home; the current meeting stays saved")
                }
                Spacer(minLength: 8)
                MeetingHeaderIconButton(
                    systemImage: "gearshape",
                    label: AppBrand.text("FluidMeet settings"),
                    action: self.onOpenMeetingSettings
                )
                .disabled(!availability.canEditSetup)
                .accessibilityHint("Change the saved recording application, microphone, and meeting defaults")

                MeetingHeaderIconButton(
                    systemImage: self.isMeetingHistoryVisible
                        ? "rectangle.righthalf.inset.filled"
                        : "sidebar.right",
                    label: self.isMeetingHistoryVisible ? PichiLocalization.text("Hide meeting history") : PichiLocalization.text("Show meeting history"),
                    isSelected: self.isMeetingHistoryVisible,
                    action: self.onToggleMeetingHistory
                )
            }
        }
        .disabled(!self.isPageVisible)
    }
}

private struct MeetingHeaderIconButton: View {
    let systemImage: String
    let label: String
    var isSelected = false
    let action: () -> Void

    @Environment(\.theme) private var theme
    var body: some View {
        Button(action: self.action) {
            Label(self.label, systemImage: self.systemImage)
                .foregroundStyle(self.isSelected ? self.theme.palette.accentText : self.theme.palette.primaryText)
        }
        .labelStyle(.iconOnly)
        .fluidGlassAction(circular: true)
        .help(self.label)
        .accessibilityLabel(self.label)
        .accessibilityAddTraits(self.isSelected ? .isSelected : [])
    }
}

private struct MeetingHistoryInspector: View {
    @ObservedObject var privateState: MeetingViewPrivateProjection
    let sessions: [MeetingSession]
    @Binding var selectedSessionID: MeetingSessionID?
    let errorMessage: String?
    let isLoading: Bool
    let isQuiescent: Bool
    let onRefresh: () -> Void
    let onRetry: (MeetingSessionID) -> Void
    let onRevealAudio: (MeetingSession) -> Void
    let onExportAudio: (MeetingSession) -> Void
    let onExportTranscript: (MeetingSession, MeetingTranscriptExportFormat) -> Void
    let onDeleteAudioRequest: (MeetingSession) -> Void
    let onDeleteRequest: (MeetingSession) -> Void
    let onRename: (MeetingSession, String) -> Void
    let onRecordAgain: (MeetingSession) -> Void
    var onOpenIntegrations: (() -> Void)? = nil


    @Environment(\.theme) private var theme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var filteredSessions: [MeetingSession] {
        let query = self.privateState.searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let visible = self.sessions.filter { !$0.isLocalContentConcealed }
        guard !query.isEmpty else { return visible }
        return visible.filter { session in
            session.displayTitle.localizedCaseInsensitiveContains(query) ||
                session.capturedApplication?.displayName.localizedCaseInsensitiveContains(query) == true ||
                session.readableSpeakers.contains(where: { $0.displayName.localizedCaseInsensitiveContains(query) })
        }
    }

    /// Sessions arrive newest-first, so a first-seen-order bucket walk keeps groups chronological.
    private var groupedSessions: [(key: String, sessions: [MeetingSession])] {
        let calendar = Calendar.current
        var order: [String] = []
        var buckets: [String: [MeetingSession]] = [:]
        for session in self.filteredSessions {
            let key = Self.dayLabel(for: session.startedAt, calendar: calendar)
            if buckets[key] == nil {
                buckets[key] = []
                order.append(key)
            }
            buckets[key]?.append(session)
        }
        return order.map { (key: $0, sessions: buckets[$0] ?? []) }
    }

    private static func dayLabel(for date: Date, calendar: Calendar) -> String {
        if calendar.isDateInToday(date) { return PichiLocalization.text("Today") }
        if calendar.isDateInYesterday(date) { return PichiLocalization.text("Yesterday") }
        return date.formatted(Date.FormatStyle(date: .abbreviated, time: .omitted).locale(PichiLocalization.locale))
    }

    var body: some View {
        let projection = self.privateState.capture()
        VStack(spacing: 0) {
            HStack(spacing: self.theme.metrics.spacing.sm) {
                Text("Meetings")
                    .font(self.theme.typography.bodySmallStrong)
                Text("\(self.sessions.count)")
                    .font(self.theme.typography.badge)
                    .foregroundStyle(self.theme.palette.secondaryText)
                Spacer()
                Button(action: self.onRefresh) {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.borderless)
                .meetingHoverFeedback()
                .help("Refresh meeting history")
                .accessibilityLabel("Refresh meeting history")
            }
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.top, self.theme.metrics.spacing.lg)
            .padding(.bottom, self.theme.metrics.spacing.md)

            HStack(spacing: self.theme.metrics.spacing.sm) {
                Image(systemName: "magnifyingglass").foregroundStyle(self.theme.palette.secondaryText)
                TextField("Search meetings", text: self.$privateState.searchText).textFieldStyle(.plain)
                if !self.privateState.searchText.isEmpty {
                    Button { self.privateState.searchText = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(self.theme.palette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .meetingHoverFeedback()
                    .accessibilityLabel("Clear meeting search")
                }
            }
            .padding(self.theme.metrics.spacing.md)
            .fluidDropdownSurface()
            .padding(.horizontal, self.theme.metrics.spacing.lg)
            .padding(.bottom, self.theme.metrics.spacing.md)

            Divider()

            if let errorMessage, !self.sessions.isEmpty {
                Text(PichiLocalization.text(errorMessage))
                    .font(.fluidSystem(.caption))
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .padding(self.theme.metrics.spacing.md)
            }

            if let errorMessage, self.sessions.isEmpty {
                ContentUnavailableView(
                    "History unavailable",
                    systemImage: "exclamationmark.triangle",
                    description: Text(PichiLocalization.text(errorMessage))
                )
            } else if self.isLoading, self.sessions.isEmpty {
                ProgressView("Loading meetings…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if self.filteredSessions.isEmpty {
                ContentUnavailableView(
                    self.privateState.searchText.isEmpty ? PichiLocalization.text("No meetings yet") : PichiLocalization.text("No matching meetings"),
                    systemImage: self.privateState.searchText.isEmpty ? "person.2.wave.2" : "magnifyingglass",
                    description: Text(self.privateState.searchText.isEmpty
                        ? PichiLocalization.text("Completed meetings will appear here.")
                        : PichiLocalization.text("Try a different title, app, or speaker."))
                )
            } else {
                // Rows draw their own selection/hover fill (never the saturated system blue),
                // so a plain ScrollView replaces List here instead of fighting its native highlight.
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 2) {
                            ForEach(self.groupedSessions, id: \.key) { group in
                                Section {
                                    ForEach(group.sessions) { session in
                                        MeetingHistoryRow(
                                            session: session,
                                            isSelected: self.selectedSessionID == session.id,
                                            isQuiescent: self.isQuiescent,
                                            onSelect: { self.selectedSessionID = session.id },
                                            onRetry: { self.onRetry(session.id) },
                                            onRename: { self.onRename(session, $0) },
                                            onRecordAgain: { self.onRecordAgain(session) }
                                        )
                                        .id(session.id)
                                        .contextMenu { self.contextMenu(for: session) }
                                        .overlay(alignment: .topTrailing) {
                                            Menu { self.contextMenu(for: session) } label: {
                                                Image(systemName: "ellipsis")
                                                    .frame(width: 24, height: 24)
                                                    .contentShape(Rectangle())
                                            }
                                            .menuStyle(.borderlessButton)
                                            .menuIndicator(.hidden)
                                            .fixedSize()
                                            .meetingHoverFeedback()
                                            .accessibilityLabel("Actions for \(session.displayTitle)")
                                            .padding(self.theme.metrics.spacing.sm)
                                        }
                                    }
                                } header: {
                                    // Matches the Command sidebar: unpinned, aligned with the row icons.
                                    Text(group.key)
                                        .font(self.theme.typography.caption)
                                        .foregroundStyle(self.theme.palette.secondaryText)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, self.theme.metrics.spacing.md)
                                        .padding(.top, self.theme.metrics.spacing.lg)
                                        .padding(.bottom, self.theme.metrics.spacing.xs)
                                }
                            }
                        }
                        .padding(.horizontal, self.theme.metrics.spacing.sm)
                        .padding(.bottom, self.theme.metrics.spacing.md)
                    }
                    // Dropping List for a custom highlight also drops its arrow-key traversal.
                    .focusable()
                    .onMoveCommand { direction in
                        guard let moved = self.sessionID(movingFrom: self.selectedSessionID, direction: direction)
                        else { return }
                        self.selectedSessionID = moved
                        withAnimation(self.reduceMotion ? nil : .easeOut(duration: 0.12)) { proxy.scrollTo(moved, anchor: .center) }
                    }
                }
            }
        }
        .frame(maxHeight: .infinity, alignment: .top)
        .background(self.theme.palette.sidebarBackground)
        .alert("Rename Meeting", isPresented: Binding(
            get: { self.privateState.renameSessionID != nil },
            set: { if !$0 { self.privateState.renameSessionID = nil; self.privateState.renameSource = nil } }
        )) {
            TextField("Meeting title", text: self.$privateState.renameDraft)
            Button("Cancel", role: .cancel) { self.privateState.renameSessionID = nil; self.privateState.renameSource = nil }
            Button("Rename") {
                if self.privateState.accepts(projection), self.isQuiescent, let id = self.privateState.renameSessionID,
                   let source = self.privateState.renameSource, source.id == id,
                   self.sessions.contains(where: { $0.id == id })
                {
                    self.onRename(source, self.privateState.renameDraft)
                }
                self.privateState.renameSessionID = nil; self.privateState.renameSource = nil
            }
            .disabled(!self.isQuiescent || self.privateState.renameDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        }
    }

    private func sessionID(
        movingFrom current: MeetingSessionID?,
        direction: MoveCommandDirection
    ) -> MeetingSessionID? {
        MeetingHistoryTraversal.sessionID(
            movingFrom: current,
            direction: direction,
            ordered: self.groupedSessions.flatMap(\.sessions).map(\.id)
        )
    }

    @ViewBuilder
    private func contextMenu(for session: MeetingSession) -> some View {
        let projection = self.privateState.capture()
        Button("Rename…", systemImage: "pencil") {
            guard self.privateState.accepts(projection) else { return }
            self.privateState.renameDraft = session.displayTitle
            self.privateState.renameSessionID = session.id
            self.privateState.renameSource = session
        }
        .disabled(!self.isQuiescent)
        Divider()
        if session.hasRetryableAudio, session.state == .failed || session.state == .interrupted {
            Button("Retry Transcription", systemImage: "arrow.clockwise") {
                self.onRetry(session.id)
            }
            .disabled(!self.isQuiescent)
        }
        Button("Reveal Audio", systemImage: "folder") {
            self.onRevealAudio(session)
        }
        Button("Export Audio…", systemImage: "square.and.arrow.up") {
            self.onExportAudio(session)
        }
        .disabled(!session.hasFinalizedAudio)
        Button("Export Transcript (Text)…", systemImage: "doc.text") {
            self.onExportTranscript(session, .text)
        }
        .disabled(!session.transcriptSegments.contains(where: { !$0.isEcho }))
        Button("Export Transcript (Markdown)…", systemImage: "doc.richtext") {
            self.onExportTranscript(session, .markdown)
        }
        .disabled(!session.transcriptSegments.contains(where: { !$0.isEcho }))
        Button("Export Transcript (JSON)…", systemImage: "curlybraces") {
            self.onExportTranscript(session, .json)
        }
        .disabled(session.transcriptSegments.isEmpty)
        if session.hasFinalizedAudio, session.retention.audioDeletedAt == nil, session.state == .completed {
            Button("Delete Audio (Keep Transcript)…", systemImage: "waveform.slash") {
                self.onDeleteAudioRequest(session)
            }
            .disabled(!self.isQuiescent)
        }
        if let onOpenIntegrations {
            Divider()
            Button("Integrations…", systemImage: "link", action: onOpenIntegrations)
        }
        Divider()
        Button("Delete Meeting…", systemImage: "trash", role: .destructive) {
            self.onDeleteRequest(session)
        }
        .disabled(!self.isQuiescent)
    }
}

nonisolated enum MeetingHistoryTraversal {
    static func sessionID(
        movingFrom current: MeetingSessionID?,
        direction: MoveCommandDirection,
        ordered: [MeetingSessionID]
    ) -> MeetingSessionID? {
        guard !ordered.isEmpty else { return nil }
        guard let current, let index = ordered.firstIndex(of: current) else { return ordered.first }
        switch direction {
        case .up: return index > 0 ? ordered[index - 1] : nil
        case .down: return index < ordered.count - 1 ? ordered[index + 1] : nil
        default: return nil
        }
    }
}

private struct MeetingHistoryRow: View {
    let session: MeetingSession
    let isSelected: Bool
    let isQuiescent: Bool
    let onSelect: () -> Void
    let onRetry: () -> Void
    let onRename: (String) -> Void
    let onRecordAgain: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            Button(action: self.onSelect) {
                HStack(alignment: .top, spacing: self.theme.metrics.spacing.md) {
                    self.tile
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text(self.session.displayTitle)
                            .font(self.theme.typography.bodyStrong)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .padding(.trailing, self.theme.metrics.spacing.xxl)
                        self.secondaryLine
                        if let place = self.session.savedLocationLabel(language: PichiLocalization.language) {
                            Text(verbatim: place)
                                .accessibilityLabel(place)
                                .font(self.theme.typography.caption)
                                .foregroundStyle(self.theme.palette.secondaryText)
                                .lineLimit(2)
                                .help(place)
                                .accessibilityIdentifier("meeting.history.location.\(self.session.id)")
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, self.theme.metrics.spacing.md)
                .padding(.vertical, self.theme.metrics.spacing.md)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel([self.session.displayTitle, self.statusText, self.sourceName,
                self.session.savedLocationLabel(language: PichiLocalization.language)].compactMap { $0 }.joined(separator: ", "))
            .accessibilityAddTraits(self.isSelected ? .isSelected : [])
            .editableTitle(self.session.displayTitle, id: "\(self.session.profileOwnership?.profileID ?? MeetingProfileOwnership.guest.profileID):\(self.session.id)", enabled: self.isQuiescent, onRename: self.onRename)
            if let actionLabel {
                Button(actionLabel, action: self.performAction)
                    .buttonStyle(.borderless)
                    .meetingHoverFeedback()
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.actionColor)
                    .disabled(!self.isQuiescent)
                    .accessibilityLabel(self.actionAccessibilityLabel ?? actionLabel)
                    .padding(.leading, 18 + self.theme.metrics.spacing.md * 2)
                    .padding(.bottom, self.theme.metrics.spacing.sm)
            }
        }
        .background {
            RoundedRectangle(cornerRadius: self.theme.metrics.corners.md, style: .continuous)
                .fill(self.rowBackground)
                .animation(self.reduceMotion ? nil : .easeOut(duration: 0.14), value: self.isHovered && self.isEnabled)
        }
        .contentShape(Rectangle())
        .onHover { self.isHovered = $0 && self.isEnabled }
        .onChange(of: self.isEnabled) { _, enabled in
            if !enabled { self.isHovered = false }
        }
        .onDisappear { self.isHovered = false }
        .accessibilityElement(children: .contain)
    }

    private var tile: some View {
        Image(systemName: self.tileIcon)
            .font(self.theme.typography.bodySmall)
            .foregroundStyle(self.tileIconColor)
            .frame(width: 18, height: 22)
    }

    @ViewBuilder
    private var secondaryLine: some View {
        HStack(spacing: self.theme.metrics.spacing.xs) {
            ForEach(Array(self.secondaryTextParts.enumerated()), id: \.offset) { index, part in
                if index > 0 {
                    Text("·").foregroundStyle(self.theme.palette.tertiaryText)
                }
                Text(part)
            }
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.secondaryText)
        .lineLimit(1)
    }

    private func performAction() {
        switch self.session.state {
        case .interrupted: self.onRetry()
        case .failed: self.onRecordAgain()
        default: break
        }
    }

    private var timeText: String {
        self.session.startedAt.formatted(Date.FormatStyle(date: .omitted, time: .shortened).locale(PichiLocalization.locale))
    }

    private var secondaryTextParts: [String] {
        switch self.session.state {
        case .completed:
            var parts = [self.timeText, Self.durationText(self.session.duration)]
            if !self.session.readableSpeakers.isEmpty {
                parts.append(self.session.readableSpeakers.count == 1 ? PichiLocalization.text("1 speaker") : PichiLocalization.format("%lld speakers", self.session.readableSpeakers.count))
            }
            return parts
        case .interrupted:
            return [self.timeText, PichiLocalization.text("Interrupted")]
        case .failed:
            return [self.timeText, PichiLocalization.text("Failed")]
        case .processing:
            return [self.timeText, PichiLocalization.text("Processing")]
        case .recording, .recordingDegraded, .preparing, .stopping:
            return [self.timeText, PichiLocalization.text("Recording")]
        }
    }

    private var actionLabel: String? {
        switch self.session.state {
        case .interrupted: return self.session.hasRetryableAudio ? PichiLocalization.text("Retry") : nil
        case .failed: return PichiLocalization.text("Record again")
        default: return nil
        }
    }

    /// The row shows "Retry" to fit a narrow sidebar; spoken output keeps the full sentence.
    private var actionAccessibilityLabel: String? {
        switch self.session.state {
        case .interrupted: return self.session.hasRetryableAudio ? PichiLocalization.text("Retry transcription") : nil
        case .failed: return PichiLocalization.text("Record again")
        default: return nil
        }
    }

    private var actionColor: Color {
        self.session.state == .interrupted ? self.theme.palette.warning : self.theme.palette.accentText
    }

    private var rowBackground: Color {
        if self.isSelected { return self.theme.palette.primaryText.opacity(self.isHovered && self.isEnabled ? 0.14 : 0.08) }
        if self.isHovered && self.isEnabled { return self.theme.palette.primaryText.opacity(0.06) }
        return .clear
    }

    private var sourceName: String {
        self.session.capturedApplication?.displayName ?? PichiLocalization.text(self.session.audioSourceDisplayName)
    }

    private var statusText: String {
        switch self.session.state {
        case .completed: PichiLocalization.text("Completed")
        case .failed: PichiLocalization.text("Failed")
        case .interrupted: PichiLocalization.text("Interrupted")
        case .processing: PichiLocalization.text("Processing")
        case .recording, .recordingDegraded, .preparing, .stopping: PichiLocalization.text("Recording")
        }
    }

    private var tileIcon: String {
        switch self.session.state {
        case .interrupted: "exclamationmark.triangle.fill"
        case .failed: "xmark.circle"
        default: "doc.text"
        }
    }

    private var tileIconColor: Color {
        switch self.session.state {
        case .interrupted: self.theme.palette.warning
        case .failed: Color(nsColor: .systemRed)
        default: self.theme.palette.secondaryText
        }
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let totalMinutes = max(0, Int(duration / 60))
        if totalMinutes >= 60 {
            return PichiLocalization.format("%lldh %lldm", totalMinutes / 60, totalMinutes % 60)
        }
        return PichiLocalization.format("%lldm", max(1, totalMinutes))
    }
}

private struct MeetingSetupCanvas: View {
    @Binding var draft: MeetingTranscriptionSetupDraft

    let applications: [MeetingApplicationOption]
    let readiness: MeetingSetupReadiness
    let isStarting: Bool
    let errorMessage: String?
    let recentSession: MeetingSession?
    let onStart: () -> Void
    let onRepairSetup: () -> Void
    let onEditSetup: () -> Void

    @Environment(\.theme) private var theme

    private var systemsReady: Bool {
        !self.readiness.isCheckingSources &&
            self.readiness.microphoneReady &&
            self.readiness.storageReady &&
            self.readiness.activityReady &&
            (self.readiness.meetingAudioReady || (self.needsApplicationSelection && !self.readiness.showScreenRecordingSettingsAction))
    }

    private var needsApplicationSelection: Bool {
        self.draft.mode == .onlineCall && self.draft.applicationAudioScope == .selectedApplication && self.resolvedApplication == nil
    }

    private var canStart: Bool {
        self.systemsReady && self.draft.selectedMicrophoneID != nil &&
            !self.draft.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var resolvedApplication: MeetingApplicationOption? {
        guard self.draft.mode == .onlineCall, self.draft.applicationAudioScope == .selectedApplication else { return nil }
        return self.applications.first(where: { $0.id == self.draft.selectedApplicationID })
    }

    private var blockedHelp: String {
        if let blockingMessage = readiness.blockingMessage { return PichiLocalization.text(blockingMessage) }
        if self.draft.selectedMicrophoneID == nil { return PichiLocalization.text("Choose a microphone in Settings to continue.") }
        return PichiLocalization.text("Check the recording setup.")
    }

    private var planHeadline: String {
        if self.draft.mode == .onlineCall, self.draft.applicationAudioScope == .systemAudio { return PichiLocalization.text("Record audio from all apps.") }
        if let app = resolvedApplication { return PichiLocalization.format("%@ is open.", app.identity.displayName) }
        return PichiLocalization.text(self.draft.mode == .inRoom ? "In-person meeting." : "Choose an app to record.")
    }

    private var planDetail: String {
        if self.draft.mode == .onlineCall, self.draft.applicationAudioScope == .systemAudio { return PichiLocalization.text("System audio and your mic will be recorded, including apps opened during the meeting.") }
        if let app = resolvedApplication { return PichiLocalization.format("%@ and your mic will be recorded.", app.identity.displayName) }
        if self.draft.mode == .inRoom { return PichiLocalization.text("Your mic will record the room.") }
        if self.readiness.showScreenRecordingSettingsAction {
            return PichiLocalization.text("Allow Screen & System Audio access, then refresh sources.")
        }
        return PichiLocalization.text("No call detected. Choose an app, or select In person for mic only.")
    }

    private var sourceLabel: String {
        if self.draft.mode == .onlineCall, self.draft.applicationAudioScope == .systemAudio { return PichiLocalization.text("System audio") }
        if let app = resolvedApplication { return app.identity.displayName }
        if self.draft.mode == .inRoom { return PichiLocalization.text("In person") }
        return PichiLocalization.text(self.draft.usesAutomaticApplication ? "Automatic" : "Source unavailable")
    }

    private var meetingApplications: [MeetingApplicationOption] {
        self.applications.pickerSections.usual
    }

    private var otherApplications: [MeetingApplicationOption] {
        self.applications.pickerSections.others
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                MeetingDocumentTitle(title: PichiLocalization.text("Be in the conversation."))
                Text("Record your meeting. Come back to every word.")
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }

            self.recordingSetup
        }
    }

    private var recordingSetup: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            ThemedCard(style: .standard, padding: self.theme.metrics.spacing.xl) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                    self.plan
                    FluidGlassControlGroup {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: self.theme.metrics.spacing.md) { self.actions }
                            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) { self.actions }
                        }
                    }
                }
            }

            self.recordingFooter
        }
    }

    @ViewBuilder private var plan: some View {
        if self.readiness.isCheckingSources {
            MeetingHomeStatus(kind: .checking, title: PichiLocalization.text("Checking your setup…"), detail: PichiLocalization.text("This only takes a moment."))
        } else if !self.canStart {
            MeetingHomeStatus(kind: .blocked, title: PichiLocalization.text("One thing before recording"), detail: self.blockedHelp)
        } else {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(self.planHeadline)
                    .font(.fluidSystem(.title2, design: .serif).weight(.medium))
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(self.planDetail)
                    .font(self.theme.typography.body)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            .fixedSize(horizontal: false, vertical: true)
            .accessibilityElement(children: .combine)
        }
    }

    @ViewBuilder private var actions: some View {
        self.startAction
        self.sourceMenu
        self.permissionAction
    }

    private var sourceMenu: some View {
        Menu {
            self.sourceEntry(PichiLocalization.text("In person · mic only"), systemImage: "person.2", selected: self.draft.mode == .inRoom) {
                self.draft.mode = .inRoom
                self.persistSourceChoice()
            }
            self.sourceEntry(PichiLocalization.text("System audio · all apps"), systemImage: "speaker.wave.2", selected: self.draft.mode == .onlineCall && self.draft.applicationAudioScope == .systemAudio) {
                self.draft.mode = .onlineCall
                self.draft.chooseSystemAudio()
                self.persistSourceChoice()
            }
            self.sourceEntry(
                PichiLocalization.text("Automatic · follows a detected call"),
                systemImage: "wand.and.stars",
                selected: self.draft.mode == .onlineCall && self.draft.applicationAudioScope == .selectedApplication && self.draft.usesAutomaticApplication
            ) {
                self.draft.mode = .onlineCall
                self.draft.chooseApplication(nil)
                self.persistSourceChoice()
            }
            if !self.meetingApplications.isEmpty {
                Divider()
                ForEach(self.meetingApplications) { option in
                    self.applicationEntry(option)
                }
            }
            if !self.otherApplications.isEmpty {
                Divider()
                Menu("Other audio sources") {
                    ForEach(self.otherApplications) { option in
                        self.applicationEntry(option)
                    }
                }
            }
            if self.readiness.showScreenRecordingSettingsAction {
                Divider()
                Button("Allow meeting audio access…", systemImage: "arrow.up.right", action: self.onRepairSetup)
            }
            Divider()
            Button("More settings…", systemImage: "gearshape", action: self.onEditSetup)
        } label: {
            Text("Change · \(self.sourceLabel)")
        }
        .fluidDropdownStyle()
        .disabled(self.isStarting)
        .help("Choose what gets recorded.")
        .accessibilityLabel("Change recording source. Currently \(self.sourceLabel)")
    }

    private func applicationEntry(_ option: MeetingApplicationOption) -> some View {
        let selected = self.draft.mode == .onlineCall && self.draft.applicationAudioScope == .selectedApplication && !self.draft.usesAutomaticApplication && self.draft.selectedApplicationID == option.id
        return self.sourceEntry(option.identity.displayName, systemImage: "app", selected: selected) {
            self.draft.mode = .onlineCall
            self.draft.chooseApplication(option.identity)
            self.persistSourceChoice()
        }
    }

    private func persistSourceChoice() {
        guard PrivateProfileStorage.acceptsNewWork else { return }
        SettingsStore.shared.meetingRecordingDefaults = self.draft.applyingSource(
            to: SettingsStore.shared.meetingRecordingDefaults,
            application: self.resolvedApplication?.identity
        )
        if self.draft.mode == .onlineCall, self.draft.applicationAudioScope == .selectedApplication,
           !self.draft.usesAutomaticApplication, let application = self.resolvedApplication {
            SettingsStore.shared.meetingRecentApplication = application.identity
        }
    }

    private func sourceEntry(_ title: String, systemImage: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if selected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }

    private var recordingFooter: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            Label(
                self.draft.mode == .onlineCall
                    ? PichiLocalization.text("Stays on this Mac. Use headphones for clearer speaker separation.")
                    : PichiLocalization.text("Stays on this Mac. Place it where everyone can be heard."),
                systemImage: "lock"
            )
            .font(self.theme.typography.caption)
            .foregroundStyle(self.theme.palette.secondaryText)
            .fixedSize(horizontal: false, vertical: true)

            if let errorMessage, !errorMessage.isEmpty {
                Label(PichiLocalization.text(errorMessage), systemImage: "exclamationmark.triangle.fill")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityLabel("Could not start recording. \(errorMessage)")
            }

            if let recentSession {
                Divider()
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Image(systemName: "clock.arrow.circlepath")
                        .foregroundStyle(self.theme.palette.secondaryText)
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                        Text("Last meeting").font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                        Text(recentSession.displayTitle).font(self.theme.typography.bodyStrong).lineLimit(2)
                    }
                    Spacer()
                    Text(Self.durationText(recentSession.duration))
                        .font(self.theme.typography.codeCaption).foregroundStyle(self.theme.palette.secondaryText)
                }
            }
        }
    }

    @ViewBuilder private var permissionAction: some View {
        if !self.readiness.isCheckingSources,
           self.readiness.showScreenRecordingSettingsAction ||
           (!self.canStart && (self.readiness.showMicrophoneSettingsAction ||
                   !self.readiness.microphoneReady || self.draft.selectedMicrophoneID == nil))
        {
            Button(
                self.readiness.showMicrophoneSettingsAction ? PichiLocalization.text("Allow microphone access") :
                    (self.readiness.showScreenRecordingSettingsAction ? PichiLocalization.text("Allow meeting audio access") :
                        PichiLocalization.text("Set up microphone…")),
                systemImage: self.readiness.showMicrophoneSettingsAction || self.readiness.showScreenRecordingSettingsAction ? "arrow.up.right" : "gearshape",
                action: self.onRepairSetup
            )
            .meetingGlassAction(spacious: true)
            .disabled(self.isStarting)
        }
    }

    private var startAction: some View {
        Button(action: self.onStart) {
            Label(self.isStarting ? PichiLocalization.text("Starting…") : PichiLocalization.text(self.needsApplicationSelection ? "Choose app…" : "Start recording"), systemImage: self.isStarting ? "hourglass" : "record.circle")
        }
        .meetingGlassAction(prominent: true, spacious: true)
        .disabled(!self.canStart || self.isStarting)
        .keyboardShortcut(.defaultAction)
    }

    private static func durationText(_ duration: TimeInterval) -> String {
        let total = max(0, Int(duration.rounded(.down)))
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

/// Readiness at a glance: a single dot carries the state, the text explains it.
private struct MeetingHomeStatus: View {
    enum Kind { case checking, blocked }

    let kind: Kind
    let title: String
    let detail: String

    @Environment(\.theme) private var theme

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: self.theme.metrics.spacing.md) {
            Group {
                if self.kind == .checking {
                    ProgressView().controlSize(.mini)
                } else {
                    Circle().fill(self.theme.palette.warning)
                }
            }
            .frame(width: 12, height: 12)
            .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(self.title)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(self.detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.title). \(self.detail)")
    }
}
