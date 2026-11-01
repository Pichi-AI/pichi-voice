import Combine
import Foundation

// Native Combine is real. The route/controller/transport doubles never load a model,
// start a server, read private settings, or use the application singleton.
@MainActor final class SettingsStore {
    enum DictationShortcutSlot { case primary, secondary }
    static let shared = SettingsStore()
    private let changes = PassthroughSubject<Void, Never>()
    private(set) var subscribers = 0
    var objectWillChange: AnyPublisher<Void, Never> {
        changes.handleEvents(receiveSubscription: { [weak self] _ in self?.subscribers += 1 },
                             receiveCancel: { [weak self] in self?.subscribers -= 1 })
            .eraseToAnyPublisher()
    }
    func change() { changes.send(()) }
}
@MainActor final class DictationAppSession {
    static let shared = DictationAppSession()
    var appID: String? = "synthetic"
    func start() {}
}
@MainActor struct DictationProviderRoute {
    let baseURL = "http://127.0.0.1/synthetic-unused"
    static func resolve(settings: SettingsStore, dictationSlot: SettingsStore.DictationShortcutSlot,
                        appBundleID: String?) -> Self { .init() }
}
@MainActor enum DictationAIPostProcessingGate {
    static func isProviderConfigured(route: DictationProviderRoute, settings: SettingsStore) -> Bool { true }
}
@MainActor enum OllamaChatAdapter { static func supports(_ value: String) -> Bool { true } }
@MainActor final class MeetingModelResidencyCoordinator {
    static let shared = MeetingModelResidencyCoordinator()
    var isExclusive = false
}
@MainActor final class MeetingSummaryActivityCoordinator {
    static let shared = MeetingSummaryActivityCoordinator()
    var isProcessing = false
    var selectionLock: UUID?
}
@MainActor final class DictationPostProcessingService {
    static let shared = DictationPostProcessingService()
    func prewarmLocalModel(_ route: DictationProviderRoute) async throws {}
}
@MainActor enum LocalAIModelResidencyTransport {
    static func isReady(_ route: DictationProviderRoute) async throws -> Bool { false }
    static func releaseWhileIdle(_ route: DictationProviderRoute) async -> Bool { true }
    static func release(_ route: DictationProviderRoute) async -> Bool { true }
}
@MainActor final class Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private(set) var entered = false
    func hold() async { entered = true; await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}
@MainActor final class LocalAIModelResidencyController {
    struct Dependencies {
        let selectedRoute: () -> DictationProviderRoute?
        let canWarm: () -> Bool
        let warm: (DictationProviderRoute) async throws -> Void
        let isReady: (DictationProviderRoute) async throws -> Bool
        let release: (DictationProviderRoute) async -> Bool
        let releaseForTermination: (DictationProviderRoute) async -> Bool
    }
    static var refreshes = 0
    private let dependencies: Dependencies
    var shutdownGate: Gate?
    private(set) var refreshCount = 0
    init(dependencies: Dependencies) { self.dependencies = dependencies }
    func start() {}
    func refresh() { refreshCount += 1; Self.refreshes += 1 }
    func shutdown() async { await shutdownGate?.hold() }
}
@MainActor final class ResidencyObservationProbe {
    var isUIReady = true
    var isTerminating = false
    var hasActiveMeetingActivity = false
    var hasActiveFileTranscriptionActivity = false
    var activeMeetingSummarySession: UUID?
// INSERT ACTUAL APP RESIDENCY METHODS
}

@main @MainActor struct LocalAIResidencyObservationTests {
    static var checks = 0
    static var failed = false
    static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { failed = true; print("FAIL: \(message)") }
    }
    static func pump(_ seconds: TimeInterval = 0.2) { RunLoop.main.run(until: Date().addingTimeInterval(seconds)) }
    static func main() async {
        let settings = SettingsStore.shared
        var owner: ResidencyObservationProbe? = ResidencyObservationProbe()
        weak let weakOwner = owner
        owner!.refreshLocalAIResidency()
        check(settings.subscribers == 1, "Creation owns exactly one settings observation")
        let original = LocalAIModelResidencyController.refreshes
        settings.change(); pump()
        check(LocalAIModelResidencyController.refreshes == original + 1, "One settings change causes one reconciliation")
        for cycle in 0..<12 {
            weak let old = owner!.controller
            await owner!.prepareProfile()
            check(settings.subscribers == 0, "Profile retirement cancels settings observer before recreation, cycle \(cycle)")
            check(old == nil, "Retired controller releases after joined shutdown, cycle \(cycle)")
            owner!.refreshLocalAIResidency()
            check(settings.subscribers == 1, "Observer count stays bounded across profile changes, cycle \(cycle)")
        }
        let beforeChange = LocalAIModelResidencyController.refreshes
        settings.change(); pump()
        print("After 12 profile cycles: \(settings.subscribers) active settings subscriptions, \(LocalAIModelResidencyController.refreshes - beforeChange) callbacks per change")
        check(LocalAIModelResidencyController.refreshes == beforeChange + 1, "Repeated profile changes never multiply callbacks")

        let beforePending = LocalAIModelResidencyController.refreshes
        settings.change()
        await owner!.prepareProfile()
        pump()
        check(settings.subscribers == 0 && owner!.controller == nil, "Queued old-profile event cannot recreate a retired controller")
        check(LocalAIModelResidencyController.refreshes == beforePending, "Retirement cancels pending debounce delivery")

        owner!.refreshLocalAIResidency()
        let heldController = owner!.controller!
        let gate = Gate(); heldController.shutdownGate = gate
        let beforeHeld = LocalAIModelResidencyController.refreshes
        settings.change()
        let retirement = Task { await owner!.prepareProfile() }
        for _ in 0..<10_000 { if gate.entered { break }; await Task.yield() }
        check(gate.entered, "Controller shutdown was entered")
        check(settings.subscribers == 0, "Settings observation ends before asynchronous shutdown joins")
        settings.change(); pump()
        check(LocalAIModelResidencyController.refreshes == beforeHeld, "No refresh enters a controller while its shutdown is held")
        gate.open(); await retirement.value
        check(owner!.controller == nil, "Controller retirement joins and clears its owned instance")

        owner!.refreshLocalAIResidency()
        settings.change()
        let beforeTermination = LocalAIModelResidencyController.refreshes
        await owner!.terminate(); pump()
        check(settings.subscribers == 0 && owner!.controller == nil, "Termination also cancels scoped observation and controller")
        check(LocalAIModelResidencyController.refreshes == beforeTermination, "No queued reconciliation survives termination")
        owner = nil; pump()
        check(weakOwner == nil && settings.subscribers == 0, "Settings stream cannot retain the application owner")
        var released: ResidencyObservationProbe? = ResidencyObservationProbe()
        released!.refreshLocalAIResidency()
        weak let releasedOwner = released
        weak let releasedController = released!.controller
        released = nil; pump()
        check(releasedOwner == nil && releasedController == nil, "Active observation does not strongly retain its application owner or controller")
        check(settings.subscribers == 0, "Owner release cancels an active scoped subscription")
        print("Local AI settings observation: \(checks) checks; \(failed ? "FAIL" : "PASS")")
        if failed { exit(1) }
    }
}
