import CoreMedia
import Foundation

// Only the sink metadata is synthetic. The runner inserts each complete shipping stop
// method so these tests exercise its ordering, concurrent callers and failure cleanup.
typealias MeetingSessionID = UUID
struct MeetingTrackHealth: Sendable { enum Status { case recording, stopped }; var status: Status = .recording }
struct MeetingAudioTrack: Sendable { var health = MeetingTrackHealth() }
// The host-clock boundary and live-transcription deferral receipt join the physical Stop facts (120, 91865f5b).
struct MeetingCaptureStopResult: Sendable {
    let tracks: [MeetingAudioTrack]; let stoppedAt: Date
    var stoppedHostTime: UInt64? = nil
    var transcriptionDeferred: Bool = false
}
// PRODUCTION_CAPTURE_ERROR
// PRODUCTION_CAPTURE_CONTINUITY

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
    struct PrivacyStopProbe: Sendable {
        func stop() async { fatalError("Mute observation is outside this transport probe") }
    }
    struct MicrophoneControlProbe: Sendable {
        func beginFinishing() { fatalError("Microphone control is outside this transport probe") }
        func finish() { fatalError("Microphone control is outside this transport probe") }
    }
    // Explicit diagnostic recording is disabled in this model-free PCM probe.
    // If enabled accidentally, fail rather than create a comparison recording.
    struct ComparisonProbe: Sendable {
        func stop() async { fatalError("Audio comparison recording is outside this probe") }
    }
    private struct ActiveCapture {
        let sessionID: MeetingSessionID
        let runtime: MeetingCaptureStopRuntimeProbe
        let writers: [MeetingCaptureStopWriterProbe]
        let continuity = MeetingCaptureContinuityState()
        let comparisonProbe: ComparisonProbe? = nil
        let streamingTee: MeetingMultiTrackCaptureTee?
        let privacyGate: PrivacyStopProbe? = nil
        let muteMonitor: PrivacyStopProbe? = nil
        let microphoneControl: MicrophoneControlProbe? = nil
    }
    private var activeCapture: ActiveCapture?
    private var stopTask: Task<MeetingCaptureStopResult, Error>?
    private var releasedAssertions = 0
    // The desktop owner joins its streaming consumer only through the shared tee (91865f5b); the real tee is built here.
    init(id: UUID, runtime: MeetingCaptureStopRuntimeProbe, consumer: MeetingCaptureStopConsumerProbe) throws {
        let tee = try MeetingMultiTrackCaptureTee(consumers: [.microphone: consumer], originHostTime: 0,
            eventHandler: { _ in }, liveAudioHandler: nil)
        activeCapture = ActiveCapture(sessionID: id, runtime: runtime, writers: [.init()], streamingTee: tee)
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
    struct Session {
        var id: UUID; var startedAt: Date; var endedAt: Date?
        var timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
    }
    var activeSession: Session?
    var state: State
    var stopRequestedAt: (sessionID: UUID, date: Date, hostTime: UInt64)?
    init(_ session: Session) { activeSession = session; state = .recording(session.id) }
    // PRODUCTION_STOP_TIMER
}

struct MeetingSessionFailure: Sendable, Equatable { let id: UUID; let code: String }
final class MeetingCaptureStopHandoffProbe {
    struct Session { var id: UUID }
    var activeSession: Session?
    var captureStopHandoff: (sessionID: MeetingSessionID, generation: UUID,
        result: MeetingCaptureStopResult?, failure: MeetingSessionFailure?)?
    init(sessionID: UUID, generation: UUID) {
        activeSession = .init(id: sessionID)
        captureStopHandoff = (sessionID, generation, nil, nil)
    }
    func record(_ result: MeetingCaptureStopResult, sessionID: UUID, generation: UUID,
                failure: MeetingSessionFailure? = nil) {
        preserveCaptureStopHandoff(result, sessionID: sessionID, generation: generation, failure: failure)
    }
    func consume(sessionID: UUID, generation: UUID?) -> (result: MeetingCaptureStopResult, failure: MeetingSessionFailure?)? {
        takeCaptureStopHandoff(sessionID: sessionID, generation: generation)
    }
    // PRODUCTION_PRESERVE_HANDOFF
    // PRODUCTION_TAKE_HANDOFF
}

final class MeetingCaptureLossCompletenessProbe {
    enum Storage { case memoryOnly, retainedFiles }
    enum MeetingInterruptionKind { case writerBackpressure, captureStoppedUnexpectedly, microphoneDisconnected }
    struct Session { var audioStorageMode: Storage; var transcriptIsComplete: Bool? }
    typealias MeetingSession = Session
    static func apply(_ session: inout Session, event: MeetingInterruptionKind) {
        markDiscardedMemoryCaptureIncomplete(&session, event: event)
    }
    // PRODUCTION_DISCARDED_CAPTURE_COMPLETENESS
}

extension MeetingCapturePCMTransportTests {
    static func testCaptureStopBoundary() async throws {
        for flag: Bool? in [nil, true, false] {
            var lost = MeetingCaptureLossCompletenessProbe.Session(audioStorageMode: .memoryOnly, transcriptIsComplete: flag)
            MeetingCaptureLossCompletenessProbe.apply(&lost, event: .writerBackpressure)
            try require(lost.transcriptIsComplete == false, "A fresh rejected strict-memory PCM block marks captured coverage incomplete")
            var retained = MeetingCaptureLossCompletenessProbe.Session(audioStorageMode: .retainedFiles, transcriptIsComplete: flag)
            MeetingCaptureLossCompletenessProbe.apply(&retained, event: .writerBackpressure)
            try require(retained.transcriptIsComplete == flag, "The bounded strict-memory loss policy does not reclassify retained-audio attempts")
            for event in [MeetingCaptureLossCompletenessProbe.MeetingInterruptionKind.captureStoppedUnexpectedly, .microphoneDisconnected] {
                var noDemonstratedLoss = MeetingCaptureLossCompletenessProbe.Session(audioStorageMode: .memoryOnly, transcriptIsComplete: flag)
                MeetingCaptureLossCompletenessProbe.apply(&noDemonstratedLoss, event: event)
                try require(noDemonstratedLoss.transcriptIsComplete == flag,
                    "An interruption event alone cannot manufacture missing transcript coverage")
            }
        }
        let sessionID = UUID(), generation = UUID()
        let handoff = MeetingCaptureStopHandoffProbe(sessionID: sessionID, generation: generation)
        let physical = MeetingCaptureStopResult(tracks: [.init()], stoppedAt: Date(timeIntervalSince1970: 17))
        let failure = MeetingSessionFailure(id: UUID(), code: "synthetic-partial-stop")
        handoff.record(physical, sessionID: sessionID, generation: UUID())
        try require(handoff.captureStopHandoff?.result == nil, "An older processing generation cannot overwrite the owned capture handoff")
        handoff.record(physical, sessionID: UUID(), generation: generation)
        try require(handoff.captureStopHandoff?.result == nil, "Another session cannot publish physical Stop facts")
        handoff.record(physical, sessionID: sessionID, generation: generation, failure: failure)
        try require(handoff.consume(sessionID: sessionID, generation: UUID()) == nil && handoff.captureStopHandoff != nil,
            "A mismatched termination generation cannot consume the current owner")
        handoff.activeSession = .init(id: UUID())
        try require(handoff.consume(sessionID: sessionID, generation: generation) == nil,
            "An older capture cannot write physical facts into a new active session")
        handoff.activeSession = .init(id: sessionID)
        let joined = handoff.consume(sessionID: sessionID, generation: generation)
        try require(joined?.result.stoppedAt == physical.stoppedAt && joined?.result.tracks.count == 1 && joined?.failure == failure,
            "The exact joined boundary, final tracks and partial failure pass to their termination owner")
        try require(handoff.captureStopHandoff == nil && handoff.consume(sessionID: sessionID, generation: generation) == nil,
            "A physical Stop handoff is consumed exactly once")
        let id = UUID(), request = Date(), start = Date().addingTimeInterval(-3)
        let timer = MeetingCaptureStopTimerProbe(.init(id: id, startedAt: start, endedAt: nil))
        timer.stopRequestedAt = (id, request, 0); timer.state = .stopping(id)
        let shownAtStop = timer.elapsedTime
        try await Task.sleep(nanoseconds: 30_000_000)
        try require(timer.elapsedTime == shownAtStop, "A Stop request freezes visible duration while model work is joined")
        timer.activeSession?.endedAt = request.addingTimeInterval(0.5)
        try require(timer.elapsedTime == request.addingTimeInterval(0.5).timeIntervalSince(start),
            "The joined capture result supersedes the provisional visible Stop request")
        timer.activeSession?.endedAt = nil
        timer.stopRequestedAt = (UUID(), request.addingTimeInterval(-10), 0)
        try require(timer.elapsedTime > shownAtStop, "An unrelated prior session cannot freeze the next recording timer")
        timer.stopRequestedAt = (id, start.addingTimeInterval(-1), 0)
        try require(timer.elapsedTime == 0, "A backward wall-clock observation never displays negative elapsed time")
        // Host-monotonic recordings (120) freeze the visible timer on the Stop request's host time instead.
        let hostStart: UInt64 = 5_000_000_000
        let hostTimer = MeetingCaptureStopTimerProbe(.init(id: id, startedAt: start, endedAt: nil, timebase: .init(
            startedHostTime: hostStart, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
            firstPresentationTime: nil, recordingTimePolicy: .hostMonotonicV1)))
        hostTimer.stopRequestedAt = (id, request, hostStart + 2_000_000_000); hostTimer.state = .stopping(id)
        try require(hostTimer.elapsedTime == 2, "A host-monotonic Stop request freezes the visible duration at its host time")
        hostTimer.activeSession?.timebase.endedHostTime = hostStart + 2_500_000_000
        try require(hostTimer.elapsedTime == 2.5, "The joined capture host boundary supersedes the provisional Stop request")
        hostTimer.stopRequestedAt = (id, request, hostStart - 1)
        hostTimer.activeSession?.timebase.endedHostTime = nil
        try require(hostTimer.elapsedTime == 0, "A host request before the recording origin never displays negative elapsed time")
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
                let desktop = try MeetingDesktopCaptureStopProbe(id: id, runtime: runtime, consumer: consumer)
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
                        // 9751bfd2: a desktop streaming-consumer failure is a recoverable processing event; the recording
                        // already closed, so only a runtime failure (or an iOS finalizer failure) remains a Stop failure.
                        try require(failure == "none" || (platform == "desktop" && failure == "consumer"),
                            "A runtime or finalizer failure must remain terminal")
                        if platform == "desktop" { try require(result.stoppedHostTime != nil, "Desktop Stop records the joined host-clock boundary") }
                        boundaries.append(result.stoppedAt)
                    } catch let MeetingCaptureError.captureStopFailed(_, partialResult: result) {
                        try require(failure != "none" && !(platform == "desktop" && failure == "consumer"),
                            "A canceled waiter cannot fail otherwise valid owned Stop, nor can a desktop processing failure")
                        if platform == "desktop" { try require(result.stoppedHostTime != nil, "Desktop partial Stop keeps its host-clock boundary") }
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
