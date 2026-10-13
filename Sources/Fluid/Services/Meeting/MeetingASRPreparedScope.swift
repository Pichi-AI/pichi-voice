import Foundation

/// Owns the prepared ASR body as well as its provider claim. Extracted from ASRService so
/// every platform joins cancellation before releasing the provider or audio activity lease.
@MainActor
final class MeetingASRPreparedScope {
    private struct Scope {
        let id: UUID
        let lease: ASRActivityLease
        var cancelBody: (() -> Void)?
        var awaitBodyCompletion: (() async -> Void)?
    }
    private var scope: Scope?
    var isActive: Bool { self.scope != nil }
    var lease: ASRActivityLease? { self.scope?.lease }

    func cancelAndWait() async {
        let captured = self.scope
        captured?.cancelBody?()
        await captured?.awaitBodyCompletion?()
    }

    func run<Result>(
        lease: ASRActivityLease,
        attemptID: UUID,
        configuration: MeetingFinalProcessingConfiguration,
        owner: MeetingASRPreparationOwner,
        isActiveLease: @escaping (ASRActivityLease) -> Bool,
        body: @escaping (any TranscriptionProvider) async throws -> Result
    ) async throws -> Result {
        try Task.checkCancellation()
        guard self.scope == nil else { throw MeetingASRPreparationError.preparationInProgress }
        let scopeID = UUID()
        self.scope = Scope(id: scopeID, lease: lease)
        defer { if self.scope?.id == scopeID { self.scope = nil } }
        let provider = try await owner.prepare(lease: lease, attemptID: attemptID, configuration: configuration)
        guard isActiveLease(lease), let token = owner.currentClaimToken, token.lease == lease else {
            if let token = owner.currentClaimToken { await owner.release(token) }
            throw CancellationError()
        }
        do {
            let bodyTask = Task { @MainActor in try await body(provider) }
            guard self.scope?.id == scopeID else {
                bodyTask.cancel()
                _ = await bodyTask.result
                throw CancellationError()
            }
            self.scope?.cancelBody = { bodyTask.cancel() }
            self.scope?.awaitBodyCompletion = { _ = await bodyTask.result }
            let result = try await withTaskCancellationHandler {
                try await bodyTask.value
            } onCancel: { bodyTask.cancel() }
            if bodyTask.isCancelled { throw CancellationError() }
            try Task.checkCancellation()
            await owner.release(token)
            return result
        } catch {
            await owner.release(token)
            throw error
        }
    }
}
