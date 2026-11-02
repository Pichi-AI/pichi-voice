import AppKit
import Combine
import CoreGraphics
import SwiftUI

/// A single snapshot keeps the app shown in the confirmation identical to the app recorded.
nonisolated struct MeetingRecordingSourceSnapshot: Sendable {
    var defaults: MeetingRecordingDefaults
    var applications: [MeetingApplicationIdentity]
    var microphones: MeetingMicrophoneCatalogSnapshot
    var selectedApplication: MeetingApplicationIdentity?
    var selectedMicrophoneID: String?
    var sourceMessage: String?
    var recentApplication: MeetingApplicationIdentity?
    var installedApplications: [MeetingInstalledCallApplication] = []
    var hasMeetingAudioAccess = true
    var audioStorageMode: MeetingAudioStorageMode = .retainedFiles
    var speakerLabelsEnabled = true
    var speakerProcessingMode: MeetingSpeakerProcessingMode = .afterRecording
    var piiRedactionEnabled = false
    var profile = PrivateProfileStorage.current

    var microphoneSelectionLabel: String {
        if let selected = self.microphones.identities.first(where: { $0.captureDeviceID == self.selectedMicrophoneID }) {
            return selected.displayName
        }
        return PichiLocalization.text(self.microphones.identities.isEmpty ? "No microphone available" : "Choose a microphone…")
    }

    var availableRecentApplication: MeetingApplicationIdentity? {
        guard let recentApplication else { return nil }
        if let exact = try? MeetingRecordingSourceResolver.resolve(
            mode: .onlineCall, source: MeetingRecordingSource(application: recentApplication), target: nil, applications: self.applications
        ) { return exact }
        guard !recentApplication.bundleIdentifier.isEmpty else { return nil }
        return try? MeetingRecordingSourceResolver.resolve(
            mode: .onlineCall,
            source: .application(bundleIdentifier: recentApplication.bundleIdentifier, processID: nil, displayName: recentApplication.displayName),
            target: nil,
            applications: self.applications
        )
    }

    func applicationLabel(_ application: MeetingApplicationIdentity) -> String {
        let name = application.displayName.isEmpty ? PichiLocalization.format("Audio source (%lld)", Int64(application.processID ?? 0)) : application.displayName
        guard self.recentApplication?.bundleIdentifier == application.bundleIdentifier,
              let recent = self.availableRecentApplication,
              recent.bundleIdentifier == application.bundleIdentifier, recent.processID == application.processID else { return name }
        return PichiLocalization.format("%@ (Recent)", name)
    }

    static func suggestedApplication(
        defaults: MeetingRecordingDefaults,
        target: MeetingAutoDetector.ResolvedTarget?,
        foreground: MeetingApplicationIdentity?,
        applications: [MeetingApplicationIdentity]
    ) -> MeetingApplicationIdentity? {
        guard defaults.mode == .onlineCall, defaults.effectiveApplicationAudioScope == .selectedApplication else { return nil }
        let source = MeetingRecordingSource(defaults: defaults)
        if let application = try? MeetingRecordingSourceResolver.resolve(mode: .onlineCall, source: source, target: target, applications: applications) {
            return application
        }
        // A missing saved choice must stay missing, rather than silently choosing a different app.
        guard source == .automatic, let foreground else { return nil }
        return try? MeetingRecordingSourceResolver.resolve(
            mode: .onlineCall, source: MeetingRecordingSource(application: foreground), target: nil, applications: applications
        )
    }

    func configuration(applications: [MeetingApplicationIdentity], microphones: [MeetingMicrophoneIdentity]) throws -> MeetingCaptureConfiguration {
        guard PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(self.profile) else { throw CancellationError() }
        guard var microphone = microphones.first(where: { $0.captureDeviceID == self.selectedMicrophoneID }) else {
            throw MeetingCaptureError.microphoneUnavailable
        }
        microphone.role = .unknown
        var application: MeetingApplicationIdentity?
        if self.defaults.mode == .onlineCall, self.defaults.effectiveApplicationAudioScope == .selectedApplication {
            guard let selectedApplication = self.selectedApplication else { throw MeetingCaptureError.applicationNotSelected }
            application = try MeetingRecordingSourceResolver.resolve(
                mode: .onlineCall, source: MeetingRecordingSource(application: selectedApplication), target: nil, applications: applications
            )
            application?.windowID = selectedApplication.windowID
        }
        return MeetingCaptureConfiguration(
            mode: self.defaults.mode,
            title: MeetingTranscriptionSetupDraft.defaultTitle(mode: self.defaults.mode, applicationDisplayName: application?.displayName),
            languageCode: self.defaults.languageCode ?? MeetingProcessingConfiguration.defaultLanguageCode,
            platform: application.map { MeetingPlatformProfile(identifier: $0.bundleIdentifier, displayName: $0.displayName) },
            application: application,
            applicationAudioScope: self.defaults.mode == .onlineCall ? self.defaults.effectiveApplicationAudioScope : nil,
            microphone: microphone,
            timestampDefaultTitle: true,
            audioStorageMode: self.audioStorageMode,
            speakerLabelsEnabled: self.speakerLabelsEnabled,
            speakerProcessingMode: self.speakerProcessingMode,
            piiRedactionEnabled: self.piiRedactionEnabled
        )
    }
}

@MainActor
final class MeetingRecordingSourcePromptController: ObservableObject, PrivateProfileTransitionParticipant {
    static let shared = MeetingRecordingSourcePromptController()
    typealias Loader = (MeetingApplicationIdentity?) async throws -> MeetingRecordingSourceSnapshot
    typealias Starter = (MeetingRecordingSourceSnapshot) async throws -> Void

    @Published private(set) var isPresented = false
    @Published private(set) var isLoading = false
    @Published private(set) var isStarting = false
    @Published private(set) var snapshot: MeetingRecordingSourceSnapshot?
    @Published private(set) var errorMessage: String?
    private var generation = UUID()
    private var task: Task<Void, Never>?
    private var ownedTasks: [UUID: Task<Void, Never>] = [:]
    private var profileSubscription: AnyCancellable?
    private var presentationProfile: PrivateProfileSnapshot?
    private var panel: MeetingFloatingCaptionsPanel?
    private var refreshSelection: MeetingRecordingSourceSnapshot?
    private var refreshMicrophoneID: String?
    private let load: Loader
    private let start: Starter
    private let showsPanel: Bool

    init(showsPanel: Bool = true, load: @escaping Loader = MeetingRecordingSourcePromptController.loadSnapshot, start: @escaping Starter = MeetingRecordingSourcePromptController.startSnapshot) {
        self.showsPanel = showsPanel
        self.load = load
        self.start = start
        PrivateProfileService.shared.register(self)
        self.profileSubscription = NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)
            .sink { [weak self] _ in
                MainActor.assumeIsolated { self?.concealPrivatePresentation() }
            }
    }

    private var canPresentCurrentProfile: Bool {
        guard let presentationProfile else { return false }
        return PrivateProfileService.shared.isPrivateDataVisible &&
            PrivateProfileStorage.acceptsNewWork && PrivateProfileStorage.isReadable(presentationProfile)
    }

    private func runTask(_ operation: @escaping @MainActor () async -> Void) {
        let id = UUID()
        let task = Task { @MainActor in
            defer { self.ownedTasks.removeValue(forKey: id) }
            await operation()
        }
        self.ownedTasks[id] = task
        self.task = task
    }

    private func concealPrivatePresentation() {
        // An admitted start retains its recording owner. Conceal and join its caller,
        // while discovery can be cancelled immediately.
        if !self.isStarting { self.task?.cancel() }
        self.dismiss()
        self.panel?.contentView = nil
        self.panel = nil
    }

    func prepareForPrivateProfileTransition() async throws {
        self.concealPrivatePresentation()
        for task in Array(self.ownedTasks.values) { await task.value }
        self.concealPrivatePresentation()
    }

    var canConfirm: Bool {
        guard self.canPresentCurrentProfile, let snapshot, !self.isLoading, !self.isStarting else { return false }
        let sourceReady = snapshot.defaults.mode == .inRoom || (snapshot.hasMeetingAudioAccess &&
            (snapshot.defaults.effectiveApplicationAudioScope == .systemAudio || snapshot.selectedApplication != nil))
        return snapshot.selectedMicrophoneID != nil && sourceReady
    }

    /// Called only after the shortcut/menu has checked that no recording or dictation is active.
    func handleShortcut(foreground: MeetingApplicationIdentity? = nil, restoring selection: MeetingRecordingSourceSnapshot? = nil, microphoneID: String? = nil) {
        guard SettingsStore.shared.fluidMeetEnabled else { self.cancel(); return }
        guard PrivateProfileStorage.acceptsNewWork, PrivateProfileService.shared.isPrivateDataVisible else {
            self.concealPrivatePresentation(); return
        }
        if self.isPresented {
            self.confirm()
            return
        }
        // Read before creating a key panel, so the popup cannot become its own fallback.
        let app = NSWorkspace.shared.frontmostApplication
        let foreground = foreground ?? app.flatMap { app in
            app.bundleIdentifier.map { MeetingApplicationIdentity(bundleIdentifier: $0, processID: app.processIdentifier, displayName: app.localizedName ?? $0) }
        }
        self.generation = UUID()
        self.presentationProfile = PrivateProfileStorage.current
        let generation = self.generation
        self.refreshSelection = selection
        self.refreshMicrophoneID = microphoneID
        self.snapshot = nil
        self.errorMessage = nil
        self.isLoading = true
        self.isPresented = true
        if self.showsPanel, !self.showPanel() {
            self.cancel()
            return
        }
        self.runTask { [weak self] in
            guard let self, self.canPresentCurrentProfile else { return }
            do {
                var snapshot = try await self.load(foreground)
                guard !Task.isCancelled, self.generation == generation, self.canPresentCurrentProfile else { return }
                guard PrivateProfileStorage.isReadable(snapshot.profile) else { return }
                snapshot.defaults.languageCode = snapshot.defaults.languageCode ?? MeetingTranscriptionSetupDraft(settings: .shared).languageCode
                snapshot.recentApplication = SettingsStore.shared.meetingRecentApplication
                if let selection {
                    snapshot.defaults.mode = selection.defaults.mode
                    snapshot.defaults.applicationAudioScope = selection.defaults.applicationAudioScope
                    if let selected = selection.selectedApplication {
                        snapshot.selectedApplication = try? MeetingRecordingSourceResolver.resolve(
                            mode: selection.defaults.mode,
                            source: .application(bundleIdentifier: selected.bundleIdentifier, processID: nil, displayName: selected.displayName),
                            target: nil,
                            applications: snapshot.applications
                        )
                    } else if selection.defaults.mode == .inRoom {
                        snapshot.selectedApplication = nil
                    }
                    // A refresh must not replace a disconnected or absent selection
                    // with the newly discovered default microphone.
                    snapshot.selectedMicrophoneID = snapshot.microphones.identities.contains(where: { $0.captureDeviceID == selection.selectedMicrophoneID })
                        ? selection.selectedMicrophoneID : nil
                }
                if let microphoneID {
                    // A page selection is explicit. If it disappeared, require another
                    // choice instead of replacing it with the system's default input.
                    snapshot.selectedMicrophoneID = snapshot.microphones.identities.contains(where: { $0.captureDeviceID == microphoneID }) ? microphoneID : nil
                }
                guard !Task.isCancelled, self.generation == generation, self.isPresented, self.canPresentCurrentProfile else { return }
                self.refreshSelection = nil
                self.refreshMicrophoneID = nil
                self.snapshot = snapshot
                self.errorMessage = snapshot.sourceMessage
                self.isLoading = false
            } catch {
                guard !Task.isCancelled, self.generation == generation, self.canPresentCurrentProfile else { return }
                self.errorMessage = error.localizedDescription
                self.isLoading = false
            }
        }
    }

    func selectApplication(_ application: MeetingApplicationIdentity?) {
        guard self.canPresentCurrentProfile, !self.isStarting, self.snapshot != nil else { return }
        self.snapshot?.defaults.mode = application == nil ? .inRoom : .onlineCall
        if application != nil { self.snapshot?.defaults.applicationAudioScope = .selectedApplication }
        self.snapshot?.selectedApplication = application
        if let application {
            SettingsStore.shared.meetingRecentApplication = application
            self.snapshot?.recentApplication = application
        }
        self.errorMessage = nil
    }

    func selectSystemAudio() {
        guard self.canPresentCurrentProfile, !self.isStarting, self.snapshot != nil else { return }
        self.snapshot?.defaults.mode = .onlineCall
        self.snapshot?.defaults.applicationAudioScope = .systemAudio
        self.snapshot?.selectedApplication = nil
        self.errorMessage = nil
    }

    func selectMicrophone(_ id: String) {
        guard self.canPresentCurrentProfile, !self.isStarting else { return }
        self.snapshot?.selectedMicrophoneID = id
    }

    func refresh() {
        guard self.canPresentCurrentProfile, !self.isStarting, !self.isLoading else { return }
        let selection = self.snapshot ?? self.refreshSelection
        let microphoneID = self.refreshMicrophoneID
        self.cancel()
        self.handleShortcut(foreground: selection?.selectedApplication, restoring: selection, microphoneID: microphoneID)
    }

    func confirm() {
        guard SettingsStore.shared.fluidMeetEnabled else { self.cancel(); return }
        guard self.canPresentCurrentProfile, self.isPresented, self.canConfirm, let snapshot else { return }
        self.isStarting = true
        self.errorMessage = nil
        let generation = self.generation
        self.runTask { [weak self] in
            guard let self, self.canPresentCurrentProfile else { return }
            do {
                try await self.start(snapshot)
                guard !Task.isCancelled, self.generation == generation, self.canPresentCurrentProfile else { return }
                self.dismiss()
            } catch {
                guard !Task.isCancelled, self.generation == generation, self.canPresentCurrentProfile else { return }
                self.isStarting = false
                self.errorMessage = error.localizedDescription
            }
        }
    }

    func recordingDidStart() {
        // The start task owns its own dismissal. Cancelling it here could interrupt capture.
        if self.isPresented, !self.isStarting { self.cancel() }
    }

    func cancel() {
        self.task?.cancel()
        self.dismiss()
    }

    private func dismiss() {
        self.generation = UUID()
        self.task = nil
        self.presentationProfile = nil
        self.isPresented = false
        self.isLoading = false
        self.isStarting = false
        self.snapshot = nil
        self.refreshSelection = nil
        self.refreshMicrophoneID = nil
        self.panel?.orderOut(nil)
    }

    private static func loadSnapshot(foreground: MeetingApplicationIdentity?) async throws -> MeetingRecordingSourceSnapshot {
        guard PrivateProfileStorage.acceptsNewWork else { throw CancellationError() }
        let profile = PrivateProfileStorage.current
        async let installedApplications = MeetingInstalledCallApplications.snapshot()
        var defaults = SettingsStore.shared.meetingRecordingDefaults
        defaults.languageCode = defaults.languageCode ?? MeetingTranscriptionSetupDraft(settings: .shared).languageCode
        let audioStorageMode: MeetingAudioStorageMode = SettingsStore.shared.meetingSaveAudio ? .retainedFiles : .memoryOnly
        let speakerLabelsEnabled = SettingsStore.shared.meetingSpeakerLabelsEnabled
        let speakerProcessingMode = SettingsStore.shared.meetingSpeakerProcessingMode(for: defaults.mode)
        let piiRedactionEnabled = SettingsStore.shared.meetingPIIRedactionEnabled
        let target = AppServices.shared.meetingAutomaticTarget
        let preferredInputUID = SettingsStore.shared.preferredInputDeviceUID
        let microphones = await MeetingCaptureSourceCatalog.microphoneSnapshot()
        guard PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(profile) else { throw CancellationError() }
        var applications: [MeetingApplicationIdentity] = []
        var sourceMessage: String?
        let hasMeetingAudioAccess = CGPreflightScreenCaptureAccess()
        if hasMeetingAudioAccess {
            do {
                applications = try await MeetingCaptureSourceCatalog.availableApplications()
            } catch {
                sourceMessage = error.localizedDescription
            }
        } else if defaults.mode == .onlineCall {
            sourceMessage = PichiLocalization.text("Allow Screen & System Audio access in System Settings, then refresh sources to choose an app.")
        }
        try Task.checkCancellation()
        let savedMicrophone = defaults.savedMicrophone(in: microphones.identities)
        let selection = MeetingMicrophonePreselection.select(
            identities: microphones.identities,
            savedDeviceID: savedMicrophone?.captureDeviceID,
            savedRole: defaults.microphoneRole,
            systemDefaultUID: microphones.defaultCoreAudioUID,
            preferredInputUID: preferredInputUID,
            systemDefaultCaptureID: nil
        )
        let installed = await installedApplications
        guard PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(profile) else { throw CancellationError() }
        return MeetingRecordingSourceSnapshot(
            defaults: defaults,
            applications: applications,
            microphones: microphones,
            selectedApplication: MeetingRecordingSourceSnapshot.suggestedApplication(
                defaults: defaults, target: target, foreground: foreground, applications: applications
            ),
            selectedMicrophoneID: selection.deviceID,
            sourceMessage: sourceMessage,
            installedApplications: installed,
            hasMeetingAudioAccess: hasMeetingAudioAccess,
            audioStorageMode: audioStorageMode,
            speakerLabelsEnabled: speakerLabelsEnabled,
            speakerProcessingMode: speakerProcessingMode,
            piiRedactionEnabled: piiRedactionEnabled,
            profile: profile
        )
    }

    private static func startSnapshot(_ snapshot: MeetingRecordingSourceSnapshot) async throws {
        guard SettingsStore.shared.fluidMeetEnabled else { throw MeetingCoordinatorError.featureDisabled }
        guard PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(snapshot.profile) else { throw CancellationError() }
        let microphones = await MeetingCaptureSourceCatalog.microphoneSnapshot()
        let applications = try await snapshot.defaults.mode == .onlineCall && snapshot.defaults.effectiveApplicationAudioScope == .selectedApplication
            ? MeetingCaptureSourceCatalog.availableApplications() : []
        try Task.checkCancellation()
        guard PrivateProfileStorage.acceptsNewWork, PrivateProfileStorage.isReadable(snapshot.profile) else { throw CancellationError() }
        let configuration = try snapshot.configuration(applications: applications, microphones: microphones.identities)
        _ = try await AppServices.shared.meetingSessionCoordinator.startRecording(configuration: configuration)
    }

    private func showPanel() -> Bool {
        MeetingDetectionPromptController.shared.dismissForSourceSelection()
        if self.panel == nil {
            let content = AnyView(AdaptiveAppTheme(accent: SettingsStore.shared.accentColor) {
                MeetingRecordingSourcePromptContent(controller: self)
                    .environment(\.locale, PichiLocalization.locale)
            })
            self.panel = MeetingFloatingPanelFactory.make(
                size: NSSize(width: 392, height: 300), resizable: false, content: content, allowsKeyboardFocus: true
            )
        }
        guard let panel = self.panel, let screen = OverlayScreenResolver.screenForCurrentPointer() ?? NSScreen.main else { return false }
        panel.setFrame(MeetingDetectionPromptController.defaultFrame(panelSize: panel.frame.size, visibleFrame: screen.visibleFrame), display: false)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        return true
    }
}

struct MeetingRecordingSourcePromptContent: View {
    @ObservedObject var controller: MeetingRecordingSourcePromptController
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Record this meeting?").font(self.theme.typography.bodyStrong)
            Text("Choose the app and microphone to record.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            if self.controller.isLoading {
                ProgressView("Finding audio sources…").controlSize(.small)
            } else if let snapshot = self.controller.snapshot {
                self.sourceSelector(snapshot)
                self.microphoneSelector(snapshot)
            }
            if let error = self.controller.errorMessage {
                Text(error).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(self.recordingDescription)
                    .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer(minLength: 0)
            FluidGlassControlGroup {
                HStack {
                    Button("Cancel") { self.controller.cancel() }.keyboardShortcut(.cancelAction).fluidGlassAction()
                    Button("Refresh") { self.controller.refresh() }.fluidGlassAction()
                        .disabled(self.controller.isLoading || self.controller.isStarting)
                    Spacer()
                    Button(PichiLocalization.text(self.controller.isStarting ? "Starting…" : "Record")) { self.controller.confirm() }
                        .keyboardShortcut(.defaultAction).fluidGlassAction(prominent: true)
                        .disabled(!self.controller.canConfirm)
                }
            }
            Text("Press the meeting shortcut again or Return to record.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
        }
        .padding(16)
        .frame(width: 392, height: 300, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: 16).fill(self.theme.palette.contentBackground))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(self.theme.palette.separator.opacity(0.55), lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Choose meeting recording sources")
    }

    private var recordingDescription: String {
        guard let snapshot = self.controller.snapshot else { return PichiLocalization.text("Nothing is recording yet.") }
        if snapshot.defaults.mode == .inRoom { return PichiLocalization.text("Only your microphone will be recorded.") }
        if snapshot.defaults.effectiveApplicationAudioScope == .systemAudio {
            return PichiLocalization.text("System audio and your mic will be recorded, including apps opened during the meeting.")
        }
        if snapshot.selectedApplication == nil { return PichiLocalization.text("Choose an app, or In person for mic only.") }
        return PichiLocalization.text("App audio and your microphone will be recorded.")
    }

    private func sourceSelector(_ snapshot: MeetingRecordingSourceSnapshot) -> some View {
        let recent = snapshot.availableRecentApplication
        let sections = MeetingAppRegistry.pickerSections(
            MeetingAppPickerEntry.entries(applications: snapshot.applications, installed: snapshot.installedApplications)
                .filter { $0.application != recent || recent == nil },
            bundleIdentifier: { $0.bundleIdentifier },
            name: { $0.displayName },
            isBackgroundItem: { _ in false }
        )
        return Menu {
            if let recent {
                self.applicationEntry(MeetingApplicationOption(identity: recent), snapshot: snapshot)
                Divider()
            }
            Button("In person · mic only") { self.controller.selectApplication(nil) }
            Button("System audio · all apps") { self.controller.selectSystemAudio() }
            Divider()
            ForEach(sections.usual) { option in
                self.pickerEntry(option, snapshot: snapshot)
            }
            if !sections.others.isEmpty {
                Menu("Other apps") {
                    ForEach(sections.others) { option in
                        self.pickerEntry(option, snapshot: snapshot)
                    }
                }
            }
            Divider()
            Button("Refresh apps") { self.controller.refresh() }
        } label: {
            Text(self.sourceSelectionLabel(snapshot))
                .lineLimit(1).truncationMode(.middle)
        }
        .fluidDropdownStyle(fillsWidth: true)
        .accessibilityLabel("App to record")
        .accessibilityValue(self.sourceSelectionLabel(snapshot))
        .disabled(self.controller.isStarting)
    }

    private func sourceSelectionLabel(_ snapshot: MeetingRecordingSourceSnapshot) -> String {
        if snapshot.defaults.mode == .inRoom { return PichiLocalization.text("In person · mic only") }
        if snapshot.defaults.effectiveApplicationAudioScope == .systemAudio { return PichiLocalization.text("System audio · all apps") }
        return snapshot.selectedApplication.map(snapshot.applicationLabel) ?? PichiLocalization.text("Choose an app…")
    }

    @ViewBuilder
    private func pickerEntry(_ entry: MeetingAppPickerEntry, snapshot: MeetingRecordingSourceSnapshot) -> some View {
        if let application = entry.application {
            self.applicationEntry(MeetingApplicationOption(identity: application), snapshot: snapshot)
        } else {
            Button(entry.unavailableLabel) {}.disabled(true)
        }
    }

    private func applicationEntry(_ option: MeetingApplicationOption, snapshot: MeetingRecordingSourceSnapshot) -> some View {
        let name = snapshot.applicationLabel(option.identity)
        return Button { self.controller.selectApplication(option.identity) } label: {
            if snapshot.selectedApplication?.processID == option.identity.processID {
                Label(name, systemImage: "checkmark")
            } else {
                Text(name)
            }
        }
    }

    private func microphoneSelector(_ snapshot: MeetingRecordingSourceSnapshot) -> some View {
        Menu {
            ForEach(snapshot.microphones.identities, id: \.captureDeviceID) { microphone in
                Button(microphone.displayName) { self.controller.selectMicrophone(microphone.captureDeviceID) }
            }
        } label: {
            Text(snapshot.microphoneSelectionLabel)
                .lineLimit(1).truncationMode(.middle)
        }
        .fluidDropdownStyle(fillsWidth: true)
        .accessibilityLabel("Microphone to record")
        .accessibilityValue(snapshot.microphoneSelectionLabel)
        .disabled(self.controller.isStarting)
    }
}
