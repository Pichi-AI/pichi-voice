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
            if isBusy { self.cancelScreenPermissionRequest() }
        }
        .onDisappear {
            self.cancelScreenPermissionRequest()
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
                        self.beginScreenPermissionRequest()
                    }
                    .fluidGlassAction()
                    .disabled(self.isBusy || self.permission.isRequesting)
                }

                Text(self.permission.requiresSettings
                    ? PichiLocalization.format("Allow %@ under Screen & System Audio Recording.", self.permissionApplicationName)
                    : PichiLocalization.text("macOS calls this Screen Recording access."))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// System Settings identifies the signed installation, independently of imported appearance.
    private var permissionApplicationName: String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String)
            ?? (Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String)
            ?? ProcessInfo.processInfo.processName
    }

    private var supportedModelsDescription: String {
        let feature = PrivateAIProviderFeature.shared
        let names = PrivateAIIntegrationService.dictationContextModelIDs.compactMap { feature.model(id: $0)?.displayName }
        return PichiLocalization.format("Off by default. Supported models: %@. Everything is processed on your device. Research preview: review your text before sending; context may cause inaccurate changes.", names.joined(separator: ", "))
    }

    private func beginScreenPermissionRequest() {
        guard !self.isBusy, self.permissionRequestTask == nil else { return }
        self.permissionRequestTask = Task {
            defer { self.permissionRequestTask = nil }
            await self.requestScreenAccess()
        }
    }

    /// The permission button's UI-to-service boundary. Refresh/toggles never call it.
    func requestScreenAccess() async {
        guard !self.isBusy else { return }
        await self.permission.requestIfNeeded { !self.isBusy && !Task.isCancelled }
    }

    func cancelScreenPermissionRequest() {
        self.permissionRequestTask?.cancel()
        self.permission.cancel()
    }
}
