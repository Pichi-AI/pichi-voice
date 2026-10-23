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

        for busy in [false, true] {
            for blockedMarker in [false, true] {
                try await checkPrivateProfileFailureJoins(root: root, context: context,
                    busy: busy, blockedMarker: blockedMarker, check: check)
            }
        }
        try await checkPrivateProfileCancelledJoins(root: root, context: context, check: check)
        try await checkPrivateProfileSourceFailure(root: root, context: context, check: check)
    }

    @MainActor private static func checkPrivateProfileFailureJoins(root: URL, context: AccountContext,
        busy: Bool, blockedMarker: Bool, check: (Bool, String) -> Void) async throws {
        let directory = root.appendingPathComponent("failure-joins-\(busy)-\(blockedMarker)")
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: directory)
        PrivateProfileStorage.select(guest)
        let markerDirectory = directory.appendingPathComponent("Profiles")
        var expectedMarkerFailure: NSError?
        if blockedMarker {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("synthetic marker obstruction".utf8).write(to: markerDirectory)
            do { try PrivateProfileStorage.persistAccessMarker(guest) }
            catch { expectedMarkerFailure = error as NSError }
            check(expectedMarkerFailure != nil, "Synthetic marker obstruction must exercise a real persistence failure")
        }
        let state = SyntheticProfileState()
        state.busy = busy
        let service = PrivateProfileService()
        let sourceGate = SyntheticProfileGate()
        try service.configure(isBusy: { state.busy }, prepare: {
            state.preparations += 1
            if state.gateSources { await sourceGate.wait() }
            if state.failSources { throw AccountError.credentialsUnavailable }
        },
            activate: { _ in state.activations += 1 })
        let first = SyntheticProfileParticipant {
            state.events.append("first")
            if state.failParticipants { throw AccountError.permissionDenied }
        }
        let participantGate = SyntheticProfileGate()
        let second = SyntheticProfileParticipant {
            state.events.append("second")
            if state.gateParticipants { await participantGate.wait() }
            state.events.append("second-joined")
            if state.failParticipants { throw AccountError.invalidResponse }
        }
        service.register(first)
        service.register(second)
        let stopID = UUID()
        service.installCaptureStopHandler(id: stopID) { state.stopRequests += 1 }
        let writeGate = SyntheticProfileGate()
        let workID = UUID()
        let write = Task {
            await writeGate.wait()
            state.writeFinished = true
            service.finishPrivateWrite(id: workID)
        }
        service.retainPrivateWrite(write, id: workID)
        await writeGate.waitUntilEntered()
        let sourceRevision = service.sourceRevision
        let transition = Task {
            defer { state.transitionFinished = true }
            try await service.transition(from: nil, to: busy ? nil : context, generation: UUID())
        }
        while PrivateProfileStorage.current.isReadable && !state.transitionFinished { await Task.yield() }
        check(!state.transitionFinished && !state.writeFinished && state.events.isEmpty,
            "A marker failure cannot return or start reader retirement before the retained write joins")
        check(service.isTransitioning && !service.isPrivateDataVisible && !PrivateProfileStorage.acceptsNewWork,
            "Normal transition and busy logout both close visibility, admission and overlapping cleanup")
        check(PrivateProfileStorage.current.id == guest.id && PrivateProfileStorage.current.generation == guest.generation
            && service.sourceRevision == sourceRevision,
            "Held cleanup cannot replace the original writer generation or publish another source")
        do {
            try await service.transition(from: nil, to: nil, generation: UUID())
            check(false, "A second transition cannot overlap a retained cleanup")
        } catch {
            check(error as? AccountError == .busy, "An overlapping cleanup is rejected by transition admission")
        }
        if busy { transition.cancel() }
        await writeGate.release()
        await participantGate.waitUntilEntered()
        check(!state.transitionFinished && state.writeFinished && state.events == ["first", "second"],
            "The first throwing participant cannot skip or outlive a later admitted reader join")
        await participantGate.release()
        if !busy {
            await sourceGate.waitUntilEntered()
            check(!state.transitionFinished && state.preparations == 1 && !service.isPrivateDataVisible
                && !PrivateProfileStorage.current.isReadable && service.sourceRevision == sourceRevision,
                "Normal cleanup must join held concrete private sources even after marker or participant failure")
            await sourceGate.release()
        }
        do { try await transition.value; check(false, "Joined cleanup must preserve its first failure") }
        catch {
            if let expectedMarkerFailure {
                let actual = error as NSError
                check(actual.domain == expectedMarkerFailure.domain && actual.code == expectedMarkerFailure.code,
                    "Marker failure stays authoritative after every participant is attempted")
            } else {
                check(error as? AccountError == .permissionDenied,
                    "The first participant failure stays authoritative after later participant failure")
            }
        }
        check(state.events == ["first", "second", "second-joined"] && !service.isTransitioning
            && !service.isPrivateDataVisible && !PrivateProfileStorage.current.isReadable
            && service.hasRetainedCaptureStopHandler
            && service.sourceRevision == sourceRevision && state.preparations == (busy ? 0 : 1)
            && state.activations == 0,
            "Failed cleanup joins concrete sources only outside active capture and cannot activate, publish or reopen a source")
        await service.requestCaptureStop()
        check(state.stopRequests == 1, "Failed cleanup retains the original local capture stop owner")
        if blockedMarker { try FileManager.default.removeItem(at: markerDirectory) }
        state.busy = false
        state.failParticipants = false
        state.gateParticipants = false
        state.failSources = false
        state.gateSources = false
        try await service.transition(from: nil, to: nil, generation: UUID())
        check(service.isPrivateDataVisible && PrivateProfileStorage.current.isGuest
            && PrivateProfileStorage.acceptsNewWork && service.sourceRevision != sourceRevision
            && state.preparations == (busy ? 1 : 2) && state.activations == 1 && first.calls == 2 && second.calls == 2,
            "An explicit retry rejoins the same readers and commits guest only after every failure is resolved")
        await service.requestCaptureStop()
        check(state.stopRequests == 1 && !service.hasRetainedCaptureStopHandler,
            "Only a successful source replacement releases the original capture stop owner")
    }

    @MainActor private static func checkPrivateProfileCancelledJoins(root: URL, context: AccountContext,
        check: (Bool, String) -> Void) async throws {
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(),
            legacyRootDirectory: root.appendingPathComponent("cancelled-joins"))
        PrivateProfileStorage.select(guest)
        let state = SyntheticProfileState()
        let service = PrivateProfileService()
        try service.configure(isBusy: { false }, prepare: { state.preparations += 1 },
            activate: { _ in state.activations += 1 })
        let writeGate = SyntheticProfileGate()
        let participantGate = SyntheticProfileGate()
        let participant = SyntheticProfileParticipant {
            if state.gateParticipants { await participantGate.wait() }
            state.events.append("joined")
        }
        service.register(participant)
        let workID = UUID()
        let write = Task { await writeGate.wait(); state.writeFinished = true; service.finishPrivateWrite(id: workID) }
        service.retainPrivateWrite(write, id: workID)
        await writeGate.waitUntilEntered()
        let sourceRevision = service.sourceRevision
        let transition = Task {
            defer { state.transitionFinished = true }
            try await service.transition(from: nil, to: context, generation: UUID())
        }
        while PrivateProfileStorage.current.isReadable && !state.transitionFinished { await Task.yield() }
        transition.cancel()
        check(!state.transitionFinished && !state.writeFinished && !PrivateProfileStorage.current.isReadable,
            "Cancellation cannot return before the retained original write joins")
        await writeGate.release()
        await participantGate.waitUntilEntered()
        check(!state.transitionFinished && state.writeFinished,
            "Cancellation cannot skip a participant that ignores cancellation until its reader joins")
        await participantGate.release()
        do { try await transition.value; check(false, "A canceled account transition cannot commit a source") }
        catch { check(error is CancellationError, "Joined cancellation preserves the cancellation failure") }
        check(state.events == ["joined"] && state.activations == 0 && !service.isPrivateDataVisible
            && !PrivateProfileStorage.current.isReadable && service.sourceRevision == sourceRevision,
            "Canceled joined cleanup stays concealed and does not publish or activate the next source")
        state.gateParticipants = false
        try await service.transition(from: nil, to: nil, generation: UUID())
        check(service.isPrivateDataVisible && PrivateProfileStorage.current.isGuest && participant.calls == 2,
            "A canceled transition permits an explicit joined guest cleanup retry")
    }

    @MainActor private static func checkPrivateProfileSourceFailure(root: URL, context: AccountContext,
        check: (Bool, String) -> Void) async throws {
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(),
            legacyRootDirectory: root.appendingPathComponent("source-failure"))
        PrivateProfileStorage.select(guest)
        let state = SyntheticProfileState()
        let service = PrivateProfileService()
        try service.configure(isBusy: { false }, prepare: {
            state.preparations += 1
            if state.failSources { throw AccountError.credentialsUnavailable }
        }, activate: { _ in state.activations += 1 })
        let sourceRevision = service.sourceRevision
        do { try await service.transition(from: nil, to: context, generation: UUID()); check(false, "Source failure must reject transition") }
        catch {
            check(error as? AccountError == .credentialsUnavailable && state.preparations == 1
                && state.activations == 0 && !service.isPrivateDataVisible && !PrivateProfileStorage.current.isReadable
                && service.sourceRevision == sourceRevision,
                "A concrete source failure remains authoritative when earlier cleanup succeeded")
        }
        state.failSources = false
        try await service.transition(from: nil, to: nil, generation: UUID())
        check(service.isPrivateDataVisible && PrivateProfileStorage.current.isGuest && state.preparations == 2
            && state.activations == 1, "A resolved concrete source failure allows explicit joined guest retry")
    }
}

@MainActor private final class SyntheticProfileState {
    var busy = false
    var preparations = 0
    var activations = 0
    var failParticipants = true
    var gateParticipants = true
    var failSources = true
    var gateSources = true
    var transitionFinished = false
    var writeFinished = false
    var stopRequests = 0
    var events: [String] = []
}

@MainActor private final class SyntheticProfileParticipant: PrivateProfileTransitionParticipant {
    private let action: @MainActor () async throws -> Void
    private(set) var calls = 0
    init(action: @escaping @MainActor () async throws -> Void) { self.action = action }
    func prepareForPrivateProfileTransition() async throws {
        calls += 1
        try await action()
    }
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
