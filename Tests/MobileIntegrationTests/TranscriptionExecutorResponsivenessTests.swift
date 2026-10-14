import Foundation
#if !PICHI_EXECUTOR_RESPONSIVENESS_STANDALONE
import XCTest
@testable import PichiVoiceMobile
#endif

/// A bounded stand-in for synchronous native allocation/teardown. Its gate can
/// only be opened by MainActor while the operation is running, so merely waiting
/// for an asynchronous sleep would not prove responsiveness.
final nonisolated class BlockingNativeProbe: @unchecked Sendable {
    private let lock = NSLock()
    private let releaseGate = DispatchSemaphore(value: 0)
    private var entered = false
    private var finished = false
    private var onMainThread = false

    var hasEntered: Bool { lock.withLock { entered } }
    var hasFinished: Bool { lock.withLock { finished } }
    var ranOnMainThread: Bool { lock.withLock { onMainThread } }

    func run() -> Bool {
        lock.withLock { entered = true; onMainThread = Thread.isMainThread }
        let released = releaseGate.wait(timeout: .now() + 3) == .success
        lock.withLock { finished = true }
        return released
    }

    func release() { releaseGate.signal() }
}

private enum ExecutorResponsivenessCases {
    struct Failure: Error { let message: String }

    static func require(_ condition: @autoclosure () -> Bool, _ message: String) throws {
        guard condition() else { throw Failure(message: message) }
    }

    @MainActor static func waitForEntry(_ probe: BlockingNativeProbe) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(1))
        while !probe.hasEntered, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try require(probe.hasEntered && !probe.hasFinished, "Native operation did not enter independently of MainActor")
    }

    @MainActor static func heartbeatDuringBlockingNativeWork() async throws {
        let executor = TranscriptionExecutor()
        let probe = BlockingNativeProbe()
        let work = Task { @MainActor in try await executor.runBlocking { probe.run() } }
        do {
            try await waitForEntry(probe)
            var previous = ContinuousClock.now
            for _ in 0..<8 {
                try await Task.sleep(for: .milliseconds(20))
                let now = ContinuousClock.now
                try require(previous.duration(to: now) < .milliseconds(250), "MainActor heartbeat stalled during native work")
                try require(!probe.hasFinished, "Native work ended before the responsiveness probe")
                previous = now
            }
            try require(!probe.ranOnMainThread, "Native work ran on the UI thread")
            probe.release()
            let released = try await work.value
            try require(released && probe.hasFinished, "Native completion was not joined")
        } catch {
            probe.release(); work.cancel(); _ = await work.result
            throw error
        }
    }

    @MainActor static func cancellationJoinsNativeWorkWhileUIContinues() async throws {
        let executor = TranscriptionExecutor()
        let probe = BlockingNativeProbe()
        let work = Task { @MainActor in try await executor.runBlocking { probe.run() } }
        do {
            try await waitForEntry(probe)
            work.cancel()
            try await Task.sleep(for: .milliseconds(50))
            try require(!probe.hasFinished, "Cancellation abandoned the still-running native call")
            probe.release()
            do {
                _ = try await work.value
                throw Failure(message: "Cancelled native result was published")
            } catch is CancellationError {}
            try require(probe.hasFinished, "Cancellation returned before native ownership ended")
            let successor = try await executor.runBlocking { !Thread.isMainThread }
            try require(successor, "Successor returned to the UI thread")
        } catch {
            probe.release(); work.cancel(); _ = await work.result
            throw error
        }
    }
}

#if PICHI_EXECUTOR_RESPONSIVENESS_STANDALONE
@main private struct ExecutorResponsivenessStandalone {
    static func main() async throws {
        try await ExecutorResponsivenessCases.heartbeatDuringBlockingNativeWork()
        try await ExecutorResponsivenessCases.cancellationJoinsNativeWorkWhileUIContinues()
        print("PASS: MainActor heartbeat during blocking native work; joined cancellation and successor admission")
    }
}
#else
@MainActor final class TranscriptionExecutorResponsivenessTests: XCTestCase {
    func testMainActorHeartbeatDuringBlockingNativePreparation() async throws {
        try await ExecutorResponsivenessCases.heartbeatDuringBlockingNativeWork()
    }
    func testCancellationJoinsBlockingNativeWorkWhileUIContinues() async throws {
        try await ExecutorResponsivenessCases.cancellationJoinsNativeWorkWhileUIContinues()
    }
}
#endif
