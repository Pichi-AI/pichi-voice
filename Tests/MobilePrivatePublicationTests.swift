import Foundation

// In-memory scope metadata only. No real profile is selected or configured.
@MainActor private final class SyntheticPublicationScope {
    var visible = true
    var context = MobilePrivatePublicationContext(profile: PrivateProfileSnapshot(id: "synthetic-a", context: nil,
        generation: UUID(), rootDirectory: URL(fileURLWithPath: "/synthetic-unused"),
        legacyRootDirectory: URL(fileURLWithPath: "/synthetic-unused"), isReadable: true), projectionRevision: UUID())
    func current(_ token: MobilePrivatePublicationContext) -> Bool { visible && token == context }
    func conceal() {
        visible = false
        context = .init(profile: context.profile, projectionRevision: UUID())
    }
}

@MainActor private final class SyntheticStatusReadiness {
    var ready = false
    var allowsSource = true
    var waits = 0
    var validations = 0
}

extension MobileAccountInteractionTests {
    @MainActor static func privatePublicationTests() async throws {
        let scope = SyntheticPublicationScope()
        let owner = MobilePrivatePublicationTasks(capture: { scope.visible ? scope.context : nil }, validate: { scope.current($0) })
        let original = owner.admit()!
        expect(owner.canPublish(original), "Current immutable profile/revision can publish")
        var gate: CheckedContinuation<Void, Never>?
        var started = false, didPublish = false, reports = 0
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("pichi-synthetic-publication-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        let staged = temporary.appendingPathComponent("synthetic.txt")
        let pending = owner.start(report: { _ in reports += 1 }) { admission in
            started = true
            await withCheckedContinuation { gate = $0 }
            // Simulate a non-cooperative exporter handing back its newly staged file.
            try Data("synthetic export".utf8).write(to: staged)
            guard owner.canPublish(admission) else { try FileManager.default.removeItem(at: staged); return }
            didPublish = true
        }
        await until { started }
        expect(owner.busyCount == 1, "Publication remains owned across suspended I/O")
        scope.conceal()
        var joined = false
        let join = Task { await owner.cancelAndJoin(); joined = true }
        await until { owner.admit() == nil }
        expect(owner.start(operation: { _ in preconditionFailure("Late work admitted during cleanup") }) == nil,
               "Joined cleanup closes local publication admission")
        expect(!joined && owner.busyCount == 1, "Cancellation joins the non-cooperative operation")
        gate!.resume(); await pending?.value; await join.value
        expect(joined && !didPublish && reports == 0, "Concealed completion cannot publish or report stale failure")
        expect(!FileManager.default.fileExists(atPath: staged.path), "Rejected staged payload is independently removed")
        expect(owner.busyCount == 0 && !owner.canPublish(original), "Joined work releases ownership and invalidates former tokens")
        owner.resume()
        expect(owner.admit() == nil, "Resuming the UI owner cannot bypass profile visibility")
        scope.visible = true
        expect(owner.admit() != nil && !owner.canPublish(original), "Same-profile return with a new revision cannot revive an old publication")

        var errorGate: CheckedContinuation<Void, Never>?
        var errorStarted = false
        owner.start(report: { _ in reports += 1 }) { _ in
            errorStarted = true; await withCheckedContinuation { errorGate = $0 }
            throw AccountError.networkUnavailable
        }
        await until { errorStarted }
        owner.cancel()
        let errorJoin = Task { await owner.cancelAndJoin() }
        errorGate!.resume(); await errorJoin.value
        expect(reports == 0, "Late private failure cannot populate the next profile's alert")
        owner.resume()
        let currentFailure = owner.start(report: { _ in reports += 1 }) { _ in throw AccountError.networkUnavailable }
        await currentFailure?.value
        expect(reports == 1, "A current-scope failure is still reported")

        var confirmation = false, delayedStarted = false
        var delayGate: CheckedContinuation<Void, Never>?
        owner.start(affectsBusy: false) { admission in
            delayedStarted = true; await withCheckedContinuation { delayGate = $0 }
            if owner.canPublish(admission) { confirmation = true }
        }
        await until { delayedStarted }
        expect(owner.busyCount == 0, "Retained confirmation work does not block recording controls")
        owner.cancel()
        let confirmationJoin = Task { await owner.cancelAndJoin() }
        delayGate!.resume(); await confirmationJoin.value
        expect(!confirmation, "A cancelled delayed confirmation cannot mutate a new presentation")

        await owner.cancelAndJoin()
        await cloudCommandTests()
        await cloudStatusReadinessTests()
        cloudAssessmentSelectionTests()
    }

    @MainActor private static func cloudStatusReadinessTests() async {
        let scope = SyntheticPublicationScope(), presented = scope.context
        let readiness = SyntheticStatusReadiness()
        var calls = 0, reports = 0
        let jobs = MobilePrivatePublicationTasks(capture: {
            readiness.ready && scope.current(presented) ? presented : nil
        }, validate: { readiness.ready && scope.current($0) && $0 == presented })
        let interaction = MobileCloudInteraction(publications: jobs,
            statusSource: { scope.current(presented) ? presented : nil },
            readinessDelay: { readiness.waits += 1; await Task.yield() })
        let row = UUID()
        let preentry = interaction.readStatus(presentationID: row, report: { _ in reports += 1 }) { _ in calls += 1; return true }
        preentry?.cancel(); await preentry?.value
        expect(interaction.pendingStatusReadCount == 0 && calls == 0 && readiness.waits == 0,
               "Pre-entry row cancellation releases its retained status slot without entering the read or wait")
        let waiting = interaction.readStatus(presentationID: row, report: { _ in reports += 1 }) { _ in calls += 1; return true }
        await until { readiness.waits > 0 }
        let duplicate = interaction.readStatus(presentationID: row, report: { _ in reports += 1 }) { _ in calls += 100; return true }
        expect(waiting != nil && duplicate != nil && interaction.pendingStatusReadCount == 1,
               "Repeated entry for one row retains one readiness/read job")
        scope.conceal(); interaction.invalidate(); await interaction.waitUntilFinished(); await waiting?.value
        expect(calls == 0 && reports == 0 && interaction.pendingStatusReadCount == 0,
               "Transition concealment cancels and joins readiness without a status call or stale error")
        scope.visible = true; readiness.ready = true
        expect(interaction.readStatus(presentationID: row, report: { _ in reports += 1 }, operation: { _ in calls += 1; return true }) == nil,
               "The old A status owner cannot capture B or a new projection revision")
        expect(reports == 0, "Invalid-source admission stays silent instead of reporting backpressure into a replacement profile")

        let current = SyntheticPublicationScope(), frozen = current.context
        let currentReadiness = SyntheticStatusReadiness()
        let currentJobs = MobilePrivatePublicationTasks(capture: {
            currentReadiness.ready && current.current(frozen) ? frozen : nil
        }, validate: { currentReadiness.ready && current.current($0) && $0 == frozen })
        let active = MobileCloudInteraction(publications: currentJobs,
            statusSource: { currentReadiness.allowsSource && current.current(frozen) ? frozen : nil },
            readinessDelay: { currentReadiness.waits += 1; await Task.yield() })
        var unavailableReports: [AccountError] = []
        let expired = active.readStatus(presentationID: UUID(), report: { if let error = $0 as? AccountError { unavailableReports.append(error) } }) { _ in calls += 1; return true }
        await expired?.value
        expect(currentReadiness.waits == 600 && active.pendingStatusReadCount == 0 && calls == 0 && reports == 0
               && unavailableReports == [.busy],
               "Exhausted current-source readiness releases ownership and reports one safe unavailable error without polling the facade")
        var boundedTasks: [Task<Void, Never>] = []
        for _ in 0..<MobileCloudInteraction.maximumStatusReads {
            if let task = active.readStatus(presentationID: UUID(), report: { _ in reports += 1 }, operation: { _ in calls += 1; return true }) {
                boundedTasks.append(task)
            }
        }
        expect(boundedTasks.count == 32 && active.pendingStatusReadCount == 32
               && active.readStatus(presentationID: UUID(), report: { if let error = $0 as? AccountError { unavailableReports.append(error) } }, operation: { _ in true }) == nil
               && unavailableReports == [.busy, .busy],
               "One window retains at most thirty-two status waiters and known row identifiers")
        currentReadiness.allowsSource = false
        expect(active.readStatus(presentationID: UUID(), report: { if let error = $0 as? AccountError { unavailableReports.append(error) } }, operation: { _ in true }) == nil
               && unavailableReports == [.busy, .busy],
               "Capacity rejection does not report into an invalid source frame")
        currentReadiness.allowsSource = true
        let cancelledCapacity = Task { @MainActor in
            active.readStatus(presentationID: UUID(), report: { if let error = $0 as? AccountError { unavailableReports.append(error) } }, operation: { _ in true })
        }
        cancelledCapacity.cancel()
        let cancelledAdmission = await cancelledCapacity.value
        expect(cancelledAdmission == nil && unavailableReports == [.busy, .busy],
               "A cancelled caller does not publish a capacity error even when its original source remains valid")
        for task in boundedTasks { task.cancel() }
        for task in boundedTasks { await task.value }
        expect(active.pendingStatusReadCount == 0 && calls == 0 && reports == 0 && unavailableReports == [.busy, .busy],
               "Cancelling bounded row waiters joins every retained task without extra unavailable errors")

        currentReadiness.ready = true
        var retriedReads = 0
        let retryAfterCleanup = active.readStatus(presentationID: UUID(), report: { _ in reports += 1 }) { _ in
            retriedReads += 1; return true
        }
        await retryAfterCleanup?.value
        expect(retryAfterCleanup != nil && retriedReads == 1 && active.pendingStatusReadCount == 0 && reports == 0,
               "A retry after exhaustion and capacity cleanup is admitted and reads the still-current source")
        var readGate: CheckedContinuation<Void, Never>?, commandGate: CheckedContinuation<Void, Never>?
        var readEntered = false, commandEntered = false, didPublish = false
        let unrelated = active.run(.toggle(false)) { _ in
            commandEntered = true; await withCheckedContinuation { commandGate = $0 }
        }
        await until { commandEntered }
        let readID = UUID()
        let reading = active.readStatus(presentationID: readID, report: { _ in reports += 1 }) { admission in
            readEntered = true; await withCheckedContinuation { readGate = $0 }
            if currentJobs.canPublish(admission) { didPublish = true }
            return didPublish
        }
        await until { readEntered }
        active.cancelStatusRead(presentationID: readID)
        var rowJoined = false
        let rowJoin = Task { await reading?.value; rowJoined = true }
        await Task.yield()
        expect(!rowJoined && active.pendingStatusReadCount == 1 && active.action == .toggle(false),
               "Row dismissal joins a non-cooperative admitted status caller and leaves the unrelated OFF command owned")
        var replacementReads = 0
        let replacementID = UUID()
        let replacement = active.readStatus(presentationID: replacementID, report: { _ in reports += 1 }) { admission in
            guard currentJobs.canPublish(admission) else { return false }
            replacementReads += 1
            return true
        }
        expect(replacement != nil && active.pendingStatusReadCount == 2,
               "A reappearing row's fresh ticket is admitted while its cancelled old caller remains owned until join")
        await replacement?.value
        expect(replacementReads == 1 && active.pendingStatusReadCount == 1 && !rowJoined,
               "The fresh row loads status independently while the retiring old ticket cannot consume or remove its request")
        readGate!.resume(); await rowJoin.value
        expect(!didPublish && reports == 0 && active.pendingStatusReadCount == 0 && active.action == .toggle(false),
               "A dismissed row cannot publish status or cancel unrelated window commands")
        commandGate!.resume(); await unrelated?.value

        currentReadiness.ready = false
        var staleWaitEntered = false
        let stale = active.readStatus(presentationID: UUID(), report: { _ in reports += 1 }) { _ in calls += 1; return true }
        await until { currentReadiness.waits > 600 }
        staleWaitEntered = active.pendingStatusReadCount == 1
        current.conceal(); current.visible = true; currentReadiness.ready = true
        await stale?.value
        expect(staleWaitEntered && calls == 0 && active.pendingStatusReadCount == 0,
               "An A-to-B source/projection change independently retires readiness even before observer cancellation")
        active.invalidate(); await active.waitUntilFinished()

        let raceScope = SyntheticPublicationScope(), race = SyntheticStatusReadiness()
        race.ready = true
        let raceJobs = MobilePrivatePublicationTasks(capture: { race.ready ? raceScope.context : nil }, validate: {
            race.validations += 1
            if race.validations == 3 { race.ready = false }
            return race.ready && raceScope.current($0)
        })
        let raceOwner = MobileCloudInteraction(publications: raceJobs, statusSource: { raceScope.context },
            readinessDelay: { race.waits += 1; await Task.yield() })
        let raceRead = raceOwner.readStatus(presentationID: UUID(), report: { _ in reports += 1 }) { _ in calls += 1; return true }
        await until { race.waits > 0 }
        expect(calls == 0 && race.validations == 3 && raceOwner.pendingStatusReadCount == 1,
               "Losing N1 readiness between admission and task entry retains the skipped initial read")
        race.ready = true
        await raceRead?.value
        expect(calls == 1 && reports == 0 && raceOwner.pendingStatusReadCount == 0,
               "A skipped status read runs exactly once when the unchanged source becomes ready again")
        var localAttempts = 0, localPublications = 0
        let waitsBeforeFacade = race.waits
        let facadeRace = raceOwner.readStatus(presentationID: UUID(), report: { _ in reports += 1 }) { _ in
            localAttempts += 1
            if localAttempts == 1 { race.ready = false; throw AccountError.staleOperation }
            localPublications += 1
            return true
        }
        await until { race.waits > waitsBeforeFacade }
        expect(localAttempts == 1 && localPublications == 0,
               "A lost N1 admission waits locally after a facade rejection without polling status")
        race.ready = true; await facadeRace?.value
        expect(localAttempts == 2 && localPublications == 1 && reports == 0,
               "A transient rejection inside the local status facade resumes after N1 readiness and projects only once")
        var projectionGate: CheckedContinuation<Void, Never>?
        var projectionAttempts = 0, projectedReads = 0
        let waitsBeforeProjection = race.waits
        let projectionRace = raceOwner.readStatus(presentationID: UUID(), report: { _ in reports += 1 }) { admission in
            projectionAttempts += 1
            if projectionAttempts == 1 { await withCheckedContinuation { projectionGate = $0 } }
            guard raceJobs.canPublish(admission) else { return false }
            projectedReads += 1
            return true
        }
        await until { projectionGate != nil }
        race.ready = false; projectionGate!.resume()
        await until { race.waits > waitsBeforeProjection }
        expect(projectionAttempts == 1 && projectedReads == 0 && raceOwner.pendingStatusReadCount == 1,
               "Losing N1 readiness during the local status read preserves the initial projection request")
        race.ready = true; await projectionRace?.value
        expect(projectionAttempts == 2 && projectedReads == 1 && raceOwner.pendingStatusReadCount == 0,
               "The unchanged row projects status once after its post-await fence becomes current again")
        let terminal = raceOwner.readStatus(presentationID: UUID(), report: { _ in reports += 1 }) { _ in
            localAttempts += 1
            throw AccountError.invalidResponse
        }
        await terminal?.value
        expect(localAttempts == 3 && reports == 1 && raceOwner.pendingStatusReadCount == 0,
               "A current non-transient status failure is reported once and does not become a retry loop")
        let currentStale = raceOwner.readStatus(presentationID: UUID(), report: { _ in reports += 1 }) { _ in
            localAttempts += 1
            throw AccountError.staleOperation
        }
        await currentStale?.value
        expect(localAttempts == 4 && reports == 2 && raceOwner.pendingStatusReadCount == 0,
               "A stale facade rejection while N1 admission is current is reported once instead of blindly polling status")
        raceOwner.invalidate(); await raceOwner.waitUntilFinished()
    }

    @MainActor private static func cloudCommandTests() async {
        let scope = SyntheticPublicationScope()
        let presented = scope.context
        let jobs = MobilePrivatePublicationTasks(capture: {
            scope.current(presented) ? presented : nil
        }, validate: { scope.current($0) && $0 == presented })
        let commands = MobileCloudInteraction(publications: jobs)
        var gate: CheckedContinuation<Void, Never>?
        var entered = false, verifiedEnabled = true, calls = 0
        let pending = commands.run(.toggle(false)) { _ in
            calls += 1; entered = true
            await withCheckedContinuation { gate = $0 }
            // Synthetic coherent facade: the UI owner never changes this value.
            verifiedEnabled = false
            throw AccountError.networkUnavailable
        }
        await until { entered }
        expect(commands.action == .toggle(false) && verifiedEnabled,
               "Pending OFF retains its command and the facade's verified ON value")
        expect(commands.run(.toggle(true), operation: { _ in calls += 1 }) == nil && calls == 1,
               "An overlapping toggle is rejected before invoking its operation")
        expect(jobs.busyCount == 0, "Cloud commands do not block local recording controls")
        scope.conceal(); commands.invalidate()
        var joined = false
        let join = Task { await commands.waitUntilFinished(); joined = true }
        await Task.yield()
        expect(!joined && commands.action != nil, "Cloud retirement retains a non-cooperative facade caller until join")
        gate!.resume(); await pending?.value; await join.value
        expect(joined && commands.action == nil && !commands.failed,
               "Concealed completion releases its UI lock without a stale error")
        scope.visible = true
        expect(commands.run(.pause, operation: { _ in calls += 1 }) == nil && calls == 1,
               "An old view cannot pause the replacement profile after a revision change")

        let current = SyntheticPublicationScope()
        let currentJobs = MobilePrivatePublicationTasks(capture: { current.context }, validate: { current.current($0) })
        let active = MobileCloudInteraction(publications: currentJobs)
        await active.run(.resume, operation: { _ in throw AccountError.networkUnavailable })?.value
        expect(active.failed && active.action == nil, "A current command failure is shown and unlocks controls")
        await active.run(.resume, operation: { _ in throw AccountError.staleOperation })?.value
        expect(!active.failed, "A stale facade rejection never becomes another profile's generic error")
        await active.run(.resume, operation: { _ in throw CancellationError() })?.value
        expect(!active.failed && active.action == nil, "Cancellation joins and clears the UI command without a false failure")
        var cancelledEntryRan = false
        let cancelledBeforeEntry = active.run(.options(UUID())) { _ in cancelledEntryRan = true }
        cancelledBeforeEntry?.cancel()
        await cancelledBeforeEntry?.value
        expect(!cancelledEntryRan && active.action == nil && !active.failed,
               "Dismissal before operation entry still releases the window's cloud command lock")
        var nextCommandRan = false
        let nextCommand = active.run(.pause) { _ in nextCommandRan = true }
        await nextCommand?.value
        expect(nextCommand != nil && nextCommandRan && active.action == nil,
               "A command after pre-entry cancellation is admitted without resetting unrelated window work")
        active.invalidate(); await active.waitUntilFinished()
        expect(!active.failed && active.action == nil, "Joined transient cleanup leaves no command or error")
    }

    @MainActor private static func cloudAssessmentSelectionTests() {
        let participant = UUID(), otherParticipant = UUID(), unknownParticipant = UUID()
        let participants: Set<UUID> = [participant, otherParticipant]
        let firstID = "opaque:criterion/Ё?=1", secondID = "opaque:criterion/Ё?=2"
        let unchangedName = "  Ёжик и ёлка: качество  "
        var selection = MobileCloudAssessmentSelection()
        expect(selection.participantID == nil && selection.criteria.isEmpty,
               "An assessment starts without copied or inferred selections")
        expect(!selection.canSubmit(canResolvePending: true, receiptPending: true, offeredParticipants: participants),
               "An empty draft cannot submit even when the server permits resolution")
        expect(!selection.selectParticipant(unknownParticipant, offered: participants) && selection.participantID == nil,
               "An unoffered participant cannot enter the draft")
        expect(selection.selectParticipant(participant, offered: participants) && selection.participantID == participant,
               "A participant requires an explicit offered identifier")
        expect(!selection.selectParticipant(unknownParticipant, offered: participants) && selection.participantID == participant,
               "A rejected participant cannot overwrite an explicit selection")
        expect(!selection.canSubmit(canResolvePending: true, receiptPending: true, offeredParticipants: participants),
               "Selecting a participant alone does not make a valid assessment")
        expect(!selection.toggleCriterion("unoffered", name: unchangedName, offered: [firstID]) && selection.criteria.isEmpty,
               "An unoffered criterion cannot enter the draft")
        expect(selection.toggleCriterion(firstID, name: unchangedName, offered: [firstID])
               && selection.criteria.count == 1
               && selection.criteria.keys.first?.utf8.elementsEqual(firstID.utf8) == true
               && selection.criteria[firstID]?.utf8.elementsEqual(unchangedName.utf8) == true,
               "Opaque criterion identifiers and Cyrillic display names are preserved byte for byte")
        expect(selection.toggleCriterion(secondID, name: unchangedName, offered: [secondID])
               && selection.criteria.count == 2 && selection.criteria[secondID] == unchangedName,
               "A next page retains prior choices and distinct identifiers with the same display name")
        expect(!selection.toggleCriterion(firstID, name: "replacement", offered: [secondID])
               && selection.criteria[firstID] == unchangedName,
               "A selection outside the current offered page cannot be toggled or renamed implicitly")
        expect(selection.canSubmit(canResolvePending: true, receiptPending: true, offeredParticipants: participants),
               "Explicit offered participant and criteria satisfy the pending-resolution gates")
        expect(!selection.canSubmit(canResolvePending: false, receiptPending: true, offeredParticipants: participants),
               "Server resolution eligibility is required at confirmation")
        expect(!selection.canSubmit(canResolvePending: true, receiptPending: false, offeredParticipants: participants),
               "A receipt that is no longer pending cannot be resolved by the draft")
        expect(!selection.canSubmit(canResolvePending: true, receiptPending: true, offeredParticipants: [otherParticipant]),
               "Revoking the selected participant disables confirmation without inferring a replacement")
        selection.removeCriterion(firstID)
        expect(selection.criteria == [secondID: unchangedName],
               "An explicit removal works for a criterion from an earlier page")
        selection.removeCriterion("missing")
        expect(selection.criteria == [secondID: unchangedName], "Removing an unknown selection preserves the draft")
        expect(selection.toggleCriterion(secondID, name: "ignored on deselection", offered: [secondID])
               && selection.criteria.isEmpty,
               "Toggling an offered selected criterion deselects its identifier")
        selection.clear()
        expect(selection.participantID == nil && selection.criteria.isEmpty,
               "Clearing the presentation removes every participant and criterion draft")

        let offered = Set((0...MobileCloudAssessmentSelection.maximumCriteria).map { "criterion/\($0)" })
        var acceptedAll = true
        for index in 0..<MobileCloudAssessmentSelection.maximumCriteria {
            acceptedAll = selection.toggleCriterion("criterion/\(index)", name: "Критерий \(index)", offered: offered) && acceptedAll
        }
        expect(MobileCloudAssessmentSelection.maximumCriteria == 100 && acceptedAll && selection.criteria.count == 100,
               "The reducer accepts exactly one hundred explicitly offered criteria")
        let fullDraft = selection.criteria
        expect(!selection.toggleCriterion("criterion/100", name: "За пределом", offered: offered) && selection.criteria == fullDraft,
               "A criterion beyond the retained bound is rejected without evicting an earlier choice")
        selection.selectParticipant(participant, offered: participants)
        expect(selection.canSubmit(canResolvePending: true, receiptPending: true, offeredParticipants: participants),
               "A draft at the criterion bound remains eligible for explicit confirmation")
        expect(selection.toggleCriterion("criterion/0", name: "ignored", offered: offered) && selection.criteria.count == 99,
               "The retention bound does not prevent deselecting a known offered criterion")
        expect(selection.toggleCriterion("criterion/100", name: unchangedName, offered: offered)
               && selection.criteria.count == 100 && selection.criteria["criterion/100"] == unchangedName
               && selection.criteria["criterion/0"] == nil,
               "A freed slot admits the next explicit opaque identifier without altering the remaining choices")
        selection.clear()
        expect(selection.participantID == nil && selection.criteria.isEmpty
               && !selection.canSubmit(canResolvePending: true, receiptPending: true, offeredParticipants: participants),
               "Dismissal clears a full draft and restores the empty confirmation gate")
    }
}
