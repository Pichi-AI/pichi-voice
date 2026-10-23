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
        print("Private capture feedback: \(checks) actual-buffer and callback checks passed")
    }
}
