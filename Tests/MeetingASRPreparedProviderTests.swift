import Foundation

// Inert neighbors for the portable orchestration test. The production configuration,
// provider lease, preparation owner, scope and service default are compiled unchanged.
nonisolated enum MeetingSpeakerProcessingMode: String, Codable, Sendable { case afterRecording, streaming }
nonisolated struct MeetingSpeakerAttributionPolicy: Codable, Equatable, Sendable {
    static let standard = Self()
    var fingerprint: String { "test-policy" }
}
nonisolated enum MeetingProcessingCheckpoint { static let currentDiarizationFingerprint = "test-speaker" }
// MeetingRetranscriptionLanguage.failedAttemptLanguage(for:) reads only these session fields.
nonisolated struct MeetingProcessingAttempt { let languageCode: String? }
nonisolated struct MeetingSession {
    var transcriptSegments: [Int] = []
    var processingAttempts: [MeetingProcessingAttempt] = []
    var languageCode = "en"
}
nonisolated struct ModelPreparationProgress: Sendable {}
nonisolated struct ASRTranscriptionResult: Sendable {}
nonisolated struct ASRWordTiming: Sendable {}
nonisolated enum MeetingModelResidencyError: Error { case unsupportedProvider }
@MainActor protocol ASRActivityLeasing {}
@MainActor struct MeetingModelParticipant {}
@MainActor final class MeetingModelResidencyCoordinator {}
@MainActor final class MeetingIdlePreparedResourceClaim {}
@MainActor protocol TranscriptionProvider: AnyObject {
    var isReady: Bool { get }
    func releaseResidency() async
}
extension MeetingProviderOptions {
    static func resolve(_ configuration: MeetingFinalProcessingConfiguration) throws {
        if configuration.asrModel == "unsupported" { throw ProbeError.rejected }
    }
}

private enum ProbeError: Error { case rejected }
@MainActor private final class Gate {
    var entered = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var isOpen: Bool
    init(open: Bool = false) { self.isOpen = open }
    func wait() async {
        entered = true
        if !isOpen { await withCheckedContinuation { waiters.append($0) } }
    }
    func open() {
        isOpen = true
        let captured = waiters; waiters = []
        captured.forEach { $0.resume() }
    }
}
@MainActor private final class Provider: TranscriptionProvider {
    var isReady = true
    var releases = 0
    var releaseGate: Gate?
    var trace: ((String) -> Void)?
    func releaseResidency() async {
        releases += 1; trace?("release")
        await releaseGate?.wait()
        isReady = false
    }
}
@MainActor private final class Harness {
    let provider = Provider()
    let lease = ASRActivityLease(id: UUID(), activity: .meeting)
    var leaseIsActive = true
    var downloading = false
    var retirementFails = false
    var retirementGate: Gate?
    var retirements = 0
    var factories = 0
    var preparations = 0
    var drains = 0
    var trace: [String] = []
    lazy var owner = MeetingASRPreparationOwner(
        isActiveLease: { [unowned self] in self.leaseIsActive && $0 == self.lease },
        isUserDownloadInProgress: { [unowned self] in self.downloading },
        retireDictationResources: { [unowned self] _ in
            self.retirements += 1; self.trace.append("retire")
            await self.retirementGate?.wait()
            if self.retirementFails { throw ProbeError.rejected }
        },
        makeProvider: { [unowned self] _ in self.factories += 1; return self.provider },
        prepareProvider: { [unowned self] _, _, _ in self.preparations += 1 },
        drainExecutor: { [unowned self] _ in self.drains += 1; self.trace.append("drain") })
    init() { provider.trace = { [weak self] in self?.trace.append($0) } }
}

// This represents an existing fake or external service that only implements the old
// overload. The additive protocol must not force it to claim retained-provider support.
@MainActor final class ASRService: ASRActivityLeasing {
    private let provider = Provider()
    var isRunning: Bool { false }
    var fileTranscriptionProvider: any TranscriptionProvider { provider }
    var scopes = 0
    func ensureAsrReady() async throws {}
    func meetingResidencyParticipant() -> MeetingModelParticipant { .init() }
    func withMeetingModelResidency<T>(attemptID: UUID, acceptsCompletedCancellation: (T) -> Bool,
                                     work: () async throws -> T) async throws -> T { try await work() }
    func withPreparedMeetingASR<T>(attemptID: UUID, configuration: MeetingFinalProcessingConfiguration,
                                  body: @escaping (any TranscriptionProvider) async throws -> T) async throws -> T {
        scopes += 1; return try await body(provider)
    }
    func transcribeMeetingSamples(_ samples: [Float], provider: any TranscriptionProvider,
                                  languageCode: String) async throws -> ASRTranscriptionResult { .init() }
    func transcribeMeetingSamplesWithTimings(_ samples: [Float], provider: any TranscriptionProvider)
        async throws -> (result: ASRTranscriptionResult, words: [ASRWordTiming]) { (.init(), []) }
    func transcribeMeetingFile(at fileURL: URL, provider: any TranscriptionProvider)
        async throws -> ASRTranscriptionResult { .init() }
}

@main struct MeetingASRPreparedProviderTests {
    private static var assertions = 0
    private static func check(_ value: Bool, _ message: String) {
        assertions += 1; precondition(value, message)
    }
    private static func config(artifact: String = "weights-one", path: String = "/installed/one",
                               language: String = "ru") -> MeetingFinalProcessingConfiguration {
        .init(asrModel: "test-asr", asrArtifactFingerprint: artifact,
              asrArtifactDirectory: URL(fileURLWithPath: path), languageCode: language,
              diarizationFingerprint: "test-speaker", speakerProcessingMode: .streaming)
    }
    private static func until(_ predicate: () -> Bool) async {
        for _ in 0..<20_000 { if predicate() { return }; await Task.yield() }
        preconditionFailure("Bounded test did not reach its rendezvous")
    }
    private static func rejected(_ body: () throws -> Void) {
        do { try body(); preconditionFailure("Expected rejection") } catch {}
    }
    private static func failed<T>(_ task: Task<T, Error>, cancellation: Bool = false) async {
        do { _ = try await task.value; preconditionFailure("Expected failure") }
        catch { if cancellation { check(error is CancellationError, "Cancellation remains explicit") } }
    }

    @MainActor static func main() async throws {
        let configuration = config()
        // The exact ready instance crosses the existing scope without a factory or load.
        do {
            let h = Harness(), scope = MeetingASRPreparedScope()
            let resource = MeetingASRPreparedProvider(configuration: configuration, provider: h.provider)
            let value = try await scope.run(lease: h.lease, attemptID: UUID(), configuration: configuration,
                owner: h.owner, preparedProvider: resource, isActiveLease: { $0 == h.lease }) { provider in
                    check(provider === h.provider, "Adoption must preserve the exact provider")
                    await resource.cleanup()
                    check(h.provider.releases == 0, "Old idle cleanup cannot unload an adopted provider")
                    return 7
                }
            check(value == 7 && h.factories == 0 && h.preparations == 0, "Ready adoption must avoid duplicate load")
            check(h.retirements == 1 && h.drains == 1 && h.provider.releases == 1, "Existing retirement/drain still owns release")
            await resource.cleanup()
            rejected { _ = try resource.take(matching: configuration) }
            check(h.provider.releases == 1 && !scope.isActive && !h.owner.isClaimed, "One-shot transfer releases exactly once")
        }
        // A nil resource preserves the old preparation route.
        do {
            let h = Harness(), scope = MeetingASRPreparedScope()
            _ = try await scope.run(lease: h.lease, attemptID: UUID(), configuration: configuration,
                owner: h.owner, isActiveLease: { $0 == h.lease }) { _ in 0 }
            check(h.factories == 1 && h.preparations == 1 && h.provider.releases == 1, "Cold fallback remains unchanged")
        }
        // Exact equality includes artifact directory, which is not part of the persisted
        // identity fingerprint. A same-model/same-fingerprint resource is still not enough.
        for changed in [config(artifact: "weights-two"), config(path: "/installed/two"), config(language: "en")] {
            let h = Harness()
            let resource = MeetingASRPreparedProvider(configuration: configuration, provider: h.provider)
            do {
                _ = try await h.owner.prepare(lease: h.lease, attemptID: UUID(), configuration: changed,
                                              preparedProvider: resource)
                preconditionFailure("Expected exact-configuration rejection")
            } catch { check(error as? MeetingASRPreparationError == .invalidPreparedProvider, "Configuration mismatch is explicit") }
            check(h.retirements == 0 && h.factories == 0 && !h.owner.isClaimed, "Mismatch must reject before side effects")
            await resource.cleanup(); check(h.provider.releases == 1, "Rejected resource remains owned by creator")
        }
        do {
            let h = Harness(); h.leaseIsActive = false
            let resource = MeetingASRPreparedProvider(configuration: configuration, provider: h.provider)
            let task = Task { try await h.owner.prepare(lease: h.lease, attemptID: UUID(), configuration: configuration,
                                                       preparedProvider: resource) }
            await failed(task)
            check(h.retirements == 0 && h.factories == 0, "A stale audio lease cannot consume the ready resource")
            await resource.cleanup(); check(h.provider.releases == 1, "Stale lease leaves unconsumed cleanup intact")
        }
        // Non-cooperative retirement may finish late. Cancellation, invalidation or failure
        // must all leave the transfer unconsumed and join the old executor before returning.
        for mode in 0..<3 {
            let h = Harness(), gate = Gate(); h.retirementGate = gate
            let resource = MeetingASRPreparedProvider(configuration: configuration, provider: h.provider)
            let task = Task { try await h.owner.prepare(lease: h.lease, attemptID: UUID(), configuration: configuration,
                                                       preparedProvider: resource) }
            await until { gate.entered }
            if mode == 0 { task.cancel() }
            if mode == 1 { h.leaseIsActive = false }
            if mode == 2 { h.retirementFails = true }
            check(h.owner.isClaimed && h.provider.releases == 0, "Retirement owns the still-claimed preparation")
            gate.open(); await failed(task, cancellation: mode != 2)
            check(h.factories == 0 && h.preparations == 0 && h.drains == 1, "Failed retirement never transfers or loads")
            check(h.provider.releases == 0 && !h.owner.isClaimed, "Unconsumed resource is not released by an unrelated claim")
            await resource.cleanup(); check(h.provider.releases == 1, "Creator releases unconsumed provider exactly once")
        }
        // Cancellation cannot unload the resource while an already admitted body still runs.
        do {
            let h = Harness(), scope = MeetingASRPreparedScope(), bodyGate = Gate()
            let resource = MeetingASRPreparedProvider(configuration: configuration, provider: h.provider)
            let task = Task {
                try await scope.run(lease: h.lease, attemptID: UUID(), configuration: configuration,
                    owner: h.owner, preparedProvider: resource, isActiveLease: { $0 == h.lease }) { _ in
                        await bodyGate.wait(); h.trace.append("body-ended"); return 1
                    }
            }
            await until { bodyGate.entered }
            task.cancel(); await resource.cleanup()
            check(h.provider.releases == 0 && scope.isActive && h.owner.isClaimed, "Body cancellation must join before unloading")
            bodyGate.open(); await failed(task, cancellation: true)
            check(h.trace == ["retire", "body-ended", "drain", "release"], "Body joins before executor drain and native release")
        }
        // Two cleanup callers join one unload. A simultaneous take cannot see a stale ready Bool.
        do {
            let provider = Provider(), gate = Gate(); provider.releaseGate = gate
            let resource = MeetingASRPreparedProvider(configuration: configuration, provider: provider)
            let first = Task { await resource.cleanup() }
            await until { gate.entered }
            let second = Task { await resource.cleanup() }
            rejected { _ = try resource.take(matching: configuration) }
            check(provider.releases == 1, "Cleanup invalidates transfer before awaiting unload")
            first.cancel(); gate.open(); await first.value; await second.value
            await resource.cleanup(); check(provider.releases == 1, "Cleanup is joined, idempotent and cancellation-independent")
        }
        // Matching waiters join the same claim; a different wrapper must not be silently ignored.
        do {
            let h = Harness(), gate = Gate(); h.retirementGate = gate
            let attempt = UUID(), resource = MeetingASRPreparedProvider(configuration: configuration, provider: h.provider)
            let otherProvider = Provider(), other = MeetingASRPreparedProvider(configuration: configuration, provider: otherProvider)
            let first = Task { try await h.owner.prepare(lease: h.lease, attemptID: attempt, configuration: configuration,
                                                        preparedProvider: resource) }
            await until { gate.entered }
            let matching = Task { try await h.owner.prepare(lease: h.lease, attemptID: attempt, configuration: configuration,
                                                           preparedProvider: resource) }
            let different = Task { try await h.owner.prepare(lease: h.lease, attemptID: attempt, configuration: configuration,
                                                            preparedProvider: other) }
            await failed(different)
            check(otherProvider.releases == 0, "A rejected competing resource remains unconsumed")
            gate.open(); let one = try await first.value, two = try await matching.value
            check(one === two && h.retirements == 1 && h.factories == 0, "Same resource joins single-flight adoption")
            await h.owner.release(h.owner.currentClaimToken!)
            await resource.cleanup(); await other.cleanup()
            check(h.provider.releases == 1 && otherProvider.releases == 1, "Each resource has one independent cleanup owner")
        }
        do {
            let h = Harness(); h.provider.isReady = false
            let resource = MeetingASRPreparedProvider(configuration: configuration, provider: h.provider)
            let task = Task { try await h.owner.prepare(lease: h.lease, attemptID: UUID(), configuration: configuration,
                                                       preparedProvider: resource) }
            await failed(task)
            check(h.factories == 0 && h.preparations == 0 && h.drains == 1, "An unready resource cannot silently create a duplicate")
            await resource.cleanup(); check(h.provider.releases == 1, "Unready resource remains unconsumed")
        }
        // Old conformers compile unchanged, and their default overload is truthful.
        do {
            let service: any MeetingASRServicing = ASRService(), provider = Provider()
            let resource = MeetingASRPreparedProvider(configuration: configuration, provider: provider)
            check(!service.supportsPreparedProviderAdoption, "Old services default to unsupported adoption")
            let value = try await service.withPreparedMeetingASR(attemptID: UUID(), configuration: configuration,
                preparedProvider: nil) { _ in 9 }
            check(value == 9, "Nil resource delegates to legacy service scope")
            do {
                _ = try await service.withPreparedMeetingASR(attemptID: UUID(), configuration: configuration,
                    preparedProvider: resource) { _ in 0 }
                preconditionFailure("Legacy service must reject retained resource")
            } catch { check(error as? MeetingModelResidencyError == .unsupportedProvider, "Unsupported adoption remains explicit") }
            check(provider.releases == 0, "Unsupported service cannot consume caller-owned provider")
            await resource.cleanup()
        }
        print("PASS: \(assertions) prepared ASR provider adoption and ownership checks")
    }
}
