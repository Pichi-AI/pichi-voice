import ApplicationServices
import Foundation

/// Exercises actual capture retirement and the actual ContentView attach/cancel methods.
/// Only the external app target, settings and profile composition are synthetic.
@MainActor enum DictationContextProfileChecks {
    static func run(root: URL, check: (Bool, String) -> Void) async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let identity = AccountIdentity(issuer: "https://synthetic.invalid/realm", subject: "A", internalUserID: "123")
        let a = try PrivateProfileStorage.proposed(context: .init(identity: identity, organizationID: "17", workspaceID: "9", generation: UUID()), generation: UUID(), legacyRootDirectory: root)
        let b = try PrivateProfileStorage.proposed(context: .init(identity: .init(issuer: identity.issuer, subject: "B", internalUserID: "124"), organizationID: "17", workspaceID: "9", generation: UUID()), generation: UUID(), legacyRootDirectory: root)
        let target = TypingService.RecordingTargetContext(id: UUID(), pid: 999_999, bundleIdentifier: "synthetic.context", window: nil, element: nil)

        PrivateProfileStorage.select(a)
        let view = ContextProfileViewHarness()
        let reader = HeldContextReader()
        var capture: DictationContextCapture?
        guard let id = view.privateOutputOperations.admit(cancel: { capture?.cancel() }, join: { await capture?.cancelAndWait() }) else {
            check(false, "Current profile admits its context reader")
            return
        }
        capture = DictationContextCapture.start(target: target, read: { await reader.read() })
        guard let capture else { check(false, "Actual capture owns the empty reader slot"); return }
        view.dictationContextCapture = capture
        view.dictationContextOperationID = id
        view.dictationContextProfile = a
        await reader.waitUntilStarted()

        // The actual ContentView cancellation clears UI references immediately but must
        // retain its owner registration until OS-style cooperative cleanup has returned.
        view.cancelDictationContextCapture()
        check(view.dictationContextCapture == nil && view.dictationContextOperationID == nil, "Cancel clears transient view state")
        PrivateProfileStorage.conceal(generation: UUID())
        var joined = false
        let transition = Task { @MainActor in await view.privateOutputOperations.retireAndJoin(); joined = true }
        for _ in 0..<20 { await Task.yield() }
        check(!joined, "Profile transition waits for a canceled context reader after the view discarded it")
        check(!view.privateOutputOperations.isCurrent, "Conceal closes reader publication immediately")
        let overlap = DictationContextCapture.start(target: target) { .init(textBeforeCursor: "must not run", screenText: nil) }
        check(overlap == nil, "Retiring actual reader keeps replacement admission closed")
        await reader.finish(.init(textBeforeCursor: "Late canceled A", screenText: ["Late A line"]))
        await transition.value
        check(joined, "Actual reader cleanup joins before transition completes")
        let canceled = await capture.result(timeout: .seconds(1))
        check(canceled == nil, "Canceled reader cannot return its late private context")

        // Deliberately omit retirement here: exact profile/generation publication guards
        // must still reject a completed A result if the selected profile became B.
        PrivateProfileStorage.select(a)
        let staleView = ContextProfileViewHarness()
        let lateReader = HeldContextReader()
        guard let lateCapture = DictationContextCapture.start(target: target, read: { await lateReader.read() }) else {
            check(false, "Joined cleanup reopens actual reader admission")
            return
        }
        var staleSnapshot: DictationStopSnapshot? = .init(target: target)
        let attach = Task { @MainActor in
            await staleView.attachDictationContext(lateCapture, profile: a, to: &staleSnapshot)
        }
        await lateReader.waitUntilStarted()
        for _ in 0..<10 { await Task.yield() }
        PrivateProfileStorage.select(b)
        await lateReader.finish(.init(textBeforeCursor: "Late A result", screenText: ["A private line"]))
        await attach.value
        check(staleSnapshot?.typingContext == nil, "Actual ContentView attachment rejects an old profile after await")
        check(staleView.benchmarkCount == 0, "Rejected context does not reach later presentation/logging")
        await lateCapture.cancelAndWait()

        // Same logical user/profile but a new generation is a distinct admission too.
        PrivateProfileStorage.select(a)
        let oldGenerationView = ContextProfileViewHarness()
        let sameIdentity = try PrivateProfileStorage.proposed(context: a.context, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(sameIdentity)
        let ready = DictationContextCapture(target: target, task: Task { .init(textBeforeCursor: "Old generation", screenText: nil) })
        var oldSnapshot: DictationStopSnapshot? = .init(target: target)
        await oldGenerationView.attachDictationContext(ready, profile: a, to: &oldSnapshot)
        check(oldSnapshot?.typingContext == nil, "Actual attachment rejects an old generation for the same profile ID")
        await ready.cancelAndWait()

        let freshView = ContextProfileViewHarness()
        let expected = DictationTypingContext(textBeforeCursor: "Current generation", screenText: ["Current line"])
        let fresh = DictationContextCapture(target: target, task: Task { expected })
        var freshSnapshot: DictationStopSnapshot? = .init(target: target)
        await freshView.attachDictationContext(fresh, profile: sameIdentity, to: &freshSnapshot)
        check(freshSnapshot?.typingContext == expected, "Current profile and exact target may attach actual context")
        check(freshView.benchmarkCount == 1, "Accepted context follows the existing completion path")
        await fresh.cancelAndWait()
        await freshView.privateOutputOperations.retireAndJoin()
        await oldGenerationView.privateOutputOperations.retireAndJoin()
        await staleView.privateOutputOperations.retireAndJoin()

        // Edit Mode uses the same reader admission and private operation owner. Clearing
        // transient UI state must not let a canceled OS reader escape transition joining.
        PrivateProfileStorage.select(a)
        let settings = SettingsStore.shared
        let savedEditReadsScreen = settings.editModeReadsScreen
        settings.editModeReadsScreen = true
        defer { settings.editModeReadsScreen = savedEditReadsScreen }
        let editReader = HeldContextReader()
        var editCapture: DictationContextCapture?
        let editService = RewriteContextProfileHarness(captureWindow: { target in
            let capture = DictationContextCapture.start(target: target) { await editReader.read() }
            editCapture = capture
            return capture
        })
        editService.startReadingWindow(target: target)
        await editReader.waitUntilStarted()
        editService.stopReadingWindow()
        PrivateProfileStorage.conceal(generation: UUID())
        var editJoined = false
        let editTransition = Task { @MainActor in
            try? await editService.prepareForPrivateProfileTransition()
            editJoined = true
        }
        for _ in 0..<20 { await Task.yield() }
        check(!editJoined, "Edit transition joins a canceled reader after its UI state was cleared")
        let retiringEditReplacement = DictationContextCapture.start(target: target) { nil }
        check(retiringEditReplacement == nil, "Retiring Edit reader keeps shared screen admission closed")
        await editReader.finish(.init(textBeforeCursor: nil, screenText: nil,
            windowLines: [.init(text: "Late private A window", x: 0, y: 0, width: 100, height: 20)]))
        await editTransition.value
        let retiredEditContext = await editService.windowContextForRewrite()
        check(editJoined && retiredEditContext == nil, "Retired Edit owner drops late private window context")
        await editCapture?.cancelAndWait()

        // A completed Edit read cannot cross profile identity or generation either.
        PrivateProfileStorage.select(a)
        let readyEdit = DictationContextCapture(target: target, task: Task {
            .init(textBeforeCursor: nil, screenText: nil,
                windowLines: [.init(text: "Ready A window", x: 0, y: 0, width: 100, height: 20)])
        })
        let staleEditService = RewriteContextProfileHarness(captureWindow: { _ in readyEdit })
        staleEditService.startReadingWindow(target: target)
        PrivateProfileStorage.select(b)
        let staleEditContext = await staleEditService.windowContextForRewrite()
        check(staleEditContext == nil, "Actual Edit context attachment rejects a different private profile")
        try await staleEditService.prepareForPrivateProfileTransition()
        await readyEdit.cancelAndWait()

        let currentEdit = DictationContextCapture(target: target, task: Task {
            .init(textBeforeCursor: nil, screenText: nil,
                windowLines: [.init(text: "Current B window", x: 0, y: 0, width: 100, height: 20)])
        })
        let freshEditService = RewriteContextProfileHarness(captureWindow: { _ in currentEdit })
        freshEditService.startReadingWindow(target: target)
        let freshEditContext = await freshEditService.windowContextForRewrite()
        check(freshEditContext?.windowLines?.first?.text == "Current B window", "Current Edit owner may attach its own window context")
        try await freshEditService.prepareForPrivateProfileTransition()
        await currentEdit.cancelAndWait()
    }
}

/// Models a cooperative OS operation which does not finish merely on Task.cancel().
private actor HeldContextReader {
    private var started = false
    private var startedWaiter: CheckedContinuation<Void, Never>?
    private var result: CheckedContinuation<DictationTypingContext?, Never>?
    func read() async -> DictationTypingContext? {
        started = true
        startedWaiter?.resume(); startedWaiter = nil
        return await withCheckedContinuation { result = $0 }
    }
    func waitUntilStarted() async {
        if started { return }
        await withCheckedContinuation { startedWaiter = $0 }
    }
    func finish(_ value: DictationTypingContext?) { result?.resume(returning: value); result = nil }
}
