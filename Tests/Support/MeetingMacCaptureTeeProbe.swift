@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Callback-only fixture: no session, microphone, file writer or UI is constructed. The
/// regression runner inserts the complete production callback and terminal sink methods.
final nonisolated class MeetingMacCaptureWriterProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var callCount = 0
    let rejectCall: Int
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

final nonisolated class MeetingMacCaptureConsumerProbe: MeetingMemoryAudioConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var counts: [Int] = []
    let accepts: Bool
    init(accepts: Bool = true) { self.accepts = accepts }
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        lock.withLock { counts.append(CMSampleBufferGetNumSamples(sample)) }
        return accepts
    }
    func finish() async throws {}
    var received: [Int] { lock.withLock { counts } }
}

final nonisolated class MeetingMacCaptureTeeProbe: @unchecked Sendable {
    // Native callback metadata is inert here and is not consulted by the production method.
    struct AVCaptureOutput {}
    struct AVCaptureConnection {}
    enum Track { case microphone }
    enum Interruption: Equatable { case writerBackpressure, captureStoppedUnexpectedly }
    enum Event { case interrupted(kind: Interruption, trackID: UUID?, detail: String) }

    private let writer: MeetingMacCaptureWriterProbe
    private let memoryConsumer: (any MeetingMemoryAudioConsuming)?
    private let microphonePCMNormalizer = MeetingMicrophonePCMNormalizer()
    private let pcmConverter: MeetingCapturePCMConverter?
    private let stateLock = NSLock()
    private var stopping = false
    private var emittedUnexpectedStop = false
    private var pcmFailure: Error?
    private let eventHandler: @Sendable (Event) -> Void
    private let liveAudioHandler: (@Sendable (Track, CMSampleBuffer) -> Void)?

    init(writer: MeetingMacCaptureWriterProbe, consumer: (any MeetingMemoryAudioConsuming)?,
         event: @escaping @Sendable (Event) -> Void, live: @escaping @Sendable (Track, CMSampleBuffer) -> Void) throws {
        self.writer = writer
        self.memoryConsumer = consumer
        self.pcmConverter = consumer == nil ? nil : try MeetingCapturePCMConverter()
        self.eventHandler = event
        self.liveAudioHandler = live
    }
    func deliver(_ sample: CMSampleBuffer) { self.captureOutput(.init(), didOutput: sample, from: .init()) }
    var isTerminal: Bool { stateLock.withLock { stopping && emittedUnexpectedStop && pcmFailure != nil } }
    var hasFailureForStop: Bool { stateLock.withLock { pcmFailure != nil } }
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
