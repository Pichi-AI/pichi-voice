import Combine
import Foundation

/// Composition owns the gap between N1's published context and its joined command.
/// This is an activation task owner, not a second account or profile lifecycle.
@MainActor final class PichiCloudPublicationActivation {
    let service: PichiCloudPublicationService
    private let account: AccountSessionService
    private let profiles: PrivateProfileService
    private var observers = Set<AnyCancellable>()
    private var installation: Task<Void, Error>?
    private var activation: Task<Void, Never>?
    private var revision = UUID()
    private var closed = false
    private(set) var isInstalled = false

    init(service: PichiCloudPublicationService, account: AccountSessionService, profiles: PrivateProfileService) {
        self.service = service; self.account = account; self.profiles = profiles
    }

    /// AppServices awaits this before restore. Its profile admission stays closed until
    /// the observer and existing transition participant have both been installed.
    func install() async throws {
        guard !closed else { throw AccountError.staleOperation }
        if isInstalled { return }
        if installation == nil {
            installation = Task { @MainActor in try await service.install() }
        }
        try await installation?.value
        guard !closed else { throw AccountError.staleOperation }
        guard !isInstalled else { return }
        isInstalled = true
        account.$context.sink { [weak self] _ in self?.scheduleActivation() }.store(in: &observers)
        account.$state.sink { [weak self] _ in self?.scheduleActivation() }.store(in: &observers)
        account.$generation.sink { [weak self] _ in self?.scheduleActivation() }.store(in: &observers)
        profiles.$sourceRevision.sink { [weak self] _ in self?.scheduleActivation() }.store(in: &observers)
        profiles.$projectionRevision.sink { [weak self] _ in self?.scheduleActivation() }.store(in: &observers)
        scheduleActivation()
    }

    /// Also called after the awaited initial restore and committed-source restoration.
    func activateAfterAccountCommand() async {
        scheduleActivation()
        await activation?.value
    }

    private func scheduleActivation() {
        guard isInstalled, !closed else { return }
        revision = UUID()
        let expectedRevision = revision, previous = activation
        previous?.cancel()
        activation = Task { @MainActor [weak self] in
            // Even cancellation of an in-flight facade command must join before its successor.
            await previous?.value
            guard let self, !Task.isCancelled, !self.closed, self.revision == expectedRevision else { return }
            // @Published notifies from willSet. Capture committed values on the next turn.
            await Task.yield()
            guard !Task.isCancelled, !self.closed, self.revision == expectedRevision else { return }
            guard self.account.configuration != nil, let context = self.account.context else {
                try? await self.service.refresh() // Clears any previous owner's presentation.
                return
            }
            let profile = PrivateProfileStorage.current, sourceRevision = self.profiles.sourceRevision
            @MainActor func matches() -> Bool {
                !Task.isCancelled && !self.closed && self.revision == expectedRevision
                    && self.account.context == context && self.account.generation == context.generation
                    && self.profiles.sourceRevision == sourceRevision
                    && !self.profiles.isTransitioning && self.profiles.isPrivateDataVisible
                    && profile.context == context && PrivateProfileStorage.current == profile
                    && PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork
            }
            guard matches() else { try? await self.service.refresh(); return }
            // N1 publishes the verified context before clearing its command/operation slots.
            // No later publisher is guaranteed. The short bounded wait covers only that tail.
            let deadline = ContinuousClock.now.advanced(by: .seconds(5))
            while !self.account.isCurrent(context) {
                guard matches() else { return }
                guard self.account.state == .signedIn, ContinuousClock.now < deadline else {
                    try? await self.service.refresh()
                    return
                }
                do { try await Task.sleep(for: .milliseconds(20)) } catch { return }
            }
            guard matches(), self.account.isCurrent(context) else { return }
            do { try await self.service.activateCurrentProfile() }
            catch {
                guard matches(), self.account.isCurrent(context) else { return }
                try? await self.service.refresh()
            }
        }
    }

    func shutdown() async {
        closed = true; revision = UUID(); observers.removeAll()
        activation?.cancel(); await activation?.value; activation = nil
        // Installation is local-only. Join it before shutting down the installed observer.
        _ = await installation?.result; installation = nil
        await service.shutdown()
    }
}
