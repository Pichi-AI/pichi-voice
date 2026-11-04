import Combine
import SwiftUI

/// The model on this Mac that Edit Mode runs on. This row is where it downloads:
/// nothing downloads when the shortcut is pressed, and API users never see it.
struct EditModeLocalModelRow: View {
    @Environment(\.theme) private var theme
    @ObservedObject private var controller = EditModeModelController.shared
    @State private var profile = PrivateProfileStorage.current

    var body: some View {
        if let model = self.controller.model {
            HStack(spacing: 24) {
                VStack(alignment: .leading, spacing: 5) {
                    Text("Model")
                        .font(self.theme.typography.bodyStrong)
                        .foregroundStyle(self.theme.palette.primaryText)
                    self.status(for: model)
                }
                Spacer(minLength: 0)
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Text(ModelDisplayName.forID(model.id))
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    self.action(for: model)
                }
                .fixedSize(horizontal: true, vertical: false)
            }
            .task {
                guard PrivateProfileStorage.isReadable(self.profile) else { return }
                await self.controller.refresh()
            }
        }
    }

    @ViewBuilder private func status(for model: PrivateAIRegisteredModel) -> some View {
        if self.controller.downloading {
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                ProgressView(value: self.controller.fraction)
                    .frame(maxWidth: 220)
                Text(PichiLocalization.format("Downloading %@%%", String(Int(self.controller.fraction * 100))))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .monospacedDigit()
            }
        } else if let error = self.controller.error {
            Text(error)
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.warning)
                .fixedSize(horizontal: false, vertical: true)
        } else if self.controller.installed {
            Text("Downloaded · On this Mac")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        } else {
            Text("A one-time download. It stays on this Mac.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func action(for model: PrivateAIRegisteredModel) -> some View {
        if self.controller.downloading {
            Button("Cancel") {
                guard PrivateProfileStorage.isReadable(self.profile) else { return }
                self.controller.cancelDownload()
            }
                .fluidGlassAction()
        } else if self.controller.installed {
            Button("Remove") {
                guard PrivateProfileStorage.isReadable(self.profile) else { return }
                self.controller.remove()
            }
                .fluidGlassAction()
                .disabled(self.controller.removing)
        } else {
            Button(self.downloadTitle(for: model)) {
                guard PrivateProfileStorage.isReadable(self.profile) else { return }
                self.controller.download()
            }
                .fluidGlassAction(prominent: true)
        }
    }

    private func downloadTitle(for model: PrivateAIRegisteredModel) -> String {
        guard let bytes = model.artifact.byteCount else { return PichiLocalization.text("Download") }
        return PichiLocalization.format("Download · %@", ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))
    }
}

/// Edit Mode's opt-in and its optional screenshot fallback have separate controls.
struct EditModeScreenContextSettings: View {
    @ObservedObject var settings: SettingsStore
    @StateObject private var permission: DictationScreenPermissionController
    @State private var permissionRequestTask: Task<Void, Never>?

    init(settings: SettingsStore, permission: DictationScreenPermissionController? = nil) {
        self.settings = settings.boundToCurrentPrivateProfile()
        self._permission = StateObject(wrappedValue: permission ?? DictationScreenPermissionController())
    }

    var body: some View {
        FluidManagementRow(
            title: "Read my screen",
            detail: "Uses app text, with screen capture as a fallback. Everything stays on this Mac."
        ) {
            HStack(spacing: 12) {
                if self.settings.editModeReadsScreen, self.permission.hasChecked, !self.permission.isAllowed {
                    Button(PichiLocalization.text(self.permission.requiresSettings ? "Open System Settings" : "Allow Screen Capture")) {
                        self.requestScreenAccess()
                    }
                    .fluidGlassAction()
                    .disabled(self.permission.isRequesting)
                }
                Toggle("Read my screen", isOn: self.enabledBinding)
                    .labelsHidden()
                    .toggleStyle(.switch)
            }
        }
        .task { await self.permission.refresh() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await self.permission.refresh() }
        }
        .onChange(of: self.settings.editModeReadsScreen) { _, enabled in
            if !enabled { self.permissionRequestTask?.cancel() }
        }
        .onDisappear { self.permissionRequestTask?.cancel() }
    }

    /// Changing the feature preference never prompts or changes dictation's context setting.
    var enabledBinding: Binding<Bool> {
        Binding(
            get: { self.settings.editModeReadsScreen },
            set: { self.settings.editModeReadsScreen = $0 }
        )
    }

    private func requestScreenAccess() {
        guard self.settings.editModeReadsScreen, self.permissionRequestTask == nil else { return }
        if self.permission.requiresSettings {
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        self.permissionRequestTask = Task {
            defer { self.permissionRequestTask = nil }
            await self.permission.requestIfNeeded { self.settings.editModeReadsScreen && !Task.isCancelled }
        }
    }
}

/// The existing cleanup controller activates dictation selections. Edit Mode needs
/// a separate task owner so downloading its model cannot change that selection.
/// Admission and profile cancellation reuse the shared settings/session contracts.
@MainActor
final class EditModeModelController: ObservableObject {
    static let shared = EditModeModelController()

    var model: PrivateAIRegisteredModel? {
        CPUArchitecture.isAppleSilicon ? PrivateAIIntegrationService.editModel : nil
    }
    @Published private(set) var installed = false
    @Published private(set) var downloading = false
    @Published private(set) var removing = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var error: String?
    @Published private var session = PrivateAISettingsSession(
        selectedModelID: PrivateAIIntegrationService.editModel?.id ?? ""
    )
    private var profileOwner = PrivateProfileOperationOwner()
    private var operation: Task<Void, Never>?

    static func joinPrivateProfileTasks() async {
        let controller = self.shared
        controller.operation?.cancel()
        await controller.profileOwner.retireAndJoin()
        await controller.operation?.value
        controller.installed = false
        controller.error = nil
    }

    static func privateProfileDidChange() {
        let controller = self.shared
        controller.profileOwner = PrivateProfileOperationOwner()
        controller.session = PrivateAISettingsSession(selectedModelID: controller.model?.id ?? "")
        controller.installed = false
        controller.error = nil
        controller.fraction = 0
    }

    func refresh() async {
        guard let model, self.profileOwner.isCurrent, !self.session.isBusy else { return }
        let revision = self.session.revision
        do {
            let installed = try await self.profileOwner.perform {
                await Self.installedState(for: model)
            }
            guard self.session.acceptsRead(revision) else { return }
            self.installed = installed
        } catch {
            // A retired profile must never refresh the next profile's status.
        }
    }

    func download() {
        guard let model, model.canDownload, self.profileOwner.isCurrent,
              let token = self.session.begin() else { return }
        self.downloading = true
        self.fraction = 0
        self.error = nil
        let owner = self.profileOwner
        self.operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(token) }
            do {
                self.installed = try await owner.perform {
                    _ = try await PrivateAIIntegrationService.prepareModel(model) { [weak self] progress in
                        guard let expected = progress.totalBytesExpected, expected > 0 else { return }
                        let fraction = min(1, Double(progress.totalBytesWritten) / Double(expected))
                        await self?.receive(fraction: fraction, token: token)
                    }
                    try Task.checkCancellation()
                    return await Self.installedState(for: model)
                }
            } catch {
                if owner.isCurrent, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    func cancelDownload() {
        // Keep the mutation slot occupied until provider cancellation has joined.
        self.operation?.cancel()
    }

    func remove() {
        guard let model, self.profileOwner.isCurrent,
              PrivateAIIntegrationService.canRemoveInstalledModel(model),
              let token = self.session.begin() else { return }
        self.removing = true
        self.error = nil
        let owner = self.profileOwner
        self.operation = Task { [weak self] in
            guard let self else { return }
            defer { self.finish(token) }
            do {
                self.installed = try await owner.perform {
                    try await PrivateAIIntegrationService.shared.unloadAndRemoveInstalledModel(
                        model, reason: "Edit Mode model removed"
                    )
                    return await Self.installedState(for: model)
                }
            } catch {
                if owner.isCurrent, !Task.isCancelled { self.error = error.localizedDescription }
            }
        }
    }

    private static func installedState(for model: PrivateAIRegisteredModel) async -> Bool {
        // Await the probe through cancellation as well, so transition cleanup joins it.
        await Task.detached(priority: .utility) {
            PrivateAIIntegrationService.isModelInstalled(model, useCache: false)
        }.value
    }

    private func receive(fraction: Double, token: UUID) {
        guard self.profileOwner.isCurrent, self.session.operationID == token else { return }
        self.fraction = fraction
    }

    private func finish(_ token: UUID) {
        guard self.session.operationID == token else { return }
        self.session.finish(token)
        self.downloading = false
        self.removing = false
        self.operation = nil
    }
}
