import Combine
import Foundation

/// Windows own transient private readers. The profile boundary joins them before replacing sources.
@MainActor protocol PrivateProfileTransitionParticipant: AnyObject {
    func prepareForPrivateProfileTransition() async throws
}

/// N1's single composition-owned local-data participant. This service stores no auth credentials.
@MainActor final class PrivateProfileService: ObservableObject, AccountSessionLifecycle {
    static let shared = PrivateProfileService()
    static let willConceal = Notification.Name("SettingsStore.privateProfileWillChange")
    @Published private(set) var projectionRevision = UUID()
    @Published private(set) var sourceRevision = UUID()
    @Published private(set) var isTransitioning = false
    @Published private(set) var isPrivateDataVisible = true
    private var installed = false
    private var isBusy: @MainActor () -> Bool = { true }
    private var prepareSources: @MainActor () async throws -> Void = {}
    private var activateSources: @MainActor (PrivateProfileSnapshot) async throws -> Void = { _ in }
    private var pendingWrites: [UUID: Task<Void, Never>] = [:]
    private var captureStopHandler: (id: UUID, stop: @MainActor () async -> Void)?
    private struct WeakParticipant { weak var value: (any PrivateProfileTransitionParticipant)? }
    private var participants: [WeakParticipant] = []

    var isAccountIsolationReady: Bool {
        installed && !isTransitioning && isPrivateDataVisible && !isBusy()
    }

    /// Called once by the app composition after every concrete private store hook is installed.
    func configure(isBusy: @escaping @MainActor () -> Bool,
                   prepare: @escaping @MainActor () async throws -> Void,
                   activate: @escaping @MainActor (PrivateProfileSnapshot) async throws -> Void) throws {
        guard !installed else { throw AccountError.busy }
        self.isBusy = isBusy; self.prepareSources = prepare; self.activateSources = activate
        installed = true
    }

    func register(_ participant: any PrivateProfileTransitionParticipant) {
        participants.removeAll { $0.value == nil }
        guard !participants.contains(where: { $0.value === participant }) else { return }
        participants.append(.init(value: participant))
    }

    func retainPrivateWrite(_ task: Task<Void, Never>, id: UUID) { pendingWrites[id] = task }
    func finishPrivateWrite(id: UUID) { pendingWrites.removeValue(forKey: id) }
    func installCaptureStopHandler(id: UUID, stop: @escaping @MainActor () async -> Void) {
        captureStopHandler = (id, stop)
    }
    func clearCaptureStopHandler(id: UUID) {
        if captureStopHandler?.id == id { captureStopHandler = nil }
    }
    var hasRetainedCaptureStopHandler: Bool { captureStopHandler != nil }
    func requestCaptureStop() async { await captureStopHandler?.stop() }
    private func joinPrivateWrites() async {
        while !pendingWrites.isEmpty {
            for task in Array(pendingWrites.values) { await task.value }
        }
    }

    /// UI can refuse an explicit switch before asking N1 to mutate account/workspace state.
    /// N1's follow-up preflight hook can call this same check, without another account manager.
    func requireTransitionAdmission() throws {
        guard installed, !isTransitioning, isPrivateDataVisible,
              PrivateProfileStorage.acceptsNewWork, !isBusy() else { throw AccountError.busy }
    }

    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async throws {
        guard installed, !isTransitioning else { throw AccountError.busy }
        if to != nil { try Task.checkCancellation() }
        if isBusy() {
            if to == nil {
                // Offline logout still clears N1's credentials. Keep the old admitted writer,
                // hide every private projection and require cleanup retry after capture drains.
                isTransitioning = true
                defer { isTransitioning = false }
                PrivateProfileStorage.closeAdmission()
                isPrivateDataVisible = false; projectionRevision = UUID()
                PrivateProfileStorage.conceal(generation: generation)
                NotificationCenter.default.post(name: Self.willConceal, object: nil)
                try await joinConcealedOperations(generation: generation)
            }
            throw AccountError.busy
        }
        let next = try PrivateProfileStorage.proposed(context: to, generation: generation)
        isTransitioning = true; isPrivateDataVisible = false; projectionRevision = UUID()
        PrivateProfileStorage.closeAdmission()
        do {
            PrivateProfileStorage.conceal(generation: generation)
            NotificationCenter.default.post(name: Self.willConceal, object: nil)
            try await joinConcealedOperations(generation: generation)
            try await prepareSources()
            guard !isBusy() else { throw AccountError.busy }
            PrivateProfileStorage.conceal(generation: generation)
            await PrivateProfileMeetingStore.shared.finishProfileTransition()
            PrivateProfileStorage.clearStoreCaches()
            PrivateProfileObjectCache.removeAll()
            captureStopHandler = nil
            if to != nil { try Task.checkCancellation() }
            try Self.prepareDirectory(next.rootDirectory)
            PrivateProfileStorage.select(next)
            PrivateProfileStorage.closeAdmission()
            try await activateSources(next)
            if to != nil { try Task.checkCancellation() }
            try PrivateProfileStorage.persistAccessMarker(next)
            PrivateProfileStorage.select(next)
            isPrivateDataVisible = true; projectionRevision = UUID(); sourceRevision = UUID(); isTransitioning = false
        } catch {
            // No fallback to another account. Failed cleanup leaves private reads concealed
            // until N1 performs its explicit joined guest rollback/logout cleanup retry.
            PrivateProfileStorage.conceal(generation: generation)
            isPrivateDataVisible = false; isTransitioning = false
            try? PrivateProfileStorage.persistAccessMarker(PrivateProfileStorage.current)
            throw error
        }
    }

    /// A failed marker or reader cannot let the credential owner return before other admitted
    /// work has joined. Preserve the first failure and leave the old scope concealed for retry.
    private func joinConcealedOperations(generation: UUID) async throws {
        var firstFailure: (any Error)?
        do { try persistHiddenMarker(generation: generation) }
        catch { firstFailure = error }
        await joinPrivateWrites()
        for participant in participants.compactMap(\.value) {
            do { try await participant.prepareForPrivateProfileTransition() }
            catch { if firstFailure == nil { firstFailure = error } }
        }
        if let firstFailure { throw firstFailure }
    }

    private func persistHiddenMarker(generation: UUID) throws {
        let profile = PrivateProfileStorage.current
        try PrivateProfileStorage.persistAccessMarker(.init(id: profile.id, context: profile.context,
            generation: generation, rootDirectory: profile.rootDirectory,
            legacyRootDirectory: profile.legacyRootDirectory, isReadable: false))
    }

    private static func prepareDirectory(_ url: URL) throws {
        let manager = FileManager.default
        if manager.fileExists(atPath: url.path) {
            let attributes = try manager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw AccountError.isolationRequired }
        } else {
            try manager.createDirectory(at: url, withIntermediateDirectories: true,
                attributes: [.posixPermissions: NSNumber(value: 0o700)])
        }
        try manager.setAttributes([.posixPermissions: NSNumber(value: 0o700)], ofItemAtPath: url.path)
        #if os(iOS)
        try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        #endif
    }
}
