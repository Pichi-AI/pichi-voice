import Foundation

// Synthetic service/profile/draft seams only. The runner extracts the actual production
// participant declaration; this is not a native target or account-provider runtime test.
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}
struct PrivateProfileSnapshot: Equatable, Sendable {
    var id: String
    var generation: UUID
}
@MainActor enum PrivateProfileStorage {
    static var current = PrivateProfileSnapshot(id: "guest", generation: UUID())
    static var acceptsNewWork = true
    static func isReadable(_ profile: PrivateProfileSnapshot) -> Bool { current == profile }
}
@MainActor final class PrivateProfileService {
    static let shared = PrivateProfileService()
    var projectionRevision = UUID()
    var isPrivateDataVisible = true
    var isTransitioning = false
    private(set) var registrations = 0
    func register(_ participant: any PrivateProfileTransitionParticipant) { registrations += 1 }
}
@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var meetingAudioRetentionPolicy = 7
}
struct MeetingSessionID: Equatable { let value: Int }
struct MeetingSession { let id: MeetingSessionID }
@MainActor struct MeetingTranscriptionSetupDraft {
    var title = "New meeting"
    var titleWasEdited = false
    var mode = "call"
    init(settings: SettingsStore) {}
    static func defaultTitle(mode: String, applicationDisplayName: String?) -> String { "New meeting" }
}

@MainActor private final class Gate {
    var continuation: CheckedContinuation<Void, Never>?
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func open() { continuation?.resume(); continuation = nil }
}

@main struct MeetingViewPrivateProjectionTests {
    @MainActor static func main() async throws {
        var assertions = 0
        func check(_ value: @autoclosure () -> Bool, _ message: String) {
            precondition(value(), message); assertions += 1
        }
        let service = PrivateProfileService.shared
        let state = MeetingViewPrivateProjection()
        check(service.registrations == 1, "actual participant registers")
        let initial = state.capture()!
        check(state.accepts(initial), "visible guest work admitted")
        service.projectionRevision = UUID()
        check(!state.accepts(initial), "render token refuses a changed projection")
        let beforeConceal = state.capture()!
        service.isPrivateDataVisible = false
        check(state.capture() == nil && !state.accepts(beforeConceal), "conceal closes read/action admission")
        service.isPrivateDataVisible = true
        service.isTransitioning = true
        check(state.capture() == nil, "transition refuses new work")
        service.isTransitioning = false
        PrivateProfileStorage.acceptsNewWork = false
        check(state.capture() == nil && !state.accepts(beforeConceal), "storage admission is authoritative")
        PrivateProfileStorage.acceptsNewWork = true
        PrivateProfileStorage.current.generation = UUID()
        check(!state.accepts(beforeConceal), "same ID with a different generation is refused")

        state.selectedHistorySessionID = MeetingSessionID(value: 1)
        state.resumedSummarySession = MeetingSession(id: MeetingSessionID(value: 1))
        state.pendingDeleteSessionID = MeetingSessionID(value: 2)
        state.pendingDeleteAudioSessionID = MeetingSessionID(value: 3)
        state.renameSessionID = MeetingSessionID(value: 4)
        state.renameDraft = "Private title"; state.searchText = "Private speaker"
        state.setupDraft.title = "Private draft"; state.setupDraft.titleWasEdited = true
        state.setupDraftBeforeEditing.title = "Private original"
        state.actionErrorMessage = "Private path"; state.isShowingMeetingSettings = true
        state.pendingBackupSetupRefresh = true
        let gate = Gate()
        var started = false
        var finished = false
        var observedCancellation = false
        state.run { stamp in
            started = true
            await gate.wait() // Deliberately ignores cancellation to prove cleanup joins.
            observedCancellation = Task.isCancelled
            if state.accepts(stamp) { state.actionErrorMessage = "Stale result" }
            finished = true
        }
        while !started { await Task.yield() }
        service.isPrivateDataVisible = false; service.projectionRevision = UUID()
        var joined = false
        let cleanup = Task { try await state.prepareForPrivateProfileTransition(); joined = true }
        while state.selectedHistorySessionID != nil { await Task.yield() }
        check(!joined && !finished, "transition waits for cancellation-ignoring owned work")
        check(state.resumedSummarySession == nil, "resumed session cleared before join")
        check(state.pendingDeleteSessionID == nil && state.pendingDeleteAudioSessionID == nil, "delete payloads cleared")
        check(state.renameSessionID == nil && state.renameDraft.isEmpty && state.searchText.isEmpty, "rename/search payloads cleared")
        check(state.actionErrorMessage == nil && !state.isShowingMeetingSettings, "error and sheet cleared")
        check(state.setupDraft.title == "New meeting" && !state.setupDraft.titleWasEdited, "private edited title cleared")
        check(state.setupDraftBeforeEditing.title == "New meeting" && !state.pendingBackupSetupRefresh, "private original/restore state cleared")
        gate.open(); try await cleanup.value
        check(joined && finished && observedCancellation, "cleanup cancels and joins view work")
        check(state.actionErrorMessage == nil, "late completion cannot republish private data")

        service.isPrivateDataVisible = true
        PrivateProfileStorage.current = .init(id: "account-b", generation: UUID())
        check(!state.accepts(initial) && state.capture() != nil, "next account accepts only its own work")
        let typedGate = Gate()
        var typedStarted = false
        let resultTask = Task {
            await state.result { _ in
                typedStarted = true
                await typedGate.wait()
                return "Private old error"
            }
        }
        while !typedStarted { await Task.yield() }
        service.isPrivateDataVisible = false; service.projectionRevision = UUID()
        var typedJoined = false
        let typedCleanup = Task { try await state.prepareForPrivateProfileTransition(); typedJoined = true }
        for _ in 0..<20 { await Task.yield() }
        check(!typedJoined, "typed mutation is also retained through its join")
        typedGate.open(); try await typedCleanup.value
        let typedResult = await resultTask.value
        check(typedJoined && typedResult == nil, "stale typed completion suppressed")

        var hiddenRan = false
        state.run { _ in hiddenRan = true }
        for _ in 0..<20 { await Task.yield() }
        check(!hiddenRan, "hidden view cannot start queued readers or exports")
        service.isPrivateDataVisible = true
        let beforeEpoch = state.capture()!
        try await state.prepareForPrivateProfileTransition()
        check(!state.accepts(beforeEpoch), "joined cleanup independently invalidates old callbacks")
        check(state.capture() != nil, "new work remains possible after completed activation")
        print("Meeting private view participant: \(assertions) assertions passed (synthetic seams)")
    }
}
