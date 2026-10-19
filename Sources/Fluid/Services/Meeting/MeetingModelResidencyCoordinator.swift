import Foundation
import Combine

/// An optional registered adapter can retain installed weights before a session exists.
/// The generic owner sees immutable identity and joined cleanup, never model-specific types.
nonisolated protocol MeetingIdlePreparedResource: Sendable {
    var configurationIdentity: String { get }
    func cleanup() async
}

nonisolated struct MeetingIdlePreparationToken: Equatable, Sendable { let id: UUID }

/// One-shot transfer of an idle preparation into an actual exclusive attempt. The loader
/// may still be running; callers join it only after microphone capture has been admitted.
@MainActor
final class MeetingIdlePreparedResourceClaim {
    let identity: String
    private let task: Task<(any MeetingIdlePreparedResource)?, Error>
    private var cleanupTask: Task<Void, Never>?

    init(identity: String, task: Task<(any MeetingIdlePreparedResource)?, Error>) {
        self.identity = identity; self.task = task
    }

    func resource() async throws -> (any MeetingIdlePreparedResource)? {
        guard cleanupTask == nil else { throw CancellationError() }
        let resource = try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
        try Task.checkCancellation()
        guard cleanupTask == nil else { throw CancellationError() }
        if let resource, resource.configurationIdentity != identity { throw MeetingModelResidencyError.staleGrant }
        return resource
    }

    func cleanup() async {
        if let cleanupTask { await cleanupTask.value; return }
        let task = self.task
        task.cancel()
        let cleanup = Task {
            if let resource = try? await task.value { await resource.cleanup() }
        }
        cleanupTask = cleanup
        await cleanup.value
    }
}

/// A single installed-resource preparation slot. Its coordinator token closes idle
/// admission during a native load and while ready weights are parked. Real work either
/// atomically adopts its claim or cancels and joins it before ordinary admission.
@MainActor
final class MeetingIdlePreparedResourceOwner {
    private struct Slot {
        let token: MeetingIdlePreparationToken
        let claim: MeetingIdlePreparedResourceClaim
    }
    private let residency: MeetingModelResidencyCoordinator
    private var slot: Slot?
    private var draining: Task<Void, Never>?

    init(residency: MeetingModelResidencyCoordinator = .shared) { self.residency = residency }

    func prepare(identity: String,
                 load: @escaping @MainActor @Sendable () async throws -> (any MeetingIdlePreparedResource)?) async throws -> MeetingIdlePreparationToken? {
        try Task.checkCancellation()
        guard slot == nil, draining == nil else { return nil }
        let token = MeetingIdlePreparationToken(id: UUID())
        // The coordinator retains this owner while its token is parked. A disappearing
        // UI/pipeline cannot orphan native work behind a weak retirement callback.
        try residency.beginIdlePreparation(token: token, identity: identity,
            adopt: { self.take(token) }, retire: { await self.cancel(token) })
        let task = Task(priority: .utility) {
            try await MeetingModelContext.$grant.withValue(nil) { try await load() }
        }
        let claim = MeetingIdlePreparedResourceClaim(identity: identity, task: task)
        slot = Slot(token: token, claim: claim)
        do {
            let resource = try await withTaskCancellationHandler { try await task.value } onCancel: {
                Task { @MainActor in await self.cancel(token) }
            }
            try Task.checkCancellation()
            guard slot?.token == token else { return nil }
            guard resource?.configurationIdentity == identity else {
                await cancel(token)
                return nil
            }
            return token
        } catch {
            await cancel(token)
            throw error
        }
    }

    private func take(_ token: MeetingIdlePreparationToken) -> MeetingIdlePreparedResourceClaim? {
        guard slot?.token == token else { return nil }
        let claim = slot?.claim
        slot = nil
        return claim
    }

    func cancel(_ token: MeetingIdlePreparationToken) async {
        if let draining { await draining.value; return }
        guard slot?.token == token else { return }
        let claim = slot!.claim
        // Remove only the exact slot. Admission stays closed until its cleanup has joined.
        slot = nil
        let residency = self.residency
        let task = Task { @MainActor in
            await claim.cleanup()
            residency.endIdlePreparation(token)
        }
        draining = task
        await task.value
        draining = nil
    }
}

nonisolated enum MeetingModelResidencyError: LocalizedError {
    case busy
    case staleGrant
    case terminating
    case unsupportedProvider

    var errorDescription: String? {
        switch self {
        case .busy: return "Models are busy. Wait for the current model operation to finish."
        case .staleGrant: return "This model operation no longer owns meeting processing."
        case .terminating: return "The app is shutting down."
        case .unsupportedProvider: return "This Fluid provider needs an update before meeting model switching can run."
        }
    }
}

nonisolated struct MeetingResidentModel: Equatable, Sendable {
    let id: String
    let configuration: String
}

@MainActor
struct MeetingModelParticipant {
    let owner: String
    let snapshot: () async throws -> MeetingResidentModel?
    let suspend: () async throws -> Void
    let restore: (MeetingResidentModel) async throws -> Void
    var finish: () async -> Void = {}
}

nonisolated struct MeetingModelGrant: Sendable {
    let attempt: UUID
    let generation: UUID
    let owner: String
    let modelID: String
}

nonisolated enum MeetingModelContext {
    @TaskLocal static var grant: MeetingModelGrant?
}

/// Admission and restoration have one owner. Snapshots contain values, never model references.
@MainActor
final class MeetingModelResidencyCoordinator {
    static let shared = MeetingModelResidencyCoordinator()

    enum Phase: String, Sendable {
        case normal, suspending, transcription, summary, cleaning, restoring, terminating
    }

    private(set) var phase: Phase = .normal
    private(set) var restorationErrors: [String] = []
    private var attempt: UUID?
    private var generation = UUID()
    private var operations: Set<UUID> = []
    private var vetoedOwners: Set<String> = []
    private var terminating = false
    private struct IdlePreparation {
        let token: MeetingIdlePreparationToken
        let identity: String
        let adopt: () -> MeetingIdlePreparedResourceClaim?
        let retire: () async -> Void
    }
    private var idlePreparation: IdlePreparation?
    private var idleDrain: Task<Void, Never>?
    private var priorityAdmissions = 0
    /// Native resource operations use executable admission. Foreground readiness observes
    /// their completion to retry once, without a timer or feedback from idle loads themselves.
    let ordinaryOperationEvents = PassthroughSubject<Void, Never>()
    var hasOrdinaryOperations: Bool { !operations.isEmpty || priorityAdmissions > 0 }

    var isExclusive: Bool { self.attempt != nil || self.terminating }

    var warmupGeneration: UUID? { self.isExclusive ? nil : self.generation }

    func canRunWarmup(_ generation: UUID?) -> Bool {
        generation != nil && generation == self.warmupGeneration
    }

    func beginOperation(owner: String, modelID: String) throws -> UUID {
        guard !self.terminating else { throw MeetingModelResidencyError.terminating }
        guard self.idlePreparation == nil, self.idleDrain == nil else { throw MeetingModelResidencyError.busy }
        if let attempt {
            guard self.phase == .restoring || (self.phase == .transcription && owner == "speech"),
                  let grant = MeetingModelContext.grant,
                  grant.attempt == attempt, grant.generation == self.generation, grant.owner == owner, grant.modelID == modelID,
                  !self.vetoedOwners.contains(owner)
            else { throw MeetingModelResidencyError.busy }
        } else if MeetingModelContext.grant != nil {
            throw MeetingModelResidencyError.staleGrant
        }
        let token = UUID()
        self.operations.insert(token)
        ordinaryOperationEvents.send()
        return token
    }

    func endOperation(_ token: UUID) {
        if self.operations.remove(token) != nil { ordinaryOperationEvents.send() }
    }

    func beginIdlePreparation(token: MeetingIdlePreparationToken, identity: String,
                              adopt: @escaping () -> MeetingIdlePreparedResourceClaim?,
                              retire: @escaping () async -> Void) throws {
        guard !terminating, attempt == nil, operations.isEmpty, priorityAdmissions == 0, MeetingModelContext.grant == nil,
              idlePreparation == nil, idleDrain == nil else { throw MeetingModelResidencyError.busy }
        idlePreparation = .init(token: token, identity: identity, adopt: adopt, retire: retire)
    }

    func endIdlePreparation(_ token: MeetingIdlePreparationToken) {
        if idlePreparation?.token == token { idlePreparation = nil }
    }

    func retireIdlePreparation() async {
        if let idleDrain { await idleDrain.value; return }
        guard let selected = idlePreparation else { return }
        idlePreparation = nil
        let task = Task { @MainActor in await selected.retire() }
        idleDrain = task
        await task.value
        idleDrain = nil
    }

    /// Real service entry points use this admission. Native idle calls are joined before
    /// the unchanged ordinary busy/grant checks run; no user retry is required for warmup.
    func beginOperationRetiringIdle(owner: String, modelID: String) async throws -> UUID {
        priorityAdmissions += 1
        defer { priorityAdmissions -= 1; ordinaryOperationEvents.send() }
        await retireIdlePreparation()
        try Task.checkCancellation()
        return try beginOperation(owner: owner, modelID: modelID)
    }

    func vetoOrBeginOperationRetiringIdle(owner: String, modelID: String, vetoDuringMeeting: Bool) async throws -> UUID? {
        priorityAdmissions += 1
        defer { priorityAdmissions -= 1; ordinaryOperationEvents.send() }
        await retireIdlePreparation()
        return try vetoOrBeginOperation(owner: owner, modelID: modelID, vetoDuringMeeting: vetoDuringMeeting)
    }

    /// Decide whether an unload belongs to the meeting or ordinary work in one actor turn.
    /// Separate checks allow a meeting to start between checking exclusivity and admission.
    func vetoOrBeginOperation(owner: String, modelID: String, vetoDuringMeeting: Bool) throws -> UUID? {
        if self.isExclusive {
            if vetoDuringMeeting { self.vetoRestoration(owner: owner) }
            return nil
        }
        return try self.beginOperation(owner: owner, modelID: modelID)
    }

    /// Background enrollment may hold a second ASR model outside the transcription executor.
    /// Keep admission until the actual model call returns, even when its caller is cancelled.
    func withBackgroundOperation<T>(owner: String, modelID: String, work: () async throws -> T) async throws -> T {
        try Task.checkCancellation()
        let token: UUID
        do { token = try await self.beginOperationRetiringIdle(owner: owner, modelID: modelID) } catch { throw CancellationError() } // Optional background work must remain retryable.
        defer { self.endOperation(token) }
        let result = try await work()
        try Task.checkCancellation()
        return result
    }

    /// Explicit unload/disable may remove restoration eligibility, never add a new model.
    func vetoRestoration(owner: String) { if self.attempt != nil { self.vetoedOwners.insert(owner) } }

    func beginTermination() {
        self.terminating = true
        self.phase = .terminating
    }

    nonisolated static func ordinary<T: Sendable>(
        owner: String, modelID: String, work: () async throws -> T
    ) async throws -> T {
        let token = try await self.shared.beginOperationRetiringIdle(owner: owner, modelID: modelID)
        do {
            let value = try await work()
            await self.shared.endOperation(token)
            return value
        } catch {
            await self.shared.endOperation(token)
            throw error
        }
    }

    /// Compatibility backend uses the selected speech provider inside the exclusive meeting scope.
    /// This capability never admits Fluid models or ordinary warmups from another task.
    func withLegacySpeechModel<T>(modelID: String, work: () async throws -> T) async throws -> T {
        guard let attempt, self.phase == .transcription else { throw MeetingModelResidencyError.staleGrant }
        let grant = MeetingModelGrant(attempt: attempt, generation: self.generation, owner: "speech", modelID: modelID)
        return try await MeetingModelContext.$grant.withValue(grant, operation: work)
    }

    func markSummary() throws {
        guard self.attempt != nil, self.phase == .transcription else { throw MeetingModelResidencyError.staleGrant }
        self.phase = .summary
    }

    func withExclusive<T>(
        attemptID: UUID, participants: [MeetingModelParticipant],
        acceptsCompletedCancellation: (T) -> Bool = { _ in false }, work: () async throws -> T
    ) async throws -> T {
        try await withExclusive(attemptID: attemptID, participants: participants,
            idleResourceIdentity: nil, acceptsCompletedCancellation: acceptsCompletedCancellation) { _ in try await work() }
    }

    func withExclusive<T>(
        attemptID: UUID, participants: [MeetingModelParticipant], idleResourceIdentity: String?,
        acceptsCompletedCancellation: (T) -> Bool = { _ in false },
        work: (MeetingIdlePreparedResourceClaim?) async throws -> T
    ) async throws -> T {
        try Task.checkCancellation()
        guard !self.terminating else { throw MeetingModelResidencyError.terminating }
        guard Set(participants.map(\.owner)).count == participants.count else { throw MeetingModelResidencyError.busy }
        priorityAdmissions += 1
        defer { priorityAdmissions -= 1 }
        var prepared: MeetingIdlePreparedResourceClaim?
        if let identity = idleResourceIdentity, let idle = idlePreparation, idle.identity == identity,
           attempt == nil, operations.isEmpty, idleDrain == nil {
            // Transfer and close ordinary admission in this same actor turn. There is no
            // suspended gap in which Settings/dictation can retire an adopted resource.
            prepared = idle.adopt()
            idlePreparation = nil
        } else {
            await retireIdlePreparation()
        }
        do {
            try Task.checkCancellation()
            guard !self.terminating else { throw MeetingModelResidencyError.terminating }
            guard self.attempt == nil, self.operations.isEmpty else { throw MeetingModelResidencyError.busy }
        } catch {
            await prepared?.cleanup()
            throw error
        }
        self.generation = UUID()
        self.attempt = attemptID
        self.phase = .suspending
        self.vetoedOwners.removeAll()
        self.restorationErrors.removeAll()
        var snapshots: [(MeetingModelParticipant, MeetingResidentModel)] = []
        var suspendedOwners: Set<String> = []
        do {
            // Close admission before any await, then snapshot everyone before unloading anyone.
            for participant in participants {
                if let snapshot = try await participant.snapshot() { snapshots.append((participant, snapshot)) }
                try Task.checkCancellation()
            }
            for participant in participants {
                suspendedOwners.insert(participant.owner)
                try await participant.suspend()
                try Task.checkCancellation()
                guard !self.terminating else { throw MeetingModelResidencyError.terminating }
            }
            self.phase = .transcription
            let value = try await work(prepared)
            if !acceptsCompletedCancellation(value) { try Task.checkCancellation() }
            await prepared?.cleanup()
            await self.finish(attemptID: attemptID, snapshots: snapshots.filter { suspendedOwners.contains($0.0.owner) }, participants: participants)
            return value
        } catch {
            await prepared?.cleanup()
            await self.finish(attemptID: attemptID, snapshots: snapshots.filter { suspendedOwners.contains($0.0.owner) }, participants: participants)
            throw error
        }
    }

    private func finish(attemptID: UUID, snapshots: [(MeetingModelParticipant, MeetingResidentModel)], participants: [MeetingModelParticipant]) async {
        guard self.attempt == attemptID else { return }
        self.phase = self.terminating ? .terminating : .cleaning
        // An unstructured joined task does not inherit the caller's cancelled status. Restoration
        // must run after a cancelled meeting, but never after termination has been requested.
        let cleanup = Task { @MainActor in
            for (participant, model) in snapshots {
                guard !self.terminating else { break }
                guard !self.vetoedOwners.contains(participant.owner) else { continue }
                self.phase = .restoring
                let grant = MeetingModelGrant(attempt: attemptID, generation: self.generation, owner: participant.owner, modelID: model.id)
                do {
                    try await MeetingModelContext.$grant.withValue(grant) {
                        try await participant.restore(model)
                    }
                    if self.vetoedOwners.contains(participant.owner) || self.terminating {
                        try await participant.suspend()
                    }
                } catch {
                    // A failed load may still own partial allocations. Drain them before another
                    // participant restores, and report the unloaded fallback without losing output.
                    try? await participant.suspend()
                    self.restorationErrors.append("\(participant.owner): \(error.localizedDescription)")
                    DebugLogger.shared.warning("Meeting saved; \(participant.owner) model could not reload: \(error.localizedDescription)", source: "MeetingModelResidency")
                }
            }
        }
        await cleanup.value
        for participant in participants {
            await participant.finish()
        }
        guard self.attempt == attemptID else { return }
        self.attempt = nil
        self.vetoedOwners.removeAll()
        self.phase = self.terminating ? .terminating : .normal
    }
}
