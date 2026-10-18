import CoreMedia
import Foundation

// Only the sink metadata is synthetic. The runner inserts each complete shipping stop
// method so these tests exercise its ordering, concurrent callers and failure cleanup.
typealias MeetingSessionID = UUID
struct MeetingTrackHealth: Sendable { enum Status { case recording, stopped }; var status: Status = .recording }
struct MeetingAudioTrack: Sendable { var health = MeetingTrackHealth() }
struct MeetingCaptureStopResult: Sendable { let tracks: [MeetingAudioTrack]; let stoppedAt: Date }
// PRODUCTION_CAPTURE_ERROR

actor MeetingCaptureStopLatch {
    private var entered = false
    private var released = false
    private var waiter: CheckedContinuation<Void, Never>?
    func wait() async {
        entered = true
        await withCheckedContinuation { value in
            if released { value.resume() } else { waiter = value }
        }
    }
    func release() { released = true; waiter?.resume(); waiter = nil }
    func hasEntered() -> Bool { entered }
}

final class MeetingCaptureStopRuntimeProbe: @unchecked Sendable {
    let gate: MeetingCaptureStopLatch
    let failure: Bool
    private let lock = NSLock()
    private var calls = 0
    private var returnedAt: Date?
    init(gate: MeetingCaptureStopLatch, failure: Bool) { self.gate = gate; self.failure = failure }
    func stop() async throws {
        lock.withLock { calls += 1 }
        await gate.wait()
        lock.withLock { returnedAt = Date() }
        if failure { throw NSError(domain: "SyntheticRuntimeStop", code: 1) }
    }
    func healthSnapshot() -> MeetingTrackHealth { .init() }
    var snapshot: (Int, Date?) { lock.withLock { (calls, returnedAt) } }
}

final class MeetingCaptureStopWriterProbe: @unchecked Sendable {
    func stop() async -> MeetingAudioTrack { .init() }
}

final class MeetingCaptureStopConsumerProbe: MeetingMemoryAudioConsuming, @unchecked Sendable {
    let gate: MeetingCaptureStopLatch
    let failure: Bool
    private let lock = NSLock()
    private var calls = 0
    init(gate: MeetingCaptureStopLatch, failure: Bool) { self.gate = gate; self.failure = failure }
    func enqueue(_ sample: CMSampleBuffer) -> Bool { true }
    func finish() async throws {
        lock.withLock { calls += 1 }
        await gate.wait()
        if failure { throw NSError(domain: "SyntheticConsumerFinish", code: 1) }
    }
    var count: Int { lock.withLock { calls } }
}

actor MeetingIOSCaptureStopProbe {
    private struct Capture {
        let sessionID: MeetingSessionID
        let runtime: MeetingCaptureStopRuntimeProbe
        let writer: MeetingCaptureStopWriterProbe?
        let memoryConsumer: MeetingCaptureStopConsumerProbe?
        var track: MeetingAudioTrack
    }
    private var active: Capture?
    private var stopTask: Task<MeetingCaptureStopResult, Error>?
    init(id: UUID, runtime: MeetingCaptureStopRuntimeProbe, consumer: MeetingCaptureStopConsumerProbe, retained: Bool) {
        active = Capture(sessionID: id, runtime: runtime, writer: retained ? .init() : nil,
            memoryConsumer: consumer, track: .init())
    }
    var isIdle: Bool { active == nil && stopTask == nil }
    // PRODUCTION_IOS_STOP
}

actor MeetingDesktopCaptureStopProbe {
    private struct ActiveCapture {
        let sessionID: MeetingSessionID
        let runtime: MeetingCaptureStopRuntimeProbe
        let writers: [MeetingCaptureStopWriterProbe]
        let memoryConsumer: MeetingCaptureStopConsumerProbe?
    }
    private var activeCapture: ActiveCapture?
    private var stopTask: Task<MeetingCaptureStopResult, Error>?
    private var releasedAssertions = 0
    init(id: UUID, runtime: MeetingCaptureStopRuntimeProbe, consumer: MeetingCaptureStopConsumerProbe) {
        activeCapture = ActiveCapture(sessionID: id, runtime: runtime, writers: [.init()], memoryConsumer: consumer)
    }
    private static func stopWriters(_ writers: [MeetingCaptureStopWriterProbe]) async -> [MeetingAudioTrack] {
        var tracks: [MeetingAudioTrack] = []
        for writer in writers { tracks.append(await writer.stop()) }
        return tracks
    }
    private func releaseDisplaySleepAssertion() { releasedAssertions += 1 }
    var isIdle: Bool { activeCapture == nil && stopTask == nil && releasedAssertions == 1 }
    // PRODUCTION_DESKTOP_STOP
}

final class MeetingCaptureStopTimerProbe {
    enum State: Equatable { case stopping(UUID), recording(UUID), completed(UUID) }
    struct Session { var id: UUID; var startedAt: Date; var endedAt: Date? }
    var activeSession: Session?
    var state: State
    var stopRequestedAt: (sessionID: UUID, date: Date)?
    init(_ session: Session) { activeSession = session; state = .recording(session.id) }
    // PRODUCTION_STOP_TIMER
}

extension MeetingCapturePCMTransportTests {
    static func testCaptureStopBoundary() async throws {
        let id = UUID(), request = Date(), start = Date().addingTimeInterval(-3)
        let timer = MeetingCaptureStopTimerProbe(.init(id: id, startedAt: start, endedAt: nil))
        timer.stopRequestedAt = (id, request); timer.state = .stopping(id)
        let shownAtStop = timer.elapsedTime
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(timer.elapsedTime == shownAtStop, "A Stop request freezes visible duration while model work is joined")
        timer.activeSession?.endedAt = request.addingTimeInterval(0.5)
        try require(timer.elapsedTime == request.addingTimeInterval(0.5).timeIntervalSince(start),
            "The joined capture result supersedes the provisional visible Stop request")
        timer.activeSession?.endedAt = nil
        timer.stopRequestedAt = (UUID(), request.addingTimeInterval(-10))
        try require(timer.elapsedTime > shownAtStop, "An unrelated prior session cannot freeze the next recording timer")
        timer.stopRequestedAt = (id, start.addingTimeInterval(-1))
        try require(timer.elapsedTime == 0, "A backward wall-clock observation never displays negative elapsed time")
        func entered(_ gate: MeetingCaptureStopLatch) async throws {
            for _ in 0..<1_000 {
                if await gate.hasEntered() { return }
                try await Task.sleep(nanoseconds: 1_000_000)
            }
            throw NSError(domain: "CaptureStopGateTimeout", code: 1)
        }
        for platform in ["ios-memory", "ios-retained", "desktop"] {
            for failure in ["none", "runtime", "consumer"] {
                let id = UUID(), runtimeGate = MeetingCaptureStopLatch(), consumerGate = MeetingCaptureStopLatch()
                let runtime = MeetingCaptureStopRuntimeProbe(gate: runtimeGate, failure: failure == "runtime")
                let consumer = MeetingCaptureStopConsumerProbe(gate: consumerGate, failure: failure == "consumer")
                let ios = MeetingIOSCaptureStopProbe(id: id, runtime: runtime, consumer: consumer, retained: platform == "ios-retained")
                let desktop = MeetingDesktopCaptureStopProbe(id: id, runtime: runtime, consumer: consumer)
                let first = Task { try await platform == "desktop" ? desktop.stop(sessionID: id) : ios.stop(sessionID: id) }
                try await entered(runtimeGate)
                // Stop must still join an admitted audio runtime before timestamping its result.
                let runtimeHeldAt = Date()
                await runtimeGate.release()
                try await entered(consumerGate)
                let modelTailBegan = Date()
                let second = Task { try await platform == "desktop" ? desktop.stop(sessionID: id) : ios.stop(sessionID: id) }
                first.cancel() // A canceled waiter must not cancel or skip the shared owned tail.
                try await Task.sleep(nanoseconds: 30_000_000)
                let modelTailReleasedAt = Date()
                await consumerGate.release()
                var boundaries: [Date] = []
                for task in [first, second] {
                    do {
                        let result = try await task.value
                        try require(failure == "none", "A runtime or finalizer failure must remain terminal")
                        boundaries.append(result.stoppedAt)
                    } catch let MeetingCaptureError.captureStopFailed(_, partialResult: result) {
                        try require(failure != "none", "A canceled waiter cannot fail otherwise valid owned Stop")
                        boundaries.append(result.stoppedAt)
                    }
                }
                try require(boundaries.count == 2 && boundaries[0] == boundaries[1],
                    "Concurrent Stop waiters share one immutable audio boundary")
                try require(boundaries[0] >= runtimeHeldAt && boundaries[0] >= runtime.snapshot.1!
                    && boundaries[0] <= modelTailBegan && boundaries[0] < modelTailReleasedAt,
                    "Stop time follows joined audio and excludes delayed model finalization, including partial failures")
                try require(runtime.snapshot.0 == 1 && consumer.count == 1,
                    "Stop joins the audio runtime and final model tail exactly once")
                try require(await platform == "desktop" ? desktop.isIdle : ios.isIdle,
                    "Successful and failed Stop both release their existing capture owner")
            }
        }
        print("Capture Stop: actual iOS/desktop methods preserve joined audio boundaries, shared cancellation and partial failures across 9 cases.")
    }
}
