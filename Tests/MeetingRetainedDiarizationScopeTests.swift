import Foundation

// Model-free witnesses typecheck the actual production parked-scope and pair ownership.
// Native model loading, inference, application compilation and memory measurements are separate gates.
nonisolated protocol MeetingIdlePreparedResource: Sendable {
    var configurationIdentity: String { get }
    func cleanup() async
}
nonisolated protocol MeetingNemotronDiarizerFactory: Sendable {
    func makeDiarizer() -> UUID
}
nonisolated struct MeetingFinalProcessingConfiguration: Equatable, Sendable {
    var identityFingerprint = "synthetic-config"
    var artifactDirectory = "/synthetic/one"
}
nonisolated struct MeetingNemotronModelArtifact: Equatable, Sendable { var generation = 1 }
nonisolated enum MeetingModelResidencyError: Error { case staleGrant, busy }
@MainActor final class MeetingASRPreparedProvider {
    private(set) var releaseCount = 0
    private var released = false
    func cleanup() async {
        guard !self.released else { return }
        self.released = true
        self.releaseCount += 1
    }
}
nonisolated enum FixtureContext { @TaskLocal static var token: String? }
nonisolated enum FixtureError: Error, Equatable { case load, consumer, assertion(String) }

private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        guard !self.open else { return }
        await withCheckedContinuation { self.waiters.append($0) }
    }
    func release() {
        self.open = true
        let waiters = self.waiters
        self.waiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }
}

private final nonisolated class Factory: MeetingNemotronDiarizerFactory, @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []
    private var instances: [UUID] = []
    func record(_ event: String) { self.lock.withLock { self.events.append(event) } }
    var snapshot: [String] { self.lock.withLock { self.events } }
    var diarizers: [UUID] { self.lock.withLock { self.instances } }
    func makeDiarizer() -> UUID {
        let id = UUID()
        self.lock.withLock {
            self.events.append("make:" + (FixtureContext.token ?? "none"))
            self.instances.append(id)
        }
        return id
    }
    func scope(loadGate: Gate? = nil, fail: Bool = false) -> MeetingRetainedDiarizationScope {
        MeetingRetainedDiarizationScope { body in
            self.record("load:" + (FixtureContext.token ?? "none"))
            defer { self.record("native-cleanup") }
            if let loadGate { await loadGate.wait() } // Deliberately ignores cancellation.
            if fail { throw FixtureError.load }
            try Task.checkCancellation()
            try await body(self)
        }
    }
}

@main private enum Tests {
    nonisolated static func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
        guard value() else { throw FixtureError.assertion(message) }
    }

    nonisolated static func eventually(_ predicate: @escaping @Sendable () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 3
        while !predicate() {
            guard ProcessInfo.processInfo.systemUptime < deadline else { throw FixtureError.assertion("event deadline") }
            await Task.yield()
        }
    }

    static func rejects(_ body: @MainActor () async throws -> Void) async throws {
        do { try await body(); throw FixtureError.assertion("expected rejection") }
        catch let error as FixtureError {
            if case .assertion = error { throw error }
        } catch {}
    }

    static func main() async throws {
        var groups = 0
        do {
            let factory = Factory()
            let scope = FixtureContext.$token.withValue("idle") { factory.scope() }
            try await scope.waitUntilReady()
            try await scope.waitUntilReady()
            try require(factory.snapshot == ["load:none"], "one retained load, no idle diarizer")
            let instance = try await FixtureContext.$token.withValue("actual-attempt") {
                try await scope.withFactory { loaded in
                    try require((loaded as? Factory) === factory, "same factory was adopted")
                    return loaded.makeDiarizer()
                }
            }
            factory.record("owner-stage")
            try require(factory.diarizers == [instance], "fresh state created only in consumer")
            try require(factory.snapshot == ["load:none", "make:actual-attempt", "native-cleanup", "owner-stage"],
                        "consumer context and native cleanup before downstream owner stage")
            try await rejects { _ = try await scope.withFactory { _ in 0 } }
            await scope.cleanup()
            try require(factory.snapshot.filter { $0 == "native-cleanup" }.count == 1, "single-use joined cleanup")
            groups += 1
        }
        do {
            let factory = Factory(), scope = factory.scope()
            try await scope.waitUntilReady()
            async let one: Void = scope.cleanup()
            async let two: Void = scope.cleanup()
            async let three: Void = scope.cleanup()
            _ = await (one, two, three)
            try require(factory.snapshot == ["load:none", "native-cleanup"], "concurrent idle cleanup joins once")
            try await rejects { try await scope.waitUntilReady() }
            groups += 1
        }
        do {
            let factory = Factory(), scope = factory.scope(fail: true)
            do { try await scope.waitUntilReady(); throw FixtureError.assertion("load failure missing") }
            catch FixtureError.load {}
            try require(factory.snapshot == ["load:none", "native-cleanup"], "failed native open joined")
            groups += 1
        }
        do {
            let factory = Factory(), gate = Gate()
            let scope = factory.scope(loadGate: gate)
            let waiter = Task { try await scope.waitUntilReady() }
            try await eventually { factory.snapshot.contains("load:none") }
            waiter.cancel()
            for _ in 0..<20 { await Task.yield() }
            try require(!factory.snapshot.contains("native-cleanup"), "noncooperative load is not reported cleaned early")
            await gate.release()
            try await rejects { try await waiter.value }
            try require(factory.snapshot == ["load:none", "native-cleanup"], "cancelled prepare joins native load")
            groups += 1
        }
        do {
            let factory = Factory(), gate = Gate()
            let scope = factory.scope()
            try await scope.waitUntilReady()
            let consumer = Task {
                try await scope.withFactory { _ in
                    factory.record("consumer-start")
                    await gate.wait() // Deliberately ignores cancellation until native work returns.
                    factory.record("consumer-finish")
                }
            }
            try await eventually { factory.snapshot.contains("consumer-start") }
            let cleanup = Task { await scope.cleanup(); factory.record("cleanup-returned") }
            for _ in 0..<20 { await Task.yield() }
            try require(!factory.snapshot.contains("native-cleanup"), "active consumer owns factory until joined")
            await gate.release()
            _ = await consumer.result
            await cleanup.value
            let events = factory.snapshot
            try require(events.firstIndex(of: "consumer-finish")! < events.firstIndex(of: "native-cleanup")!, "consumer drains before weights")
            try require(events.last == "cleanup-returned", "cleanup return joins native release")
            groups += 1
        }
        do {
            let factory = Factory(), scope = factory.scope()
            try await scope.waitUntilReady()
            do {
                _ = try await scope.withFactory { _ -> Int in throw FixtureError.consumer }
                throw FixtureError.assertion("consumer failure missing")
            } catch FixtureError.consumer {}
            try require(factory.snapshot == ["load:none", "native-cleanup"], "throwing consumer joins weights")
            groups += 1
        }
        do {
            let factory = Factory(), gate = Gate(), scope = factory.scope()
            try await scope.waitUntilReady()
            let consumer = Task {
                try await scope.withFactory { _ in
                    factory.record("consumer-start")
                    await gate.wait()
                    factory.record("consumer-finish")
                }
            }
            try await eventually { factory.snapshot.contains("consumer-start") }
            consumer.cancel()
            for _ in 0..<20 { await Task.yield() }
            try require(!factory.snapshot.contains("native-cleanup"), "cancelled consumer still joins noncooperative work")
            await gate.release()
            try await rejects { try await consumer.value }
            try require(factory.snapshot.last == "native-cleanup", "cancelled consumer releases native scope")
            groups += 1
        }
        do {
            let factory = Factory(), scope = factory.scope()
            try await scope.waitUntilReady()
            let asr = MeetingASRPreparedProvider()
            let config = MeetingFinalProcessingConfiguration(), artifact = MeetingNemotronModelArtifact()
            let resource = MeetingIdleParakeetNemotronResources(configuration: config, artifact: artifact, asr: asr, speakerScope: scope)
            try await rejects { try resource.claim(configuration: config, artifact: artifact) }
            var sameFingerprintDifferentDirectory = config
            sameFingerprintDifferentDirectory.artifactDirectory = "/synthetic/two"
            try await rejects { try resource.adopt(configuration: sameFingerprintDifferentDirectory, artifact: artifact) }
            try await rejects { try resource.adopt(configuration: config, artifact: .init(generation: 2)) }
            try resource.adopt(configuration: config, artifact: artifact)
            try await rejects { try resource.adopt(configuration: config, artifact: artifact) }
            try await rejects { try resource.claim(configuration: config, artifact: .init(generation: 2)) }
            try resource.claim(configuration: config, artifact: artifact)
            try await rejects { try resource.claim(configuration: config, artifact: artifact) }
            await resource.cleanup()
            await resource.cleanup()
            let releaseCount = asr.releaseCount
            try require(releaseCount == 1 && factory.snapshot.last == "native-cleanup", "pair cleanup joins both owners idempotently")
            groups += 1
        }
        do {
            let factory = Factory(), scope = factory.scope()
            try await scope.waitUntilReady()
            let resource = MeetingIdleParakeetNemotronResources(configuration: .init(), artifact: .init(),
                asr: MeetingASRPreparedProvider(), speakerScope: scope)
            await resource.cleanup()
            try await rejects { try resource.adopt(configuration: .init(), artifact: .init()) }
            groups += 1
        }
        print("PASS \(groups) actual-source retained-scope and paired-ownership groups (no native models)")
    }
}
