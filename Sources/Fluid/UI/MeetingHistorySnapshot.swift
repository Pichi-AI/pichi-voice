import Combine
import Foundation

/// Owned by the window, so leaving FluidMeet does not discard its last loaded history.
@MainActor
final class MeetingHistorySnapshot: ObservableObject {
    @Published private(set) var sessions: [MeetingSession] = []
    @Published private(set) var errorMessage: String?
    @Published private(set) var hasLoaded = false
    private let load: @Sendable () async throws -> [MeetingSession]
    private var refreshTask: Task<Void, Never>?
    private var refreshRequested = false

    init(load: @escaping @Sendable () async throws -> [MeetingSession] = {
        try await MeetingSessionStore.shared.loadAll()
    }) {
        self.load = load
    }

    func refresh() async {
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
                    guard !self.refreshRequested else { continue }
                    self.sessions = sessions
                    self.errorMessage = nil
                    self.hasLoaded = true
                } catch {
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
}
