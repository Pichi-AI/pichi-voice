import Combine
import Foundation

/// Owned by the window, so leaving FluidMeet does not discard its last loaded history.
@MainActor
final class MeetingHistorySnapshot: ObservableObject, PrivateProfileTransitionParticipant {
    @Published private(set) var sessions: [MeetingSession] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false
    private let load: @Sendable () async throws -> [MeetingSession]
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false
    private let profile = PrivateProfileStorage.current

    init(load: @escaping @Sendable () async throws -> [MeetingSession] = {
        try await MeetingSessionStore.shared.loadAll()
    }) {
        self.load = load
        PrivateProfileService.shared.register(self)
    }

    /// The coordinator returns this value only after its store commit succeeds.
    /// Corrections do not require decoding every other meeting before updating UI.
    func applyCommitted(_ session: MeetingSession) {
        guard PrivateProfileStorage.isReadable(self.profile) else { return }
        if let index = self.sessions.firstIndex(where: { $0.id == session.id }) {
            self.sessions[index] = session
        } else {
            self.sessions.append(session)
            self.sessions.sort { $0.startedAt > $1.startedAt }
        }
        self.errorMessage = nil
        self.hasLoaded = true
        // An older in-flight disk read cannot overwrite the committed local value.
        // Its existing owner performs the follow-up, without blocking this action.
        if self.refreshTask != nil { self.refreshRequested = true }
    }

    func refresh() async {
        guard PrivateProfileStorage.isReadable(self.profile) else { return }
        self.refreshRequested = true
        if let refreshTask {
            await refreshTask.value
            return
        }
        let task = Task { @MainActor in
            // A mutation during a disk read requests one follow-up, never a competing read.
            while self.refreshRequested {
                self.refreshRequested = false
                do {
                    let sessions = try await self.load()
                    guard !Task.isCancelled, PrivateProfileStorage.isReadable(self.profile) else { break }
                    guard !self.refreshRequested else { continue }
                    self.sessions = sessions
                    self.errorMessage = nil
                    self.hasLoaded = true
                } catch {
                    guard !Task.isCancelled, PrivateProfileStorage.isReadable(self.profile) else { break }
                    guard !self.refreshRequested else { continue }
                    self.errorMessage = PichiLocalization.text("Meeting history could not be loaded.")
                    self.hasLoaded = true
                }
            }
            self.refreshTask = nil
        }
        self.refreshTask = task
        await task.value
    }

    func prepareForPrivateProfileTransition() async throws {
        refreshRequested = false
        let task = refreshTask; task?.cancel()
        await task?.value
        refreshTask = nil; sessions = []; errorMessage = nil; hasLoaded = false
    }
}
