@main struct PrivateProfileActivationSummaryTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        guard value else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        checks += 1
    }
    @MainActor static func awaitEntry(_ gate: Gate) async {
        for _ in 0..<10_000 {
            if gate.entered { return }
            await Task.yield()
        }
        fputs("FAIL: The owned synthetic restoration did not reach its gate\n", stderr); exit(1)
    }
    @MainActor static func main() async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["PICHI_PROFILE_LIFECYCLE_ROOT"]!)
        let a = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        let b = try PrivateProfileStorage.proposed(context: .init(identity: .init(issuer: "https://synthetic.invalid", subject: "B", internalUserID: "B"),
            organizationID: "org", workspaceID: "workspace", generation: UUID()), generation: UUID(), legacyRootDirectory: root)
        let only = ProcessInfo.processInfo.environment["PICHI_PROFILE_LIFECYCLE_ONLY"] ?? "all"
        if only != "summary" { await activation(a: a, b: b) }
        if only != "activation" { try summary(a: a, b: b) }
        print("PASS: \(checks) actual profile restoration and summary-entry admission checks")
    }

    @MainActor static func activation(a: PrivateProfileSnapshot, b: PrivateProfileSnapshot) async {
        PrivateProfileStorage.select(a)
        PrivateProfileStorage.closeAdmission()
        let closed = RestorationProbe()
        let starts = LocalAPIServer.shared.starts
        await closed.restorePrivateSourcesAfterCommit()
        check(closed._meetingSessionCoordinator?.restores == 0 && closed.availabilityReconciliations == 0,
              "The pre-commit source phase cannot restore or start the detector")
        check(LocalAPIServer.shared.starts == starts, "Closed admission cannot start the API")

        PrivateProfileStorage.select(a)
        let committed = RestorationProbe()
        await committed.restorePrivateSourcesAfterCommit()
        check(committed._meetingSessionCoordinator?.restores == 1 && committed._cloudPublicationActivation?.activations == 1,
              "Committed sources restore through the existing coordinator and publication owner")
        check(committed.availabilityReconciliations == 1 && committed.detectorStarts == 1,
              "A committed foreground profile reconciles meeting availability")
        check(LocalAPIServer.shared.starts == starts + 1, "The current committed profile starts its API")

        for holdCloud in [false, true] {
            PrivateProfileStorage.select(a)
            let service = RestorationProbe(), gate = Gate()
            if holdCloud { service._cloudPublicationActivation?.gate = gate }
            else { service._meetingSessionCoordinator?.gate = gate }
            let initialStarts = LocalAPIServer.shared.starts
            let operation = Task { await service.restorePrivateSourcesAfterCommit() }
            await awaitEntry(gate)
            PrivateProfileStorage.conceal(generation: UUID())
            PrivateProfileStorage.select(b)
            gate.open()
            await operation.value
            check(service.availabilityReconciliations == 0 && service.detectorStarts == 0,
                  "A held old-profile restoration cannot enable B's detector")
            check(LocalAPIServer.shared.starts == initialStarts,
                  "A held old-profile restoration cannot start an API after the profile changes")
            if !holdCloud {
                check(service._cloudPublicationActivation?.activations == 0,
                      "An old coordinator completion cannot admit B's cloud activation")
            }
        }

        PrivateProfileStorage.select(a)
        let sameAccount = RestorationProbe(), sameGate = Gate()
        sameAccount._meetingSessionCoordinator?.gate = sameGate
        let held = Task { await sameAccount.restorePrivateSourcesAfterCommit() }
        await awaitEntry(sameGate)
        PrivateProfileStorage.select(try! PrivateProfileStorage.proposed(context: a.context, generation: UUID(), legacyRootDirectory: a.legacyRootDirectory))
        sameGate.open()
        await held.value
        check(sameAccount.availabilityReconciliations == 0, "A new generation of the same profile rejects old restoration")

        PrivateProfileStorage.select(a)
        let cancelled = RestorationProbe(), cancellationGate = Gate()
        cancelled._cloudPublicationActivation?.gate = cancellationGate
        let cancelledOperation = Task { await cancelled.restorePrivateSourcesAfterCommit() }
        await awaitEntry(cancellationGate)
        let cancelledStarts = LocalAPIServer.shared.starts
        cancelledOperation.cancel()
        cancellationGate.open()
        await cancelledOperation.value
        check(cancelled.detectorStarts == 0 && LocalAPIServer.shared.starts == cancelledStarts,
              "Cancellation while cloud restoration is held cannot start foreground resources")

        let notReady = RestorationProbe()
        notReady.isUIReady = false
        await notReady.restorePrivateSourcesAfterCommit()
        check(notReady.detectorStarts == 0, "The existing UI-ready dependency still gates detector startup")
        let disabled = RestorationProbe()
        disabled.featureEnabled = false
        await disabled.restorePrivateSourcesAfterCommit()
        check(disabled.detectorStarts == 0, "The disabled FluidMeet dependency still gates detector startup")
        let terminating = RestorationProbe()
        terminating.isTerminating = true
        await terminating.restorePrivateSourcesAfterCommit()
        check(terminating._meetingSessionCoordinator?.restores == 0, "Termination cannot admit restoration")
    }

    @MainActor static func allActions(_ controller: SummaryAdmissionProbe) {
        controller.download()
        controller.deleteModel(asr: ASRService())
        controller.summarize(session: MeetingSession(), kind: .executive, route: MeetingSummaryRoute())
        controller.summarizeOnDevice(session: MeetingSession(), kind: .executive, thinking: false, asr: ASRService())
    }
    @MainActor static func summary(a: PrivateProfileSnapshot, b: PrivateProfileSnapshot) throws {
        PrivateProfileStorage.select(a)
        let old = SummaryAdmissionProbe()
        PrivateProfileStorage.select(b)
        let locks = MeetingSummaryActivityCoordinator.shared.selectionLocks
        allActions(old)
        check(old.admittedEffects == 0, "Retained A commands cannot download, delete or process text under B")
        check(MeetingSummaryActivityCoordinator.shared.selectionLocks == locks,
              "Rejected old commands acquire no model selection lease")

        PrivateProfileStorage.select(a)
        let closed = SummaryAdmissionProbe()
        PrivateProfileStorage.closeAdmission()
        allActions(closed)
        check(closed.admittedEffects == 0, "A profile with closed admission cannot start any summary command")

        PrivateProfileStorage.select(try PrivateProfileStorage.proposed(context: a.context, generation: UUID(), legacyRootDirectory: a.legacyRootDirectory))
        allActions(old)
        check(old.admittedEffects == 0, "A new generation cannot revive a retained summary controller")
        let current = SummaryAdmissionProbe()
        allActions(current)
        check(current.admittedEffects == 4, "A current committed profile retains all four summary entry paths")
        current.busy = true
        allActions(current)
        check(current.admittedEffects == 4, "Existing busy admission remains in force")
        current.busy = false; current.model = nil
        current.download(); current.deleteModel(asr: ASRService())
        current.summarizeOnDevice(session: MeetingSession(), kind: .executive, thinking: false, asr: ASRService())
        check(current.admittedEffects == 4, "Missing local model still rejects local model operations")
    }
}
