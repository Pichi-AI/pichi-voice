import Foundation

extension MeetingSessionStoreCheckpointTests {
    @MainActor static func checkPrivateProfileOperationOwner(root: URL, check: (Bool, String) -> Void) async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(profile)
        let owner = PrivateProfileOperationOwner()
        check(try await owner.perform { 7 } == 7, "Current profile can use its existing async operation")
        let gate = PrivateOperationTestGate()
        var started = false
        let operation = Task { @MainActor in
            try await owner.perform {
                started = true
                await gate.wait()
                // A copy can finish with a recoverable failure after logout concealed its source.
                return false
            }
        }
        while !started { await Task.yield() }
        PrivateProfileStorage.conceal(generation: UUID())
        check(!owner.isCurrent, "Conceal immediately invalidates operation publication")
        var joined = false
        let retirement = Task { @MainActor in await owner.retireAndJoin(); joined = true }
        for _ in 0..<10 { await Task.yield() }
        check(!joined, "Retirement waits for an operation that ignores cancellation")
        gate.open()
        await retirement.value
        check(joined, "Retirement joins the concrete operation before returning")
        do { _ = try await operation.value; check(false, "Retired copy failure must not reach fallback presentation") }
        catch { check(true, "Held copy failure is discarded after conceal and joined cancellation") }
        PrivateProfileStorage.select(profile)
        check(!owner.isCurrent, "An old controller cannot revive on the same profile")
        do { _ = try await owner.perform { 9 }; check(false, "Retired controller cannot admit work") }
        catch { check(true, "Retired controller remains closed") }
        let fresh = PrivateProfileOperationOwner()
        check(try await fresh.perform { 11 } == 11, "A new source controller admits fresh work")
        await fresh.retireAndJoin()
    }
}

@MainActor private final class PrivateOperationTestGate {
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
