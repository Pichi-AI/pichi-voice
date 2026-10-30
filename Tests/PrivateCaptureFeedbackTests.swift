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
        let profileA = try PrivateProfileStorage.proposed(context: nil, generation: UUID(),
            legacyRootDirectory: URL(fileURLWithPath: ProcessInfo.processInfo.environment["PICHI_FEEDBACK_PROFILE_ROOT"]!))
        let identityB = AccountIdentity(issuer: "https://synthetic.invalid", subject: "b", internalUserID: "b")
        let contextB = AccountContext(identity: identityB, organizationID: nil, workspaceID: nil, generation: UUID())
        let profileB = try PrivateProfileStorage.proposed(context: contextB, generation: UUID(), legacyRootDirectory: profileA.legacyRootDirectory)

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
        try await checkPasteVerification(profileA: profileA, profileB: profileB)
        try await checkJoinedDiscovery(profileA: profileA, profileB: profileB)
        try await checkJoinedPasteVerification(profileA: profileA, profileB: profileB)
        try await checkRealPasteReadbackCancellation()
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
        coordinatorA.activeSession = .init(capturedApplication: .init(displayName: "encrypted guest app"),
            startedAt: Date(), requiresEncryptedPersistence: true, profileOwnership: .guest)
        await drainMenuQueue()
        check(manager.meetingMenuPresentation.sourceName == "encrypted guest app",
              "Encrypted device-guest captures retain readable local source metadata")
        coordinatorA.activeSession = .init(capturedApplication: .init(displayName: "SECRET protected account app"),
            startedAt: Date(), requiresEncryptedPersistence: true)
        await drainMenuQueue()
        check(manager.meetingMenuPresentation.sourceName == nil,
              "A concealed account-protected source cannot expose its app name through the menu")

        // Actual Combine receive(on:) queues are still pending while A is concealed and B selected.
        NotchOverlayManager.shared.events.removeAll()
        asrA.partialTranscription = "SECRET queued menu A preview"
        coordinatorA.activeSession = .init(capturedApplication: .init(displayName: "SECRET queued A app"), startedAt: Date(timeIntervalSince1970: 200))
        manager.meetingStartError = "SECRET A setup error"
        manager.isProcessingActive = true; manager.overlayVisible = true
        let trainingExpiry = Task<Void, Never> { await Task.yield() }
        manager.dictionaryWordTrainingExpiry = trainingExpiry
        manager.pendingDictionaryWordTrainingRequest = UUID()
        manager.dictionaryWordTrainingRequestID = UUID()
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
        check(trainingExpiry.isCancelled && manager.dictionaryWordTrainingExpiry == nil
              && manager.pendingDictionaryWordTrainingRequest == nil && manager.dictionaryWordTrainingRequestID == nil,
              "Menu conceal cancels the dictionary expiry and clears its owner-bound pending handoff")
        check(coordinatorA.stops == 0 && manager.stopMeetingRecordingHandler != nil,
              "Conceal does not stop the recorder or discard its Stop route")
        PrivateProfileStorage.select(profileB)
        await drainMenuQueue()
        check(NotchOverlayManager.shared.events.isEmpty && manager.meetingMenuPresentation.sourceName == nil,
              "Queued A menu preview and meeting metadata cannot publish under readable B")
        await trainingExpiry.value
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
        while queuedStart.meetingStartRequested { await Task.yield() }
        check(AppServices.shared.starts == starts, "A queued A menu Start does not admit capture under B")
        let freshCapture = MenuStartGate()
        AppServices.shared.meetingSessionCoordinator.captureGate = freshCapture
        queuedStart.startMeetingRecording()
        await freshCapture.waitUntilEntered()
        check(AppServices.shared.starts == starts + 1, "A fresh B menu Start remains usable")
        freshCapture.open()
        while queuedStart.meetingStartRequested { await Task.yield() }
        AppServices.shared.meetingSessionCoordinator.captureGate = nil
        PrivateProfileStorage.conceal(generation: UUID())
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        await drainMenuQueue()
        check(!queuedStart.canStartMeetingRecording, "A concealed menu cannot admit a new recording")
    }

    @MainActor private static func checkDiscoveryAdmission(profileA: PrivateProfileSnapshot, profileB: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profileA)
        SettingsStore.shared.fluidMeetEnabled = false
        let disabled = AppServices()
        let disabledReads = MeetingCaptureSourceCatalog.microphoneReads
        do { try await disabled.startMeetingRecordingFromMenuBar(); check(false, "Disabled FluidMeet cannot begin discovery") }
        catch {
            check(error is MeetingCoordinatorError && disabled.starts == 0
                  && MeetingCaptureSourceCatalog.microphoneReads == disabledReads,
                  "Disabled feature rejects before reading capture sources")
        }
        var disabledOperationCalled = false
        await MenuBarFeedbackProbe().startMeetingRecordingInBackground { disabledOperationCalled = true }
        check(!disabledOperationCalled, "Disabled menu does not invoke its recording operation")
        SettingsStore.shared.fluidMeetEnabled = true
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

    @MainActor private static func checkPasteVerification(profileA: PrivateProfileSnapshot, profileB: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profileA)
        let manager = MenuBarFeedbackProbe(), typing = TypingService()
        var notifications: [Notification] = []
        let observer = NotificationCenter.default.publisher(for: .fluidPasteNotLanded).sink { notifications.append($0) }
        defer { observer.cancel() }
        let gate = PasteVerificationGate()
        PasteVerifier.gate = gate
        let before = PasteVerifier.Snapshot(pid: 123, summary: "SECRET A verifier metadata")
        let logs = DebugLogger.shared.information.count
        let held = typing.verifyPasteLanded("SECRET A held paste", before: before, profile: profileA, isOutputValid: { true })!
        await gate.waitUntilEntered()
        PrivateProfileStorage.conceal(generation: UUID())
        PrivateProfileStorage.select(profileB)
        await gate.open()
        await held.value
        await drainMenuQueue()
        check(notifications.isEmpty && DebugLogger.shared.information.count == logs,
              "A held paste verifier posts and logs no private A feedback after B becomes readable")
        check(DeliveryFailureOverlayController.shared.cards.isEmpty, "Held A verification cannot present a failure card under B")

        // A has already posted its local notification, but the real menu handler's Task is queued.
        PrivateProfileStorage.select(profileA)
        NotificationCenter.default.post(name: .fluidPasteNotLanded, object: nil,
            userInfo: ["transcript": "SECRET A queued notification", "privateProfile": profileA])
        check(notifications.count == 1, "The original A notification is delivered synchronously before its queued menu action")
        PrivateProfileStorage.conceal(generation: UUID())
        PrivateProfileStorage.select(profileB)
        await drainMenuQueue()
        check(DeliveryFailureOverlayController.shared.cards.isEmpty, "A queued paste notification cannot present private A text under B")
        manager.showPasteNotLandedFailure(transcript: "SECRET A direct stale card", profile: profileA)
        check(DeliveryFailureOverlayController.shared.cards.isEmpty, "The concrete failure presentation also refuses a stale original profile")

        PasteVerifier.gate = nil
        let valid = typing.verifyPasteLanded("valid B paste", before: before, profile: profileB, isOutputValid: { true })!
        await valid.value
        await drainMenuQueue()
        check(notifications.last?.userInfo?["privateProfile"] as? PrivateProfileSnapshot == profileB,
              "Successful verifier feedback carries its exact original profile snapshot locally")
        check(DeliveryFailureOverlayController.shared.cards.count == 1
              && DeliveryFailureOverlayController.shared.cards[0].profile == profileB
              && DeliveryFailureOverlayController.shared.cards[0].text == "valid B paste",
              "Current B verification preserves the existing failure card behavior")
        let suppressed = typing.verifyPasteLanded("dismissed B output", before: before, profile: profileB, isOutputValid: { false })
        check(suppressed == nil, "The original caller's output-validity callback can suppress verification admission")
    }

    @MainActor private static func checkJoinedDiscovery(profileA: PrivateProfileSnapshot, profileB: PrivateProfileSnapshot) async throws {
        let state = DiscoveryTransitionState()
        let profiles = PrivateProfileService.shared
        try profiles.configure(isBusy: { state.busy }, prepare: {}, activate: { _ in })
        for holdMicrophone in [true, false] {
            PrivateProfileStorage.select(profileA)
            SettingsStore.shared.meetingRecordingDefaults.owner = "A"
            let service = AppServices(), gate = MenuStartGate()
            MeetingCaptureSourceCatalog.microphoneGate = holdMicrophone ? gate : nil
            MeetingCaptureSourceCatalog.applicationGate = holdMicrophone ? nil : gate
            let discovery = Task { try await service.startMeetingRecordingFromMenuBar() }
            await gate.waitUntilEntered()
            state.finished = false
            let transition = Task {
                defer { state.finished = true }
                try await profiles.transition(from: nil, to: profileB.context, generation: profileB.generation)
            }
            while !profiles.isTransitioning && !state.finished { await Task.yield() }
            for _ in 0..<20 { await Task.yield() }
            check(!state.finished && profiles.isTransitioning && !PrivateProfileStorage.current.isReadable
                  && PrivateProfileStorage.current.generation == profileA.generation && service.starts == 0,
                  "Actual profile transition joins held discovery before committing B or admitting capture")
            gate.open()
            do { try await discovery.value; check(false, "Retired discovery cannot produce a capture configuration") }
            catch { check(error is CancellationError && gate.wasCancelled,
                          "Actual discovery owner cancellation joins a catalog operation that ignored cancellation") }
            try await transition.value
            check(state.finished && PrivateProfileStorage.current.context == profileB.context && service.starts == 0,
                  "B activates only after original discovery cancellation joins without coordinator capture")
            MeetingCaptureSourceCatalog.microphoneGate = nil; MeetingCaptureSourceCatalog.applicationGate = nil
        }
        SettingsStore.shared.meetingRecordingDefaults.owner = "B"
        let admitted = AppServices(), captureGate = MenuStartGate()
        admitted.meetingSessionCoordinator.captureGate = captureGate
        let capture = Task { try await admitted.startMeetingRecordingFromMenuBar() }
        await captureGate.waitUntilEntered()
        state.busy = true
        do { try await profiles.transition(from: profileB.context, to: nil, generation: UUID()); check(false, "Admitted capture requires busy logout") }
        catch { check(error as? AccountError == .busy, "Busy logout preserves the coordinator's existing capture admission") }
        check(!capture.isCancelled && admitted.starts == 1 && admitted.meetingSessionCoordinator.stops == 0
              && !PrivateProfileStorage.current.isReadable,
              "Joined discovery ownership does not cancel or stop the subsequently admitted capture on logout")
        captureGate.open()
        try await capture.value
        check(!captureGate.wasCancelled && !admitted.meetingSessionCoordinator.captureWasCancelled,
              "Coordinator capture runs outside the retired discovery owner and finishes under its original admission")
        state.busy = false
        try await profiles.transition(from: nil, to: nil, generation: UUID())
    }

    @MainActor private static func checkJoinedPasteVerification(profileA: PrivateProfileSnapshot, profileB: PrivateProfileSnapshot) async throws {
        let profiles = PrivateProfileService.shared, typing = TypingService()
        PrivateProfileStorage.select(profileA)
        var notifications: [Notification] = []
        let observer = NotificationCenter.default.publisher(for: .fluidPasteNotLanded).sink { notifications.append($0) }
        defer { observer.cancel(); PasteVerifier.gate = nil }
        let before = PasteVerifier.Snapshot(pid: 123, summary: "synthetic original A")
        let logs = DebugLogger.shared.information.count
        let gate = PasteVerificationGate()
        PasteVerifier.gate = gate
        let verifier = typing.verifyPasteLanded("SECRET A held reader", before: before, profile: profileA, isOutputValid: { true })!
        await gate.waitUntilEntered()
        let state = DiscoveryTransitionState()
        let transition = Task {
            defer { state.finished = true }
            try await profiles.transition(from: nil, to: profileB.context, generation: profileB.generation)
        }
        while !profiles.isTransitioning && !state.finished { await Task.yield() }
        for _ in 0..<20 { await Task.yield() }
        check(!state.finished && profiles.isTransitioning && !PrivateProfileStorage.current.isReadable
              && PrivateProfileStorage.current.generation == profileA.generation,
              "B cannot commit while A's actual detached verifier worker is held")
        await gate.open()
        await verifier.value
        try await transition.value
        let cancelled = await gate.wasCancelled
        let focusReads = await gate.focusReads
        check(cancelled, "Profile retirement forwards cancellation to the detached reader that ignored it while held")
        check(state.finished && PrivateProfileStorage.current.context == profileB.context,
              "B commits after the cancelled verifier worker has actually joined")
        check(focusReads.isEmpty, "A's cancelled verifier performs no later focus read under B")
        check(notifications.isEmpty && DebugLogger.shared.information.count == logs,
              "A's joined verifier publishes neither private feedback nor logs")

        // There is no MainActor yield between admission and transition. The registered
        // owner must close even when the outer Task has not created its worker yet.
        PrivateProfileStorage.select(profileA)
        let queuedGate = PasteVerificationGate()
        PasteVerifier.gate = queuedGate
        let queued = typing.verifyPasteLanded("SECRET A queued reader", before: before, profile: profileA, isOutputValid: { true })!
        try await profiles.transition(from: nil, to: profileB.context, generation: UUID())
        await queued.value
        let queuedEntered = await queuedGate.hasEntered
        let queuedReads = await queuedGate.focusReads
        check(!queuedEntered && queuedReads.isEmpty, "A queued verifier retired before execution never launches its reader")
        check(notifications.isEmpty && DebugLogger.shared.information.count == logs,
              "The queued retired A verifier cannot publish into B")

        PrivateProfileStorage.select(profileA)
        PasteVerifier.gate = nil
        let valid = typing.verifyPasteLanded("valid A paste", before: before, profile: profileA, isOutputValid: { true })!
        await valid.value
        check(notifications.last?.userInfo?["privateProfile"] as? PrivateProfileSnapshot == profileA
              && notifications.last?.userInfo?["transcript"] as? String == "valid A paste",
              "Fresh A verification retains its normal failure feedback and original profile")
    }

    @MainActor private static func checkRealPasteReadbackCancellation() async throws {
        let element = NSObject()
        let before = ActualPasteVerifierProbe.Snapshot(element: element, pid: 123, role: "synthetic",
            value: "before", characterCount: 6, caret: CFRange(location: 6, length: 0))
        let readback = PasteReadbackDouble.shared
        for completedReads in 0...2 {
            readback.reset([before, before, before])
            let worker = Task.detached { await ActualPasteVerifierProbe.verify(before: before, pastedText: "new") }
            if completedReads == 0 {
                try await Task.sleep(nanoseconds: 20_000_000)
            } else {
                while readback.readCount < completedReads { await Task.yield() }
            }
            worker.cancel()
            let verdict = await worker.value
            check(verdict == .unknown(reason: "cancelled"), "Real verifier returns a silent cancelled verdict during delay \(completedReads + 1)")
            check(readback.readCount == completedReads, "Real verifier performs no AX read after cancellation during delay \(completedReads + 1)")
        }
        readback.reset([.init(element: element, pid: 123, role: "synthetic", value: "before new",
                              characterCount: 10, caret: CFRange(location: 10, length: 0))])
        let confirmed = await Task.detached { await ActualPasteVerifierProbe.verify(before: before, pastedText: "new") }.value
        check(confirmed == .confirmed(method: "value") && readback.readCount == 1,
              "Actual verifier retains successful current-owner value confirmation")
        readback.reset([before, before, before])
        let unchanged = await Task.detached { await ActualPasteVerifierProbe.verify(before: before, pastedText: "new") }.value
        check(unchanged == .notLanded(reason: "value_count_caret_unchanged") && readback.readCount == 3,
              "Actual verifier still requires all three unchanged reads for failure feedback")
    }
}

@MainActor final class MenuStartGate {
    private var entered = false
    private var waiter: CheckedContinuation<Void, Never>?
    var wasCancelled = false
    func hold() async { entered = true; await withCheckedContinuation { waiter = $0 }; wasCancelled = Task.isCancelled }
    func waitUntilEntered() async { while !entered { await Task.yield() } }
    func open() { waiter?.resume(); waiter = nil }
}
@MainActor private final class DiscoveryTransitionState { var busy = false; var finished = false }
private enum MenuStartError: LocalizedError {
    case failed(String)
    var errorDescription: String? { switch self { case let .failed(message): return message } }
}

actor PasteVerificationGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    private(set) var wasCancelled = false
    private(set) var focusReads: [PrivateProfileSnapshot] = []
    var hasEntered: Bool { entered }
    func hold() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }
        entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
        wasCancelled = Task.isCancelled
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func open() { releaseWaiter?.resume(); releaseWaiter = nil }
    func recordFocusRead(profile: PrivateProfileSnapshot) { focusReads.append(profile) }
}
