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

/// Replaces the entire administrative navigation tree, including its presentations.
/// No transcript, participant, history or export view is constructed in this subtree.
struct MobileKioskRoot: View {
    @ObservedObject var coordinator: MeetingSessionCoordinator
    @ObservedObject var required: MobileRequiredResources
    @ObservedObject var privacyActivation: MobilePrivacyActivation
    @ObservedObject var access: MobileKioskAccess
    @Environment(\.theme) private var theme
    @Environment(\.scenePhase) private var scenePhase
    @State private var isBusy = false
    @State private var showUnlock = false
    @State private var recordingError = false
    @State private var awakeToken: UUID?

    private var status: String {
        if !access.isAvailable {
            return "Kiosk security is unavailable. Access remains locked. Try again after unlocking the device."
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
            GeometryReader { geometry in
                ScrollView {
                    VStack(spacing: theme.metrics.spacing.xxl) {
                        Spacer(minLength: 24)
                        Image(systemName: coordinator.isRecording ? "record.circle.fill" : "mic.circle")
                            .font(theme.typography.displayTitle)
                            .foregroundStyle(coordinator.isRecording ? theme.palette.accent : theme.palette.secondaryText)
                            .accessibilityHidden(true)
                        Text(PichiLocalization.text(status))
                            .font(theme.typography.title).multilineTextAlignment(.center)
                            .accessibilityIdentifier("kiosk.status")
                        if coordinator.isRecording || !coordinator.isQuiescent {
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(MeetingTranscriptExporter.timestampText(coordinator.elapsedTime))
                                    .font(theme.typography.displayTitle).monospacedDigit()
                                    .accessibilityIdentifier("kiosk.timer")
                            }
                        }
                        if coordinator.isRecording {
                            Button { stop() } label: {
                                Label(PichiLocalization.text("Stop Recording"), systemImage: "stop.fill")
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                            }.buttonStyle(.borderedProminent)
                                .disabled(isBusy).accessibilityIdentifier("kiosk.stop")
                        } else if coordinator.isQuiescent && !isBusy {
                            Button { start() } label: {
                                Label(PichiLocalization.text("Start Recording"), systemImage: "record.circle")
                                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                            }.buttonStyle(.borderedProminent)
                                .disabled(!access.isAvailable).accessibilityIdentifier("kiosk.start")
                        } else {
                            ProgressView().accessibilityIdentifier("kiosk.progress")
                        }
                        Spacer(minLength: 24)
                    }
                    .frame(maxWidth: 480).padding(24)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height)
                }
            }
            .background(theme.palette.windowBackground)
            .foregroundStyle(theme.palette.primaryText)
            .navigationTitle(PichiLocalization.text("Kiosk mode"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showUnlock = true } label: {
                        Label(PichiLocalization.text("Administrator"), systemImage: "lock.shield")
                    }.accessibilityIdentifier("kiosk.admin")
                }
            }
        }
        .accessibilityIdentifier("kiosk.root")
        .sheet(isPresented: $showUnlock) { MobileKioskUnlock(access: access) }
        .task { await coordinator.ensureRestored() }
        .onChange(of: coordinator.state) { _, _ in updateAwake() }
        .onChange(of: scenePhase) { _, phase in
            updateAwake()
            if phase != .active { showUnlock = false }
        }
        .onAppear { updateAwake() }
        .onDisappear { releaseAwake() }
    }

    private func start() {
        run {
            // Reset only terminal presentation state. The coordinator preserves prior sessions.
            if case .completed = coordinator.state { try coordinator.resetForNewMeeting() }
            try await MobileMeetingRecordingActions.start(coordinator: coordinator,
                required: required, privacyActivation: privacyActivation)
        }
    }

    private func stop() { run { _ = try await coordinator.stopAndTranscribe() } }

    private func run(_ operation: @escaping @MainActor () async throws -> Void) {
        guard !isBusy else { return }
        isBusy = true
        recordingError = false
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
            awakeToken = nil
            MobilePresentationAwakeRegistry.shared.release(token)
        }
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

    var body: some View {
        Form {
            Section {
                Text(PichiLocalization.text("Configure recording, transcription and storage first. Kiosk mode keeps these settings and shows only recording controls."))
                Text(PichiLocalization.text("To keep audio on this device, enable Save Audio and choose the recording retention period before entering kiosk mode."))
            }
            Section(PichiLocalization.text("Administrator password")) {
                SecureField(PichiLocalization.text(access.hasPassword ? "Current password" : "Password"), text: $password)
                    .textContentType(access.hasPassword ? .password : .newPassword)
                    .accessibilityIdentifier("kiosk.password")
                if !access.hasPassword {
                    SecureField(PichiLocalization.text("Confirm password"), text: $confirmation)
                        .textContentType(.newPassword).accessibilityIdentifier("kiosk.confirmation")
                }
                Text(PichiLocalization.text("Use a password with 6 to 128 characters."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                if let error {
                    Text(error).foregroundStyle(theme.palette.primaryText)
                        .accessibilityIdentifier("kiosk.passwordError")
                }
                Button(PichiLocalization.text("Enable kiosk mode")) {
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
                Text(PichiLocalization.text("The password is required to leave kiosk mode. Kiosk mode stays enabled after restarting the app."))
                Text(PichiLocalization.text("To keep the device in this app, also enable Guided Access in iPad or iPhone settings."))
            }
        }
        .navigationTitle(PichiLocalization.text("Kiosk mode"))
        .accessibilityIdentifier("kiosk.settings")
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

    var body: some View {
        NavigationStack {
            Form {
                SecureField(PichiLocalization.text("Administrator password"), text: $password)
                    .textContentType(.password).accessibilityIdentifier("kiosk.unlockPassword")
                if let error {
                    Text(error).accessibilityIdentifier("kiosk.passwordError")
                }
                Button(PichiLocalization.text("Exit kiosk mode")) {
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
