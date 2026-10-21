import Foundation

@MainActor final class DebugLogger {
    static let shared = DebugLogger()
    func warning(_ text: String, source: String) {}
}

@MainActor private final class Gate {
    var entered = false
    private var open: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(open: Bool = false) { self.open = open }
    func wait() async {
        entered = true
        if !open { await withCheckedContinuation { waiters.append($0) } }
    }
    func release() { open = true; let prior = waiters; waiters = []; prior.forEach { $0.resume() } }
}

@MainActor private final class Model: MeetingIdlePreparedResource {
    nonisolated let configurationIdentity: String
    private let harness: Harness
    private var released = false
    init(identity: String, harness: Harness) { configurationIdentity = identity; self.harness = harness }
    func cleanup() async {
        guard !released else { return }
        released = true
        await harness.releaseGate.wait()
        harness.weights -= 1; harness.releases += 1
    }
}

@MainActor private final class Harness {
    let residency = MeetingModelResidencyCoordinator()
    lazy var owner = MeetingIdlePreparedResourceOwner(residency: residency)
    let loadGate: Gate
    let releaseGate: Gate
    var loads = 0
    var releases = 0
    var weights = 0
    var maximumWeights = 0
    var loadGrant: MeetingModelGrant?
    var failLoad = false
    init(blockLoad: Bool = false, blockRelease: Bool = false) {
        loadGate = Gate(open: !blockLoad); releaseGate = Gate(open: !blockRelease)
    }
    func prepare(_ identity: String = "backend/fingerprint") async throws -> MeetingIdlePreparationToken? {
        try await owner.prepare(identity: identity) { [self] in try await load(identity) }
    }
    func load(_ identity: String) async throws -> (any MeetingIdlePreparedResource)? {
        loads += 1; weights += 1; maximumWeights = max(maximumWeights, weights)
        loadGrant = MeetingModelContext.grant
        await loadGate.wait() // Native loading deliberately does not observe cancellation.
        if failLoad { weights -= 1; throw URLError(.cannotOpenFile) }
        return Model(identity: identity, harness: self)
    }
}

@MainActor struct ScopeWitness { var isActive = false }
@MainActor struct PreparationWitness { var isClaimed = false; var isDraining = false }
@MainActor final class ExecutorWitness { func cancelAndAwaitPending() async {} }
@MainActor final class ResidentProviderWitness {
    let fingerprint: String
    private let resource: any MeetingIdlePreparedResource
    init(fingerprint: String, resource: any MeetingIdlePreparedResource) { self.fingerprint = fingerprint; self.resource = resource }
    func releaseResidency() async { await resource.cleanup() }
}
// The two methods are extracted unchanged from the actual iOS ASR service by the runner.
@MainActor final class IdleSpeechHostWitness {
    var activityLease: ASRActivityLease?
    var modelOperation: Task<Void, Error>?
    var scope = ScopeWitness()
    var preparationOwner = PreparationWitness()
    var isTerminating = false
    var executor = ExecutorWitness()
    var residentProvider: ResidentProviderWitness?
    var residentModelID: String?
    var isAsrReady = true
    var residentReleaseTask: Task<Void, Never>?
    init(provider: ResidentProviderWitness) { residentProvider = provider; residentModelID = provider.fingerprint }
}

@main
struct MeetingIdlePreparedResourceTests {
    @MainActor private static var checks = 0
    @MainActor private static func check(_ value: Bool, _ message: String) { checks += 1; precondition(value, message) }
    @MainActor private static func until(_ condition: () -> Bool) async {
        for _ in 0..<20_000 { if condition() { return }; await Task.yield() }
        preconditionFailure("Bounded concurrency checkpoint was not reached")
    }
    @MainActor private static func settle() async { for _ in 0..<100 { await Task.yield() } }

    @MainActor static func main() async throws {
        for residentFingerprint in ["backend/fingerprint", "different-ordinary-model"] {
            let h = Harness(blockRelease: true)
            h.weights = 1; h.maximumWeights = 1
            let ordinary = ResidentProviderWitness(fingerprint: residentFingerprint, resource: Model(identity: residentFingerprint, harness: h))
            let service = IdleSpeechHostWitness(provider: ordinary)
            let idle = Task {
                try await h.owner.prepare(identity: "backend/fingerprint") {
                    guard try await service.retireIdleSpeechResidency() else { return nil }
                    return try await h.load("backend/fingerprint")
                }
            }
            await until { h.releaseGate.entered }
            check(h.loads == 0 && h.weights == 1, "Idle loading must join the existing ready provider's actual release first")
            h.releaseGate.release()
            _ = try await idle.value
            check(h.weights == 1 && h.maximumWeights == 1 && !service.isAsrReady,
                "Matching and unmatched ordinary residents cannot create duplicate peak weights")
            try await h.residency.withExclusive(attemptID: UUID(), participants: [], idleResourceIdentity: "backend/fingerprint") { claim in
                _ = try await claim?.resource()
                check(h.loads == 1 && h.releases == 1, "The single replacement load is adopted by the actual attempt")
            }
            check(h.weights == 0 && h.releases == 2, "Both ordinary and adopted owners release exactly their own model")
        }
        // Real ordinary native admissions retire both loading and ready optional resources.
        for ownerName in ["speech", "fluid", "local-text"] {
            for loading in [false, true] {
                let h = Harness(blockLoad: loading)
                let idle = Task { try await h.prepare() }
                await until { h.loadGate.entered }
                if !loading { _ = try await idle.value }
                var admitted = false
                let real = Task {
                    let token = try await h.residency.beginOperationRetiringIdle(owner: ownerName, modelID: "actual")
                    admitted = true
                    check(h.weights == 0, "Real work cannot overlap native idle weights")
                    h.residency.endOperation(token)
                }
                await settle()
                if loading { check(!admitted, "Real work must join the non-cooperative idle load"); h.loadGate.release() }
                try await real.value
                _ = try? await idle.value
                check(admitted && h.releases == 1 && h.maximumWeights == 1, "Idle preparation cannot force a user busy/retry")
            }
        }
        // Atomic selection happens before a loader is ready. Capture can already accept
        // bounded PCM while only the deferred inference body waits for the preparation.
        do {
            let h = Harness(blockLoad: true)
            let idle = Task { try await h.prepare() }
            await until { h.loadGate.entered }
            let captureAdmitted = true
            var enteredInference = false
            let recording = Task {
                try await h.residency.withExclusive(attemptID: UUID(), participants: [], idleResourceIdentity: "backend/fingerprint") { claim in
                    check(captureAdmitted && h.residency.phase == .transcription, "Only admitted capture enters actual inference ownership")
                    check(claim != nil, "A matching loading lease must transfer, not restart")
                    enteredInference = true
                    _ = try await claim?.resource()
                    check(h.loads == 1 && h.weights == 1 && h.loadGrant == nil, "One prepared model serves the actual recording without borrowing a TaskLocal grant")
                    do { _ = try h.residency.beginOperation(owner: "other", modelID: "x"); preconditionFailure("Expected ordinary exclusive guard") }
                    catch { check(error is MeetingModelResidencyError, "Existing exclusive admission remains strict") }
                }
            }
            await until { enteredInference }
            h.loadGate.release()
            try await recording.value; _ = try? await idle.value
            check(h.weights == 0 && h.releases == 1 && !h.residency.isExclusive, "Actual scope cleanup joins before ordinary admission reopens")
        }
        // A ready one-shot claim cannot be unloaded by the stale foreground token.
        do {
            let h = Harness()
            let token = try await h.prepare()!
            try await h.residency.withExclusive(attemptID: UUID(), participants: [], idleResourceIdentity: "backend/fingerprint") { claim in
                _ = try await claim?.resource()
                await h.owner.cancel(token)
                check(h.weights == 1, "The old idle token loses cleanup authority after adoption")
            }
            check(h.loads == 1 && h.releases == 1, "One-shot adoption must not duplicate or retain weights")
        }
        // Unmatched identity cleans the old resource, then preserves the ordinary cold body.
        do {
            let h = Harness(); _ = try await h.prepare("old-fingerprint")
            let value = try await h.residency.withExclusive(attemptID: UUID(), participants: [], idleResourceIdentity: "new-fingerprint") { claim in
                check(claim == nil && h.weights == 0, "A mismatched fingerprint must not be adopted")
                return "cold-recording"
            }
            check(value == "cold-recording" && h.releases == 1, "Optional mismatch cannot fail an ordinary recording")
        }
        // Direct foreground cancellation and an executable native admission must join the
        // SAME retirement, including when the owner's idle slot is already cleared.
        do {
            let h = Harness(blockRelease: true), token = try await h.prepare()!
            let background = Task { await h.owner.cancel(token) }
            await until { h.releaseGate.entered }
            var admitted = false
            let real = Task { let t = try await h.residency.beginOperationRetiringIdle(owner: "speech", modelID: "real"); admitted = true; h.residency.endOperation(t) }
            await settle()
            check(!admitted && h.weights == 1, "A parallel lifecycle drain cannot be mistaken for completed retirement")
            h.releaseGate.release(); await background.value; try await real.value
            check(h.releases == 1 && admitted, "Parallel cancellation and priority admission release exactly once")
        }
        // Memory-pressure/foreground retirement can clear the owner's slot before the
        // coordinator metadata disappears. Matching Record must join that exact drain,
        // rather than treating a nil one-shot claim as successful adoption.
        do {
            let h = Harness(blockRelease: true), token = try await h.prepare()!
            let background = Task { await h.owner.cancel(token) }
            await until { h.releaseGate.entered }
            var enteredCold = false
            let recording = Task {
                try await h.residency.withExclusive(attemptID: UUID(), participants: [], idleResourceIdentity: "backend/fingerprint") { claim in
                    enteredCold = true
                    check(claim == nil && h.weights == 0, "A retired claim must be joined before matching Record falls back")
                    let cold = try await h.load("backend/fingerprint")
                    await cold?.cleanup()
                }
            }
            await settle()
            check(!enteredCold && h.weights == 1, "Matching Record cannot bypass an ongoing direct owner drain")
            h.releaseGate.release(); await background.value; try await recording.value
            check(h.loads == 2 && h.releases == 2 && h.maximumWeights == 1,
                "Cold fallback after memory retirement cannot duplicate resident weights")
        }
        do {
            let h = Harness(blockLoad: true)
            let idle = Task { try await h.prepare() }
            await until { h.loadGate.entered }
            let actual = Task { try await h.residency.beginOperationRetiringIdle(owner: "speech", modelID: "real") }
            await settle(); actual.cancel(); h.loadGate.release()
            do { _ = try await actual.value; preconditionFailure("Expected cancellation") }
            catch { check(error is CancellationError, "Real caller cancellation remains explicit after joined idle cleanup") }
            _ = try? await idle.value
            check(h.weights == 0 && h.releases == 1, "Cancelled admission still joins native retirement")
        }
        do {
            let h = Harness()
            _ = try await h.prepare()
            let bad = MeetingModelParticipant(owner: "speech", snapshot: { throw URLError(.cancelled) }, suspend: {}, restore: { _ in })
            do {
                try await h.residency.withExclusive(attemptID: UUID(), participants: [bad], idleResourceIdentity: "backend/fingerprint") { _ in preconditionFailure("Rejected participant cannot execute") }
            } catch { check(error is URLError, "Participant failure remains the real error") }
            check(h.weights == 0 && h.releases == 1 && !h.residency.isExclusive, "Pre-body failure must join transferred resources")
        }
        do {
            let h = Harness(); _ = try await h.prepare()
            h.residency.beginTermination()
            await h.residency.retireIdlePreparation()
            check(h.weights == 0 && h.releases == 1, "Shutdown joins only its current idle resource")
            do { _ = try await h.residency.beginOperationRetiringIdle(owner: "speech", modelID: "x"); preconditionFailure("Terminating admission must reject") }
            catch { check(error is MeetingModelResidencyError, "Termination checks remain intact") }
        }
        // Prefix-only fallback remains in the same executable idle admission. A native
        // ordinary operation cannot begin while those optional weights are still parked.
        do {
            let residency = MeetingModelResidencyCoordinator()
            var prefixReady = false, releases = 0
            // Use the owner's production coordinator so the executable admission retires it.
            let actualOwner = MeetingIdlePreparedResourceOwner(residency: residency)
            let token = try await actualOwner.prepare(identity: "prefix-only") {
                prefixReady = true
                return MeetingIdlePrefixResource(configurationIdentity: "prefix-only", release: {
                    await MainActor.run { prefixReady = false; releases += 1 }
                })
            }
            check(token != nil && prefixReady, "A PII-only fallback must retain its explicit idle admission")
            let admission = try await residency.beginOperationRetiringIdle(owner: "speech", modelID: "ordinary")
            check(!prefixReady && releases == 1, "Ordinary native work must join prefix-only retirement")
            residency.endOperation(admission)
        }
        print("Meeting idle prepared resource tests passed: \(checks) checks across 17 admission/ownership scenarios")
    }
}
