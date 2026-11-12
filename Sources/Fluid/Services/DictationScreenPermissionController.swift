import Combine
import CoreGraphics
import Foundation

/// Permission checks are read-only. Only the permission button may prompt.
@MainActor
final class DictationScreenPermissionController: ObservableObject {
    @Published private(set) var isAllowed = false
    @Published private(set) var hasChecked = false
    @Published private(set) var isRequesting = false
    @Published private(set) var requiresSettings = false

    private let check: @Sendable () -> Bool
    private let request: @MainActor () -> Bool
    private let guide: any PermissionDragGuidePresenting
    private var guideRequestID: UUID?
    private var guideSessionID: UUID?
    private var refreshTask: Task<Bool, Never>?
    private var generation: UInt64 = 0
    private var actionGeneration: UInt64 = 0

    init(
        check: @escaping @Sendable () -> Bool = { CGPreflightScreenCaptureAccess() },
        request: @escaping @MainActor () -> Bool = { CGRequestScreenCaptureAccess() },
        guide: (any PermissionDragGuidePresenting)? = nil
    ) {
        self.check = check
        self.request = request
        self.guide = guide ?? PermissionDragGuideController.shared
    }

    func refresh() async {
        let generation: UInt64
        let task: Task<Bool, Never>
        if let pending = self.refreshTask {
            task = pending
            generation = self.generation
        } else {
            self.generation &+= 1
            generation = self.generation
            let check = self.check
            task = Task.detached(priority: .utility) { check() }
            self.refreshTask = task
        }
        let allowed = await task.value
        guard generation == self.generation else { return }
        self.refreshTask = nil
        guard !Task.isCancelled else { return }
        if self.isAllowed, !allowed { self.requiresSettings = true }
        self.isAllowed = allowed
        if allowed {
            self.requiresSettings = false
            self.dismissGuide()
        }
        self.hasChecked = true
    }

    func requestIfNeeded(shouldRequest: @MainActor () -> Bool) async {
        guard !self.isRequesting, shouldRequest() else { return }
        self.isRequesting = true
        defer { self.isRequesting = false }
        let actionGeneration = self.actionGeneration
        await self.refresh()
        guard actionGeneration == self.actionGeneration,
              shouldRequest(), !self.isAllowed, !Task.isCancelled else { return }
        // Only a subsequent explicit action opens Settings. The first action
        // retains the normal macOS permission request, even if it is denied.
        if self.requiresSettings {
            self.presentGuide()
            return
        }
        self.generation &+= 1
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.isAllowed = self.request()
        self.requiresSettings = !self.isAllowed
        self.hasChecked = true
    }

    /// Called when leaving the surface or when its action becomes ineligible.
    func cancel() {
        self.actionGeneration &+= 1
        self.generation &+= 1
        self.refreshTask?.cancel()
        self.refreshTask = nil
        self.dismissGuide()
    }

    private func presentGuide() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        self.dismissGuide()
        let sessionID = UUID()
        self.guideSessionID = sessionID
        self.guideRequestID = self.guide.present(
            instruction: PichiLocalization.format("Drag %@ into the Screen & System Audio Recording list as shown", Bundle.main.fluidAppDisplayName),
            settingsPaneURL: url,
            isGranted: self.check,
            onGranted: { [weak self] in
                guard let self, self.guideSessionID == sessionID else { return }
                self.generation &+= 1
                self.refreshTask?.cancel()
                self.refreshTask = nil
                self.isAllowed = true
                self.requiresSettings = false
                self.hasChecked = true
                self.dismissGuide()
            }
        )
    }

    private func dismissGuide() {
        self.guideSessionID = nil
        if let requestID = self.guideRequestID { self.guide.dismiss(requestID: requestID) }
        self.guideRequestID = nil
    }
}
