import Foundation

// Shared test-only policies. Native drivers supply already-owned controls and clocks.
@MainActor enum PhysicalControlReveal {
    struct NotVisible: Error {}

    // Preserve the frozen 6641 driver's direction/cancellation contract as well as legacy callers.
    static func run(startingUpward: Bool = true, ready: () throws -> Bool, scroll: (Bool, Int) throws -> Void) throws {
        // The reverse leg first covers the outbound travel, then searches above
        // the original position even when the first leg never reached an edge.
        for (upward, limit) in [(startingUpward, 5), (!startingUpward, 10)] {
            for step in 0..<limit {
                if try ready() { return }
                try scroll(upward, step)
            }
        }
        guard try ready() else { throw NotVisible() }
    }
}

@MainActor enum PhysicalUITransitionWait {
    struct TimedOut: Error {}
    enum OwnedRecordingAction: Equatable { case requestStop, join }

    static func ownedRecordingAction(stopReady: Bool, processing: Bool, completed: Bool) -> OwnedRecordingAction? {
        if processing || completed { return .join }
        return stopReady ? .requestStop : nil
    }

    static func until(timeout: TimeInterval, condition: () -> Bool,
                      now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                      pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }) async throws {
        let deadline = now() + timeout
        while true {
            try Task.checkCancellation()
            if condition() { return }
            guard now() < deadline else { throw TimedOut() }
            try await pause()
        }
    }
}

@MainActor enum PhysicalOwnedRecordingCleanup {
    struct OperationAndCleanupFailure: Error {
        let operationError: Error
        let cleanupError: Error
    }

    struct StopAndJoinFailure: Error {
        let stopError: Error
        let joinError: Error
    }

    /// An async defer: cleanup has its own cancellation lifetime and is always joined.
    static func withJoinedCleanup(operation: () async throws -> Void,
                                  cleanup: @escaping @MainActor () async throws -> Void) async throws {
        var operationError: Error?
        do { try await operation() } catch { operationError = error }
        let task = Task { @MainActor in try await cleanup() }
        do { try await task.value }
        catch {
            if let operationError {
                throw OperationAndCleanupFailure(operationError: operationError, cleanupError: error)
            }
            throw error
        }
        if let operationError { throw operationError }
    }

    static func run(observe: () -> PhysicalUITransitionWait.OwnedRecordingAction?,
                    stop: () async throws -> Void, join: () async throws -> Void,
                    now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
                    pause: () async throws -> Void = { try await Task.sleep(nanoseconds: 250_000_000) }) async throws {
        var action: PhysicalUITransitionWait.OwnedRecordingAction?
        try await PhysicalUITransitionWait.until(timeout: 30, condition: {
            action = observe()
            return action != nil
        }, now: now, pause: pause)
        var stopError: Error?
        if action == .requestStop {
            do { try await stop() }
            catch {
                stopError = error
                let failure = error as NSError
                print("[PHYSICAL_RECORDING_UI] stop_failed_before_join domain=\(failure.domain) code=\(failure.code)")
            }
        }
        do { try await join() }
        catch {
            let failure = error as NSError
            print("[PHYSICAL_RECORDING_UI] join_failed domain=\(failure.domain) code=\(failure.code)")
            if let stopError { throw StopAndJoinFailure(stopError: stopError, joinError: error) }
            throw error
        }
        if let stopError { throw stopError }
    }
}
