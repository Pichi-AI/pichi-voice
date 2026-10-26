import Foundation

/// Retains the existing async UI operation so account transitions can cancel and join it.
/// This adds ownership to existing command/rewrite/file services, without another pipeline.
@MainActor final class PrivateProfileOperationOwner: PrivateProfileTransitionParticipant {
    private let profile = PrivateProfileStorage.current
    private var retired = false
    private struct Work {
        let cancel: @MainActor () -> Void
        let join: @MainActor () async -> Void
    }
    private var work: [UUID: Work] = [:]
    init(registerForTransitions: Bool = false) {
        if registerForTransitions { PrivateProfileService.shared.register(self) }
    }
    var isCurrent: Bool { !retired && PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork }

    /// Register a synchronously admitted resource before starting its async work.
    /// Completion must be reported only after the concrete resource has joined.
    func admit(cancel: @escaping @MainActor () -> Void,
               join: @escaping @MainActor () async -> Void) -> UUID? {
        guard isCurrent, !Task.isCancelled else { return nil }
        let id = UUID()
        work[id] = .init(cancel: cancel, join: join)
        return id
    }

    func complete(_ id: UUID) { work.removeValue(forKey: id) }

    func perform<Value: Sendable>(_ operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        guard isCurrent, !Task.isCancelled else { throw CancellationError() }
        let id = UUID()
        let task = Task { @MainActor in
            guard self.isCurrent, !Task.isCancelled else { throw CancellationError() }
            return try await operation()
        }
        work[id] = .init(cancel: { task.cancel() }, join: { _ = await task.result })
        defer { work.removeValue(forKey: id) }
        let value = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        guard isCurrent, !Task.isCancelled else { throw CancellationError() }
        return value
    }

    func retireAndJoin() async {
        retired = true
        let operations = Array(work.values)
        for operation in operations { operation.cancel() }
        for operation in operations { await operation.join() }
        work.removeAll()
    }
    func prepareForPrivateProfileTransition() async throws { await retireAndJoin() }
}
