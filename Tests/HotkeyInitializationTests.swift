import Foundation

nonisolated final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()
    private let lock = NSLock()
    private var storage: [String] = []
    var entries: [String] { self.lock.lock(); defer { self.lock.unlock() }; return self.storage }
    func clear() { self.lock.lock(); defer { self.lock.unlock() }; self.storage = [] }
    func debug(_ text: String, source: String) { self.record(text) }
    func info(_ text: String, source: String) { self.record(text) }
    func warning(_ text: String, source: String) { self.record(text) }
    func error(_ text: String, source: String) { self.record(text) }
    private func record(_ text: String) { self.lock.lock(); defer { self.lock.unlock() }; self.storage.append(text) }
}

@MainActor enum HotkeyInitializationTestClock {
    struct Wait {
        let id: UUID
        let nanoseconds: UInt64
        let continuation: CheckedContinuation<Void, Error>
    }
    static var waits: [Wait] = []
    static var durations: [UInt64] = []
    static var cooperatesWithCancellation = false

    static func sleep(nanoseconds: UInt64) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            if self.cooperatesWithCancellation { try Task.checkCancellation() }
            try await withCheckedThrowingContinuation { continuation in
                self.durations.append(nanoseconds)
                self.waits.append(.init(id: id, nanoseconds: nanoseconds, continuation: continuation))
            }
        } onCancel: {
            Task { @MainActor in
                if self.cooperatesWithCancellation,
                   let index = self.waits.firstIndex(where: { $0.id == id }) {
                    self.waits.remove(at: index).continuation.resume(throwing: CancellationError())
                }
            }
        }
    }
    static func release(_ id: UUID) {
        let index = self.waits.firstIndex { $0.id == id }!
        self.waits.remove(at: index).continuation.resume()
    }
    static func releaseAll() {
        let pending = self.waits
        self.waits = []
        for wait in pending { wait.continuation.resume() }
    }
    static func reset() {
        precondition(self.waits.isEmpty, "Every prior owner must have drained its test waits")
        self.durations = []
        self.cooperatesWithCancellation = false
        DebugLogger.shared.clear()
    }
}

@main @MainActor struct HotkeyInitializationTests {
    static var checks = 0
    static func check(_ condition: @autoclosure () -> Bool, _ message: String) {
        self.checks += 1
        precondition(condition(), message)
    }
    static func settle() async { for _ in 0..<100 { await Task.yield() } }
    static func waitUntil(_ condition: () -> Bool) async {
        for _ in 0..<10_000 {
            if condition() { return }
            await Task.yield()
        }
        preconditionFailure("The production task failed to reach the expected deterministic boundary")
    }
    static func finish(_ manager: GlobalHotkeyManager) async {
        let initial = manager.initializationTask
        let health = manager.healthCheckTask
        initial?.cancel()
        health?.cancel()
        for _ in 0..<3 {
            HotkeyInitializationTestClock.releaseAll()
            await self.settle()
        }
        await initial?.value
        await health?.value
        self.check(HotkeyInitializationTestClock.waits.isEmpty, "No retry or health wait survives cancellation")
    }

    static func testMaximumAttemptsAndImmediateTapRecovery() async {
        HotkeyInitializationTestClock.reset()
        let manager = GlobalHotkeyManager()
        manager.setupGlobalHotkeyWithRetry() // actual tap-disabled recovery entry point
        await self.waitUntil { !HotkeyInitializationTestClock.waits.isEmpty }
        for _ in 0..<5 {
            guard let wait = HotkeyInitializationTestClock.waits.first else { break }
            HotkeyInitializationTestClock.release(wait.id)
            await self.settle()
        }
        self.check(manager.setupCount == 5, "Retries must stop at five setup calls; actual \(manager.setupCount); attempts: \(DebugLogger.shared.entries.filter { $0.hasPrefix("Setup attempt") })")
        self.check(DebugLogger.shared.entries.filter { $0.hasPrefix("Setup attempt") } == (1...5).map { "Setup attempt \($0)/5" },
                   "One attempt sequence must advance 1..5 without recursion/reset")
        self.check(HotkeyInitializationTestClock.durations == [UInt64](repeating: 500_000_000, count: 4),
                   "Tap recovery starts immediately and waits only between its five attempts")
        self.check(!manager.isInitialized && manager.healthCheckTask == nil, "Exhaustion must not claim ready or start health work")
        self.check(DebugLogger.shared.entries.filter { $0 == "Failed to initialize after 5 attempts" }.count == 1,
                   "Terminal exhaustion must be emitted exactly once")
        await self.finish(manager)
    }

    static func testEventualSuccessAndHealthRecovery() async {
        HotkeyInitializationTestClock.reset()
        let manager = GlobalHotkeyManager()
        manager.onSetup = { $0.setupCount == 3 }
        manager.setupGlobalHotkeyWithRetry()
        await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
        for _ in 0..<2 {
            HotkeyInitializationTestClock.release(HotkeyInitializationTestClock.waits[0].id)
            await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
        }
        self.check(manager.setupCount == 3 && manager.isInitialized, "The successful third attempt commits readiness")
        self.check(HotkeyInitializationTestClock.durations == [500_000_000, 500_000_000, 30_000_000_000],
                   "Success stops retries and starts the existing 30-second health schedule")
        self.check(DebugLogger.shared.entries.filter { $0.contains("Successfully initialized") }.count == 1,
                   "Only one successful attempt starts the health owner")
        manager.onSetup = nil
        manager.tapHealthy = false
        manager.setupResult = true
        HotkeyInitializationTestClock.release(HotkeyInitializationTestClock.waits[0].id)
        await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
        self.check(manager.setupCount == 4 && manager.isInitialized, "Current health check still recovers a disabled tap")
        manager.tapHealthy = true
        HotkeyInitializationTestClock.release(HotkeyInitializationTestClock.waits[0].id)
        await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
        self.check(manager.recoverMouseCount == 1, "Healthy tap checks preserve mouse-tap recovery")
        await self.finish(manager)
    }

    static func testCancellationDuringInitialOrRetryWait() async {
        for cooperative in [false, true] {
        for initialWait in [true, false] {
            HotkeyInitializationTestClock.reset()
            HotkeyInitializationTestClock.cooperatesWithCancellation = cooperative
            let manager = GlobalHotkeyManager()
            if initialWait { manager.initializeWithDelay() } else { manager.setupGlobalHotkeyWithRetry() }
            await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
            let setupBefore = manager.setupCount
            let task = manager.initializationTask!
            task.cancel()
            if cooperative { await self.waitUntil { HotkeyInitializationTestClock.waits.isEmpty } }
            else { HotkeyInitializationTestClock.release(HotkeyInitializationTestClock.waits[0].id) }
            await task.value
            self.check(manager.setupCount == setupBefore, "Cancellation stops setup even if the scheduler resumes normally")
            self.check(!manager.isInitialized && manager.healthCheckTask == nil, "A canceled wait cannot commit ready or health state")
            self.check(HotkeyInitializationTestClock.waits.isEmpty, "The same owned task includes the retry wait")
            await self.finish(manager)
        }
        }
    }

    static func testFailedTapRecoveryPreservesHealthMonitoring() async {
        HotkeyInitializationTestClock.reset()
        let manager = GlobalHotkeyManager()
        manager.setupResult = true
        manager.setupGlobalHotkeyWithRetry()
        await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
        let staleHealth = manager.healthCheckTask!
        let staleWait = HotkeyInitializationTestClock.waits[0].id
        manager.setupResult = false
        manager.setupGlobalHotkeyWithRetry()
        await self.waitUntil { HotkeyInitializationTestClock.waits.contains { $0.nanoseconds == 500_000_000 } }
        for _ in 0..<4 {
            let retry = HotkeyInitializationTestClock.waits.first { $0.nanoseconds == 500_000_000 }!
            HotkeyInitializationTestClock.release(retry.id)
            await self.settle()
        }
        self.check(manager.setupCount == 6 && !manager.isInitialized, "An established tap recovery still stops after five failed attempts")
        self.check(staleHealth.isCancelled, "The stale health owner is replaced with the current generation")
        HotkeyInitializationTestClock.release(staleWait)
        await staleHealth.value
        self.check(HotkeyInitializationTestClock.waits.count == 1 && HotkeyInitializationTestClock.waits[0].nanoseconds == 30_000_000_000,
                   "Exhaustion retains the established health recovery schedule")
        manager.setupResult = true
        manager.tapHealthy = false
        HotkeyInitializationTestClock.release(HotkeyInitializationTestClock.waits[0].id)
        await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
        self.check(manager.setupCount == 7 && manager.isInitialized, "The current health owner can recover after the retry budget is exhausted")
        await self.finish(manager)
    }

    static func testReinitializeWhileOldRetrySleeps() async {
        HotkeyInitializationTestClock.reset()
        let manager = GlobalHotkeyManager()
        manager.setupGlobalHotkeyWithRetry()
        await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
        let staleWait = HotkeyInitializationTestClock.waits[0].id
        let staleTask = manager.initializationTask!
        let staleGeneration = manager.initializationGeneration
        manager.setupResult = true
        manager.reinitialize()
        await self.waitUntil { HotkeyInitializationTestClock.waits.count == 2 }
        self.check(staleTask.isCancelled && manager.initializationGeneration != staleGeneration, "Restart invalidates the whole prior retry owner")
        self.check(manager.resetCount == 1 && !manager.isInitialized, "Existing modifier reset and ready reset are preserved")
        let currentWait = HotkeyInitializationTestClock.waits.first { $0.id != staleWait }!.id
        HotkeyInitializationTestClock.release(currentWait)
        await self.waitUntil { manager.isInitialized }
        let calls = manager.setupCount
        HotkeyInitializationTestClock.release(staleWait)
        await staleTask.value
        self.check(manager.setupCount == calls && manager.isInitialized, "Stale retry cannot reinstall a tap or overwrite current readiness")
        self.check(HotkeyInitializationTestClock.waits.count == 1 && HotkeyInitializationTestClock.waits[0].nanoseconds == 30_000_000_000,
                   "Only the current generation's health timer remains")
        await self.finish(manager)
    }

    static func testReentrancyDuringSetupAndHealth() async {
        for health in [false, true] {
            HotkeyInitializationTestClock.reset()
            let manager = GlobalHotkeyManager()
            manager.setupResult = true
            manager.setupGlobalHotkeyWithRetry()
            await self.waitUntil { manager.isInitialized }
            await self.waitUntil { HotkeyInitializationTestClock.waits.contains { $0.nanoseconds == 30_000_000_000 } }
            let originalGeneration = manager.initializationGeneration
            if health {
                manager.onValidate = { current in current.onValidate = nil; current.reinitialize(); return false }
                let calls = manager.setupCount
                HotkeyInitializationTestClock.release(HotkeyInitializationTestClock.waits[0].id)
                await self.waitUntil { manager.initializationGeneration != originalGeneration }
                await self.settle()
                self.check(manager.setupCount == calls, "Reentrant health restart must not call stale setup after validation")
            } else {
                manager.onSetup = { current in current.onSetup = nil; current.reinitialize(); return true }
                manager.setupGlobalHotkeyWithRetry()
                await self.waitUntil { manager.initializationGeneration != originalGeneration && !manager.isInitialized }
                await self.settle()
            }
            self.check(!manager.isInitialized, "Reentrant setup success cannot commit readiness for its stale generation")
            self.check(HotkeyInitializationTestClock.waits.contains { $0.nanoseconds == 1_500_000_000 }, "Reentrant manual restart preserves delayed admission")
            self.check(DebugLogger.shared.entries.filter { $0.contains("Successfully initialized") }.count == 1,
                       "Stale setup must not start another health owner")
            await self.finish(manager)
        }
    }

    static func testTeardownDoesNotRetainRetryOwner() async {
        for cooperative in [false, true] {
            HotkeyInitializationTestClock.reset()
            HotkeyInitializationTestClock.cooperatesWithCancellation = cooperative
            var manager: GlobalHotkeyManager? = GlobalHotkeyManager()
            weak let weakManager = manager
            manager?.setupGlobalHotkeyWithRetry()
            await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
            let task = manager!.initializationTask!
            manager = nil
            self.check(weakManager == nil, "Retry waiting must not retain the manager and postpone its deinit")
            self.check(task.isCancelled, "Actual production deinit cancels the retained initialization owner")
            await self.settle()
            HotkeyInitializationTestClock.releaseAll()
            await task.value
            self.check(HotkeyInitializationTestClock.waits.isEmpty, "Teardown leaves no continuing retry")
        }
    }

    static func testGenerationInvalidationIndependentlyOfCancellation() async {
        for phase in 0...2 {
            HotkeyInitializationTestClock.reset()
            let manager = GlobalHotkeyManager()
            manager.setupResult = true
            if phase == 0 {
                manager.initializeWithDelay()
                await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
                let old = manager.initializationTask!
                manager.initializationGeneration = UUID()
                self.check(!old.isCancelled, "Generation ownership is tested independently of Task cancellation")
                HotkeyInitializationTestClock.release(HotkeyInitializationTestClock.waits[0].id)
                await old.value
                self.check(manager.setupCount == 0 && !manager.isInitialized && manager.healthCheckTask == nil,
                           "Invalidated initial admission cannot install a tap or publish readiness")
            } else if phase == 1 {
                manager.onSetup = { current in current.initializationGeneration = UUID(); return true }
                manager.setupGlobalHotkeyWithRetry()
                await manager.initializationTask?.value
                self.check(manager.setupCount == 1 && !manager.isInitialized && manager.healthCheckTask == nil,
                           "A setup result can only commit under the generation that admitted it")
            } else {
                manager.setupGlobalHotkeyWithRetry()
                await self.waitUntil { HotkeyInitializationTestClock.waits.count == 1 }
                let old = manager.healthCheckTask!
                manager.initializationGeneration = UUID()
                manager.tapHealthy = false
                self.check(!old.isCancelled, "Stale health ownership is also tested without cancel flags")
                HotkeyInitializationTestClock.release(HotkeyInitializationTestClock.waits[0].id)
                await old.value
                self.check(manager.setupCount == 1 && manager.isInitialized && HotkeyInitializationTestClock.waits.isEmpty,
                           "An invalidated health callback cannot reinstall taps, rewrite state or reschedule itself")
            }
            await self.finish(manager)
        }
    }

    static func main() async {
        await self.testMaximumAttemptsAndImmediateTapRecovery()
        await self.testEventualSuccessAndHealthRecovery()
        await self.testCancellationDuringInitialOrRetryWait()
        await self.testFailedTapRecoveryPreservesHealthMonitoring()
        await self.testReinitializeWhileOldRetrySleeps()
        await self.testReentrancyDuringSetupAndHealth()
        await self.testTeardownDoesNotRetainRetryOwner()
        await self.testGenerationInvalidationIndependentlyOfCancellation()
        print("Hotkey initialization: \(self.checks) checks passed; production lifecycle/real Task cancellation, maximum 5/eventual success/restart/reentrancy/deinit; no event taps, permissions, UI or hardware")
    }
}
