import Foundation
import XCTest

@testable import FluidVoice_Debug

final class EditModeRouteTests: XCTestCase {
    private let model = PrivateAIRegisteredModel(
        displayName: "Edit",
        detail: "",
        isEnabled: true,
        parameterCount: "",
        recommendedMemoryGB: nil,
        artifact: PrivateAIModelArtifact(identifier: "edit-model", filename: "edit-model")
    )

    func testCloudProviderKeepsItsRouteWhateverIsInstalled() {
        for installed in [true, false] {
            let route = EditModeRoute.resolve(
                providerID: "openai",
                privateProviderID: "fluid-1",
                editModel: self.model,
                isInstalled: { _ in installed }
            )
            XCTAssertEqual(route, .provider)
        }
    }

    func testBuildWithoutThePrivateProviderAlwaysUsesTheProvider() {
        let route = EditModeRoute.resolve(
            providerID: "fluid-1",
            privateProviderID: nil,
            editModel: nil,
            isInstalled: { _ in false }
        )
        XCTAssertEqual(route, .provider)
    }

    func testLocalProviderRunsOnTheInstalledEditModel() {
        let route = EditModeRoute.resolve(
            providerID: " fluid-1 ",
            privateProviderID: "fluid-1",
            editModel: self.model,
            isInstalled: { _ in true }
        )
        XCTAssertEqual(route, .local(self.model))
    }

    func testLocalProviderAsksForTheDownloadInsteadOfFetchingIt() {
        var checked = 0
        let route = EditModeRoute.resolve(
            providerID: "fluid-1",
            privateProviderID: "fluid-1",
            editModel: self.model,
            isInstalled: { _ in
                checked += 1
                return false
            }
        )
        XCTAssertEqual(route, .modelMissing)
        XCTAssertEqual(checked, 1)
    }

    func testLocalProviderWithTheModelTurnedOffPointsElsewhere() {
        let route = EditModeRoute.resolve(
            providerID: "fluid-1",
            privateProviderID: "fluid-1",
            editModel: nil,
            isInstalled: { _ in true }
        )
        XCTAssertEqual(route, .notOffered)
        XCTAssertEqual(route.failureMessage, PichiLocalization.text("Choose an AI provider to use Edit Mode."))
    }

    func testUnsupportedHardwareDoesNotCheckOrDownloadTheLocalModel() {
        let route = EditModeRoute.resolve(
            providerID: "fluid-1",
            privateProviderID: "fluid-1",
            editModel: self.model,
            supportsLocalModel: false,
            isInstalled: { _ in
                XCTFail("Unsupported hardware must stop before checking model files")
                return true
            }
        )
        XCTAssertEqual(route, .unsupportedHardware)
        XCTAssertEqual(route.failureMessage, PichiLocalization.text("On-device Edit Mode needs Apple Silicon. Choose an AI provider."))
        XCTAssertNotEqual(route.failureMessage, EditModeRoute.modelMissing.failureMessage)
        XCTAssertEqual(EditModeRoute.resolve(
            providerID: "openai",
            privateProviderID: "fluid-1",
            editModel: self.model,
            supportsLocalModel: false,
            isInstalled: { _ in false }
        ), .provider)
    }

    @MainActor
    func testDownloadButtonOnlyLastsForItsOwnFailure() {
        let state = NotchContentState.shared
        defer {
            state.showAIProcessingFailure()
            state.clearAIProcessingFailure()
        }

        state.showAIProcessingFailure(message: "needs model", canRetry: false, downloadAction: {})
        XCTAssertNotNil(state.aiProcessingFailureDownloadAction)

        state.showAIProcessingFailure(message: "other failure", canRetry: false)
        XCTAssertNil(state.aiProcessingFailureDownloadAction)

        state.showAIProcessingFailure(message: "needs model", canRetry: false, downloadAction: {})
        state.clearAIProcessingFailure()
        XCTAssertNil(state.aiProcessingFailureDownloadAction)
    }

    func testOnlyFailuresHaveAMessage() {
        XCTAssertNil(EditModeRoute.provider.failureMessage)
        XCTAssertNil(EditModeRoute.local(self.model).failureMessage)
        XCTAssertNotNil(EditModeRoute.modelMissing.failureMessage)
    }
    @MainActor
    func testLegacyEditLinkIsPinnedOnceWithoutChangingOtherModes() {
        self.withIndependentDefaults { defaults in
            defaults.set(true, forKey: "RewriteModeLinkedToGlobal")
            defaults.set("dictation-provider", forKey: "SelectedProviderID")
            defaults.set("dictation-model", forKey: "SelectedAIModel")
            defaults.set("command-provider", forKey: "CommandModeSelectedProviderID")
            SettingsStore.makeEditModeIndependent(defaults: defaults, providerID: "edit-provider", modelID: "edit-model")
            XCTAssertFalse(defaults.bool(forKey: "RewriteModeLinkedToGlobal"))
            XCTAssertEqual(defaults.string(forKey: "RewriteModeSelectedProviderID"), "edit-provider")
            XCTAssertEqual(defaults.string(forKey: "RewriteModeSelectedModel"), "edit-model")
            XCTAssertEqual(defaults.string(forKey: "SelectedProviderID"), "dictation-provider")
            XCTAssertEqual(defaults.string(forKey: "SelectedAIModel"), "dictation-model")
            XCTAssertEqual(defaults.string(forKey: "CommandModeSelectedProviderID"), "command-provider")

            defaults.set("new-dictation-provider", forKey: "SelectedProviderID")
            SettingsStore.makeEditModeIndependent(defaults: defaults, providerID: "new-dictation-provider", modelID: "new-model")
            XCTAssertEqual(defaults.string(forKey: "RewriteModeSelectedProviderID"), "edit-provider")
            XCTAssertEqual(defaults.string(forKey: "RewriteModeSelectedModel"), "edit-model")
        }
    }

    @MainActor
    func testExplicitIndependentEditChoiceIsNotOverwritten() {
        self.withIndependentDefaults { defaults in
            defaults.set(false, forKey: "RewriteModeLinkedToGlobal")
            defaults.set("chosen-provider", forKey: "RewriteModeSelectedProviderID")
            defaults.set("chosen-model", forKey: "RewriteModeSelectedModel")
            SettingsStore.makeEditModeIndependent(defaults: defaults, providerID: "other", modelID: nil)
            XCTAssertEqual(defaults.string(forKey: "RewriteModeSelectedProviderID"), "chosen-provider")
            XCTAssertEqual(defaults.string(forKey: "RewriteModeSelectedModel"), "chosen-model")
        }
    }

    @MainActor
    func testMissingLegacyRouteBecomesIndependentWithoutAnInventedModel() {
        self.withIndependentDefaults { defaults in
            defaults.set("stale-model", forKey: "RewriteModeSelectedModel")
            SettingsStore.makeEditModeIndependent(defaults: defaults, providerID: "", modelID: nil)
            XCTAssertFalse(defaults.bool(forKey: "RewriteModeLinkedToGlobal"))
            XCTAssertEqual(defaults.string(forKey: "RewriteModeSelectedProviderID"), "")
            XCTAssertNil(defaults.string(forKey: "RewriteModeSelectedModel"))
        }
    }

    @MainActor
    func testEditScreenToggleDoesNotPromptOrChangeDictationContext() async {
        let suite = "EditModeScreenToggleTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: suite) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, initializeDesktop: false)
        settings.editModeReadsScreen = false
        settings.dictationScreenContextEnabled = false
        var requests = 0
        let permission = DictationScreenPermissionController(check: { false }, request: {
            requests += 1
            return true
        })
        let row = EditModeScreenContextSettings(settings: settings, permission: permission)
        row.enabledBinding.wrappedValue = false
        row.enabledBinding.wrappedValue = true
        await permission.refresh()
        XCTAssertTrue(settings.editModeReadsScreen)
        XCTAssertFalse(settings.dictationScreenContextEnabled)
        XCTAssertFalse(permission.isAllowed)
        XCTAssertEqual(requests, 0)
    }

    @MainActor
    func testBoundEditScreenConsentInvalidatesAndJoinsItsReader() async throws {
        try await EditModeConsentChecks.run { XCTAssertTrue($0, $1) }
    }

    @MainActor
    func testEditScreenConsentIsExcludedFromSettingsBackups() throws {
        try self.withIndependentDefaults { defaults in
            let settings = SettingsStore(defaults: defaults, initializeDesktop: false)
            settings.editModeReadsScreen = true
            let oldRevision = settings.editModeScreenContextRevision
            let payload = settings.makeBackupPayload()
            let encoded = try JSONEncoder().encode(payload)
            let values = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
            XCTAssertNil(values["editModeReadsScreen"])
            XCTAssertNil(values["editModeScreenContextRevision"])
            XCTAssertFalse(String(decoding: encoded, as: UTF8.self).contains(oldRevision))
            settings.editModeReadsScreen = false
            let revokedRevision = settings.editModeScreenContextRevision
            settings.restore(from: payload)
            XCTAssertFalse(settings.editModeReadsScreen)
            XCTAssertEqual(settings.editModeScreenContextRevision, revokedRevision)
            XCTAssertNotEqual(settings.editModeScreenContextRevision, oldRevision)
        }
    }

    private func withIndependentDefaults(_ body: (UserDefaults) throws -> Void) rethrows {
        let name = "EditModeRouteTests-\(UUID().uuidString)"
        guard let defaults = UserDefaults(suiteName: name) else {
            XCTFail("Could not create isolated defaults")
            return
        }
        defer { defaults.removePersistentDomain(forName: name) }
        try body(defaults)
    }

}

/// Reused by the bounded real-source probe and native XCTest. No AX/OCR, model,
/// permission prompt, account service or real profile content is accessed.
@MainActor enum EditModeConsentChecks {
    static func run(check: @escaping (Bool, String) -> Void) async throws {
        let originalProfile = PrivateProfileStorage.current
        let testID = UUID().uuidString
        let identity = AccountIdentity(issuer: "https://synthetic.invalid/consent", subject: testID, internalUserID: testID)
        let context = AccountContext(identity: identity, organizationID: "synthetic-org", workspaceID: "A", generation: UUID())
        let a = try PrivateProfileStorage.proposed(context: context, generation: UUID())
        let otherContext = AccountContext(identity: identity, organizationID: "synthetic-org", workspaceID: "B", generation: UUID())
        let b = try PrivateProfileStorage.proposed(context: otherContext, generation: UUID())
        let suiteA = "EditModeConsent-\(testID)-A"
        let suiteB = "EditModeConsent-\(testID)-B"
        let domains = [AppBrand.storageNamespace + ".private-profile." + a.id,
                       AppBrand.storageNamespace + ".private-profile." + b.id, suiteA, suiteB]
        defer {
            PrivateProfileStorage.select(originalProfile)
            for domain in domains { UserDefaults.standard.removePersistentDomain(forName: domain) }
        }
        PrivateProfileStorage.select(a)
        let root = SettingsStore(defaults: PrivateProfileDefaults(), initializeDesktop: false)
        let peer = root.boundToCurrentPrivateProfile()
        let permission = DictationScreenPermissionController(check: { false }, request: {
            check(false, "The feature toggle must never request OS permission")
            return true
        })
        let row = EditModeScreenContextSettings(settings: root, permission: permission)
        check(row.settings !== root && peer !== root, "The actual row and peer retain separate bound stores")
        check(!root.editModeReadsScreen && root.editModeScreenContextRevision.isEmpty, "A new private profile defaults off without an authorization token")
        row.enabledBinding.wrappedValue = true
        let capturedRevision = root.editModeScreenContextRevision
        check(!capturedRevision.isEmpty && peer.editModeScreenContextRevision == capturedRevision,
              "The actual bound row shares consent with the root and peer")
        check(root.editModeReadsScreen && peer.editModeReadsScreen, "Root and peer see the bound row's opt-in")
        row.enabledBinding.wrappedValue = true
        check(root.editModeScreenContextRevision == capturedRevision, "An unchanged toggle does not revoke its own capture")

        let target = TypingService.RecordingTargetContext(id: UUID(), pid: 999_999,
            bundleIdentifier: "synthetic.edit-consent", window: nil, element: nil)
        let reader = EditModeConsentHeldReader()
        var capture: DictationContextCapture?
        let service = RewriteModeService(settings: root, captureWindow: { target in
            let started = DictationContextCapture.start(target: target) { await reader.read() }
            capture = started
            return started
        })
        service.startReadingWindow(target: target)
        await reader.waitUntilStarted()
        let beforeRevocation = Task { @MainActor in await service.windowContextForRewrite() }

        let unrelated = SettingsStore(defaults: UserDefaults(suiteName: suiteB)!, initializeDesktop: false)
        unrelated.editModeReadsScreen = true
        unrelated.editModeReadsScreen = false
        check(!reader.cancellation.isCancelled, "Another defaults suite cannot cancel this private-profile reader")
        row.enabledBinding.wrappedValue = false
        check(reader.cancellation.isCancelled, "The actual bound toggle synchronously cancels its reader without ContentView")
        check(!peer.editModeReadsScreen && peer.editModeScreenContextRevision != capturedRevision,
              "Revocation updates root and bound peer authority")
        row.enabledBinding.wrappedValue = true
        check(root.editModeScreenContextRevision != capturedRevision, "Rapid off/on cannot revive the captured authorization")
        let rejected = await beforeRevocation.value
        check(rejected == nil, "An already-awaiting consumer drops revoked context")

        var joined = false
        let retirement = Task { @MainActor in
            try? await service.prepareForPrivateProfileTransition()
            joined = true
        }
        for _ in 0..<20 { await Task.yield() }
        check(!joined, "Revoked readers remain registered until actual completion")
        let overlapping = DictationContextCapture.start(target: target) { nil }
        check(overlapping == nil, "Revocation keeps replacement admission closed while the reader retires")
        await reader.finish(.init(textBeforeCursor: nil, screenText: ["synthetic late context"]))
        await retirement.value
        let late = await service.windowContextForRewrite()
        check(joined && late == nil, "Joined retirement cannot publish a late pre-revocation result")
        await capture?.cancelAndWait()

        // Separate UserDefaults objects for the same suite share authority too.
        let plainRoot = SettingsStore(defaults: UserDefaults(suiteName: suiteA)!, initializeDesktop: false)
        let plainPeer = SettingsStore(defaults: UserDefaults(suiteName: suiteA)!, initializeDesktop: false)
        plainRoot.editModeReadsScreen = true
        let plainRevision = plainPeer.editModeScreenContextRevision
        let readyTask = Task<DictationTypingContext?, Never> { .init(textBeforeCursor: nil, screenText: ["same-suite context"]) }
        let readyCapture = DictationContextCapture(target: target, task: readyTask)
        let plainService = RewriteModeService(settings: plainRoot, captureWindow: { _ in readyCapture })
        plainService.startReadingWindow(target: target)
        unrelated.editModeReadsScreen = true
        let unaffected = await plainService.windowContextForRewrite()
        check(unaffected?.screenText == ["same-suite context"], "Unrelated suite notifications preserve an eligible read")
        plainPeer.editModeReadsScreen = false
        plainPeer.editModeReadsScreen = true
        check(plainRoot.editModeScreenContextRevision != plainRevision && readyTask.isCancelled,
              "Same-suite peer revocation cancels even a completed reader")
        let stale = await plainService.windowContextForRewrite()
        check(stale == nil, "Completed context is not reused after same-suite off/on")
        try await plainService.prepareForPrivateProfileTransition()
        await readyCapture.cancelAndWait()

        let aRevision = root.editModeScreenContextRevision
        PrivateProfileStorage.select(b)
        check(!root.editModeReadsScreen && root.editModeScreenContextRevision.isEmpty,
              "A different profile cannot inherit consent or the token")
        let bRow = EditModeScreenContextSettings(settings: root, permission: permission)
        bRow.enabledBinding.wrappedValue = true
        let bRevision = root.editModeScreenContextRevision
        check(bRevision != aRevision, "Different profiles have distinct consent authority")
        row.enabledBinding.wrappedValue = true
        row.enabledBinding.wrappedValue = false
        check(root.editModeReadsScreen && root.editModeScreenContextRevision == bRevision,
              "A retired bound row cannot alter the current profile's consent or token")
        let nextB = try PrivateProfileStorage.proposed(context: b.context, generation: UUID())
        PrivateProfileStorage.select(nextB)
        bRow.enabledBinding.wrappedValue = false
        check(root.editModeReadsScreen && root.editModeScreenContextRevision == bRevision,
              "An old generation cannot rotate the new generation's consent")
        PrivateProfileStorage.select(a)
        check(root.editModeReadsScreen && root.editModeScreenContextRevision == aRevision,
              "Returning to a profile preserves only that profile's consent")
    }
}

private final nonisolated class EditModeConsentCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    var isCancelled: Bool { self.lock.withLock { self.cancelled } }
    func cancel() { self.lock.withLock { self.cancelled = true } }
}

private actor EditModeConsentHeldReader {
    nonisolated let cancellation = EditModeConsentCancellation()
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<DictationTypingContext?, Never>?
    func read() async -> DictationTypingContext? {
        await withTaskCancellationHandler {
            self.started = true
            self.startedWaiter?.resume(); self.startedWaiter = nil
            return await withCheckedContinuation { self.result = $0 }
        } onCancel: { self.cancellation.cancel() }
    }
    func waitUntilStarted() async {
        if self.started { return }
        await withCheckedContinuation { self.startedWaiter = $0 }
    }
    func finish(_ value: DictationTypingContext?) { self.result?.resume(returning: value); self.result = nil }
}
