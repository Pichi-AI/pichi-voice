@main struct PrivatePanelConcealmentTests {
    @MainActor static func main() async throws {
        var checks = 0
        func check(_ condition: Bool, _ label: String) {
            checks += 1
            precondition(condition, label)
        }
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID())
        PrivateProfileStorage.select(guest)
        let pill = Probe0(); let captions = Probe1(); let prompt = Probe2(); let nudge = Probe3(); let failure = Probe4()
        nudge.presentationProfile = guest
        check(nudge.canPresentCurrentProfile, "Readable nudge is visible")
        PrivateProfileService.shared.isPrivateDataVisible = false
        check(!nudge.canPresentCurrentProfile, "Hidden profile fences the nudge")
        nudge.attemptReopen()
        check(nudge.reopens == 0, "Hidden profile also rejects nudge admission")
        PrivateProfileService.shared.isPrivateDataVisible = true
        nudge.panel = PanelDouble()
        nudge.isPresented = true
        nudge.presentationProfile = guest
        let ticket = nudge.countdown.begin(sessionID: UUID(), now: 0)
        let countdownGate = PanelStartGate()
        let countdownWorker = Task { @MainActor in await countdownGate.wait() }
        nudge.countdownTask = countdownWorker
        nudge.countdownTasks[ticket.generation] = countdownWorker
        let panels = [pill.panel!, captions.panel!, prompt.panel!, nudge.panel!, failure.panel!]
        prompt.presentationProfile = guest
        check(prompt.canPresentCurrentProfile, "Readable guest prompt is admitted")
        var stateSubscriptionCancelled = false
        captions.stateSubscription = AnyCancellable { stateSubscriptionCancelled = true }
        var captureStopped = false
        let admittedCapture = Task { @MainActor in
            // This double represents the separate common capture owner. Concealment must not cancel it.
            await Task.yield()
            captureStopped = Task.isCancelled
        }
        prompt.startTask = admittedCapture
        PrivateProfileStorage.closeAdmission()
        check(!prompt.canPresentCurrentProfile, "Closing admission immediately fences prompt actions")
        PrivateProfileStorage.conceal(generation: UUID())
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        for panel in panels {
            check(!panel.isVisible, "Every independent panel is hidden before synchronous notification returns")
            check(panel.contentView == nil, "Every independent panel detaches old private pixels")
        }
        check(pill.panel == nil && captions.panel == nil && prompt.panel == nil && nudge.panel == nil && failure.panel == nil,
              "Concealed controllers cannot retain their old panel")
        check(stateSubscriptionCancelled && captions.stateSubscription == nil, "Caption subscriber is retired for fresh binding")
        check(prompt.request == nil && prompt.pendingSuppressedRequest == nil && prompt.presentationProfile == nil,
              "Prompt drops old detection and account context")
        check(prompt.appDisplayName.isEmpty && prompt.appIcon == nil && prompt.startErrorMessage == nil,
              "Prompt clears private presentation metadata")
        check(!nudge.isPresented && failure.hostingView == nil, "Nudge flag and transcript hosting view are cleared")
        check(nudge.countdown.ticket == nil && countdownWorker.isCancelled && nudge.presentationProfile == nil,
              "Conceal cancels the current countdown and retires its ticket and profile")
        var joined = false
        let transition = Task { @MainActor in
            try await nudge.prepareForPrivateProfileTransition()
            joined = true
        }
        await Task.yield()
        check(!joined, "Transition waits for a cancelled countdown that has not finished")
        countdownGate.open()
        try await transition.value
        check(joined, "Transition joins the original countdown worker")
        pill.attemptReopen(); captions.attemptReopen(); prompt.attemptReopen(); nudge.attemptReopen(); failure.attemptReopen()
        check([pill.reopens, captions.reopens, prompt.reopens, nudge.reopens, failure.reopens].allSatisfy { $0 == 0 },
              "Timer or coordinator reentry cannot reopen any concealed panel")
        await admittedCapture.value
        check(!captureStopped && prompt.startTask != nil, "Conceal does not cancel the admitted capture/start task")
        let context = AccountContext(identity: .init(issuer: "https://issuer.invalid", subject: "synthetic-b", internalUserID: "b"),
                                     organizationID: "org", workspaceID: "workspace", generation: UUID())
        let account = try PrivateProfileStorage.proposed(context: context, generation: UUID())
        PrivateProfileStorage.select(account)
        prompt.presentationProfile = guest
        check(!prompt.canPresentCurrentProfile, "A held guest prompt cannot publish into account B")
        nudge.presentationProfile = guest
        check(!nudge.canPresentCurrentProfile, "A held guest nudge cannot publish into account B")
        prompt.presentationProfile = account
        check(prompt.canPresentCurrentProfile, "A newly admitted account prompt works")
        let nextGeneration = try PrivateProfileStorage.proposed(context: context, generation: UUID())
        PrivateProfileStorage.select(nextGeneration)
        check(!prompt.canPresentCurrentProfile, "Same account with a new source generation rejects stale callbacks")
        PrivateProfileStorage.select(guest)
        for reopen in [pill.attemptReopen, captions.attemptReopen, prompt.attemptReopen, nudge.attemptReopen, failure.attemptReopen] {
            reopen()
        }
        check([pill.reopens, captions.reopens, prompt.reopens, nudge.reopens, failure.reopens].allSatisfy { $0 == 1 },
              "Fresh readable source admission is usable after concealment")
        prompt.startTask = nil
        // Run the real startTapped task around an await whose callee deliberately ignores cancellation.
        prompt.presentationProfile = guest; prompt.request = PromptRequest(); prompt.isStarting = false
        let gate = PanelStartGate()
        var startCalls = 0
        prompt.onStart = { _ in startCalls += 1; await gate.wait(); throw PanelStartFailure.failed }
        prompt.startTapped()
        while startCalls == 0 { await Task.yield() }
        let heldStart = prompt.startTask!
        PrivateProfileStorage.conceal(generation: UUID())
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        check(!heldStart.isCancelled, "Conceal leaves an already admitted start alone")
        PrivateProfileStorage.select(account)
        prompt.presentationProfile = account; prompt.request = PromptRequest(); prompt.isStarting = true
        let nextEpisode = prompt.request!.episodeID
        gate.open()
        await heldStart.value
        check(prompt.request?.episodeID == nextEpisode && prompt.isStarting && prompt.startErrorMessage == nil,
              "A held old-profile start failure cannot change B's prompt")
        prompt.isStarting = false
        prompt.startTapped()
        let queuedStart = prompt.startTask!
        PrivateProfileStorage.conceal(generation: UUID())
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        await queuedStart.value
        check(startCalls == 1, "A queued start does not invoke capture admission after conceal")
        prompt.startTask = nil
        print("Private panel concealment: \(checks) actual-method synthetic checks passed")
    }
}

@MainActor private final class PanelStartGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
private enum PanelStartFailure: Error { case failed }
