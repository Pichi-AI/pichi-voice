import Foundation

private actor Loader {
    var ready = false
    var installed = true
    var loads = 0
    var installedChecks = 0
    var explicitInstallations = 0
    var unloads = 0
    var active = 0
    var maximumActive = 0
    var failNext = false
    private var blocked: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []

    init(blocked: Bool = false, installed: Bool = true) {
        self.blocked = blocked; self.installed = installed
    }
    func load(installedOnly: Bool) async throws -> Bool {
        installedChecks += 1
        if installedOnly && !installed { return false }
        if !installed { explicitInstallations += 1; installed = true }
        loads += 1; active += 1; maximumActive = max(maximumActive, active)
        defer { active -= 1 }
        if blocked { await withCheckedContinuation { waiters.append($0) } }
        if failNext { failNext = false; throw URLError(.cannotOpenFile) }
        // Deliberately ignores cancellation, as a native model load may do.
        ready = true
        return true
    }
    func unblock() {
        blocked = false
        let pending = waiters; waiters = []
        pending.forEach { $0.resume() }
    }
    func unload() { ready = false; unloads += 1 }
    func markFailure() { failNext = true }
    func counts() -> (loads: Int, unloads: Int, installs: Int, active: Int, maximum: Int) {
        (loads, unloads, explicitInstallations, active, maximumActive)
    }
}

private actor Completion {
    var finished = false
    func finish() { finished = true }
}

/// Suspends exactly one readiness call after it has captured the runtime's Boolean.
/// This exposes an unload that fully finishes while that stale snapshot is in flight.
private actor ReadinessSnapshotGate {
    private var shouldHold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHolding: Bool { continuation != nil }
    func arm() { shouldHold = true }
    func snapshot(_ ready: Bool) async -> Bool {
        if shouldHold {
            shouldHold = false
            await withCheckedContinuation { continuation = $0 }
        }
        return ready
    }
    func resume() { let prior = continuation; continuation = nil; prior?.resume() }
}

@MainActor final class IdleSceneRestoreProbe {
    var entered = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func finish() { continuation?.resume(); continuation = nil }
}
@MainActor final class IdleSceneCoordinatorProbe {
    let restore = IdleSceneRestoreProbe()
    func ensureRestored() async { await restore.wait() }
    func sweepExpiredAudio() async {}
}
@MainActor final class IdleScenePrivacyActivationProbe {
    var restores = 0
    func restore() { restores += 1 }
}
@MainActor final class IdleSceneRequiredResourcesProbe {
    var requests = 0
    func prepare(modelID: String) async throws { requests += 1 }
}
struct IdleSceneSettingsProbe {
    struct Model { let rawValue = "synthetic-model" }
    let selectedSpeechModel = Model()
}
@MainActor final class IdleSceneHostProbe {
    let meetingSessionCoordinator = IdleSceneCoordinatorProbe()
    let privacyActivation = IdleScenePrivacyActivationProbe()
    let requiredResources = IdleSceneRequiredResourcesProbe()
    let settings = IdleSceneSettingsProbe()
    var requiredPreparationTask: Task<Void, Never>?
    var isUIReady = false
    var hasRestoredInitialState = false
    var isSceneActive = false
    var preparations = 0
    lazy var controller = MeetingIdlePreparationController<UUID>(prepare: { [weak self] in
        await MainActor.run { self?.preparations += 1 }
        return UUID()
    }, release: { _ in })
    func updateIdlePreparation() async {
        await controller.update(.init(isSceneActive: isSceneActive, isUIReady: isUIReady && hasRestoredInitialState,
            preparationEnabled: true, configurationIdentity: "scene-lifecycle", hasRecordingActivity: false, hasOtherModelWork: false))
    }
}

@main
struct PrivacyIdlePreparationTests {
    private static var assertions = 0
    private static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        precondition(condition, message)
    }
    private static func owner(_ loader: Loader) -> PichiPrivacyPreparationOwner {
        PichiPrivacyPreparationOwner(isReady: { await loader.ready },
            load: { installedOnly, _ in try await loader.load(installedOnly: installedOnly) },
            unload: { await loader.unload() })
    }
    private static func until(_ condition: () async -> Bool) async {
        for _ in 0..<20_000 {
            if await condition() { return }
            await Task.yield()
        }
        preconditionFailure("A bounded asynchronous test did not reach its checkpoint")
    }
    private static func settle() async { for _ in 0..<100 { await Task.yield() } }
    private static func cancelled<T>(_ task: Task<T, Error>) async {
        do { _ = try await task.value; preconditionFailure("Expected cancellation") }
        catch { check(error is CancellationError, "Cancellation must remain explicit") }
    }
    @MainActor
    private static func controller(_ owner: PichiPrivacyPreparationOwner) -> MeetingIdlePreparationController<PichiPrivacyPreparationOwner.IdleToken> {
        .init(prepare: { try await owner.prepareInstalledForIdle() }, release: { await owner.releaseIdle($0) })
    }
    @MainActor
    private static func input(active: Bool = true, identity: String = "a1/one", recording: Bool = false,
                              otherWork: Bool = false, enabled: Bool = true) -> MeetingIdlePreparationController<PichiPrivacyPreparationOwner.IdleToken>.Input {
        .init(isSceneActive: active, isUIReady: true, preparationEnabled: enabled,
              configurationIdentity: identity, hasRecordingActivity: recording, hasOtherModelWork: otherWork)
    }

    @MainActor
    static func main() async throws {
        // The initial view task captures an inactive phase while restore is suspended.
        // A later actual foreground event must remain authoritative after restore joins.
        // Both host methods and the task's service calls are extracted from MobileApp.
        do {
            let host = IdleSceneHostProbe()
            let initial = Task { await runInitialMobileTask(services: host, capturedSceneActive: false) }
            await until { await MainActor.run { host.meetingSessionCoordinator.restore.entered } }
            await host.setSceneActive(true)
            host.meetingSessionCoordinator.restore.finish()
            await initial.value
            check(host.isSceneActive, "An initial task's captured inactive scene cannot overwrite a newer active event")
            await until { await MainActor.run { host.preparations == 1 } }
            check(mobileSceneUsesInitialCallback, "One scene callback must supply both initial and later phases")
            check(host.hasRestoredInitialState && host.preparations == 1, "Foreground preparation starts once after restoration joins")
            await host.controller.shutdown()
        }
        // Readiness is a resource-generation snapshot, not a promise that remains true
        // after an owner-controlled unload completes while the callback is suspended.
        do {
            let loader = Loader(), gate = ReadinessSnapshotGate()
            let owner = PichiPrivacyPreparationOwner(isReady: { await gate.snapshot(loader.ready) },
                load: { installedOnly, _ in try await loader.load(installedOnly: installedOnly) },
                unload: { await loader.unload() })
            let token = try await owner.prepareInstalledForIdle()!
            await gate.arm()
            let recording = Task { try await owner.prepare() }
            await until { await gate.isHolding }
            await owner.releaseIdle(token)
            check(await !loader.ready, "The regression must actually unload the old idle resource")
            await gate.resume(); try await recording.value
            let ready = await loader.ready, c = await loader.counts()
            check(ready && c.loads == 2, "Record must reject a stale true snapshot and reload the current resource")
            try await owner.unload()
        }
        do {
            let loader = Loader(), gate = ReadinessSnapshotGate()
            let owner = PichiPrivacyPreparationOwner(isReady: { await gate.snapshot(loader.ready) },
                load: { installedOnly, _ in try await loader.load(installedOnly: installedOnly) },
                unload: { await loader.unload() })
            let token = try await owner.prepareInstalledForIdle()!
            await gate.arm()
            let replacement = Task { try await owner.prepareInstalledForIdle() }
            await until { await gate.isHolding }
            await owner.releaseIdle(token)
            await gate.resume()
            guard let nextToken = try await replacement.value else { preconditionFailure("Idle must recheck the retired readiness generation") }
            check(await loader.counts().loads == 2, "Installed-only readiness cannot accept a retired true snapshot")
            await owner.releaseIdle(nextToken)
        }
        do {
            let loader = Loader(), gate = ReadinessSnapshotGate()
            let owner = PichiPrivacyPreparationOwner(isReady: { await gate.snapshot(loader.ready) },
                load: { installedOnly, _ in try await loader.load(installedOnly: installedOnly) },
                unload: { await loader.unload() })
            await gate.arm()
            let idle = Task { try await owner.prepareInstalledForIdle() }
            await until { await gate.isHolding }
            try await owner.prepare()
            await gate.resume()
            let token = try await idle.value, c = await loader.counts()
            check(token == nil && c.loads == 1, "A stale false snapshot cannot reload an already adopted resource")
            try await owner.unload()
        }
        // A completed warm resource is transferred, never reopened or unloaded by an old token.
        do {
            let loader = Loader(), owner = owner(loader)
            let token = try await owner.prepareInstalledForIdle()!
            try await owner.prepare()
            await owner.releaseIdle(token)
            let c = await loader.counts()
            check(c.loads == 1 && c.unloads == 0 && c.installs == 0, "Ready adoption must keep the same loaded model")
            try await owner.unload()
        }
        // Recording and Settings can join an in-flight idle load; the cancelled idle waiter
        // has no authority to cancel or unload their adopted operation.
        do {
            let loader = Loader(blocked: true), owner = owner(loader)
            let idle = Task { try await owner.prepareInstalledForIdle() }
            await until { await loader.counts().active == 1 }
            let recording = Task { try await owner.prepare() }
            let settings = Task { try await owner.prepare() }
            await settle()
            idle.cancel()
            await loader.unblock()
            try await recording.value; try await settings.value
            await cancelled(idle)
            let c = await loader.counts()
            check(c.loads == 1 && c.unloads == 0, "One actual load must serve idle, Record and Settings")
            try await owner.unload()
        }
        // Cancelling one Settings waiter cannot cancel a concurrent recording waiter.
        do {
            let loader = Loader(blocked: true), owner = owner(loader)
            let settings = Task { try await owner.prepare() }
            await until { await loader.counts().active == 1 }
            let recording = Task { try await owner.prepare() }
            await settle()
            settings.cancel()
            await loader.unblock()
            try await recording.value
            await cancelled(settings)
            let c = await loader.counts()
            check(c.loads == 1 && c.unloads == 0, "A cancelled waiter must preserve the other caller's ready model")
            try await owner.unload()
        }
        // Idle cancellation joins even a non-cooperative native load and releases its late result.
        do {
            let loader = Loader(blocked: true), owner = owner(loader), completion = Completion()
            let idle = Task { () throws -> PichiPrivacyPreparationOwner.IdleToken? in
                defer { Task { await completion.finish() } }
                return try await owner.prepareInstalledForIdle()
            }
            await until { await loader.counts().active == 1 }
            idle.cancel(); await settle()
            check(await !completion.finished, "Cancellation must wait for the actual model call")
            await loader.unblock(); await cancelled(idle)
            let c = await loader.counts()
            let ready = await loader.ready
            check(c.active == 0 && c.unloads == 1 && !ready, "An unadopted late result must be released")
            try await owner.prepare()
            check(await loader.counts().loads == 2, "Ordinary preparation must remain retryable after idle cancellation")
            try await owner.unload()
        }
        // An absent artifact never downloads at launch, while an explicit service call keeps
        // the existing installation behavior.
        do {
            let loader = Loader(installed: false), owner = owner(loader)
            let token = try await owner.prepareInstalledForIdle()
            let c = await loader.counts()
            check(token == nil && c.loads == 0 && c.installs == 0, "Idle work must never install a missing model")
            try await owner.prepare()
            check(await loader.counts().installs == 1, "Explicit preparation still owns installation")
            try await owner.unload()
        }
        do {
            let loader = Loader(blocked: true), owner = owner(loader)
            let explicit = Task { try await owner.prepare() }
            await until { await loader.counts().active == 1 }
            explicit.cancel(); await settle(); await loader.unblock()
            await cancelled(explicit)
            let c = await loader.counts()
            check(c.unloads == 1 && c.active == 0, "A sole cancelled explicit waiter must release a late successful load")
        }
        do {
            let loader = Loader(blocked: true), owner = owner(loader)
            let idle = Task { try await owner.prepareInstalledForIdle() }
            await until { await loader.counts().active == 1 }
            idle.cancel(); await settle()
            let explicit = Task { try await owner.prepare() }
            await loader.unblock()
            await cancelled(idle); try await explicit.value
            let c = await loader.counts()
            check(c.loads == 2 && c.unloads == 1 && c.maximum == 1,
                "Record must join a cancelled idle drain, then use its ordinary retry path")
            try await owner.unload()
        }
        do {
            let loader = Loader(), owner = owner(loader)
            await loader.markFailure()
            do { _ = try await owner.prepareInstalledForIdle(); preconditionFailure("Expected fake model error") }
            catch { check(error is URLError, "Optional preparation preserves the original failure") }
            try await owner.prepare()
            check(await loader.counts().loads == 2, "An idle failure cannot poison the ordinary recording path")
            try await owner.unload()
        }
        // Foreground lifecycle and memory warning release only an idle-owned resource.
        do {
            let loader = Loader(), owner = owner(loader), controller = controller(owner)
            await controller.update(input())
            await until { await loader.ready }
            await settle()
            await controller.didReceiveMemoryWarning()
            check(await !loader.ready, "A memory warning releases idle residency")
            await controller.update(input())
            check(await loader.counts().loads == 1, "A memory warning must not immediately trigger another warmup")
            await controller.update(input(active: false))
            await controller.update(input())
            await until { await loader.counts().loads == 2 }
            await controller.update(input(active: false))
            check(await !loader.ready, "Background retirement must join and release idle work")
        }
        // Record keeps the owned load, then adopts it through the existing service operation.
        do {
            let loader = Loader(blocked: true), owner = owner(loader), controller = controller(owner)
            await controller.update(input())
            await until { await loader.counts().active == 1 }
            await controller.update(input(recording: true))
            let recording = Task { try await owner.prepare() }
            await settle(); await loader.unblock(); try await recording.value
            await controller.update(input(active: false, recording: true))
            let c = await loader.counts()
            let ready = await loader.ready
            check(c.loads == 1 && c.unloads == 0 && ready, "Background cannot unload Record's adopted model")
            try await owner.unload()
        }
        // Configuration changes retire and join the prior owner before a replacement starts.
        do {
            let loader = Loader(blocked: true), owner = owner(loader), controller = controller(owner)
            await controller.update(input())
            await until { await loader.counts().active == 1 }
            let change = Task { await controller.update(input(identity: "a1/two")) }
            await settle()
            check(await loader.counts().loads == 1, "A replacement cannot overlap an unjoined load")
            await loader.unblock(); await change.value
            await until { await loader.counts().loads == 2 }
            check(await loader.counts().maximum == 1, "Native privacy loads must stay serial across configuration changes")
            await controller.update(input(active: false, identity: "a1/two"))
        }
        // Other model work wins. Returning to idle allows one new optional preparation.
        do {
            let loader = Loader(), owner = owner(loader), controller = controller(owner)
            await controller.update(input(otherWork: true)); await settle()
            check(await loader.counts().loads == 0, "Other model operations must block new idle work")
            await controller.update(input())
            await until { await loader.ready }; await settle()
            await controller.update(input(otherWork: true))
            check(await !loader.ready, "Other model work retires an unadopted idle model")
            await controller.update(input())
            await until { await loader.counts().loads == 2 }
            await controller.update(input(active: false))
        }
        // A resource operation can complete without a scene/configuration change. Retry
        // once for that explicit event, never by polling or repeatedly observing the same input.
        do {
            var installed = false, attempts = 0, releases = 0
            let controller = MeetingIdlePreparationController<UUID>(prepare: {
                await MainActor.run { attempts += 1; return installed ? UUID() : nil }
            }, release: { _ in await MainActor.run { releases += 1 } })
            var state = MeetingIdlePreparationController<UUID>.Input(isSceneActive: true, isUIReady: true,
                preparationEnabled: true, configurationIdentity: "same-exact-config",
                hasRecordingActivity: false, hasOtherModelWork: false, resourceRevision: UUID())
            await controller.update(state)
            await until { await MainActor.run { attempts == 1 } }
            await controller.update(state); await settle()
            check(attempts == 1, "Missing assets cannot start a warmup polling loop")
            installed = true; state.resourceRevision = UUID()
            await controller.update(state)
            await until { await MainActor.run { attempts == 2 } }
            await settle(); await controller.shutdown()
            check(attempts == 2 && releases == 1, "An installed event retries the same configuration once and shutdown joins its token")
            await controller.update(state); await settle()
            check(attempts == 2, "Shutdown cannot restart optional preparation")
        }
        print("Privacy idle preparation tests passed: \(assertions) assertions across 17 ownership/lifecycle scenarios")
    }
}
