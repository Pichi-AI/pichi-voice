import AudioToolbox
@preconcurrency import AVFoundation
import CoreMedia
import Foundation

final nonisolated class MeetingAudioChunkWriter: @unchecked Sendable {
    let clockContext: MeetingRecordingClockContext?
    typealias EventHandler = @Sendable (MeetingCaptureEvent) -> Void

    private final class SampleBox: @unchecked Sendable {
        let sampleBuffer: CMSampleBuffer
        let producerEpoch: UInt64

        init(_ sampleBuffer: CMSampleBuffer, producerEpoch: UInt64) {
            self.sampleBuffer = sampleBuffer
            self.producerEpoch = producerEpoch
        }
    }

    private enum Lifecycle: Equatable {
        case accepting
        case stopping
        case stopped
    }

    enum SequencedCommandError: Error {
        case writerNotAccepting
        case queueFull
    }

    private struct ActiveChunk: @unchecked Sendable {
        var id: MeetingAudioChunkID
        var sequence: Int
        var relativeFinalPath: String
        var sink: MeetingAudioChunkSink
        var start: CMTime
        var end: CMTime
        var discontinuities: [MeetingAudioDiscontinuity]
        /// Captured at `beginChunk` — `self.track.format` may already be the NEXT chunk's by finalize.
        var format: MeetingAudioFormat
        var sourceFormatDescription: CMFormatDescription
        var formatContract: MeetingPCMFormatContract
        var producerEpoch: UInt64
        var framesWritten: Int64
        var lastCheckpointFrames: Int64
        var clockMapping: MeetingAudioClockMapping? = nil
    }

    private let queue: DispatchQueue
    private var journal: MeetingAudioRecordingJournal?
    private var activeIntent: MeetingAudioChunkLedgerIntent?
    private var latestCheckpoint: MeetingAudioChunkLedgerCheckpoint?
    private var metadataRevision: UInt64 = 0
    private var scheduledMetadata: MeetingAudioTrack?
    private var metadataFailureReported = false
    private let pendingSlots: DispatchSemaphore
    private let audioBudget = MeetingPCMIntakeGate(maximumBytes: 16 * 1024 * 1024, maximumSeconds: 10, closeOnRejection: false)
    var retainedPCMBytes: Int { self.audioBudget.retainedBytes }
    private let stateLock = NSLock()
    private let sessionDirectory: URL
    private let trackDirectory: URL
    private let chunkDuration: TimeInterval
    private let eventHandler: EventHandler
    private let diagnosticSampleObserver: (@Sendable (CMSampleBuffer, UInt64) -> Void)?
    private let sampleAdmission: (@Sendable (CMSampleBuffer) -> Bool)?

    let trackID: MeetingAudioTrackID

    private var track: MeetingAudioTrack
    private var activeChunk: ActiveChunk?
    /// Set synchronously when a chunk closes, since `track.chunks.last` can be stale (finalization is async).
    private var lastFinalizedEnd: CMTime?
    /// Monotonically identifies the producer that owns callback order. Samples from retired
    /// producers are rejected instead of being retimed as duplicate audio.
    private var currentProducerEpoch: UInt64?
    /// Canonical mapping from the current producer's own clock onto the meeting timeline. A new
    /// epoch (or a backward reset inside one) establishes this offset exactly once; every later
    /// sample of that epoch is then shifted by the same delta, so a producer that restarts at zero
    /// stays internally contiguous instead of being clamped sample-by-sample onto one instant.
    private var canonicalTimelineOffset: CMTime = .zero
    /// The epoch `canonicalTimelineOffset` was established for. Purely diagnostic bookkeeping that
    /// makes the "offset belongs to one producer epoch" invariant explicit.
    private var canonicalTimelineOffsetEpoch: UInt64?
    private var lifecycle: Lifecycle = .accepting
    private var stopWaiters: [CheckedContinuation<MeetingAudioTrack, Never>] = []
    private var stoppedTrack: MeetingAudioTrack?
    private var nextChunkSequence = 0
    private var pendingDroppedSampleCount = 0
    private var dropReportScheduled = false
    /// At most one bounded overflow command may bypass `pendingSlots` to publish a
    /// conservative era while physical capture continues.
    private var emergencySafetyCommandPending = false
    private var lastHealthEmission = Date.distantPast
    private var lastLevelMeasurement = Date.distantPast
    private var silenceAccumulatedSeconds: Double = 0
    /// Cleared by a successful append so a later failure is a new episode. Repeated rejected
    /// buffers must not produce an unbounded session-event history.
    private var hasReportedWriterFailure = false

    /// Peak amplitude (0...1) below which a buffer counts as silent for watchdog purposes.
    private static let silenceAmplitudeThreshold: Float = 0.0001

    init(
        track: MeetingAudioTrack,
        sessionDirectory: URL,
        chunkDuration: TimeInterval,
        eventHandler: @escaping EventHandler,
        // PCM persistence owns a serialized queue. Command count, bytes and duration are all
        // bounded; temporary pressure never permanently closes admission for later buffers.
        pendingSlotLimit: Int = 1_024,
        diagnosticSampleObserver: (@Sendable (CMSampleBuffer, UInt64) -> Void)? = nil,
        sampleAdmission: (@Sendable (CMSampleBuffer) -> Bool)? = nil,
        clockContext: MeetingRecordingClockContext? = nil,
        persistenceHook: MeetingAudioRecordingJournal.Hook? = nil
    ) throws {
        self.clockContext = clockContext
        self.trackID = track.id
        self.track = track
        self.sessionDirectory = sessionDirectory
        self.trackDirectory = sessionDirectory
            .appendingPathComponent("tracks", isDirectory: true)
            .appendingPathComponent(track.kind.rawValue, isDirectory: true)
        self.chunkDuration = max(60, chunkDuration)
        self.eventHandler = eventHandler
        self.diagnosticSampleObserver = diagnosticSampleObserver
        self.sampleAdmission = sampleAdmission
        self.queue = DispatchQueue(
            label: "com.fluidvoice.meeting.writer.\(track.kind.rawValue)",
            qos: .userInitiated
        )
        self.pendingSlots = DispatchSemaphore(value: max(0, pendingSlotLimit))

        try FileManager.default.createDirectory(
            at: self.trackDirectory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: NSNumber(value: Int16(0o700))]
        )
        self.nextChunkSequence = (track.chunks.map(\.sequence).max() ?? -1) + 1
        self.journal = MeetingAudioRecordingJournal(directory: sessionDirectory, hook: persistenceHook) { [weak self] chunks, error, completions in
            guard let self else { return }
            self.queue.async {
                self.receiveJournal(chunks, error: error)
                for completion in completions { completion(error.map { .failure($0) } ?? .success(())) }
            }
        }
        self.publishJournal()
    }

    @discardableResult
    func enqueue(
        _ sampleBuffer: CMSampleBuffer,
        producerEpoch: UInt64 = 0,
        onConsumed: (@Sendable () -> Void)? = nil
    ) -> Bool {
        self.stateLock.lock()
        guard self.lifecycle == .accepting else {
            self.stateLock.unlock()
            return false
        }

        guard self.pendingSlots.wait(timeout: .now()) == .success else {
            self.pendingDroppedSampleCount += 1
            let shouldScheduleReport = !self.dropReportScheduled
            self.dropReportScheduled = true
            self.stateLock.unlock()
            if shouldScheduleReport {
                self.queue.async { [weak self] in
                    self?.drainDroppedSampleReport()
                }
            }
            return false
        }

        guard let reservation = self.reservePCM(sampleBuffer) else {
            self.pendingSlots.signal()
            self.pendingDroppedSampleCount += 1
            let report = !self.dropReportScheduled
            self.dropReportScheduled = true
            self.stateLock.unlock()
            if report { self.queue.async { self.drainDroppedSampleReport() } }
            return false
        }
        let sampleBox = SampleBox(sampleBuffer, producerEpoch: producerEpoch)
        self.queue.async { [weak self, sampleBox] in
            defer { self?.pendingSlots.signal(); self?.audioBudget.release(reservation) }
            self?.consume(sampleBox.sampleBuffer, producerEpoch: sampleBox.producerEpoch)
            onConsumed?()
        }
        self.stateLock.unlock()
        return true
    }

    private func reservePCM(_ sample: CMSampleBuffer) -> MeetingPCMIntakeGate.Reservation? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(format)?.pointee else { return nil }
        return self.audioBudget.reserve(frames: CMSampleBufferGetNumSamples(sample),
            channels: Int(asbd.mChannelsPerFrame), sampleRate: asbd.mSampleRate)
    }

    /// Runs a safety-era mutation, durable manifest write, and sample consume as one writer-queue
    /// command. Callers may open live admission only from the success completion. On a fail-closed
    /// persistence error the conservative candidate remains the in-memory track and the sample is
    /// not consumed.
    func enqueue(
        _ sampleBuffer: CMSampleBuffer,
        producerEpoch: UInt64 = 0,
        afterPersistingMetadata mutate: @escaping @Sendable (inout MeetingAudioTrack) -> Void,
        failClosed: Bool,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.stateLock.lock()
        guard self.lifecycle == .accepting else {
            self.stateLock.unlock()
            completion(.failure(SequencedCommandError.writerNotAccepting))
            return
        }
        guard self.pendingSlots.wait(timeout: .now()) == .success else {
            self.failOverflowedSequencedCommand(failClosed: failClosed, mutate: mutate, completion: completion)
            return
        }

        guard let reservation = self.reservePCM(sampleBuffer) else {
            self.pendingSlots.signal()
            self.pendingDroppedSampleCount += 1
            let report = !self.dropReportScheduled
            self.dropReportScheduled = true
            self.stateLock.unlock()
            if report { self.queue.async { self.drainDroppedSampleReport() } }
            completion(.failure(SequencedCommandError.queueFull))
            return
        }
        let sampleBox = SampleBox(sampleBuffer, producerEpoch: producerEpoch)
        self.queue.async { [self, sampleBox] in
            defer { self.pendingSlots.signal(); self.audioBudget.release(reservation) }
            self.metadataRevision &+= 1
            let revision = self.metadataRevision
            var candidate = self.scheduledMetadata ?? self.track
            mutate(&candidate)
            if failClosed { self.applyMetadata(candidate) }
            self.consume(sampleBox.sampleBuffer, producerEpoch: sampleBox.producerEpoch)
            candidate.chunks = self.track.chunks
            let metadata = candidate
            self.scheduledMetadata = metadata
            self.publishJournal(track: metadata) { result in
                if self.metadataRevision == revision {
                    if case .success = result { self.applyMetadata(metadata) }
                    self.scheduledMetadata = nil
                }
                completion(result)
            }
        }
        self.stateLock.unlock()
    }

    /// Enqueues a durable metadata-only command in the same bounded order as audio samples.
    /// This is used for safety transitions that must cut the writer timeline before a later
    /// callback is allowed to enqueue raw microphone audio.
    func enqueueMetadata(
        failClosed: Bool,
        mutate: @escaping @Sendable (inout MeetingAudioTrack) -> Void,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        self.stateLock.lock()
        guard self.lifecycle == .accepting else {
            self.stateLock.unlock()
            completion(.failure(SequencedCommandError.writerNotAccepting))
            return
        }
        guard self.pendingSlots.wait(timeout: .now()) == .success else {
            self.failOverflowedSequencedCommand(failClosed: failClosed, recordsAudioLoss: false, mutate: mutate, completion: completion)
            return
        }

        self.queue.async { [self] in
            defer { self.pendingSlots.signal() }
            self.metadataRevision &+= 1
            let revision = self.metadataRevision
            var candidate = self.scheduledMetadata ?? self.track
            mutate(&candidate)
            if failClosed { self.applyMetadata(candidate) }
            let metadata = candidate
            self.scheduledMetadata = metadata
            self.publishJournal(track: metadata) { result in
                if self.metadataRevision == revision {
                    if case .success = result { self.applyMetadata(metadata) }
                    self.scheduledMetadata = nil
                }
                completion(result)
            }
        }
        self.stateLock.unlock()
    }

    /// Full-queue path for sequenced commands. Must be called with `stateLock` held; returns with
    /// it released. A fail-closed command gets one bounded slot-bypassing emergency run so the
    /// conservative era still reaches the in-memory track (and best-effort the manifest).
    private func failOverflowedSequencedCommand(
        failClosed: Bool,
        recordsAudioLoss: Bool = true,
        mutate: @escaping @Sendable (inout MeetingAudioTrack) -> Void,
        completion: @escaping @Sendable (Result<Void, Error>) -> Void
    ) {
        let shouldScheduleReport = recordsAudioLoss && !self.dropReportScheduled
        if recordsAudioLoss { self.pendingDroppedSampleCount += 1; self.dropReportScheduled = true }
        let enqueueEmergency = failClosed && !self.emergencySafetyCommandPending
        if enqueueEmergency { self.emergencySafetyCommandPending = true }
        self.stateLock.unlock()
        if shouldScheduleReport {
            self.queue.async { [weak self] in self?.drainDroppedSampleReport() }
        }
        if enqueueEmergency {
            self.queue.async { [self] in
                self.metadataRevision &+= 1
                var candidate = self.scheduledMetadata ?? self.track
                mutate(&candidate)
                self.applyMetadata(candidate)
                self.scheduledMetadata = candidate
                self.publishJournal(track: candidate)
                self.stateLock.withLock { self.emergencySafetyCommandPending = false }
                completion(.failure(SequencedCommandError.queueFull))
            }
        } else {
            completion(.failure(SequencedCommandError.queueFull))
        }
    }

    func stop() async -> MeetingAudioTrack {
        await withCheckedContinuation { continuation in
            self.stateLock.lock()
            switch self.lifecycle {
            case .accepting:
                self.lifecycle = .stopping
                self.stopWaiters.append(continuation)
                self.queue.async { [self] in
                    self.scheduleActiveChunkFinalization()
                    self.track.health.status = self.track.chunks.isEmpty ? .unavailable : .stopped
                    self.publishJournal(final: true) { _ in self.completeStop() }
                }
                self.stateLock.unlock()
            case .stopping:
                self.stopWaiters.append(continuation)
                self.stateLock.unlock()
            case .stopped:
                let stoppedTrack = self.stoppedTrack ?? self.track
                self.stateLock.unlock()
                continuation.resume(returning: stoppedTrack)
            }
        }
    }

    /// Hardware facts are committed to the recording's in-memory owner immediately. Optional
    /// persistence follows separately; creating or switching a physical source never waits for it.
    func updateCaptureMetadata(_ mutate: @escaping (inout MeetingAudioTrack) -> Void) async {
        await withCheckedContinuation { continuation in
            self.queue.async {
                self.metadataRevision &+= 1
                let revision = self.metadataRevision
                var metadata = self.scheduledMetadata ?? self.track
                mutate(&metadata)
                self.applyMetadata(metadata)
                self.scheduledMetadata = metadata
                self.publishJournal(track: metadata) { _ in
                    if self.metadataRevision == revision { self.scheduledMetadata = nil }
                }
                continuation.resume()
            }
        }
    }

    /// Metadata receipt governs transcription admission only. Capture never waits for it.
    func updateTrackMetadata(_ mutate: @escaping (inout MeetingAudioTrack) -> Void) async throws {
        try await self.updateMetadata(false, mutate)
    }

    func updateTrackMetadataFailClosed(_ mutate: @escaping (inout MeetingAudioTrack) -> Void) async throws {
        try await self.updateMetadata(true, mutate)
    }

    private func updateMetadata(_ failClosed: Bool, _ mutate: @escaping (inout MeetingAudioTrack) -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                self.metadataRevision &+= 1
                let revision = self.metadataRevision
                var candidate = self.scheduledMetadata ?? self.track
                mutate(&candidate)
                if failClosed { self.applyMetadata(candidate) }
                let metadata = candidate
                self.scheduledMetadata = metadata
                self.publishJournal(track: metadata) { result in
                    if self.metadataRevision == revision {
                    if case .success = result { self.applyMetadata(metadata) }
                    self.scheduledMetadata = nil
                }
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func applyMetadata(_ candidate: MeetingAudioTrack) {
        let chunks = self.track.chunks, health = self.track.health, format = self.track.format
        self.track = candidate
        self.track.chunks = chunks; self.track.health = health; self.track.format = format
    }

    /// Splice point for a capture-side swap: finalizes the active chunk, returns its `presentationEnd`. No-op unless `.accepting`.
    func beginSplice() async -> MeetingMediaTime? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MeetingMediaTime?, Never>) in
            self.queue.async { [self] in
                self.stateLock.lock()
                let accepting = self.lifecycle == .accepting
                self.stateLock.unlock()
                guard accepting else {
                    continuation.resume(returning: self.track.chunks.last?.presentationEnd)
                    return
                }
                guard let activeChunk = self.activeChunk else {
                    continuation.resume(returning: self.track.chunks.last?.presentationEnd)
                    return
                }
                let boundary = Self.mediaTime(activeChunk.end)
                self.scheduleActiveChunkFinalization()
                continuation.resume(returning: boundary)
            }
        }
    }

    func snapshot() async -> MeetingAudioTrack {
        await withCheckedContinuation { continuation in
            self.queue.async { [self] in
                continuation.resume(returning: self.track)
            }
        }
    }

    private func consume(_ sourceSampleBuffer: CMSampleBuffer, producerEpoch: UInt64) {
        // Intentional privacy exclusion is neither a hardware failure nor writer backpressure.
        // Recheck here because a producer or normalization queue can outlive an observation.
        guard self.sampleAdmission?(sourceSampleBuffer) != false else { return }
        guard CMSampleBufferIsValid(sourceSampleBuffer), CMSampleBufferDataIsReady(sourceSampleBuffer) else {
            self.recordDroppedSample(detail: "Capture delivered an invalid audio sample.")
            return
        }
        let clockPacket = MeetingCaptureClockMetadata.read(from: sourceSampleBuffer)
        if let clockContext {
            guard let clockPacket, clockContext.accepts(clockPacket) else {
                self.reportWriterFailure(detail: PichiLocalization.text("Audio timing could not be verified."), sampleBuffer: sourceSampleBuffer)
                return
            }
        }
        let producerEpoch = self.clockContext != nil ? clockPacket?.producerEpoch ?? producerEpoch : producerEpoch
        var hostMapping = self.clockContext != nil ? clockPacket?.mapping : nil
        let sourcePresentationTime = CMSampleBufferGetPresentationTimeStamp(sourceSampleBuffer)
        guard sourcePresentationTime.isValid, sourcePresentationTime.isNumeric else {
            self.recordDroppedSample(detail: "Capture delivered audio without a valid presentation timestamp.")
            return
        }

        if let currentProducerEpoch = self.currentProducerEpoch, producerEpoch < currentProducerEpoch {
            self.recordDroppedSample(detail: "Capture delivered audio from a retired producer epoch.")
            return
        }
        self.diagnosticSampleObserver?(sourceSampleBuffer, producerEpoch)

        let mappedEnd = hostMapping?.spans.last.map { CMTime(value: $0.hostEnd.value, timescale: $0.hostEnd.timescale) }
        let duration = mappedEnd.map { $0 - sourcePresentationTime } ?? Self.sampleDuration(sourceSampleBuffer)
        let previousEnd = self.activeChunk?.end ?? self.lastFinalizedEnd
        // The same measured gap represents excluded input, not clock drift. It must remain
        // a boundary even when it is shorter than the legacy half-second chunk threshold.
        if let previousEnd, let first = hostMapping?.spans.first,
           first.hostStart.seconds > previousEnd.seconds + 1e-9 {
            hostMapping?.spans[0].discontinuityBefore = true
        }
        let epochChanged = self.currentProducerEpoch.map { producerEpoch > $0 } ?? false
        self.currentProducerEpoch = max(self.currentProducerEpoch ?? producerEpoch, producerEpoch)

        // A new producer brings its own clock origin; its canonical mapping is derived below from
        // the first sample it delivers rather than inherited from the retired producer.
        if epochChanged {
            self.canonicalTimelineOffset = .zero
            self.canonicalTimelineOffsetEpoch = nil
        }

        var presentationTime = sourcePresentationTime + (hostMapping == nil ? self.canonicalTimelineOffset : .zero)
        var backwardReset = false
        if hostMapping != nil {
            if let previousEnd, presentationTime < previousEnd - CMTime(value: 1, timescale: 1_000_000) {
                self.reportWriterFailure(detail: PichiLocalization.text("Audio timing could not be verified."), sampleBuffer: sourceSampleBuffer)
                return
            }
        } else if let previousEnd, presentationTime < previousEnd {
            // SCK nanosecond stamps and frame-derived durations can differ by tens of
            // nanoseconds after CMTime rescaling. Keep them contiguous without creating
            // hundreds of tiny analysis epochs. A real one-frame overlap still rotates.
            let overlap = previousEnd - presentationTime
            let isRoundingOverlap = overlap <= CMTime(value: 1, timescale: 1_000_000)
            // Establish (or re-establish) the mapping once, then keep applying it. Anchoring the
            // offset instead of clamping each sample preserves the producer's internal spacing.
            self.canonicalTimelineOffset = previousEnd - sourcePresentationTime
            self.canonicalTimelineOffsetEpoch = producerEpoch
            presentationTime = previousEnd
            backwardReset = !isRoundingOverlap
        } else if self.canonicalTimelineOffsetEpoch == nil {
            self.canonicalTimelineOffsetEpoch = producerEpoch
        }

        var boundaryDiscontinuity: MeetingAudioDiscontinuity?
        if previousEnd != nil, epochChanged || backwardReset {
            boundaryDiscontinuity = MeetingAudioDiscontinuity(
                kind: .clockDiscontinuity,
                presentationTime: Self.mediaTime(sourcePresentationTime),
                gapSeconds: nil,
                detail: epochChanged
                    ? "Capture producer epoch changed."
                    : "Presentation timestamp moved backwards."
            )
        }

        let sampleBuffer: CMSampleBuffer
        if presentationTime != sourcePresentationTime {
            guard let retimed = Self.retimedCopy(sourceSampleBuffer, presentationTime: presentationTime) else {
                self.recordDroppedSample(detail: "Capture audio could not be normalized onto the meeting timeline.")
                return
            }
            sampleBuffer = retimed
        } else {
            sampleBuffer = sourceSampleBuffer
        }

        if let activeChunk = self.activeChunk {
            let elapsed = CMTimeGetSeconds(presentationTime - activeChunk.start)
            let gap = CMTimeGetSeconds(presentationTime - activeChunk.end)
            // Compared on the canonical timeline: once the epoch's offset is established, later
            // samples are contiguous here even though their raw stamps are far behind `end`.
            let clockBoundary = epochChanged || backwardReset || hostMapping?.spans.first?.discontinuityBefore == true
            if elapsed >= self.chunkDuration || clockBoundary || gap > 0.5 {
                if clockBoundary || gap > 0.5 {
                    self.silenceAccumulatedSeconds = 0
                    self.activeChunk?.discontinuities.append(boundaryDiscontinuity ?? MeetingAudioDiscontinuity(
                        kind: .sourceLost,
                        presentationTime: Self.mediaTime(sourcePresentationTime),
                        gapSeconds: gap,
                        detail: "Unexpected audio gap."
                    ))
                    boundaryDiscontinuity = nil
                }
                self.scheduleActiveChunkFinalization()
            }
        }

        do {
            if self.activeChunk == nil {
                try self.beginChunk(
                    with: sampleBuffer,
                    at: presentationTime,
                    producerEpoch: producerEpoch,
                    discontinuities: boundaryDiscontinuity.map { [$0] } ?? []
                )
            } else if let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
                      let incomingContract = try? MeetingPCMFormatContract(formatDescription: formatDescription),
                      incomingContract != self.activeChunk?.formatContract
            {
                self.scheduleActiveChunkFinalization()
                try self.beginChunk(
                    with: sampleBuffer,
                    at: presentationTime,
                    producerEpoch: producerEpoch,
                    discontinuities: [],
                    contract: incomingContract
                )
            }
            guard var activeChunk = self.activeChunk else { return }
            if let hostMapping {
                activeChunk.clockMapping = try activeChunk.clockMapping.map { try $0.appending(hostMapping) } ?? hostMapping
            }
            let receipt = try activeChunk.sink.append(sampleBuffer)
            guard receipt.framesAccepted == receipt.framesWritten,
                  receipt.framesAccepted == Int64(CMSampleBufferGetNumSamples(sampleBuffer))
            else {
                throw MeetingCaptureError.writerFailed("PCM sink reported a short write.")
            }

            activeChunk.end = mappedEnd ?? (presentationTime + duration)
            activeChunk.framesWritten += receipt.framesWritten
            if activeChunk.framesWritten - activeChunk.lastCheckpointFrames >= Int64((activeChunk.format.sampleRate).rounded()) {
                try self.writeCheckpoint(for: &activeChunk)
            }
            self.activeChunk = activeChunk
            let recoveredFromWriterFailure = self.hasReportedWriterFailure
            self.hasReportedWriterFailure = false
            self.track.health.status = .healthy
            self.track.health.lastPresentationTime = Self.mediaTime(presentationTime)
            let now = Date()
            self.track.health.lastSampleAt = now

            let peak = Self.peakAmplitude(sampleBuffer)
            if let peak {
                self.silenceAccumulatedSeconds = peak < Self.silenceAmplitudeThreshold
                    ? self.silenceAccumulatedSeconds + max(0, CMTimeGetSeconds(duration))
                    : 0
            }
            self.track.health.silentForSeconds = self.silenceAccumulatedSeconds

            if now.timeIntervalSince(self.lastLevelMeasurement) >= 0.1 {
                self.lastLevelMeasurement = now
                self.track.health.level = Self.normalizedLevel(fromPeak: peak ?? 0)
            }
            self.track.health.detail = nil
            self.emitHealthIfNeeded(force: recoveredFromWriterFailure)
        } catch {
            self.track.health.droppedSampleCount += 1
            // A sink failure poisons the current container. Retire it immediately so the next
            // callback can establish a fresh chunk. Chunk-start failures have no sink to retire,
            // but must use the same failure-episode reporting as append/finalization failures.
            if let failedChunk = self.activeChunk {
                self.activeChunk = nil
                self.lastFinalizedEnd = failedChunk.end
                self.activeChunk = failedChunk
                self.scheduleActiveChunkFinalization()
                self.reportWriterFailure(detail: "PCM chunk write failed: \(error.localizedDescription)")
            } else {
                self.reportWriterFailure(detail: error.localizedDescription, sampleBuffer: sampleBuffer)
            }
        }
    }

    private func beginChunk(
        with sampleBuffer: CMSampleBuffer,
        at start: CMTime,
        producerEpoch: UInt64,
        discontinuities: [MeetingAudioDiscontinuity],
        contract: MeetingPCMFormatContract? = nil
    ) throws {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mSampleRate > 0,
              asbd.mChannelsPerFrame > 0
        else {
            throw MeetingCaptureError.unsupportedAudioFormat
        }

        let formatContract = try contract ?? MeetingPCMFormatContract(formatDescription: formatDescription)

        guard asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              asbd.mBitsPerChannel == 32,
              asbd.mFramesPerPacket == 1
        else { throw MeetingCaptureError.unsupportedAudioFormat }

        let channelCount = Int(asbd.mChannelsPerFrame)
        let sequence = self.nextChunkSequence
        self.nextChunkSequence += 1
        let stem = String(format: "%06d", sequence)
        let format = MeetingAudioFormat(
            codec: "lpcm-f32",
            sampleRate: asbd.mSampleRate,
            channelCount: channelCount,
            bitRate: nil
        )
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: self.sessionDirectory)
        let relativePath = "tracks/\(self.track.kind.rawValue)/\(stem).caf"
        // Temporary, metadata-only diagnostics for the remote capture crash. This runs on
        // the writer queue once per chunk, never on the capture callback or UI thread.
        if DebugLogger.diagnosticsEnabled {
            var diagnosticLayoutSize = 0
            let layout = CMAudioFormatDescriptionGetChannelLayout(formatDescription, sizeOut: &diagnosticLayoutSize)
            FileLogger.shared.appendSync(line:
                "[MeetingPCMProbe] before-format track=\(self.track.kind.rawValue) chunk=\(sequence) " +
                    "rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) flags=\(asbd.mFormatFlags) " +
                    "bits=\(asbd.mBitsPerChannel) bytesPerFrame=\(asbd.mBytesPerFrame) bytesPerPacket=\(asbd.mBytesPerPacket) " +
                    "layoutBytes=\(diagnosticLayoutSize) layoutTag=\(layout?.pointee.mChannelLayoutTag ?? 0) " +
                    "frames=\(CMSampleBufferGetNumSamples(sampleBuffer))")
        }
        let clientFormat = try MeetingPCMFormatResolver.resolve(formatDescription)
        if DebugLogger.diagnosticsEnabled {
            FileLogger.shared.appendSync(line: "[MeetingPCMProbe] after-format track=\(self.track.kind.rawValue) chunk=\(sequence)")
        }
        try sink.begin(relativeFilePath: relativePath, format: clientFormat, contract: formatContract)
        let id = UUID()
        self.activeIntent = MeetingAudioChunkLedgerIntent(chunkID: id, sequence: sequence,
            canonicalStart: Self.mediaTime(start), producerEpoch: producerEpoch, sourceFormat: format,
            partialRelativeFilePath: sink.partialRelativeFilePath ?? relativePath, createdAt: Date())
        self.latestCheckpoint = nil
        self.track.format = format
        self.activeChunk = ActiveChunk(
            id: id,
            sequence: sequence,
            relativeFinalPath: relativePath,
            sink: sink,
            start: start,
            end: start,
            discontinuities: discontinuities,
            format: format,
            sourceFormatDescription: formatDescription,
            formatContract: formatContract,
            producerEpoch: producerEpoch,
            framesWritten: 0,
            lastCheckpointFrames: 0
        )
        self.publishJournal()
    }

    private func scheduleActiveChunkFinalization() {
        guard var chunk = self.activeChunk else { return }
        self.activeChunk = nil
        self.lastFinalizedEnd = chunk.end
        // Only a bounded per-file recovery capsule and handle close belong to capture.
        // Hashing, fsync, ledger and index writes are owned by the coalescing journal.
        try? self.writeCheckpoint(for: &chunk)
        guard chunk.framesWritten > 0 else { chunk.sink.cancel(); return }
        let mapping = (try? chunk.clockMapping?.compacted()) ?? chunk.clockMapping
        let partial = chunk.sink.partialRelativeFilePath ?? chunk.relativeFinalPath
        let record = MeetingAudioChunk(id: chunk.id, sequence: chunk.sequence, relativeFilePath: chunk.relativeFinalPath,
            presentationStart: Self.mediaTime(chunk.start), presentationEnd: Self.mediaTime(chunk.end),
            discontinuities: chunk.discontinuities, sha256: "", byteCount: 0, finalizationState: .writing,
            audioSchemaVersion: 2, captureAnalysisAsset: .init(role: .captureAnalysis,
                encoding: .linearPCMFloat32CAFV1, presence: .partial, relativeFilePath: partial, byteCount: 0,
                sampleRate: chunk.format.sampleRate, channelCount: chunk.format.channelCount, frameCount: chunk.framesWritten),
            clockMapping: mapping)
        do {
            let eras = (self.scheduledMetadata ?? self.track).captureEras ?? []
            let first = eras.lastIndex(where: { $0.startSeconds <= record.presentationStart.seconds }) ?? 0
            let relevant = eras.isEmpty ? [] : Array(eras.dropFirst(first).prefix(while: { $0.startSeconds <= record.presentationEnd.seconds }))
            let capsule = MeetingAudioRecoveryCapsule(trackID: self.track.id, kind: self.track.kind, chunk: record, sessionID: UUID(uuidString: self.sessionDirectory.lastPathComponent),
                captureEras: relevant.isEmpty ? nil : relevant)
            try chunk.sink.writeRecoveryMetadata(JSONEncoder().encode(capsule))
        } catch {
            self.eventHandler(.interrupted(kind: .metadataPersistenceDelayed, trackID: self.track.id,
                detail: PichiLocalization.text("Audio recording continues. Metadata recovery is pending.")))
        }
        do { try chunk.sink.sealForRecovery() }
        catch { self.reportWriterFailure(detail: "Audio container close will be retried during recovery.") }
        self.track.chunks.append(record)
        self.publishJournal()
    }

    private func publishJournal(track: MeetingAudioTrack? = nil, final: Bool = false,
                                completion: MeetingAudioRecordingJournal.Completion? = nil) {
        var snapshot = track ?? self.scheduledMetadata ?? self.track
        snapshot.chunks = self.track.chunks; snapshot.health = self.track.health; snapshot.format = self.track.format
        self.journal?.submit(.init(track: snapshot, intent: self.activeIntent,
            checkpoint: self.latestCheckpoint, final: final), completion: completion)
    }

    private func receiveJournal(_ chunks: [MeetingAudioChunk], error: Error?) {
        for chunk in chunks {
            guard let index = self.track.chunks.firstIndex(where: { $0.id == chunk.id }) else { continue }
            let wasReady = self.track.chunks[index].finalizationState == .finalized
            self.track.chunks[index] = chunk
            if !wasReady, chunk.finalizationState == .finalized, let asset = chunk.captureAnalysisAsset,
               let rate = asset.sampleRate, let channels = asset.channelCount {
                self.eventHandler(.chunkFinalized(trackID: self.track.id, chunk: chunk,
                    format: .init(codec: "lpcm-f32", sampleRate: rate, channelCount: channels, bitRate: nil)))
            }
        }
        if error != nil, !self.metadataFailureReported {
            self.metadataFailureReported = true
            self.eventHandler(.interrupted(kind: .metadataPersistenceDelayed, trackID: self.track.id,
                detail: PichiLocalization.text("Audio recording continues. Metadata recovery is pending.")))
        } else if error == nil, self.metadataFailureReported {
            self.metadataFailureReported = false
            self.eventHandler(.interrupted(kind: .metadataPersistenceRecovered, trackID: self.track.id, detail: nil))
        }
    }

    private func reportWriterFailure(detail: String, sampleBuffer: CMSampleBuffer? = nil) {
        guard !self.hasReportedWriterFailure else { return }
        self.hasReportedWriterFailure = true
        if DebugLogger.diagnosticsEnabled,
           let sampleBuffer,
           let description = CMSampleBufferGetFormatDescription(sampleBuffer),
           let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee
        {
            FileLogger.shared.appendSync(line:
                "[MeetingPCMProbe] rejected-format track=\(self.track.kind.rawValue) " +
                    "formatID=\(asbd.mFormatID) rate=\(asbd.mSampleRate) channels=\(asbd.mChannelsPerFrame) " +
                    "flags=\(asbd.mFormatFlags) bits=\(asbd.mBitsPerChannel) " +
                    "bytesPerFrame=\(asbd.mBytesPerFrame) bytesPerPacket=\(asbd.mBytesPerPacket) " +
                    "framesPerPacket=\(asbd.mFramesPerPacket)")
        }
        self.track.health.status = .degraded
        self.track.health.detail = detail
        self.eventHandler(.interrupted(kind: .writerFailure, trackID: self.track.id, detail: detail))
        self.emitHealthIfNeeded(force: true)
    }

    private func completeStop() {
        self.track.chunks.sort { $0.sequence < $1.sequence }
        self.track.health.status = self.track.chunks.contains(where: { $0.finalizationState == .finalized })
            ? .stopped
            : .unavailable
        if self.track.health.status == .stopped {
            self.track.health.detail = nil
        }

        self.stateLock.lock()
        self.lifecycle = .stopped
        self.stoppedTrack = self.track
        let waiters = self.stopWaiters
        self.stopWaiters = []
        self.stateLock.unlock()
        waiters.forEach { $0.resume(returning: self.track) }
    }

    private func writeCheckpoint(for activeChunk: inout ActiveChunk) throws {
        guard activeChunk.framesWritten > 0 else { return }
        self.latestCheckpoint = MeetingAudioChunkLedgerCheckpoint(chunkID: activeChunk.id,
            expectedFrames: activeChunk.framesWritten, writtenFrames: activeChunk.framesWritten,
            lastCanonicalPTS: Self.mediaTime(activeChunk.end), updatedAt: Date())
        self.publishJournal()
        activeChunk.lastCheckpointFrames = activeChunk.framesWritten
    }

    private func recordDroppedSample(detail: String) {
        self.track.health.status = .degraded
        self.track.health.droppedSampleCount += 1
        self.track.health.detail = detail
        self.eventHandler(.interrupted(kind: .writerBackpressure, trackID: self.track.id, detail: detail))
        self.emitHealthIfNeeded(force: true)
    }

    private func drainDroppedSampleReport() {
        self.stateLock.lock()
        let droppedCount = self.pendingDroppedSampleCount
        self.pendingDroppedSampleCount = 0
        self.dropReportScheduled = false
        self.stateLock.unlock()
        guard droppedCount > 0 else { return }
        self.track.health.status = .degraded
        self.track.health.droppedSampleCount += droppedCount
        let detail = "Audio writer queue dropped \(droppedCount) samples while saturated."
        self.track.health.detail = detail
        self.eventHandler(.interrupted(kind: .writerBackpressure, trackID: self.track.id, detail: detail))
        self.emitHealthIfNeeded(force: true)
    }

    private func emitHealthIfNeeded(force: Bool = false) {
        let now = Date()
        guard force || now.timeIntervalSince(self.lastHealthEmission) >= 0.25 else { return }
        self.lastHealthEmission = now
        self.eventHandler(.trackHealth(trackID: self.track.id, health: self.track.health))
    }

    private static func mediaTime(_ time: CMTime) -> MeetingMediaTime {
        MeetingMediaTime(value: time.value, timescale: time.timescale)
    }

    private static func sampleDuration(_ sampleBuffer: CMSampleBuffer) -> CMTime {
        let duration = CMSampleBufferGetDuration(sampleBuffer)
        if duration.isValid, duration.isNumeric, duration > .zero {
            return duration
        }
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mSampleRate > 0
        else { return CMTime(value: 1, timescale: 48_000) }
        return CMTime(
            value: CMTimeValue(CMSampleBufferGetNumSamples(sampleBuffer)),
            timescale: CMTimeScale(asbd.mSampleRate.rounded())
        )
    }

    /// Retimes every timing entry by one delta so PCM duration/order are preserved while writer
    /// metadata and encoded timestamps share the same monotonic meeting timeline.
    private static func retimedCopy(
        _ sampleBuffer: CMSampleBuffer,
        presentationTime: CMTime
    ) -> CMSampleBuffer? {
        var timingCount = 0
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: 0,
            arrayToFill: nil,
            entriesNeededOut: &timingCount
        ) == noErr, timingCount > 0 else { return nil }

        var timings = Array(
            repeating: CMSampleTimingInfo(
                duration: .invalid,
                presentationTimeStamp: .invalid,
                decodeTimeStamp: .invalid
            ),
            count: timingCount
        )
        guard CMSampleBufferGetSampleTimingInfoArray(
            sampleBuffer,
            entryCount: timingCount,
            arrayToFill: &timings,
            entriesNeededOut: &timingCount
        ) == noErr else { return nil }

        let original = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        let delta = presentationTime - original
        for index in timings.indices {
            if timings[index].presentationTimeStamp.isValid {
                timings[index].presentationTimeStamp = CMTimeAdd(
                    timings[index].presentationTimeStamp,
                    delta
                )
            }
            if timings[index].decodeTimeStamp.isValid {
                timings[index].decodeTimeStamp = CMTimeAdd(
                    timings[index].decodeTimeStamp,
                    delta
                )
            }
        }
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopyWithNewTiming(
            allocator: kCFAllocatorDefault,
            sampleBuffer: sampleBuffer,
            sampleTimingEntryCount: timingCount,
            sampleTimingArray: &timings,
            sampleBufferOut: &copy
        )
        return status == noErr ? copy : nil
    }

    private static func normalizedLevel(fromPeak peak: Float) -> Float {
        guard peak > 0 else { return 0 }
        let decibels = 20 * log10f(min(1, peak))
        return max(0, min(1, (decibels + 60) / 60))
    }

    private static func peakAmplitude(_ sampleBuffer: CMSampleBuffer) -> Float? {
        guard let formatDescription = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(formatDescription)?.pointee,
              asbd.mFormatID == kAudioFormatLinearPCM,
              asbd.mBitsPerChannel == 32,
              asbd.mFormatFlags & kAudioFormatFlagIsFloat != 0
        else { return nil }

        var requiredSize = 0
        let sizeStatus = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: &requiredSize,
            bufferListOut: nil,
            bufferListSize: 0,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: 0,
            blockBufferOut: nil
        )
        guard sizeStatus == noErr, requiredSize > 0 else { return nil }

        let rawBuffer = UnsafeMutableRawPointer.allocate(
            byteCount: requiredSize,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        defer { rawBuffer.deallocate() }
        let audioBufferList = rawBuffer.bindMemory(to: AudioBufferList.self, capacity: 1)
        var retainedBlockBuffer: CMBlockBuffer?
        let status = CMSampleBufferGetAudioBufferListWithRetainedBlockBuffer(
            sampleBuffer,
            bufferListSizeNeededOut: nil,
            bufferListOut: audioBufferList,
            bufferListSize: requiredSize,
            blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil,
            flags: UInt32(kCMSampleBufferFlag_AudioBufferList_Assure16ByteAlignment),
            blockBufferOut: &retainedBlockBuffer
        )
        guard status == noErr else { return nil }

        var peak: Float = 0
        for buffer in UnsafeMutableAudioBufferListPointer(audioBufferList) {
            guard let data = buffer.mData else { continue }
            let sampleCount = Int(buffer.mDataByteSize) / MemoryLayout<Float>.size
            guard sampleCount > 0 else { continue }
            let samples = data.assumingMemoryBound(to: Float.self)
            let stride = max(1, sampleCount / 512)
            var index = 0
            while index < sampleCount {
                peak = max(peak, abs(samples[index]))
                index += stride
            }
        }
        return peak
    }
}
