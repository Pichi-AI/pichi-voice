@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Callback-only fixture: no session, microphone, file writer or UI is constructed. The
/// regression runner inserts the complete production callback and terminal sink methods.
final nonisolated class MeetingMacCaptureWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    let rejectCall: Int
    let trackID = UUID()
    let beforeEnqueue: (@Sendable () -> Void)?
    init(rejectCall: Int, beforeEnqueue: (@Sendable () -> Void)? = nil) {
        self.rejectCall = rejectCall; self.beforeEnqueue = beforeEnqueue
    }
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        let index = lock.withLock { callCount += 1; return callCount }
        beforeEnqueue?()
        return index != rejectCall
    }
    var calls: Int { lock.withLock { callCount } }
}

final nonisolated class MeetingMacCaptureTeeProbe: @unchecked Sendable {
    // Native callback metadata is inert here and is not consulted by the production method.
    struct AVCaptureOutput {}
    struct AVCaptureConnection {}
    /// The production callback only reaches its measured-clock branch through a started AVCaptureSession.
    struct SessionClock { var synchronizationClock: CMClock? { nil } }
    enum Track { case microphone }
    enum Interruption: Equatable { case liveTranscriptionDeferred }
    enum Event { case interrupted(kind: Interruption, trackID: UUID?, detail: String) }

    private let writer: MeetingMacCaptureWriterProbe
    private let microphonePCMNormalizer = MeetingMicrophonePCMNormalizer()
    private let session = SessionClock()
    // A recording without a clock context (legacy sample-clock capture) delivers each buffer directly.
    private let sourceClock: MeetingCaptureSourceClock? = nil
    private let stateLock = NSLock()
    private var stopping = false
    private var emittedUnexpectedStop = false
    private let eventHandler: @Sendable (Event) -> Void
    private let liveAudioHandler: (@Sendable (Track, CMSampleBuffer) -> Void)?

    init(writer: MeetingMacCaptureWriterProbe,
         event: @escaping @Sendable (Event) -> Void, live: @escaping @Sendable (Track, CMSampleBuffer) -> Void) {
        self.writer = writer
        self.eventHandler = event
        self.liveAudioHandler = live
    }
    func deliver(_ sample: CMSampleBuffer) { self.captureOutput(.init(), didOutput: sample, from: .init()) }
    var hasDeferredLiveTranscription: Bool { stateLock.withLock { emittedUnexpectedStop } }
    func closeForStop() { stateLock.withLock { stopping = true } }

    // PRODUCTION_CALLBACKS
}

final nonisolated class MeetingMacCaptureEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeetingMacCaptureTeeProbe.Interruption] = []
    private var presentations = 0
    func record(_ event: MeetingMacCaptureTeeProbe.Event) {
        if case let .interrupted(kind, _, _) = event { lock.withLock { events.append(kind) } }
    }
    func presented() { lock.withLock { presentations += 1 } }
    var snapshot: ([MeetingMacCaptureTeeProbe.Interruption], Int) { lock.withLock { (events, presentations) } }
}
