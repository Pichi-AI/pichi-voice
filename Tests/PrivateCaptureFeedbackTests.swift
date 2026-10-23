@main struct PrivateCaptureFeedbackTests {
    @MainActor private static var checks = 0
    @MainActor private static func check(_ condition: Bool, _ label: String) {
        checks += 1
        precondition(condition, label)
    }
    @MainActor private static func drain(_ buffer: DictationAIStreamPreviewBuffer) async throws {
        for _ in 0..<100 {
            if !buffer.isUIUpdateScheduled { return }
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        preconditionFailure("The queued synthetic stream publication did not finish")
    }
    @MainActor static func main() async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let profileA = try PrivateProfileStorage.proposed(context: nil, generation: UUID())
        let identityB = AccountIdentity(issuer: "https://synthetic.invalid", subject: "b", internalUserID: "b")
        let contextB = AccountContext(identity: identityB, organizationID: nil, workspaceID: nil, generation: UUID())
        let profileB = try PrivateProfileStorage.proposed(context: contextB, generation: UUID())

        // Real queued publication and all three real callbacks still work for their admitted owner.
        PrivateProfileStorage.select(profileA)
        let active = ContentFeedbackProbe()
        let valid = active.makeAIProcessingFeedback(lifecycleID: 7)
        await valid.statusTask.value
        check(active.menuBarManager.processing == 1 && active.menuBarManager.flushes == 1,
              "Current-owner delayed status still updates existing processing UI")
        check(NotchOverlayManager.shared.events.last?.text == "Refining", "Current-owner status is visible")
        valid.streamPreview.nextEligibleUIUpdate = 0
        valid.streamPreview.append("valid A preview")
        check(valid.streamPreview.isUIUpdateScheduled, "The actual stream buffer enqueues its MainActor publication")
        try await drain(valid.streamPreview)
        check(NotchOverlayManager.shared.events.last?.text == "valid A preview", "Current-owner queued stream still publishes")
        let warm = active.prepareOverlayForASRStop(shouldHideOverlayOnStop: false, lifecycleID: 7)
        check(!warm.didRequestHide && active.menuBarManager.reservations == 1 && warm.onFinalTranscriptionStarted != nil,
              "Current-owner warm Stop keeps its existing presentation reservation")
        warm.onFinalTranscriptionStarted?()
        check(active.menuBarManager.processing == 2 && active.menuBarManager.flushes == 2,
              "Current-owner final-ASR callback remains usable")
        active.asr.isFinalTranscriptionReady = false
        _ = active.prepareOverlayForASRStop(shouldHideOverlayOnStop: false, lifecycleID: 7)
        check(active.menuBarManager.processing == 3 && NotchOverlayManager.shared.events.last?.text == "Transcribing",
              "Current-owner cold Stop retains immediate processing feedback")
        _ = active.prepareOverlayForASRStop(shouldHideOverlayOnStop: true, lifecycleID: 7)
        check(active.hides == 1, "Current-owner hidden Stop keeps its existing hide request")

        // Do not yield between enqueueing A's preview and replacing the readable profile.
        // Owner retirement has no admitted operations, and its synchronous portion must not
        // let the queued preview drain. The explicit pending check proves this test ordering.
        NotchOverlayManager.shared.events.removeAll()
        let stale = ContentFeedbackProbe()
        let queued = stale.makeAIProcessingFeedback(lifecycleID: 7)
        queued.streamPreview.nextEligibleUIUpdate = 0
        queued.streamPreview.append("SECRET A preview")
        let heldFinal = stale.prepareOverlayForASRStop(shouldHideOverlayOnStop: false, lifecycleID: 7)
        check(queued.streamPreview.isUIUpdateScheduled, "A preview is queued before concealment")
        PrivateProfileStorage.conceal(generation: UUID())
        await stale.privateOutputOperations.retireAndJoin()
        PrivateProfileStorage.select(profileB)
        check(queued.streamPreview.isUIUpdateScheduled && queued.streamPreview.lastPublishedText.isEmpty,
              "A preview is still queued after B becomes readable")
        heldFinal.onFinalTranscriptionStarted?()
        await queued.statusTask.value
        try await drain(queued.streamPreview)
        check(NotchOverlayManager.shared.events.isEmpty, "No old A stream, status or final-ASR callback publishes into B")
        check(stale.menuBarManager.processing == 0 && stale.menuBarManager.flushes == 0,
              "Stale status and final callbacks cannot mutate B's shared processing state")
        let reservationCount = stale.menuBarManager.reservations
        let hideCount = stale.hides
        _ = stale.prepareOverlayForASRStop(shouldHideOverlayOnStop: false, lifecycleID: 7)
        stale.asr.isFinalTranscriptionReady = false
        _ = stale.prepareOverlayForASRStop(shouldHideOverlayOnStop: false, lifecycleID: 7)
        _ = stale.prepareOverlayForASRStop(shouldHideOverlayOnStop: true, lifecycleID: 7)
        check(stale.menuBarManager.reservations == reservationCount && stale.menuBarManager.processing == 0 && stale.hides == hideCount,
              "A queued old-view Stop requests neither immediate nor reserved presentation under B")
        check(stale.asr.isRunning, "Concealment fences presentation without stopping the admitted capture")

        // Concealment alone closes callbacks before participant retirement, and an old
        // same-account source generation cannot gain access when that account returns.
        PrivateProfileStorage.select(profileA)
        let concealed = ContentFeedbackProbe()
        let beforeConceal = concealed.prepareOverlayForASRStop(shouldHideOverlayOnStop: false, lifecycleID: 7)
        PrivateProfileStorage.conceal(generation: UUID())
        beforeConceal.onFinalTranscriptionStarted?()
        check(concealed.menuBarManager.processing == 0, "Closing source readability fences final-ASR before owner retirement")
        let nextA = try PrivateProfileStorage.proposed(context: nil, generation: UUID())
        PrivateProfileStorage.select(nextA)
        beforeConceal.onFinalTranscriptionStarted?()
        check(concealed.menuBarManager.processing == 0, "A new generation cannot revive old presentation callbacks")
        let fresh = ContentFeedbackProbe()
        let freshFeedback = fresh.makeAIProcessingFeedback(lifecycleID: 7)
        await freshFeedback.statusTask.value
        check(fresh.menuBarManager.processing == 1, "A fresh source owner remains usable after retirement")
        check(NotchOverlayManager.shared.events.count == 1 && NotchOverlayManager.shared.events[0].profile == nextA,
              "The only later publication belongs to the new admitted source")
        await active.privateOutputOperations.retireAndJoin()
        await concealed.privateOutputOperations.retireAndJoin()
        await fresh.privateOutputOperations.retireAndJoin()
        try await checkMenuFeedback(profileA: profileA, profileB: profileB)
        try await checkDiscoveryAdmission(profileA: profileA, profileB: profileB)
        print("Private capture feedback: \(checks) actual-buffer and callback checks passed")
    }

    @MainActor private static func drainMenuQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @MainActor private static func checkMenuFeedback(profileA: PrivateProfileSnapshot, profileB: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profileA)
        let manager = MenuBarFeedbackProbe(), asrA = ASRService(), coordinatorA = MeetingSessionCoordinator()
        manager.configure(asrService: asrA)
        manager.configure(meetingCoordinator: coordinatorA)
        await drainMenuQueue()
        NotchOverlayManager.shared.events.removeAll()
        asrA.partialTranscription = "valid menu A preview"
        coordinatorA.activeSession = .init(capturedApplication: .init(displayName: "private A app"), startedAt: Date(timeIntervalSince1970: 100))
        coordinatorA.state = .recording(UUID())
        await drainMenuQueue()
        check(NotchOverlayManager.shared.events.last?.text == "valid menu A preview", "Current-owner menu preview still publishes")
        check(manager.meetingMenuPresentation.sourceName == "private A app" && manager.meetingMenuPresentation.startedAt != nil,
              "Current-owner meeting metadata reaches its menu")

        // Actual Combine receive(on:) queues are still pending while A is concealed and B selected.
        NotchOverlayManager.shared.events.removeAll()
        asrA.partialTranscription = "SECRET queued menu A preview"
        coordinatorA.activeSession = .init(capturedApplication: .init(displayName: "SECRET queued A app"), startedAt: Date(timeIntervalSince1970: 200))
        manager.meetingStartError = "SECRET A setup error"
        manager.isProcessingActive = true; manager.overlayVisible = true
        NotchContentState.shared.text = "SECRET A notch text"
        PrivateProfileStorage.conceal(generation: UUID())
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        check(manager.meetingMenuPresentation.activity == .recording && manager.meetingMenuPresentation.sourceName == nil
              && manager.meetingMenuPresentation.startedAt == nil && manager.meetingMenuPresentation.attentionStatus == nil
              && manager.meetingStartError == nil,
              "Synchronous conceal removes private cached menu payload while preserving generic recording activity")
        check(manager.meetingStatusMenuItem?.title.isEmpty == true && manager.meetingStatusMenuItem?.toolTip == nil,
              "Conceal clears cached private menu item titles and tooltips before any later refresh")
        check(!manager.isProcessingActive && !manager.overlayVisible && NotchContentState.shared.text.isEmpty && manager.pendingCancellations > 0,
              "Menu conceal retires its pending presentation and private notch payload synchronously")
        check(coordinatorA.stops == 0 && manager.stopMeetingRecordingHandler != nil,
              "Conceal does not stop the recorder or discard its Stop route")
        PrivateProfileStorage.select(profileB)
        await drainMenuQueue()
        check(NotchOverlayManager.shared.events.isEmpty && manager.meetingMenuPresentation.sourceName == nil,
              "Queued A menu preview and meeting metadata cannot publish under readable B")
        manager.stopMeetingRecording()
        await drainMenuQueue()
        check(coordinatorA.stops == 1, "The generic concealed recording item still invokes its original coordinator Stop")

        let asrB = ASRService(), coordinatorB = MeetingSessionCoordinator()
        manager.configure(asrService: asrB); manager.configure(meetingCoordinator: coordinatorB)
        coordinatorB.activeSession = .init(capturedApplication: .init(displayName: "B app"), startedAt: Date(timeIntervalSince1970: 300))
        coordinatorB.state = .recording(UUID())
        asrB.partialTranscription = "valid menu B preview"
        await drainMenuQueue()
        check(manager.meetingMenuPresentation.sourceName == "B app" && NotchOverlayManager.shared.events.last?.text == "valid menu B preview",
              "Newly configured B sources retain normal preview and meeting presentation")
        let bEvents = NotchOverlayManager.shared.events.count
        asrA.partialTranscription = "SECRET retired ASR A preview"
        coordinatorA.activeSession = .init(capturedApplication: .init(displayName: "SECRET retired coordinator"), startedAt: Date())
        await drainMenuQueue()
        check(manager.meetingMenuPresentation.sourceName == "B app" && NotchOverlayManager.shared.events.count == bEvents,
              "Retired source objects cannot borrow B's emission-time profile snapshot")

        // Actual start/error completion waits for an operation that ignores cancellation.
        PrivateProfileStorage.select(profileA)
        let starting = MenuBarFeedbackProbe(), gate = MenuStartGate()
        let pendingStart = Task { await starting.startMeetingRecordingInBackground {
            await gate.hold()
            throw MenuStartError.failed("SECRET held A error")
        } }
        await gate.waitUntilEntered()
        check(starting.meetingStartRequested, "Original start owns its duplicate-click guard while awaiting admission")
        PrivateProfileStorage.conceal(generation: UUID())
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        PrivateProfileStorage.select(profileB)
        starting.meetingStartRequested = true
        let bUpdates = starting.menuUpdates, announcements = AccessibilityNotification.announcements.count
        gate.open()
        await pendingStart.value
        check(starting.meetingStartError == nil && starting.meetingStartRequested && starting.menuUpdates == bUpdates
              && AccessibilityNotification.announcements.count == announcements,
              "Late A start error and defer cannot replace B's menu, announcement or request ownership")
        starting.meetingStartRequested = false
        await starting.startMeetingRecordingInBackground { throw MenuStartError.failed("valid B error") }
        check(starting.meetingStartError == "valid B error" && !starting.meetingStartRequested,
              "Current B start failures remain reviewable and release their own request guard")
        check(AccessibilityNotification.announcements.last?.contains("valid B error") == true,
              "Current B start errors retain their accessibility announcement")

        PrivateProfileStorage.select(profileA)
        let queuedStart = MenuBarFeedbackProbe()
        let starts = AppServices.shared.starts
        queuedStart.startMeetingRecording()
        PrivateProfileStorage.conceal(generation: UUID())
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        PrivateProfileStorage.select(profileB)
        await drainMenuQueue()
        check(AppServices.shared.starts == starts, "A queued A menu Start does not admit capture under B")
        queuedStart.startMeetingRecording()
        await drainMenuQueue()
        check(AppServices.shared.starts == starts + 1, "A fresh B menu Start remains usable")
        PrivateProfileStorage.conceal(generation: UUID())
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        await drainMenuQueue()
        check(!queuedStart.canStartMeetingRecording, "A concealed menu cannot admit a new recording")
    }

    @MainActor private static func checkDiscoveryAdmission(profileA: PrivateProfileSnapshot, profileB: PrivateProfileSnapshot) async throws {
        for holdMicrophone in [true, false] {
            PrivateProfileStorage.select(profileA)
            SettingsStore.shared.meetingRecordingDefaults.owner = "A"
            let service = AppServices(), gate = MenuStartGate()
            MeetingCaptureSourceCatalog.microphoneGate = holdMicrophone ? gate : nil
            MeetingCaptureSourceCatalog.applicationGate = holdMicrophone ? nil : gate
            let discovery = Task { try await service.startMeetingRecordingFromMenuBar() }
            await gate.waitUntilEntered()
            PrivateProfileStorage.conceal(generation: UUID())
            PrivateProfileStorage.select(profileB)
            SettingsStore.shared.meetingRecordingDefaults.owner = "B"
            gate.open()
            do { try await discovery.value; check(false, "A held discovery must reject capture admission under B") }
            catch { check(error is CancellationError, "A held discovery rejects changed-profile admission with cancellation") }
            check(service.starts == 0 && service.meetingSessionCoordinator.configurationOwners.isEmpty,
                  "Neither held microphone nor application discovery can start A's settings under B")
            MeetingCaptureSourceCatalog.microphoneGate = nil
            MeetingCaptureSourceCatalog.applicationGate = nil
            try await service.startMeetingRecordingFromMenuBar()
            check(service.starts == 1 && service.meetingSessionCoordinator.configurationOwners == ["B"],
                  "Fresh B discovery still reaches the existing coordinator with B's captured settings")
        }
        PrivateProfileStorage.conceal(generation: UUID())
        let reads = MeetingCaptureSourceCatalog.microphoneReads
        do { try await AppServices().startMeetingRecordingFromMenuBar(); check(false, "Hidden sources cannot begin discovery") }
        catch { check(error is CancellationError && MeetingCaptureSourceCatalog.microphoneReads == reads,
                      "The shared service refuses concealed discovery before reading any capture sources") }
    }
}

@MainActor final class MenuStartGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    func hold() async { entered = true; await withCheckedContinuation { waiter = $0 } }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func open() { waiter?.resume(); waiter = nil }
}
private enum MenuStartError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case let .failed(message): return message } }
}
