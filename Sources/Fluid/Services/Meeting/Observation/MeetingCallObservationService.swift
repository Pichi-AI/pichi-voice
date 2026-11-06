#if os(macOS)
import Foundation

/// The single owner of call-discovery and active microphone-observation scheduling.
/// Platform adapters receive ticks; they do not add another production polling loop.
@MainActor
protocol MeetingCallDetectionDriving: AnyObject {
    func startManagedObservation()
    func stopManagedObservation()
    func pollManagedObservation() async
}

nonisolated protocol MeetingMicrophoneObservationPolling: AnyObject, Sendable {
    func start(externallyDriven: Bool)
    func requestPoll()
    func handleSharedPTT(_ event: MeetingMutePTTListener.Event)
    func stop() async
}

nonisolated protocol MeetingCallKeyListening: AnyObject, Sendable {
    func start() -> Bool
    func stop()
}

@MainActor
final class MeetingCallObservationService {
    static let shared = MeetingCallObservationService()
    typealias MicrophoneFactory = @Sendable (MeetingApplicationIdentity?,
        @escaping MeetingMicrophoneMuteMonitor.Handler) -> any MeetingMicrophoneObservationPolling
    typealias KeyListenerFactory = @Sendable (@escaping @Sendable (MeetingMutePTTListener.Event) -> Void) -> any MeetingCallKeyListening

    private weak var detectionDriver: (any MeetingCallDetectionDriving)?
    private let microphoneFactory: MicrophoneFactory
    private let keyListenerFactory: KeyListenerFactory
    private let automaticScheduling: Bool
    private struct ActiveObservation {
        let driver: any MeetingMicrophoneObservationPolling
        let delivery: DeliveryFence
    }
    private var microphones: [UUID: ActiveObservation] = [:]
    private var stoppingMicrophones: [UUID: Task<Void, Never>] = [:]
    private var scheduler: Task<Void, Never>?
    private var scheduledIntervalNanoseconds: UInt64?
    private var detectionPoll: Task<Void, Never>?
    private var detectionPollID: UUID?
    private var generation: UInt64 = 0
    private var lastDetectionPoll = -Double.infinity
    private var shuttingDown = false
    private let keyRouter = KeyRouter()
    private var keyListener: (any MeetingCallKeyListening)?

    private final nonisolated class DeliveryFence: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        func close() { self.lock.withLock { self.open = false } }
        func deliver(_ observation: MeetingMicrophoneMuteObservation,
                     to handler: MeetingMicrophoneMuteMonitor.Handler) {
            self.lock.withLock { if self.open { handler(observation) } }
        }
    }

    /// Keyboard releases must reach audio admission without waiting behind the UI actor.
    private final nonisolated class KeyRouter: @unchecked Sendable {
        private let lock = NSLock()
        private var recipients: [UUID: any MeetingMicrophoneObservationPolling] = [:]
        func add(_ recipient: any MeetingMicrophoneObservationPolling, id: UUID) {
            self.lock.withLock { self.recipients[id] = recipient }
        }
        func remove(id: UUID) { self.lock.withLock { _ = self.recipients.removeValue(forKey: id) } }
        func route(_ event: MeetingMutePTTListener.Event) {
            let recipients = self.lock.withLock { Array(self.recipients.values) }
            for recipient in recipients { recipient.handleSharedPTT(event) }
        }
    }

    init(automaticScheduling: Bool = true,
         microphoneFactory: @escaping MicrophoneFactory = { application, handler in
             MeetingCommunicationModuleHost.makeMicrophoneDriver(application: application, handler: handler)
         }, keyListenerFactory: @escaping KeyListenerFactory = { MeetingMutePTTListener(keyCodes: MeetingCommunicationModuleHost.observedKeyCodes, handler: $0) }) {
        self.automaticScheduling = automaticScheduling
        self.microphoneFactory = microphoneFactory
        self.keyListenerFactory = keyListenerFactory
    }

    var activeMicrophoneObservationCount: Int { self.microphones.count }
    var hasDetectionDriver: Bool { self.detectionDriver != nil }
    var pollingIntervalNanoseconds: UInt64? {
        guard self.detectionDriver != nil || !self.microphones.isEmpty else { return nil }
        return self.microphones.isEmpty ? 2_000_000_000 : 250_000_000
    }

    func attachDetection(_ driver: any MeetingCallDetectionDriving) {
        guard !self.shuttingDown else { return }
        if let existing = self.detectionDriver, existing === driver { return }
        self.detectionDriver?.stopManagedObservation()
        self.detectionPoll?.cancel()
        self.detectionDriver = driver
        self.lastDetectionPoll = -Double.infinity
        driver.startManagedObservation()
        self.reconcileScheduler()
    }

    func detachDetection(_ driver: (any MeetingCallDetectionDriving)?) {
        guard let driver, self.detectionDriver === driver else { return }
        driver.stopManagedObservation()
        self.detectionDriver = nil
        // Retain the task slot until its bounded native work returns. Restarting detection
        // cannot accumulate old HAL/AX requests while cancellation is being joined.
        self.detectionPoll?.cancel()
        self.reconcileScheduler()
    }

    func makeMicrophoneObservation(application: MeetingApplicationIdentity?,
        handler: @escaping MeetingMicrophoneMuteMonitor.Handler) -> MeetingCallMicrophoneObservation {
        MeetingCallMicrophoneObservation(service: self, application: application, handler: handler)
    }

    fileprivate func startMicrophone(id: UUID, application: MeetingApplicationIdentity?,
        handler: @escaping MeetingMicrophoneMuteMonitor.Handler) throws {
        guard self.microphones[id] == nil else { return }
        guard !self.shuttingDown, self.microphones.count + self.stoppingMicrophones.count < 8 else { throw MeetingCaptureError.captureAlreadyActive }
        let delivery = DeliveryFence()
        let microphone = self.microphoneFactory(application) { observation in delivery.deliver(observation, to: handler) }
        self.microphones[id] = ActiveObservation(driver: microphone, delivery: delivery)
        self.keyRouter.add(microphone, id: id)
        microphone.start(externallyDriven: true)
        if self.keyListener == nil {
            let router = self.keyRouter
            let listener = self.keyListenerFactory { event in router.route(event) }
            self.keyListener = listener
            _ = listener.start()
        }
        self.reconcileScheduler()
    }

    fileprivate func stopMicrophone(id: UUID) async {
        if let stopping = self.stoppingMicrophones[id] { await stopping.value; return }
        guard let observation = self.microphones.removeValue(forKey: id) else { return }
        observation.delivery.close()
        self.keyRouter.remove(id: id)
        if self.microphones.isEmpty {
            self.keyListener?.stop()
            self.keyListener = nil
        }
        self.reconcileScheduler()
        let stopping = Task { await observation.driver.stop() }
        self.stoppingMicrophones[id] = stopping
        await stopping.value
        self.stoppingMicrophones[id] = nil
    }

    /// The same scheduling seam is driven with deterministic clocks and fakes in XCTest.
    func pollOnce(at uptime: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        if self.pollingIntervalNanoseconds == nil { self.reconcileScheduler(); return }
        for microphone in self.microphones.values { microphone.driver.requestPoll() }
        guard let driver = self.detectionDriver, self.detectionPoll == nil,
              uptime - self.lastDetectionPoll >= 2 else { return }
        self.lastDetectionPoll = uptime
        let id = UUID()
        self.detectionPollID = id
        self.detectionPoll = Task { [weak self, weak driver] in
            await driver?.pollManagedObservation()
            guard let self, self.detectionPollID == id else { return }
            self.detectionPollID = nil
            self.detectionPoll = nil
        }
    }

    func shutdown() async {
        self.shuttingDown = true
        self.detectionDriver?.stopManagedObservation()
        self.detectionDriver = nil
        self.generation &+= 1
        self.scheduler?.cancel()
        let scheduler = self.scheduler
        self.scheduler = nil
        self.scheduledIntervalNanoseconds = nil
        self.detectionPoll?.cancel()
        let poll = self.detectionPoll
        let ids = Set(self.microphones.keys).union(self.stoppingMicrophones.keys)
        for id in ids { await self.stopMicrophone(id: id) }
        await poll?.value
        await scheduler?.value
        MeetingCommunicationAXProbe.shared.invalidate()
        self.shuttingDown = false
    }

    private func reconcileScheduler() {
        let desired = self.shuttingDown ? nil : self.pollingIntervalNanoseconds
        guard desired != self.scheduledIntervalNanoseconds else { return }
        self.scheduledIntervalNanoseconds = desired
        self.generation &+= 1
        let generation = self.generation
        self.scheduler?.cancel()
        self.scheduler = nil
        guard self.automaticScheduling, let nanos = desired else { return }
        self.scheduler = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, self.generation == generation else { return }
                self.pollOnce()
                do { try await Task.sleep(nanoseconds: nanos) }
                catch { return }
            }
        }
    }
}

/// Attempt-scoped ownership. The capture owner joins stop before retiring its audio sinks.
@MainActor
final class MeetingCallMicrophoneObservation {
    private let id = UUID()
    private let service: MeetingCallObservationService
    private let application: MeetingApplicationIdentity?
    private let handler: MeetingMicrophoneMuteMonitor.Handler
    private var stopped = false

    init(service: MeetingCallObservationService, application: MeetingApplicationIdentity?,
         handler: @escaping MeetingMicrophoneMuteMonitor.Handler) {
        self.service = service; self.application = application; self.handler = handler
    }

    nonisolated deinit {
        let service = self.service, id = self.id
        Task { @MainActor in await service.stopMicrophone(id: id) }
    }

    func start() throws {
        guard !self.stopped else { return }
        try self.service.startMicrophone(id: self.id, application: self.application, handler: self.handler)
    }

    func stop() async {
        self.stopped = true
        await self.service.stopMicrophone(id: self.id)
    }
}

extension MeetingAutoDetector: MeetingCallDetectionDriving {
    func startManagedObservation() { self.start(externallyDriven: true) }
    func stopManagedObservation() { self.stop() }
    func pollManagedObservation() async { await self.pollTick() }
}

extension MeetingMicrophoneMuteMonitor: MeetingMicrophoneObservationPolling {}
extension MeetingMutePTTListener: MeetingCallKeyListening {}
#endif
