import Foundation
import Combine
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// A publication attempt retains N2's immutable source and the concealment revision.
/// This is a view-work fence, never a selected profile or account manager.
struct MobilePrivatePublicationContext: Equatable {
    let profile: PrivateProfileSnapshot
    let projectionRevision: UUID
}

/// Owns only cancellable private presentation work. Capture/finalization stays with
/// the meeting coordinator and is never cancelled by this owner.
@MainActor
final class MobilePrivatePublicationTasks: ObservableObject {
    struct Admission {
        let context: MobilePrivatePublicationContext
        fileprivate let epoch: UUID
    }
    @Published private(set) var busyCount = 0
    private var jobs: [UUID: Task<Void, Never>] = [:]
    private var epoch = UUID()
    private var isClosing = false
    private var joinTask: Task<Void, Never>?
    private let capture: @MainActor () -> MobilePrivatePublicationContext?
    private let validate: @MainActor (MobilePrivatePublicationContext) -> Bool

    init(capture: @escaping @MainActor () -> MobilePrivatePublicationContext?,
         validate: @escaping @MainActor (MobilePrivatePublicationContext) -> Bool) {
        self.capture = capture; self.validate = validate
    }

    func admit() -> Admission? {
        guard !isClosing, let context = capture(), validate(context) else { return nil }
        return Admission(context: context, epoch: epoch)
    }

    func canPublish(_ admission: Admission) -> Bool {
        !Task.isCancelled && !isClosing && admission.epoch == epoch && validate(admission.context)
    }

    @discardableResult
    func start(affectsBusy: Bool = true,
               report: @escaping @MainActor (Error) -> Void = { _ in },
               finished: @escaping @MainActor () -> Void = {},
               operation: @escaping @MainActor (Admission) async throws -> Void) -> Task<Void, Never>? {
        guard let admission = admit() else { return nil }
        let id = UUID()
        if affectsBusy { busyCount += 1 }
        let task = Task { @MainActor in
            defer {
                self.jobs.removeValue(forKey: id)
                if affectsBusy { self.busyCount -= 1 }
                // Callers can own a command lock before the operation is entered.
                // Cancellation at admission must release it too.
                finished()
            }
            do {
                guard self.canPublish(admission) else { return }
                try await operation(admission)
            } catch {
                guard self.canPublish(admission), !(error is CancellationError) else { return }
                report(error)
            }
        }
        jobs[id] = task
        return task
    }

    /// Immediate concealment invalidates publication before any asynchronous join.
    func cancel() {
        isClosing = true; epoch = UUID()
        for job in jobs.values { job.cancel() }
    }

    func cancelAndJoin() async {
        if let joinTask { await joinTask.value; return }
        cancel()
        let pending = Array(jobs.values)
        let task = Task { @MainActor in
            for pending in pending { await pending.value }
            self.joinTask = nil
        }
        joinTask = task
        await task.value
    }

    func resume() {
        guard jobs.isEmpty, joinTask == nil else { return }
        isClosing = false
    }
}

#if os(iOS)
/// The recording screen and restricted mode share the process idle timer. Only the last owner
/// restores its previous value; releasing another cannot turn the timer back on under a recording.
@MainActor
final class MobileScreenAwakeRegistry {
    static let shared = MobileScreenAwakeRegistry(
        getDisabled: { UIApplication.shared.isIdleTimerDisabled },
        setDisabled: { UIApplication.shared.isIdleTimerDisabled = $0 })

    private let getDisabled: () -> Bool
    private let setDisabled: (Bool) -> Void
    private var owners = Set<UUID>()
    private var previousValue: Bool?

    init(getDisabled: @escaping () -> Bool, setDisabled: @escaping (Bool) -> Void) {
        self.getDisabled = getDisabled
        self.setDisabled = setDisabled
    }

    func acquire() -> UUID {
        if owners.isEmpty {
            previousValue = getDisabled()
            setDisabled(true)
        }
        let token = UUID()
        owners.insert(token)
        return token
    }

    func release(_ token: UUID) {
        guard owners.remove(token) != nil, owners.isEmpty else { return }
        if let previousValue { setDisabled(previousValue) }
        previousValue = nil
    }
}
#endif
