import SwiftUI

/// One opt-in for local context. Unsupported models never read it.
struct DictationScreenContextSettings: View {
    @Environment(\.theme) private var theme
    @ObservedObject var settings: SettingsStore
    let isBusy: Bool

    @StateObject private var permission: DictationScreenPermissionController
    @State private var permissionRequestTask: Task<Void, Never>?

    init(settings: SettingsStore, isBusy: Bool, permission: DictationScreenPermissionController? = nil) {
        self.settings = settings
        self.isBusy = isBusy
        self._permission = StateObject(wrappedValue: permission ?? DictationScreenPermissionController())
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FluidManagementRow(
                title: PichiLocalization.text("Use my active screen to improve dictation accuracy"),
                detail: self.supportedModelsDescription
            ) {
                Toggle(PichiLocalization.text("Use my active screen to improve dictation accuracy"), isOn: self.enabledBinding)
                    .toggleStyle(.switch)
                    .labelsHidden()
                    .disabled(self.isBusy)
            }

            self.permissionStatus
        }
        .task { await self.permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.permission.refresh() }
        }
        .onChange(of: self.isBusy) { _, isBusy in
            if isBusy { self.permissionRequestTask?.cancel() }
        }
        .onDisappear {
            self.permissionRequestTask?.cancel()
        }
    }

    /// The feature switch never requests permission or opens System Settings.
    var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.dictationScreenContextEnabled },
            set: { self.settings.dictationScreenContextEnabled = $0 }
        )
    }

    @ViewBuilder private var permissionStatus: some View {
        if !self.permission.hasChecked {
            Text(PichiLocalization.text("Checking screen access…"))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        } else if self.permission.isAllowed {
            Label(PichiLocalization.text("Screen access allowed"), systemImage: "checkmark.circle.fill")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.success)
        } else {
            HStack(spacing: 12) {
                FluidGlassControlGroup {
                    Button(PichiLocalization.text(self.permission.requiresSettings ? "Open System Settings" : "Allow screen access")) {
                        self.requestScreenAccess()
                    }
                    .fluidGlassAction()
                    .disabled(self.isBusy || self.permission.isRequesting)
                }

                Text(self.permission.requiresSettings
                    ? PichiLocalization.format("Allow %@ under Screen & System Audio Recording.", AppBrand.appName)
                    : PichiLocalization.text("macOS calls this Screen Recording access."))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var supportedModelsDescription: String {
        let feature = PrivateAIProviderFeature.shared
        let names = PrivateAIIntegrationService.dictationContextModelIDs.compactMap { feature.model(id: $0)?.displayName }
        return PichiLocalization.format("Supported models: %@. Everything is processed on your device.", names.joined(separator: ", "))
    }

    private func requestScreenAccess() {
        guard !self.isBusy, self.permissionRequestTask == nil else { return }
        if self.permission.requiresSettings {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        self.permissionRequestTask = Task {
            defer { self.permissionRequestTask = nil }
            await self.permission.requestIfNeeded { !Task.isCancelled }
        }
    }
}
