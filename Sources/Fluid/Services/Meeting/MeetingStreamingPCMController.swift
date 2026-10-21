import Foundation

/// An attempt-scoped prepared adapter. Only the resource owner's worker may call it. The
/// adapter retains exact model selection and continuous speaker state; it owns no publication.
nonisolated protocol MeetingPreparedStreamingPCMProcessing: Sendable {
    func recognize(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                   preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingStreamingPCMObservation
    func finishStreaming() async throws -> MeetingStreamingPCMObservation
    func discardActivity(beforeSample: Int) async throws
    /// Joins mandatory downstream work before the next window's optional-work decision.
    func recordWindowProcessing(_ feedback: MeetingPCMWindowProcessingFeedback) async throws
}

extension MeetingPreparedStreamingPCMProcessing {
    func recordWindowProcessing(_ feedback: MeetingPCMWindowProcessingFeedback) async throws {}
}

nonisolated struct MeetingStreamingPCMObservation: Sendable {
    let batch: MeetingPCMTranscriptBatch
    let activity: [MeetingBackendSpeakerActivity]
    let acceptedThroughSample: Int
    let processedThroughSample: Int
    let retainedFromSample: Int
    let isFinal: Bool
    /// Physical source end of a sealed ASR window, including silence. Metadata-only
    /// speaker updates leave this nil so they cannot advance the stable speech prefix.
    let asrStableThroughSample: Int?
    /// Exact source interval of a sealed, complete ASR result with no words.
    /// This is a decoder result, not inferred VAD confidence or elapsed time.
    let sealedEmptyASRRange: Range<Int>?
    /// Exact acoustic owner decision, independent of text/privacy readiness. Nil leaves the
    /// prior decision unchanged; an empty set revokes it. Tokens never create participants.
    let confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken>?

    init(batch: MeetingPCMTranscriptBatch, activity: [MeetingBackendSpeakerActivity],
         acceptedThroughSample: Int, processedThroughSample: Int, retainedFromSample: Int,
         isFinal: Bool, asrStableThroughSample: Int? = nil,
         sealedEmptyASRRange: Range<Int>? = nil,
         confirmedLocalUserTokens: Set<MeetingBackendSpeakerToken>? = nil) {
        self.batch = batch
        self.activity = activity
        self.acceptedThroughSample = acceptedThroughSample
        self.processedThroughSample = processedThroughSample
        self.retainedFromSample = retainedFromSample
        self.isFinal = isFinal
        self.asrStableThroughSample = asrStableThroughSample
        self.sealedEmptyASRRange = sealedEmptyASRRange
        self.confirmedLocalUserTokens = confirmedLocalUserTokens
    }
}

nonisolated enum MeetingStreamingPCMControllerError: Error, Equatable {
    case concurrentOperation
    case closed
    case invalidScope
    case reentrantOperation
}

private nonisolated enum MeetingStreamingPCMCallContext {
    @TaskLocal static var controllerID: UUID?
}

/// Keeps native resources on one owned stack across windows. The existing PCM transport owns
/// the audio budget; this mailbox admits at most one command and never copies its PCM. The
/// creator must finish or cancelAndWait before releasing the attempt. Preview callbacks must
/// not recursively call this controller; publication still needs its normal generation check.
final nonisolated class MeetingStreamingPCMController: @unchecked Sendable {
    typealias ScopeOperation = @Sendable (
        @escaping @Sendable (any MeetingPreparedStreamingPCMProcessing) async throws -> Void
    ) async throws -> Void

    private enum Command: Sendable {
        case recognize(UUID, MeetingPCMProgressiveWindow, TimeInterval,
                       (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?,
                       CheckedContinuation<MeetingStreamingPCMObservation, Error>)
        case discard(UUID, Int, CheckedContinuation<Void, Error>)
        case processed(UUID, MeetingPCMWindowProcessingFeedback, CheckedContinuation<Void, Error>)
        case finish(UUID, CheckedContinuation<MeetingStreamingPCMObservation, Error>)

        var id: UUID {
            switch self { case .recognize(let id, _, _, _, _), .discard(let id, _, _), .processed(let id, _, _), .finish(let id, _): return id }
        }
        func fail(_ error: Error) {
            switch self {
            case .recognize(_, _, _, _, let reply), .finish(_, let reply): reply.resume(throwing: error)
            case .discard(_, _, let reply), .processed(_, _, let reply): reply.resume(throwing: error)
            }
        }
    }

    private let id = UUID()
    private let lock = NSLock()
    private var preparation: ScopeOperation?
    private var worker: Task<Void, Never>?
    private var prepared = false
    private var closed = false
    private var finishing = false
    private var terminalError: Error?
    private var readiness: CheckedContinuation<Void, Error>?
    private var command: Command?
    private var delivered = false
    private var waiting: CheckedContinuation<Command?, Never>?
    private var finalObservation: MeetingStreamingPCMObservation?

    private init(scope: @escaping ScopeOperation) { self.preparation = scope }

    /// Admit capture without opening native models first. The existing bounded PCM transport
    /// owns all samples while the first command waits for preparation. Creating this controller
    /// does not start a task or acquire model resources; Stop before any PCM still joins its
    /// final command, and cancellation before first use has no native work to abandon.
    static func deferred(using scope: @escaping ScopeOperation) -> MeetingStreamingPCMController {
        MeetingStreamingPCMController(scope: scope)
    }

    static func prepare(using scope: @escaping ScopeOperation) async throws -> MeetingStreamingPCMController {
        let controller = MeetingStreamingPCMController(scope: scope)
        controller.startIfNeeded()
        return try await controller.joined {
            try await controller.waitUntilReady()
            return controller
        }
    }

    func recognize(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                   preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)? = nil) async throws -> MeetingStreamingPCMObservation {
        try await self.submit { .recognize(UUID(), window, offset, preview, $0) }
    }

    /// Exactly once. Completion is delivered only after the enclosing resource operation has
    /// returned, including its cleanup on success or error. Repeated finish is a closed error.
    func finishStreaming() async throws -> MeetingStreamingPCMObservation {
        let result: MeetingStreamingPCMObservation = try await self.submit { .finish(UUID(), $0) }
        await self.join()
        try Task.checkCancellation()
        return result
    }

    func discardActivity(beforeSample: Int) async throws {
        try await self.submit { .discard(UUID(), beforeSample, $0) }
    }

    func recordWindowProcessing(_ feedback: MeetingPCMWindowProcessingFeedback) async throws {
        try await self.submit { .processed(UUID(), feedback, $0) }
    }

    /// A failed microphone start or an empty recording has no native state to flush. The
    /// transport calls this only after its sole worker has drained every accepted PCM window.
    /// Closing atomically prevents a racing first command from opening an abandoned scope.
    func cancelIfUnstarted() -> Bool {
        self.lock.withLock {
            guard self.worker == nil else { return false }
            self.closed = true
            self.preparation = nil
            return true
        }
    }

    func cancelAndWait() async {
        self.cancel()
        // A callback cannot await its own worker. Its owning public operation performs the
        // join when cancellation unwinds the callback and prepared resource scope.
        if MeetingStreamingPCMCallContext.controllerID == self.id { return }
        await self.join()
    }

    private func startIfNeeded() {
        self.lock.withLock {
            guard self.worker == nil, !self.closed, let scope = self.preparation else { return }
            self.preparation = nil
            self.worker = Task.detached(priority: .userInitiated) {
                await MeetingStreamingPCMCallContext.$controllerID.withValue(self.id) {
                    do {
                        try Task.checkCancellation()
                        // A prepared provider may bridge the body through its own detached
                        // executor. Bind at the actual command owner too, so callback reentry
                        // still rejects before trying to join this controller's outer worker.
                        try await scope { session in
                            try await MeetingStreamingPCMCallContext.$controllerID.withValue(self.id) {
                                try await self.run(session)
                            }
                        }
                        try Task.checkCancellation()
                        self.complete(error: nil)
                    } catch { self.complete(error: error) }
                }
            }
        }
    }

    private func waitUntilReady() async throws {
        try await withCheckedThrowingContinuation { continuation in
            let result = self.lock.withLock { () -> Result<Void, Error>? in
                if self.closed { return .failure(self.terminalError ?? CancellationError()) }
                if self.prepared { return .success(()) }
                guard self.readiness == nil else { return .failure(MeetingStreamingPCMControllerError.invalidScope) }
                self.readiness = continuation
                return nil
            }
            if let result { continuation.resume(with: result) }
        }
    }

    private func submit<Value: Sendable>(_ make: (CheckedContinuation<Value, Error>) -> Command) async throws -> Value {
        // A callback executing on this worker cannot join itself on rejection. Reject before
        // admission; its outer public call still joins any error propagated by the callback.
        guard MeetingStreamingPCMCallContext.controllerID != self.id else {
            throw MeetingStreamingPCMControllerError.reentrantOperation
        }
        return try await self.joined {
            self.startIfNeeded()
            try await self.waitUntilReady()
            return try await withCheckedThrowingContinuation { continuation in
                let proposed = make(continuation)
                do {
                    let waiter = try self.lock.withLock { () throws -> CheckedContinuation<Command?, Never>? in
                        guard self.prepared, !self.closed, !self.finishing else {
                            throw self.terminalError ?? MeetingStreamingPCMControllerError.closed
                        }
                        guard self.command == nil else { throw MeetingStreamingPCMControllerError.concurrentOperation }
                        self.command = proposed
                        if case .finish = proposed { self.finishing = true }
                        let waiter = self.waiting
                        self.waiting = nil
                        self.delivered = waiter != nil
                        return waiter
                    }
                    waiter?.resume(returning: proposed)
                } catch { proposed.fail(error) }
            }
        }
    }

    private func joined<Value>(_ work: () async throws -> Value) async throws -> Value {
        try await withTaskCancellationHandler {
            do {
                try Task.checkCancellation()
                let value = try await work()
                try Task.checkCancellation()
                return value
            } catch {
                self.cancel()
                await self.join()
                throw error
            }
        } onCancel: { self.cancel() }
    }

    private func join() async { await self.lock.withLock { self.worker }?.value }

    private func cancel() {
        let state = self.lock.withLock { () -> (Task<Void, Never>?, CheckedContinuation<Command?, Never>?) in
            self.closed = true
            self.preparation = nil
            let waiter = self.waiting
            self.waiting = nil
            return (self.worker, waiter)
        }
        state.0?.cancel()
        state.1?.resume(returning: nil)
    }

    private func run(_ session: any MeetingPreparedStreamingPCMProcessing) async throws {
        let ready = try self.lock.withLock { () throws -> CheckedContinuation<Void, Error>? in
            guard !self.closed else { throw CancellationError() }
            guard !self.prepared else { throw MeetingStreamingPCMControllerError.invalidScope }
            self.prepared = true
            let ready = self.readiness
            self.readiness = nil
            return ready
        }
        ready?.resume()
        while let command = await self.next() {
            try Task.checkCancellation()
            switch command {
            case .recognize(_, let window, let offset, let preview, let reply):
                let guardedPreview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?
                if let preview {
                    guardedPreview = { @Sendable batch in
                        try self.checkOpen()
                        try await preview(batch)
                        try self.checkOpen()
                    }
                } else { guardedPreview = nil }
                let value = try await session.recognize(window: window, offset: offset, preview: guardedPreview)
                try self.resolve(command.id)
                reply.resume(returning: value)
            case .discard(_, let sample, let reply):
                try await session.discardActivity(beforeSample: sample)
                try self.resolve(command.id)
                reply.resume()
            case .processed(_, let feedback, let reply):
                try await session.recordWindowProcessing(feedback)
                try self.resolve(command.id)
                reply.resume()
            case .finish:
                let value = try await session.finishStreaming()
                try self.checkOpen()
                guard value.isFinal else { throw MeetingStreamingPCMControllerError.invalidScope }
                self.lock.withLock { self.finalObservation = value }
                return
            }
        }
        throw CancellationError()
    }

    private func checkOpen() throws {
        try Task.checkCancellation()
        guard !self.lock.withLock({ self.closed }) else { throw CancellationError() }
    }

    private func resolve(_ id: UUID) throws {
        try self.checkOpen()
        try self.lock.withLock {
            guard !self.closed, self.command?.id == id else { throw CancellationError() }
            self.command = nil
            self.delivered = false
        }
    }

    private func next() async -> Command? {
        await withCheckedContinuation { continuation in
            let available = self.lock.withLock { () -> (Bool, Command?) in
                if self.closed { return (true, nil) }
                if let command = self.command, !self.delivered { self.delivered = true; return (true, command) }
                self.waiting = continuation
                return (false, nil)
            }
            if available.0 { continuation.resume(returning: available.1) }
        }
    }

    private func complete(error: Error?) {
        let result = self.lock.withLock { () -> (CheckedContinuation<Void, Error>?, Command?, MeetingStreamingPCMObservation?, Error) in
            let failure = error ?? (self.closed ? CancellationError() : MeetingStreamingPCMControllerError.invalidScope)
            let success = error == nil && !self.closed && self.finalObservation != nil
            self.closed = true
            self.terminalError = success ? MeetingStreamingPCMControllerError.closed : failure
            let state = (self.readiness, self.command, success ? self.finalObservation : nil, failure)
            self.readiness = nil
            self.command = nil
            self.finalObservation = nil
            return state
        }
        result.0?.resume(throwing: result.3)
        if let command = result.1 {
            if case .finish(_, let reply) = command, let final = result.2 { reply.resume(returning: final) }
            else { command.fail(result.3) }
        }
    }
}
