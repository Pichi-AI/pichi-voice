// Compiled only inside the source-projected fixture with its existing inert doubles.
@MainActor
enum ClipboardTargetBackupFixtureTests {
    static func run(check: (Bool, String) -> Void) async {
        let a = SyntheticAXElement("A", pid: 42)
        let b = SyntheticAXElement("B", pid: 42)
        let target = TypingService.CapturedFocusTarget(pid: 42, window: nil, element: a)
        let scenarios: [(name: String, newerCopy: String?, keepOlderBackup: Bool, cancelled: Bool, expectedText: String, expectedCopies: Int)] = [
            ("newer user copy", "newer user copy", false, false, "newer user copy", 0),
            ("owned restoration", nil, false, false, "pending backup", 1),
            ("owned intentional copy", nil, true, false, "pending backup", 2),
            ("cancelled output", "newer cancellation copy", false, true, "newer cancellation copy", 0),
        ]

        for scenario in scenarios {
            TypingFocusIdentityRegression.reset(a)
            let coordinator = PasteDeliveryCoordinator.shared
            let held = await coordinator.deliver("older owned payload", preserveTranscriptOnClipboard: scenario.keepOlderBackup)
            check(held == .commandPosted && coordinator.fixtureHasLease,
                  "Backup ownership scenario must begin with an actual held lease: \(scenario.name)")
            syntheticAX.values = [:]
            syntheticAX.insertions = []
            let requestedChangeCount = syntheticPasteboard.changeCount
            var valid = true
            let pending = Task { @MainActor in
                await coordinator.deliver(
                    "pending backup",
                    preserveTranscriptOnClipboard: true,
                    isOutputValid: { valid },
                    targetIsReady: { TypingService.isExactFocusTargetActive(target) }
                )
            }
            await TypingFocusIdentityRegression.waitUntil { coordinator.fixtureWaiterCount == 1 }
            if let newerCopy = scenario.newerCopy { syntheticPasteboard.simulateExternalCopy(newerCopy) }
            syntheticAX.focus = b
            if scenario.cancelled {
                valid = false
                pending.cancel()
            }
            coordinator.runPendingSettlementForTesting()
            let settledChangeCount = syntheticPasteboard.changeCount
            let result = await pending.value
            check(result == (scenario.cancelled ? .cancelled : .recoverableFailure(.targetUnavailable)),
                  "Lost target and cancellation retain their result contracts: \(scenario.name)")
            check(syntheticPasteboard.text == scenario.expectedText,
                  "A failed queued target must preserve a newer user copy and admit only owned backup: \(scenario.name); actual clipboard: \(syntheticPasteboard.text)")
            check(syntheticPasteboard.intentionalWriteCount == scenario.expectedCopies,
                  "Only admitted owned backups may write intentionally: \(scenario.name)")
            check(syntheticPoster.postCount == 1 && syntheticPasteboard.temporaryWriteCount == 1 && syntheticAX.insertions.isEmpty,
                  "A failed or cancelled target never dispatches into B or creates another temporary item: \(scenario.name)")
            check(!syntheticPasteboard.isTemporary && !coordinator.fixtureHasLease && !coordinator.fixtureIsDelivering && coordinator.fixtureWaiterCount == 0,
                  "Failed queued backup releases clipboard and waiter ownership: \(scenario.name)")
            if scenario.newerCopy == nil {
                check(settledChangeCount != requestedChangeCount,
                      "Owned settlement must change the count so last-written admission is exercised: \(scenario.name)")
            }

            let healthy = await coordinator.deliver("healthy next payload", preserveTranscriptOnClipboard: false)
            check(healthy == .commandPosted && syntheticAX.values["B"] == "healthy next payload",
                  "A healthy subsequent delivery must acquire and use the released slot: \(scenario.name)")
            coordinator.runPendingSettlementForTesting()
            check(syntheticPasteboard.text == scenario.expectedText && !coordinator.fixtureIsDelivering && !coordinator.fixtureHasLease && coordinator.fixtureWaiterCount == 0,
                  "Healthy subsequent settlement restores the preserved clipboard: \(scenario.name)")
        }

        TypingFocusIdentityRegression.reset(b)
        let coordinator = PasteDeliveryCoordinator.shared
        let immediate = await coordinator.deliver(
            "immediate requested backup",
            preserveTranscriptOnClipboard: true,
            targetIsReady: { TypingService.isExactFocusTargetActive(target) }
        )
        check(immediate == .recoverableFailure(.targetUnavailable) && syntheticPasteboard.text == "immediate requested backup",
              "An unchanged requested clipboard admits backup even without an older lease")
        check(syntheticPoster.postCount == 0 && syntheticPasteboard.intentionalWriteCount == 1 && !coordinator.fixtureIsDelivering,
              "Immediate target failure keeps backup without posting or retaining its slot")
    }
}
