import Foundation

@main struct DesktopCloudPublicationUITests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message); assertions += 1
        }
        func snapshot(_ availability: PichiCloudPublicationAvailability, enabled: Bool) -> PichiCloudPublicationSnapshot {
            .init(availability: availability, cloudSyncEnabled: enabled, items: [:])
        }
        func fixture() -> (PichiCloudPublicationService, AccountSessionService, PrivateProfileService) {
            let profiles = PrivateProfileService.shared
            profiles.projectionRevision = UUID()
            profiles.isPrivateDataVisible = true
            profiles.isTransitioning = false
            PrivateProfileStorage.select(.init(id: "synthetic-A", context: CloudUIFixture.context,
                generation: CloudUIFixture.context.generation, isReadable: true))
            return (PichiCloudPublicationService(), AccountSessionService(), profiles)
        }
        func idle(_ state: DesktopCloudPublicationPresentation) async {
            let deadline = ContinuousClock.now.advanced(by: .seconds(6))
            while state.isWorking {
                precondition(ContinuousClock.now < deadline, "Synthetic command did not join")
                try? await Task.sleep(for: .milliseconds(1))
            }
        }
        check(!DesktopCloudPublicationPolicy.canUseNetwork(snapshot(.ready, enabled: false), accountState: .signedIn), "OFF denies network controls")
        check(DesktopCloudPublicationPolicy.canUseNetwork(snapshot(.paused, enabled: true), accountState: .signedIn), "Explicit resume/retry remains possible")
        for availability in [PichiCloudPublicationAvailability.unconfigured, .signedOut, .profileUnavailable,
                             .pausing, .transportUnavailable, .storageUnavailable] {
            check(!DesktopCloudPublicationPolicy.canUseNetwork(snapshot(availability, enabled: true), accountState: .signedIn), "Unavailable transport denies sends")
        }
        check(DesktopCloudPublicationPolicy.canToggle(snapshot(.storageUnavailable, enabled: true), accountState: .signedIn), "OFF persistence repair stays available")
        check(!DesktopCloudPublicationPolicy.canToggle(snapshot(.pausing, enabled: true), accountState: .signedIn), "Joining OFF cannot overlap another toggle")
        check(DesktopCloudPublicationPolicy.action(for: .localOnly) == nil, "Local history cannot be claimed")
        check(DesktopCloudPublicationPolicy.action(for: .waitingForSource) == nil, "An unprepared source is not advertised as uploadable")
        check(DesktopCloudPublicationPolicy.action(for: .queued) == .send, "Admitted prepared work can be sent")
        check(DesktopCloudPublicationPolicy.action(for: .paused(.permissionReview)) == nil, "Permission review is not silently retried")
        let receipt = PichiPublicationReceipt(schemaVersion: 1, importID: "synthetic-import",
            recordingID: "synthetic-recording", uploadState: .accepted, analysisState: .failed)
        let review = PichiCloudPublicationStatus.acceptedNeedsReview(receipt, .receiptReview)
        check(DesktopCloudPublicationPolicy.action(for: review) == .reconcile, "Accepted work reconciles rather than reimports")
        check(DesktopCloudPublicationCopy.receipt(review) == receipt, "Review retains upload acceptance")
        check(DesktopCloudPublicationCopy.status(review) == "Cloud upload accepted", "Acceptance is separate from analysis")
        check(DesktopCloudPublicationCopy.analysis(.failed) == "Analysis failed. Upload retained.", "Analysis failure keeps upload")
        for reason in PichiPublicationWithholdingReason.allCases {
            check(!DesktopCloudPublicationCopy.status(.withheld(reason)).isEmpty, "Every withheld reason has copy")
            check(DesktopCloudPublicationPolicy.action(for: .withheld(reason)) == nil, "Withheld text stays local")
        }
        for analysis in PichiPublicationAnalysisState.allCases {
            check(!DesktopCloudPublicationCopy.analysis(analysis).isEmpty, "Every analysis state has copy")
        }

        let (publication, account, profiles) = fixture()
        let state = DesktopCloudPublicationPresentation(publication: publication, account: account, profiles: profiles)
        state.activate()
        let toggleGate = CloudUIFixtureGate(); publication.gate = toggleGate
        state.start(.setEnabled(false)); state.start(.setEnabled(true))
        while publication.calls.isEmpty { await Task.yield() }
        check(state.isWorking && publication.calls == ["toggle"], "Toggle admission is synchronous and single-flight")
        check(publication.snapshot.cloudSyncEnabled && publication.snapshot.availability == .pausing, "OFF retains last verified value during join")
        await toggleGate.release(); await idle(state)
        check(!publication.snapshot.cloudSyncEnabled && state.failure == nil, "Only completed OFF projects disabled")
        publication.gate = nil; publication.shouldFail = true
        state.start(.setEnabled(true)); await idle(state)
        check(state.failure == .operation, "Raw service failures become a typed UI failure")
        check(DesktopCloudPublicationCopy.failure(state.failure!) == "Cloud sync could not finish. Review its status and try again.", "Provider details are never UI copy")

        let stableGeneration = account.generation
        let stableProfileRevision = profiles.projectionRevision
        publication.snapshot = snapshot(.ready, enabled: true)
        account.state = .reauthenticationRequired
        check(account.generation == stableGeneration && profiles.projectionRevision == stableProfileRevision, "Refresh can require authentication without a source change")
        check(!state.isCurrent, "Same-generation authentication loss closes command admission")
        check(!DesktopCloudPublicationPolicy.canToggle(publication.snapshot, accountState: account.state), "Retained ready snapshot cannot enable consent controls")
        check(!DesktopCloudPublicationPolicy.canUseNetwork(publication.snapshot, accountState: account.state), "Retained ready snapshot cannot enable pause or resume")
        check(!DesktopCloudPublicationPolicy.canUseNetwork(snapshot(.paused, enabled: true), accountState: account.state), "Retained paused snapshot cannot enable resume")
        check(DesktopCloudPublicationCopy.availability(publication.snapshot, accountState: account.state) == "Sign in again to resume cloud uploads", "Authentication-required copy takes precedence over retained readiness")
        let callsBefore = publication.calls
        state.start(.pause)
        check(publication.calls == callsBefore, "Authentication loss cannot schedule an old button command")
        state.deactivate()

        let (queuedPublication, queuedAccount, queuedProfiles) = fixture()
        let queued = DesktopCloudPublicationPresentation(publication: queuedPublication, account: queuedAccount, profiles: queuedProfiles)
        queued.activate(); queued.start(.setEnabled(true))
        queuedProfiles.projectionRevision = UUID()
        await idle(queued)
        check(queuedPublication.calls.isEmpty, "A retained intent is revalidated inside its task")
        check(queued.failure == nil, "A stale intent cannot publish errors")

        let (pausingPublication, pausingAccount, pausingProfiles) = fixture()
        let pausing = DesktopCloudPublicationPresentation(publication: pausingPublication, account: pausingAccount, profiles: pausingProfiles)
        pausing.activate()
        let pauseGate = CloudUIFixtureGate(); pausingPublication.gate = pauseGate
        pausing.start(.pause)
        while pausingPublication.calls.isEmpty { await Task.yield() }
        pausingProfiles.isPrivateDataVisible = false
        var began = false, joined = false
        let cleanup = Task { @MainActor in
            began = true
            try await pausing.prepareForPrivateProfileTransition()
            joined = true
        }
        while !began { await Task.yield() }
        await Task.yield()
        check(!joined && pausing.isWorking, "Transition joins a nonthrowing pause caller")
        check(pausing.loadedStatus == nil && pausing.failure == nil, "Concealment clears local payloads before join")
        await pauseGate.release(); try await cleanup.value
        check(joined && !pausing.isWorking && !pausing.isCurrent, "Retired command lifetime is fully joined")
        pausingProfiles.isPrivateDataVisible = true; pausing.activate(); pausing.start(.resume)
        check(pausingPublication.calls == ["pause"], "A retired owner never binds to a later profile")

        let (reopenPublication, reopenAccount, reopenProfiles) = fixture()
        let reopened = DesktopCloudPublicationPresentation(publication: reopenPublication, account: reopenAccount, profiles: reopenProfiles)
        reopened.activate()
        let reopenGate = CloudUIFixtureGate(); reopenPublication.gate = reopenGate
        let sessionID = UUID()
        reopened.start(.status(sessionID))
        while reopenPublication.calls.isEmpty { await Task.yield() }
        reopened.deactivate()
        let restart = Task { @MainActor in await reopened.activateAndStart(.status(sessionID)) }
        await reopenGate.release(); await restart.value; await idle(reopened)
        check(reopenPublication.calls == ["status", "status"], "Reappearance waits for the cancelled caller before one new status read")
        check(reopened.loadedStatus == .localOnly && reopened.failure == nil, "Only the current observation is retained")
        reopened.deactivate()

        let meetingID = UUID(), participantA = UUID(), participantB = UUID()
        let pendingReceipt = PichiPublicationReceipt(schemaVersion: 1, importID: "synthetic-pending",
            recordingID: "synthetic-recording", uploadState: .accepted, analysisState: .needsCriteria)
        let pendingStatus = PichiCloudPublicationStatus.accepted(pendingReceipt)
        let baseline = PichiPublicationAssessment(participantID: participantB, criteriaIDs: ["existing-off-page"])
        func page(offset: Int, count: Int, cursor: String?, next: String?, canResolve: Bool = true,
                  accountID: String = "person") -> PichiPublicationAssessmentOptions {
            .init(schemaVersion: 1,
                context: .init(accountID: accountID, organizationID: "organization", workspaceID: "workspace"),
                receipt: pendingReceipt,
                participants: [.init(id: participantA, displayName: "Алёна Ёжик"), .init(id: participantB, displayName: "Борис Ёлкин")],
                criteria: .init(data: (offset..<(offset + count)).map {
                    .init(id: "criterion-\($0)", name: "Synthetic criterion \($0)")
                }, pagination: .init(limit: 50, cursor: cursor, nextCursor: next, hasMore: next != nil)),
                currentAssessment: baseline, canResolvePending: canResolve)
        }
        func assessmentFixture(canResolve: Bool = true) -> (PichiCloudPublicationService, AccountSessionService, PrivateProfileService, DesktopCloudPublicationPresentation) {
            let (publication, account, profiles) = fixture()
            publication.snapshot = .init(availability: .ready, cloudSyncEnabled: true, items: [meetingID: pendingStatus])
            publication.optionsPages = [
                "": page(offset: 0, count: 50, cursor: nil, next: "opaque-next-B", canResolve: canResolve),
                "opaque-next-B": page(offset: 50, count: 50, cursor: "opaque-next-B", next: "opaque-next-C", canResolve: canResolve),
                "opaque-next-C": page(offset: 100, count: 1, cursor: "opaque-next-C", next: nil, canResolve: canResolve),
            ]
            let state = DesktopCloudPublicationPresentation(publication: publication, account: account, profiles: profiles)
            state.activate()
            return (publication, account, profiles, state)
        }

        let (selectionPublication, _, _, selection) = assessmentFixture()
        selection.beginAssessment(for: meetingID, status: pendingStatus); await idle(selection)
        let epoch = selection.assessmentSession!.id
        check(selectionPublication.optionsRequests.count == 1 && selectionPublication.optionsRequests[0].cursor == nil &&
              selectionPublication.optionsRequests[0].limit == 50, "Opening performs one bounded known-record options request")
        check(selectionPublication.resolutions.isEmpty, "Loading options never sends PATCH")
        check(selection.selectedParticipantID == nil && selection.selectedCriteria.isEmpty, "Current bindings never become inferred defaults")
        check(selection.currentAssessment == baseline, "Existing off-page binding IDs remain intact")
        selection.selectParticipant(UUID(), epoch: epoch)
        selection.selectCriterion("existing-off-page", selected: true, epoch: epoch)
        check(selection.selectedParticipantID == nil && selection.selectedCriteria.isEmpty, "Unrepresented people and unseen binding IDs cannot grant new selection authority")
        selection.selectParticipant(participantA, epoch: epoch)
        check(!selection.canConfirmAssessment, "A participant alone cannot confirm")
        selection.selectCriterion("criterion-0", selected: true, epoch: epoch)
        check(selection.canConfirmAssessment, "Explicit represented participant plus authorized criterion can confirm")
        selection.loadNextCriteria(epoch: epoch); await idle(selection)
        check(selectionPublication.optionsRequests.count == 2 &&
              selectionPublication.optionsRequests[1].cursor == "opaque-next-B", "Only explicit pagination uses the unchanged opaque cursor")
        check(selection.assessmentPage?.criteria.data.first?.id == "criterion-50" &&
              selection.assessmentPage?.criteria.data.count == 50, "A next page replaces the previous page")
        check(selection.selectedCriteria["criterion-0"] != nil && selection.currentAssessment == baseline, "Selected IDs and baseline survive page replacement")
        selection.selectCriterion("criterion-50", selected: true, epoch: epoch)
        selection.confirmAssessment(epoch: epoch)
        selection.selectCriterion("criterion-51", selected: true, epoch: epoch)
        await idle(selection)
        check(selectionPublication.resolutions.count == 1 && selectionPublication.resolutions[0].id == meetingID &&
              selectionPublication.resolutions[0].participantID == participantA &&
              selectionPublication.resolutions[0].criteriaIDs == ["criterion-0", "criterion-50"], "Confirmed PATCH freezes exact explicit IDs")
        check(selection.assessmentSession == nil && selection.selectedCriteria.isEmpty && selection.currentAssessment == nil,
              "Successful confirmation closes and clears the draft")
        check(selectionPublication.snapshot.items[meetingID].flatMap(DesktopCloudPublicationCopy.receipt)?.analysisState == .queued,
              "Updated accepted receipt comes from the shared facade")

        let (boundedPublication, _, _, bounded) = assessmentFixture()
        bounded.beginAssessment(for: meetingID, status: pendingStatus); await idle(bounded)
        let boundEpoch = bounded.assessmentSession!.id
        bounded.selectParticipant(participantA, epoch: boundEpoch)
        for index in 0..<50 { bounded.selectCriterion("criterion-\(index)", selected: true, epoch: boundEpoch) }
        bounded.loadNextCriteria(epoch: boundEpoch); await idle(bounded)
        for index in 50..<100 { bounded.selectCriterion("criterion-\(index)", selected: true, epoch: boundEpoch) }
        bounded.loadNextCriteria(epoch: boundEpoch); await idle(bounded)
        bounded.selectCriterion("criterion-100", selected: true, epoch: boundEpoch)
        check(bounded.selectedCriteria.count == 100 && bounded.assessmentPage?.criteria.data.count == 1,
              "Retain at most 100 explicit choices and one page")
        check(boundedPublication.optionsRequests.count == 3 && boundedPublication.resolutions.isEmpty, "No automatic paging or PATCH")
        bounded.dismissAssessment(epoch: boundEpoch); await bounded.joinAssessmentDismissal()
        check(bounded.assessmentSession == nil && bounded.assessmentPage == nil && bounded.currentAssessment == nil &&
              bounded.selectedParticipantID == nil && bounded.selectedCriteria.isEmpty, "Dismissal clears page, cursor, baseline and draft")

        let (unavailablePublication, _, _, unavailable) = assessmentFixture(canResolve: false)
        unavailable.beginAssessment(for: meetingID, status: pendingStatus); await idle(unavailable)
        let unavailableEpoch = unavailable.assessmentSession!.id
        unavailable.selectParticipant(participantA, epoch: unavailableEpoch)
        unavailable.selectCriterion("criterion-0", selected: true, epoch: unavailableEpoch)
        unavailable.confirmAssessment(epoch: unavailableEpoch)
        check(!unavailable.canConfirmAssessment && unavailable.selectedCriteria.isEmpty &&
              unavailablePublication.resolutions.isEmpty, "Server canResolvePending=false denies all selection and confirmation")
        unavailable.dismissAssessment(epoch: unavailableEpoch); await unavailable.joinAssessmentDismissal()

        let (failedPublication, _, _, failedSelection) = assessmentFixture()
        failedPublication.shouldFail = true
        failedSelection.beginAssessment(for: meetingID, status: pendingStatus); await idle(failedSelection)
        check(failedSelection.failure == .operation && failedSelection.assessmentPage == nil, "Options failure shows only sanitized feedback")
        check(failedPublication.snapshot.items[meetingID].flatMap(DesktopCloudPublicationCopy.receipt) == pendingReceipt,
              "Options failure cannot erase upload acceptance")
        failedSelection.dismissAssessment(epoch: failedSelection.assessmentSession!.id); await failedSelection.joinAssessmentDismissal()

        let (wrongPublication, _, _, wrongSelection) = assessmentFixture()
        wrongPublication.optionsPages[""] = page(offset: 0, count: 50, cursor: nil, next: nil, accountID: "another-account")
        wrongSelection.beginAssessment(for: meetingID, status: pendingStatus); await idle(wrongSelection)
        check(wrongSelection.assessmentPage == nil && wrongSelection.failure == .operation, "A response for another context cannot populate private options")
        wrongSelection.dismissAssessment(epoch: wrongSelection.assessmentSession!.id); await wrongSelection.joinAssessmentDismissal()

        let (latePublication, _, _, lateSelection) = assessmentFixture()
        latePublication.ignoreCancellation = true
        let lateGate = CloudUIFixtureGate(); latePublication.gate = lateGate
        lateSelection.beginAssessment(for: meetingID, status: pendingStatus)
        while latePublication.calls.isEmpty { await Task.yield() }
        let oldEpoch = lateSelection.assessmentSession!.id
        lateSelection.dismissAssessment(epoch: oldEpoch)
        check(lateSelection.assessmentSession == nil && lateSelection.assessmentPage == nil && lateSelection.isWorking,
              "Dismissal clears immediately while a caller still joins")
        var dismissalJoined = false
        let dismissal = Task { @MainActor in await lateSelection.joinAssessmentDismissal(); dismissalJoined = true }
        await Task.yield()
        check(!dismissalJoined, "Dismissal retains an explicit join for an uncooperative options caller")
        await lateGate.release(); await dismissal.value; await idle(lateSelection)
        check(lateSelection.assessmentPage == nil && lateSelection.failure == nil, "A late cancelled options response cannot restore dismissed data")
        latePublication.gate = nil
        lateSelection.beginAssessment(for: meetingID, status: pendingStatus); await idle(lateSelection)
        let newEpoch = lateSelection.assessmentSession!.id
        lateSelection.dismissAssessment(epoch: oldEpoch)
        check(lateSelection.assessmentSession?.id == newEpoch, "Old sheet cleanup cannot clear a replacement sheet")
        lateSelection.dismissAssessment(epoch: newEpoch); await lateSelection.joinAssessmentDismissal()

        let (_, authAccount, authProfiles, authSelection) = assessmentFixture()
        authSelection.beginAssessment(for: meetingID, status: pendingStatus); await idle(authSelection)
        let authEpoch = authSelection.assessmentSession!.id
        authSelection.selectParticipant(participantA, epoch: authEpoch)
        authSelection.selectCriterion("criterion-0", selected: true, epoch: authEpoch)
        let authGeneration = authAccount.generation, authRevision = authProfiles.projectionRevision
        authAccount.state = .reauthenticationRequired
        check(authAccount.generation == authGeneration && authProfiles.projectionRevision == authRevision &&
              authSelection.assessmentSession == nil && authSelection.selectedCriteria.isEmpty,
              "Same-generation reauthentication clears options and drafts synchronously")
        await authSelection.joinAssessmentDismissal()

        let (_, changedAccount, _, changedSelection) = assessmentFixture()
        changedSelection.beginAssessment(for: meetingID, status: pendingStatus); await idle(changedSelection)
        changedAccount.context = .init(identity: CloudUIFixture.context.identity, organizationID: "organization",
                                      workspaceID: "another-workspace", generation: changedAccount.generation)
        check(changedSelection.assessmentSession == nil && changedSelection.currentAssessment == nil,
              "Context changes clear options before a new profile could be presented")
        await changedSelection.joinAssessmentDismissal()

        let (_, _, concealedProfiles, concealedSelection) = assessmentFixture()
        concealedSelection.beginAssessment(for: meetingID, status: pendingStatus); await idle(concealedSelection)
        concealedProfiles.isPrivateDataVisible = false
        concealedProfiles.projectionRevision = UUID()
        NotificationCenter.default.post(name: PrivateProfileService.willConceal, object: nil)
        check(concealedSelection.assessmentSession == nil && concealedSelection.assessmentPage == nil &&
              concealedSelection.currentAssessment == nil && !concealedSelection.isCurrent,
              "The synchronous N2 conceal signal clears options before participant joins")
        await concealedSelection.joinAssessmentDismissal()

        let (heldPublication, heldAccount, heldProfiles) = fixture()
        heldAccount.commandInFlight = true
        let held = DesktopCloudPublicationPresentation(publication: heldPublication, account: heldAccount, profiles: heldProfiles)
        let heldGeneration = heldAccount.generation, heldRevision = heldProfiles.sourceRevision
        await held.activateAndStart(.status(UUID()))
        try await Task.sleep(for: .milliseconds(35))
        check(held.isWorking && heldPublication.calls.isEmpty, "An initial read waits for N1's command tail without touching the facade")
        // Simulate a failed workspace command that clears its slot while retaining
        // the same published context, generation, profile and availability.
        heldAccount.commandInFlight = false
        await idle(held)
        check(heldAccount.generation == heldGeneration && heldProfiles.sourceRevision == heldRevision &&
              heldPublication.snapshot.availability == .ready, "The command tail can settle with no source/status publisher change")
        check(heldPublication.calls == ["status"] && held.loadedStatus == .localOnly,
              "A same-source initial load resumes exactly once after local readiness")

        let (cancelWaitPublication, cancelWaitAccount, _) = fixture()
        cancelWaitAccount.commandInFlight = true
        let cancelWait = DesktopCloudPublicationPresentation(publication: cancelWaitPublication,
            account: cancelWaitAccount, profiles: .shared)
        await cancelWait.activateAndStart(.status(UUID()))
        try await Task.sleep(for: .milliseconds(25))
        cancelWait.deactivate()
        await idle(cancelWait)
        check(cancelWaitPublication.calls.isEmpty && cancelWait.failure == nil, "A cancelled readiness wait makes no facade call")

        let (switchWaitPublication, switchWaitAccount, switchWaitProfiles) = fixture()
        switchWaitAccount.commandInFlight = true
        let switchWait = DesktopCloudPublicationPresentation(publication: switchWaitPublication,
            account: switchWaitAccount, profiles: switchWaitProfiles)
        await switchWait.activateAndStart(.status(UUID()))
        try await Task.sleep(for: .milliseconds(25))
        switchWaitAccount.context = .init(identity: CloudUIFixture.context.identity,
            organizationID: "organization", workspaceID: "B", generation: UUID())
        switchWaitAccount.generation = switchWaitAccount.context!.generation
        switchWaitAccount.commandInFlight = false
        await idle(switchWait)
        check(switchWaitPublication.calls.isEmpty && switchWait.loadedStatus == nil,
              "Readiness waiting never follows a captured A intent into B")

        let (timeoutPublication, timeoutAccount, timeoutProfiles) = fixture()
        timeoutAccount.commandInFlight = true
        let timeout = DesktopCloudPublicationPresentation(publication: timeoutPublication,
            account: timeoutAccount, profiles: timeoutProfiles)
        let timeoutGeneration = timeoutAccount.generation, timeoutSource = timeoutProfiles.sourceRevision
        await timeout.activateAndStart(.refresh)
        await idle(timeout)
        check(timeout.failure == .busy && timeoutPublication.calls.isEmpty,
              "Exhausting local readiness leaves a visible recoverable busy state without a facade call")
        timeoutAccount.commandInFlight = false
        timeout.retryProjectionObservation()
        await idle(timeout)
        check(timeoutAccount.generation == timeoutGeneration && timeoutProfiles.sourceRevision == timeoutSource &&
              timeoutPublication.calls == ["refresh"] && timeout.failure == nil,
              "Explicit refresh recovers after timeout when N1 clears its slot without any publisher change")
        print("Desktop cloud UI: \(assertions) synthetic assertions passed; actual typed contracts, UI owner, N2 operation owner and native SwiftUI views compiled. No app, HTTP, credentials, models or installed data.")
    }
}
