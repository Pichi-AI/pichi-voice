import Foundation

extension MeetingSessionStoreCheckpointTests {
    @MainActor static func checkPrivateProfileLifecycle(root: URL, check: (Bool, String) -> Void) async throws {
        let original = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(original) }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        let state = SyntheticProfileState()
        let service = PrivateProfileService()
        let identity = AccountIdentity(issuer: "https://synthetic.invalid", subject: UUID().uuidString, internalUserID: "synthetic")
        let context = AccountContext(identity: identity, organizationID: nil, workspaceID: nil, generation: UUID())
        try service.configure(isBusy: { state.busy }, prepare: { state.preparations += 1 }, activate: { _ in state.activations += 1 })
        state.busy = true
        do { try await service.transition(from: nil, to: context, generation: context.generation); check(false, "Capture must refuse account switch") }
        catch { check(PrivateProfileStorage.current.isGuest, "Refused capture switch preserves selected guest source") }
        state.busy = false
        try await service.transition(from: nil, to: context, generation: context.generation)
        check(PrivateProfileStorage.current.context == context && service.isPrivateDataVisible,
            "Successful joined transition selects only the verified context")
        check(state.preparations == 1 && state.activations == 1, "One profile participant owns prepare and activation")
        state.busy = true
        do { try await service.transition(from: context, to: nil, generation: UUID()); check(false, "Active logout must preserve local writer") }
        catch {
            check(!service.isPrivateDataVisible && !PrivateProfileStorage.current.isReadable,
                "Logout immediately conceals account reads while active local capture remains owned")
            check(PrivateProfileStorage.current.context == context, "Busy logout cannot select the next person or retarget capture")
            check(!service.isAccountIsolationReady && !PrivateProfileStorage.acceptsNewWork,
                "Unfinished logout cannot admit new account/private operations")
        }
        state.busy = false
        try await service.transition(from: nil, to: nil, generation: UUID())
        check(PrivateProfileStorage.current.isGuest && service.isPrivateDataVisible,
            "Offline guest cleanup retry completes after original capture drains")

        let gate = SyntheticProfileGate()
        let workID = UUID()
        let write = Task { await gate.wait(); service.finishPrivateWrite(id: workID) }
        service.retainPrivateWrite(write, id: workID)
        let switchTask = Task { try await service.transition(from: nil, to: context, generation: UUID()) }
        await gate.waitUntilEntered()
        await Task.yield()
        check(PrivateProfileStorage.current.isGuest && !PrivateProfileStorage.current.isReadable,
            "Scope replacement waits for the admitted original writer and denies reads meanwhile")
        await gate.release()
        try await switchTask.value
        check(PrivateProfileStorage.current.context == context && service.isPrivateDataVisible,
            "Drained original writer permits atomic source replacement")

        let activationGate = SyntheticProfileGate()
        let canceledService = PrivateProfileService()
        try canceledService.configure(isBusy: { false }, prepare: {}, activate: { _ in await activationGate.wait() })
        let canceled = Task { try await canceledService.transition(from: context, to: context, generation: UUID()) }
        await activationGate.waitUntilEntered()
        canceled.cancel()
        await activationGate.release()
        do { try await canceled.value; check(false, "Canceled transition may not publish account readiness") }
        catch {
            check(!canceledService.isPrivateDataVisible && !PrivateProfileStorage.current.isReadable,
                "Cancellation after ignored activation cannot publish a readable account or marker")
        }
        let blockedRoot = root.appendingPathComponent("blocked-marker")
        try FileManager.default.createDirectory(at: blockedRoot, withIntermediateDirectories: true)
        try Data("synthetic obstruction".utf8).write(to: blockedRoot.appendingPathComponent("Profiles"))
        let blockedGuest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: blockedRoot)
        PrivateProfileStorage.select(blockedGuest)
        let failedMarker = PrivateProfileService()
        try failedMarker.configure(isBusy: { true }, prepare: {}, activate: { _ in })
        let priorRevision = failedMarker.sourceRevision
        do { try await failedMarker.transition(from: nil, to: nil, generation: UUID()); check(false, "Marker obstruction must fail cleanup") }
        catch {
            check(!PrivateProfileStorage.current.isReadable && !failedMarker.isPrivateDataVisible
                && failedMarker.sourceRevision == priorRevision,
                "Failed busy-logout marker cannot leave memory readable or commit another source")
        }
    }
}

@MainActor private final class SyntheticProfileState {
    var busy = false
    var preparations = 0
    var activations = 0
}

private actor SyntheticProfileGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        for waiter in entryWaiters { waiter.resume() }; entryWaiters.removeAll()
        await withCheckedContinuation { releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if !entered { await withCheckedContinuation { entryWaiters.append($0) } }
    }
    func release() { releaseWaiter?.resume(); releaseWaiter = nil }
}
