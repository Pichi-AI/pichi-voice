import Combine
import Foundation

// Only OS and neighboring domain boundaries are inert. The owner/plan are compiled from source.
nonisolated enum MeetingCaptureMode: Sendable { case inRoom, onlineCall }
typealias MeetingSessionID = UUID
nonisolated enum MeetingCoordinatorState: Sendable {
    case idle, preparing(UUID), recording(UUID), recordingDegraded(UUID), stopping(UUID)
    case processing(UUID, Int), completed(UUID), interrupted(UUID), failed(UUID?, String)
}
nonisolated struct PrivateProfileSnapshot: Sendable, Equatable {
    let id: String
    let generation: UUID
    var isGuest: Bool { id == "guest" }
}
nonisolated enum PrivateProfileStorage {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var selected = PrivateProfileSnapshot(id: "A", generation: UUID())
    nonisolated(unsafe) private static var readable = true
    nonisolated(unsafe) private static var admission = true
    static var current: PrivateProfileSnapshot { lock.withLock { selected } }
    static var acceptsNewWork: Bool { lock.withLock { admission } }
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool {
        lock.withLock { readable && profile == selected }
    }
    static func select(_ profile: PrivateProfileSnapshot, open: Bool = true) {
        lock.withLock { selected = profile; readable = open; admission = open }
    }
}
nonisolated struct MeetingProfileOwnership: Sendable {
    let id: String
    func matches(_ profile: PrivateProfileSnapshot) -> Bool { id == profile.id }
}
nonisolated struct MeetingSession: Sendable {
    let id: UUID
    let startedAt: Date
    let mode: MeetingCaptureMode
    let profileOwnership: MeetingProfileOwnership?
}
@MainActor final class MeetingSessionCoordinator {
    @Published var state: MeetingCoordinatorState = .idle
    @Published var activeSession: MeetingSession?
    private(set) var stopCalls = 0
    var isRecording: Bool {
        switch state { case .recording, .recordingDegraded: true; default: false }
    }
    func stop() { stopCalls += 1; state = .idle }
}
@MainActor final class SettingsStore { static let shared = SettingsStore() }
nonisolated enum UIApplication { static let willTerminateNotification = Notification.Name("InertWillTerminate") }
nonisolated enum DebugLogger {
    static var shared: DebugLogger.Type { self }
    static func warning(_ message: String, source: String) {}
}
nonisolated protocol InertActivityAttributes: Sendable { associatedtype ContentState: Sendable }
nonisolated struct MobileRecordingActivityAttributes: InertActivityAttributes {
    nonisolated struct ContentState: Sendable { let startedAt: Date }
    let sessionID: UUID
}
nonisolated struct ActivityContent<State: Sendable>: Sendable {
    let state: State
    let staleDate: Date?
}
nonisolated enum ActivityUIDismissalPolicy { case immediate }
nonisolated struct ActivityAuthorizationInfo { var areActivitiesEnabled: Bool { OSState.allowed } }
nonisolated private enum InertRefusal: Error { case refused }
private actor Gate {
    private var open = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if open { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func release() { open = true; for waiter in waiters { waiter.resume() }; waiters.removeAll() }
}
nonisolated private enum OSState {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var history: [String] = []
    nonisolated(unsafe) private static var handles: [AnyObject] = []
    nonisolated(unsafe) private static var endHold: Gate?
    nonisolated(unsafe) private static var updateHold: Gate?
    nonisolated(unsafe) private static var enabled = true
    static var events: [String] { lock.withLock { history } }
    static var allowed: Bool { get { lock.withLock { enabled } } set { lock.withLock { enabled = newValue } } }
    static var endGate: Gate? { get { lock.withLock { endHold } } set { lock.withLock { endHold = newValue } } }
    static var updateGate: Gate? { get { lock.withLock { updateHold } } set { lock.withLock { updateHold = newValue } } }
    static func record(_ event: String) { lock.withLock { history.append(event) } }
    static func add(_ value: AnyObject) { lock.withLock { handles.append(value) } }
    static func remove(_ value: AnyObject) { lock.withLock { handles.removeAll { $0 === value } } }
    static func current<A>() -> [A] { lock.withLock { handles.compactMap { $0 as? A } } }
    static func reset() { lock.withLock { history = []; handles = []; endHold = nil; updateHold = nil; enabled = true } }
}
nonisolated final class Activity<Attributes: InertActivityAttributes>: @unchecked Sendable {
    let id = UUID().uuidString
    let attributes: Attributes
    init(attributes: Attributes) { self.attributes = attributes }
    static var activities: [Activity<Attributes>] { OSState.current() }
    static func request(attributes: Attributes, content: ActivityContent<Attributes.ContentState>, pushType: String?) throws -> Activity<Attributes> {
        guard OSState.allowed else { throw InertRefusal.refused }
        let activity = Activity(attributes: attributes)
        OSState.add(activity)
        if let typed = attributes as? MobileRecordingActivityAttributes { OSState.record("request:\(typed.sessionID)") }
        return activity
    }
    func update(_ content: ActivityContent<Attributes.ContentState>) async {
        OSState.record("update-start:\(id)")
        await OSState.updateGate?.wait()
        OSState.record("update-end:\(id)")
    }
    func end(_ content: ActivityContent<Attributes.ContentState>?, dismissalPolicy: ActivityUIDismissalPolicy) async {
        OSState.record("end-start:\(id)")
        await OSState.endGate?.wait()
        OSState.record("end:\(id)")
        OSState.remove(self)
    }
}

@main struct MobileRecordingActivityLifecycleTests {
    @MainActor static var checks = 0
    @MainActor static func expect(_ value: @autoclosure () -> Bool, _ message: String) {
        precondition(value(), message); checks += 1
    }
    @MainActor static func eventually(_ condition: @escaping () -> Bool) async {
        for _ in 0..<500 {
            if condition() { return }
            try? await Task.sleep(for: .milliseconds(1))
        }
        precondition(condition(), "Inert asynchronous action did not finish")
    }
    @MainActor static func recording(_ id: UUID = UUID()) -> MobileRecordingActivityPlan.Recording {
        .init(sessionID: id, startedAt: Date(timeIntervalSince1970: 100), mode: .inRoom)
    }
    @MainActor static func requests(_ id: UUID) -> Int { OSState.events.filter { $0 == "request:\(id)" }.count }
    @MainActor static func freshProfile(_ id: String = "A") -> PrivateProfileSnapshot {
        let value = PrivateProfileSnapshot(id: id, generation: UUID()); PrivateProfileStorage.select(value); return value
    }
    @MainActor static func main() async {
        // Startup cleanup is joined before any new activity request.
        OSState.reset(); _ = freshProfile()
        let old = Activity<MobileRecordingActivityAttributes>(attributes: .init(sessionID: UUID()))
        OSState.add(old); let startupGate = Gate(); OSState.endGate = startupGate
        let startupOwner = MobileRecordingActivityOwner()
        let startupRecording = recording()
        var restored = false
        let restoration = Task { @MainActor in await startupOwner.resumeAfterProfileCommit(); restored = true }
        await eventually { OSState.events.contains("end-start:\(old.id)") }
        startupOwner.apply(startupRecording)
        for _ in 0..<5 { await Task.yield() }
        expect(!restored && requests(startupRecording.sessionID) == 0, "Startup cannot present before old end joins")
        await startupGate.release(); await restoration.value
        startupOwner.apply(startupRecording)
        await eventually { requests(startupRecording.sessionID) == 1 }
        expect(OSState.events.firstIndex(of: "end:\(old.id)")! < OSState.events.firstIndex(of: "request:\(startupRecording.sessionID)")!, "Old activity ends before new request")
        startupOwner.apply(startupRecording); startupOwner.apply(startupRecording)
        for _ in 0..<5 { await Task.yield() }
        expect(requests(startupRecording.sessionID) == 1, "Repeated active values never duplicate requests")
        await startupOwner.shutdown()

        // A new session waits for old end; a superseded pending start never reaches the OS.
        OSState.reset(); _ = freshProfile()
        let owner = MobileRecordingActivityOwner(); await owner.resumeAfterProfileCommit()
        let a = recording(), b = recording(), c = recording(); owner.apply(a)
        await eventually { requests(a.sessionID) == 1 }
        let aHandle = Activity<MobileRecordingActivityAttributes>.activities[0]
        let endGate = Gate(); OSState.endGate = endGate
        owner.apply(b); owner.apply(c)
        await eventually { OSState.events.contains("end-start:\(aHandle.id)") }
        expect(requests(b.sessionID) == 0 && requests(c.sessionID) == 0, "Held end prevents replacement starts")
        await endGate.release(); await eventually { requests(c.sessionID) == 1 }
        expect(requests(b.sessionID) == 0, "Superseded start is canceled and joined")
        expect(OSState.events.firstIndex(of: "end:\(aHandle.id)")! < OSState.events.firstIndex(of: "request:\(c.sessionID)")!, "Replacement is ordered after end")
        await owner.shutdown()

        // Busy logout joins an in-flight update, then ends presentation, never stopping capture.
        OSState.reset(); let profile = freshProfile()
        let updateGate = Gate(); OSState.updateGate = updateGate
        let busy = MobileRecordingActivityOwner(waitForRefresh: { try await Task.sleep(for: .milliseconds(1)) })
        let coordinator = MeetingSessionCoordinator(); let sessionID = UUID()
        coordinator.activeSession = MeetingSession(id: sessionID, startedAt: Date(), mode: .inRoom, profileOwnership: .init(id: profile.id))
        coordinator.state = .recording(sessionID); busy.observe(coordinator)
        await busy.resumeAfterProfileCommit()
        await eventually { requests(sessionID) == 1 }
        let active = Activity<MobileRecordingActivityAttributes>.activities[0]
        await eventually { OSState.events.contains("update-start:\(active.id)") }
        PrivateProfileStorage.select(profile, open: false)
        var concealed = false
        let conceal = Task { @MainActor in await busy.conceal(admittedSessionID: sessionID); concealed = true }
        for _ in 0..<10 { await Task.yield() }
        expect(!concealed && !OSState.events.contains("end-start:\(active.id)"), "Conceal waits in-flight refresh before end")
        expect(coordinator.isRecording && coordinator.stopCalls == 0, "Busy logout never stops admitted capture")
        await updateGate.release(); await conceal.value
        expect(OSState.events.firstIndex(of: "update-end:\(active.id)")! < OSState.events.firstIndex(of: "end:\(active.id)")!, "OS end follows the joined update")
        expect(Activity<MobileRecordingActivityAttributes>.activities.isEmpty, "Conceal removes external recording presentation")
        _ = freshProfile("B"); await busy.resumeAfterProfileCommit(); busy.apply(recording(sessionID))
        for _ in 0..<10 { await Task.yield() }
        expect(requests(sessionID) == 1, "Hidden admitted session cannot resurrect after profile restore")
        let next = UUID(); coordinator.activeSession = MeetingSession(id: next, startedAt: Date(), mode: .inRoom, profileOwnership: .init(id: "B")); coordinator.state = .recording(next)
        await eventually { requests(next) == 1 }
        expect(coordinator.stopCalls == 0, "New profile presentation does not alter capture authority")
        await busy.shutdown()

        // A late post-end start is rejected even for the same profile ID with a new generation.
        OSState.reset(); let original = freshProfile(); let late = MobileRecordingActivityOwner(); await late.resumeAfterProfileCommit()
        let first = recording(), stale = recording(); late.apply(first); await eventually { requests(first.sessionID) == 1 }
        let oldHandle = Activity<MobileRecordingActivityAttributes>.activities[0]; let generationGate = Gate(); OSState.endGate = generationGate
        late.apply(stale); await eventually { OSState.events.contains("end-start:\(oldHandle.id)") }
        PrivateProfileStorage.select(.init(id: original.id, generation: UUID()))
        await generationGate.release(); for _ in 0..<20 { await Task.yield() }
        expect(requests(stale.sessionID) == 0, "Late start cannot cross a generation boundary")
        await late.shutdown()

        // Termination waits the same background cleanup chain while the main actor is blocked.
        OSState.reset(); _ = freshProfile(); let exitOwner = MobileRecordingActivityOwner(); await exitOwner.resumeAfterProfileCommit()
        let exitRecording = recording(); exitOwner.apply(exitRecording); await eventually { requests(exitRecording.sessionID) == 1 }
        let exitGate = Gate(); OSState.endGate = exitGate
        Task.detached { try? await Task.sleep(for: .milliseconds(20)); await exitGate.release() }
        expect(exitOwner.endBeforeExit(timeout: 1), "Termination can join end without main-actor deadlock")
        expect(Activity<MobileRecordingActivityAttributes>.activities.isEmpty, "Termination completes actual queued OS end")
        exitOwner.apply(recording()); for _ in 0..<10 { await Task.yield() }
        expect(OSState.events.filter { $0.hasPrefix("request:") }.count == 1, "Terminating owner never reopens admission")
        await exitOwner.shutdown()

        OSState.reset(); _ = freshProfile(); let timeoutOwner = MobileRecordingActivityOwner(); await timeoutOwner.resumeAfterProfileCommit()
        let timeoutRecording = recording(); timeoutOwner.apply(timeoutRecording); await eventually { requests(timeoutRecording.sessionID) == 1 }
        let timeoutGate = Gate(); OSState.endGate = timeoutGate
        expect(!timeoutOwner.endBeforeExit(timeout: 0.002), "Unfinished OS cleanup reports bounded termination failure")
        await timeoutGate.release(); await timeoutOwner.shutdown()
        expect(Activity<MobileRecordingActivityAttributes>.activities.isEmpty, "Ordinary shutdown still joins retained cleanup after deadline")

        OSState.reset(); _ = freshProfile(); OSState.allowed = false
        let disabled = MobileRecordingActivityOwner(); await disabled.resumeAfterProfileCommit(); let denied = recording(); disabled.apply(denied)
        for _ in 0..<10 { await Task.yield() }
        OSState.allowed = true; disabled.apply(denied); for _ in 0..<10 { await Task.yield() }
        expect(requests(denied.sessionID) == 0, "Unavailable request is not retried for same session")
        await disabled.shutdown()
        print("PASS: \(checks) actual Activity owner lifecycle assertions; inert OS only")
    }
}
