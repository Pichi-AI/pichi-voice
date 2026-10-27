import SwiftUI
import UIKit

/// Both entry points use the same preparation and immutable configuration operation.
enum MobileMeetingRecordingActions {
    @MainActor static func start(coordinator: MeetingSessionCoordinator,
                                 required: MobileRequiredResources,
                                 privacyActivation: MobilePrivacyActivation,
                                 settings: SettingsStore = .shared) async throws {
        try await required.prepare(modelID: settings.selectedSpeechModel.rawValue)
        try await privacyActivation.waitUntilReadyIfRequested()
        let configuration = try await coordinator.defaultConfiguration(mode: .inRoom,
            title: PichiLocalization.text("In-room meeting"))
        _ = try await coordinator.startRecording(configuration: configuration)
    }
}

/// The operator surface uses the ordinary recording and voice-profile owners while
/// leaving administrative configuration, transcripts, history and exports outside its tree.
struct MobileKioskRoot: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator
    @ObservedObject var required: MobileRequiredResources
    @ObservedObject var privacyActivation: MobilePrivacyActivation
    @ObservedObject var access: MobileKioskAccess
    @StateObject private var voice: MeetingOwnerVoiceEnrollmentModel
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.verticalSizeClass) private var verticalSizeClass
    @State private var isBusy = false
    @State private var showSettings = false
    @State private var showUnlock = false
    @State private var recordingError = false
    @State private var checkedEntry = false
    @State private var showVoiceWelcome = false
    @State private var awakeToken: UUID?

    init(coordinator: MeetingSessionCoordinator, required: MobileRequiredResources,
         privacyActivation: MobilePrivacyActivation, access: MobileKioskAccess,
         audioArbiter: any MeetingAudioActivityArbitrating,
         voiceProfileService: MeetingOwnerVoiceProfileService = .shared) {
        self.coordinator = coordinator; self.required = required
        self.privacyActivation = privacyActivation; self.access = access
        _voice = StateObject(wrappedValue: MeetingOwnerVoiceEnrollmentModel(
            audioArbiter: audioArbiter, service: voiceProfileService))
    }

    private var compactHeight: Bool { verticalSizeClass == .compact }
    private var status: String {
        if !access.isAvailable {
            return "Administrator access is unavailable. Try again after unlocking the device."
        }
        if recordingError { return "Recording could not be completed. Contact your administrator." }
        switch coordinator.state {
        case .recording, .recordingDegraded: return "Recording"
        case .preparing: return "Preparing recording…"
        case .stopping, .processing: return "Finishing recording…"
        case .completed: return "Recording saved"
        case .failed, .interrupted: return "Recording was interrupted. Contact your administrator."
        case .idle: return isBusy ? "Preparing recording…" : "Ready to record"
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if !checkedEntry {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if showVoiceWelcome {
                    voiceWelcome
                } else {
                    recorder
                }
            }
            .background(theme.palette.windowBackground)
            .foregroundStyle(theme.palette.primaryText)
            .navigationTitle(AppBrand.meetingName)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if checkedEntry && !showVoiceWelcome {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button { showSettings = true } label: {
                            Label(PichiLocalization.text("Settings"), systemImage: "gearshape")
                        }.accessibilityIdentifier("kiosk.settings.open")
                    }
                }
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if checkedEntry && !showVoiceWelcome { recordingControls }
            }
        }
        .accessibilityIdentifier("kiosk.root")
        .sheet(isPresented: $showSettings) {
            MobileKioskVoiceSettings(voice: voice, coordinator: coordinator) {
                showSettings = false
            } openAdministrator: {
                showUnlock = true
            }
            .sheet(isPresented: $showUnlock) { MobileKioskUnlock(access: access) }
            .interactiveDismissDisabled(voice.isBusy)
        }
        .task {
            await coordinator.ensureRestored()
            do {
                // Consume before the asynchronous profile read: a relaunch never repeats
                // this entry's offer, even if the user closes the app on this question.
                if try access.claimVoiceWelcome() {
                    await voice.refresh()
                    try Task.checkCancellation()
                    showVoiceWelcome = !voice.hasProfile
                }
                checkedEntry = true
            } catch is CancellationError {
                return
            } catch {
                // The access owner has already failed closed. Only its recovery entry
                // remains reachable, with recording disabled until storage is available.
                checkedEntry = true
            }
        }
        .onChange(of: coordinator.state) { _, _ in updateAwake() }
        .onChange(of: scenePhase) { _, phase in
            updateAwake()
            if phase != .active { showUnlock = false }
            if phase == .background { voice.cancel(); showSettings = false }
        }
        .onAppear { updateAwake() }
        .onDisappear { voice.cancel(); releaseAwake() }
    }

    private var voiceWelcome: some View {
        ScrollView {
            VStack(spacing: theme.metrics.spacing.xxl) {
                Image(systemName: "person.wave.2")
                    .font(theme.typography.titleIcon).foregroundStyle(theme.palette.accentText)
                    .accessibilityHidden(true)
                Text(PichiLocalization.text("Would you like to set up your voice?"))
                    .font(theme.typography.title).multilineTextAlignment(.center)
                Text(PichiLocalization.text("Set up your voice so matching speech is labelled You in future meetings. The voice profile stays on this device."))
                    .font(theme.typography.body).foregroundStyle(theme.palette.secondaryText)
                    .multilineTextAlignment(.center)
                VStack(spacing: theme.metrics.spacing.md) {
                    Button {
                        showVoiceWelcome = false; showSettings = true
                    } label: {
                        Text(PichiLocalization.text("Set up my voice"))
                            .foregroundStyle(theme.palette.accentForeground)
                            .frame(maxWidth: .infinity, minHeight: 48)
                    }.buttonStyle(.borderedProminent)
                        .accessibilityIdentifier("kiosk.voiceWelcome.setup")
                    Button(PichiLocalization.text("Not now")) { showVoiceWelcome = false }
                        .buttonStyle(.bordered).accessibilityIdentifier("kiosk.voiceWelcome.skip")
                }
            }
            .padding(24).frame(maxWidth: 632)
            .frame(maxWidth: .infinity)
            .padding(.top, compactHeight ? 12 : 48)
        }.accessibilityIdentifier("kiosk.voiceWelcome")
    }

    private var recorder: some View {
        GeometryReader { geometry in
            ScrollView {
                VStack(spacing: theme.metrics.spacing.xxl) {
                    HStack {
                        Label(PichiLocalization.text(status),
                              systemImage: coordinator.isRecording ? "record.circle" : "mic")
                            .font(theme.typography.bodyStrong)
                            .foregroundStyle(coordinator.isRecording ? theme.palette.accentText : theme.palette.primaryText)
                            .accessibilityIdentifier("kiosk.status")
                        Spacer(minLength: 12)
                        if coordinator.isRecording || !coordinator.isQuiescent {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(MeetingTranscriptExporter.timestampText(coordinator.elapsedTime))
                                    .font(theme.typography.title).monospacedDigit()
                                    .accessibilityIdentifier("kiosk.timer")
                            }
                        }
                    }
                    Spacer(minLength: compactHeight ? 0 : 24)
                    AudioWaveformBars(color: theme.palette.accent, barCount: 7,
                        barWidth: 12, barSpacing: 10, minHeight: 8,
                        maxHeight: compactHeight ? 64 : 144,
                        level: { CGFloat(coordinator.trackHealth[.microphone]?.level ?? 0) },
                        noiseThreshold: 0.02, isAnimating: coordinator.isRecording,
                        isIdleWaveEnabled: false)
                        .foregroundStyle(theme.palette.accent)
                        .frame(maxWidth: .infinity, minHeight: compactHeight ? 80 : 176)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(PichiLocalization.text("Microphone"))
                        .accessibilityIdentifier("kiosk.waveform")
                    Spacer(minLength: compactHeight ? 0 : 24)
                }
                .padding(compactHeight ? 12 : 24)
                .frame(maxWidth: 1000, minHeight: geometry.size.height)
                .frame(maxWidth: .infinity)
            }
        }
    }

    @ViewBuilder private var recordingControls: some View {
        Group {
            if coordinator.isRecording {
                Button { stop() } label: {
                    Label(PichiLocalization.text("Stop Recording"), systemImage: "stop.fill")
                        .foregroundStyle(theme.palette.accentForeground)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent)
                    .disabled(isBusy).accessibilityIdentifier("kiosk.stop")
            } else if coordinator.isQuiescent && !isBusy {
                Button { start() } label: {
                    Label(PichiLocalization.text("Start Recording"), systemImage: "record.circle")
                        .foregroundStyle(theme.palette.accentForeground)
                        .frame(maxWidth: .infinity, minHeight: 48)
                }.buttonStyle(.borderedProminent)
                    .disabled(!access.isAvailable || voice.isBusy)
                    .accessibilityIdentifier("kiosk.start")
            } else {
                ProgressView().frame(maxWidth: .infinity, minHeight: 48)
                    .accessibilityIdentifier("kiosk.progress")
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(theme.palette.toolbarBackground)
    }

    private func start() {
        guard !voice.isBusy else { return }
        run {
            if case .completed = coordinator.state { try coordinator.resetForNewMeeting() }
            try await MobileMeetingRecordingActions.start(coordinator: coordinator,
                required: required, privacyActivation: privacyActivation)
        }
    }

    private func stop() { run { _ = try await coordinator.stopAndTranscribe() } }
    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true; recordingError = false
        Task { @MainActor in
            defer { isBusy = false }
            do { try await operation() } catch { recordingError = true }
        }
    }
    private func updateAwake() {
        if scenePhase == .active && coordinator.isRecording {
            if awakeToken == nil { awakeToken = MobilePresentationAwakeRegistry.shared.acquire() }
        } else { releaseAwake() }
    }
    private func releaseAwake() {
        if let token = awakeToken {
            awakeToken = nil; MobilePresentationAwakeRegistry.shared.release(token)
        }
    }
}

/// The operator can manage only their own voice. The shared enrollment transaction
/// remains alive in the root while cancellation drains and hands the audio lease back.
private struct MobileKioskVoiceSettings: View {
    @ObservedObject var voice: MeetingOwnerVoiceEnrollmentModel
    @ObservedObject var coordinator: MeetingSessionCoordinator
    let close: () -> Void
    let openAdministrator: () -> Void
    @Environment(\.theme) private var theme

    var body: some View {
        NavigationStack {
            Form {
                Section(PichiLocalization.text("My voice")) {
                    MeetingOwnerVoiceSettingsContent(model: voice, microphone: nil)
                        .disabled(!coordinator.isQuiescent)
                    if !coordinator.isQuiescent {
                        Text(PichiLocalization.text("Finish the current recording or transcription before setting up your voice."))
                            .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                    }
                }
                Section {
                    Button(action: openAdministrator) {
                        Label(PichiLocalization.text("Administrator"), systemImage: "lock.shield")
                    }.disabled(voice.isBusy).accessibilityIdentifier("kiosk.admin")
                }
            }
            .navigationTitle(PichiLocalization.text("Settings"))
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(PichiLocalization.text("Done"), action: close)
                        .disabled(voice.isBusy).accessibilityIdentifier("kiosk.settings.done")
                }
            }
        }.accessibilityIdentifier("kiosk.limitedSettings")
    }
}

struct MobileKioskSettings: View {
    @ObservedObject var access: MobileKioskAccess
    let canEnable: Bool
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var confirmation = ""
    @State private var error: String?
    @FocusState private var focusedField: PasswordField?
    private enum PasswordField: Hashable { case password, confirmation }

    var body: some View {
        Form {
            Section {
                Text(PichiLocalization.text("Configure recording, transcription and storage first. Restricted access keeps these settings and allows only recording and your voice setup."))
                Text(PichiLocalization.text("To keep audio on this device, enable Save Audio and choose the recording retention period before restricting access."))
            }
            Section(PichiLocalization.text("Administrator password")) {
                SecureField(PichiLocalization.text(access.hasPassword ? "Current password" : "Password"), text: $password)
                    .textContentType(access.hasPassword ? .password : .newPassword)
                    .focused($focusedField, equals: .password)
                    .submitLabel(access.hasPassword ? .done : .next)
                    .onSubmit { focusedField = access.hasPassword ? nil : .confirmation }
                    .accessibilityIdentifier("kiosk.password")
                if !access.hasPassword {
                    SecureField(PichiLocalization.text("Confirm password"), text: $confirmation)
                        .textContentType(.newPassword).accessibilityIdentifier("kiosk.confirmation")
                        .focused($focusedField, equals: .confirmation)
                        .submitLabel(.done).onSubmit { focusedField = nil }
                }
                Text(PichiLocalization.text("Use a password with 6 to 128 characters."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                if let error {
                    Text(error).foregroundStyle(theme.palette.primaryText)
                        .accessibilityIdentifier("kiosk.passwordError")
                }
                Button(PichiLocalization.text("Enable restricted mode")) {
                    guard canEnable else { return }
                    Task { @MainActor in
                        do {
                            try await access.enable(password: password, confirmation: confirmation)
                            password = ""; confirmation = ""
                        }
                        catch { self.error = error.localizedDescription }
                    }
                }.disabled(!canEnable || access.isBusy).accessibilityIdentifier("kiosk.enable")
            }.disabled(access.isBusy)
            Section {
                Text(PichiLocalization.text("The password is required to restore full access. Restricted access stays enabled after restarting the app."))
                Text(PichiLocalization.text("To keep the device in this app, also enable Guided Access in iPad or iPhone settings."))
            }
        }
        .navigationTitle(PichiLocalization.text("Restricted mode"))
        .accessibilityIdentifier("kiosk.settings")
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button(PichiLocalization.text("Done")) { focusedField = nil }
                    .accessibilityIdentifier("kiosk.keyboardDone")
            }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { password = ""; confirmation = "" }
        }
    }
}

private struct MobileKioskUnlock: View {
    @ObservedObject var access: MobileKioskAccess
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var password = ""
    @State private var error: String?
    @FocusState private var passwordFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                SecureField(PichiLocalization.text("Administrator password"), text: $password)
                    .textContentType(.password).accessibilityIdentifier("kiosk.unlockPassword")
                    .focused($passwordFocused).submitLabel(.done)
                    .onSubmit { passwordFocused = false }
                if let error {
                    Text(error).accessibilityIdentifier("kiosk.passwordError")
                }
                Button(PichiLocalization.text("Unlock")) {
                    Task { @MainActor in
                        do { try await access.unlock(password: password); dismiss() }
                        catch { self.error = error.localizedDescription }
                        password = ""
                    }
                }.accessibilityIdentifier("kiosk.unlockConfirm")
            }
            .disabled(access.isBusy)
            .navigationTitle(PichiLocalization.text("Administrator"))
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button(PichiLocalization.text("Done")) { passwordFocused = false }
                        .accessibilityIdentifier("kiosk.keyboardDone")
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button(PichiLocalization.text("Cancel")) { dismiss() }
                        .disabled(access.isBusy).accessibilityIdentifier("kiosk.unlockCancel")
                }
            }
        }.interactiveDismissDisabled(access.isBusy)
            .accessibilityIdentifier("kiosk.unlock")
            .onChange(of: scenePhase) { _, phase in
                if phase != .active { password = ""; dismiss() }
            }
    }
}
