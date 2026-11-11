@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Quarantines microphone PCM before diagnostics, processing, persistence and live ASR. This
/// bounds the response to observed mute state; visual polling is not an audio-source attestation.
/// One owner must call `stop()` before retiring the capture attempt or its delivery queues.
final nonisolated class MeetingMicrophonePrivacyGate: @unchecked Sendable {
    /// The native tap proves acquisition time against its sample-count timeline before intake.
    /// Keep this bound shared with that proof; it is not a future-time allowance for other PCM.
    static let maximumAcquisitionDivergenceSeconds: Double = 0.020
    private static let acquisitionAttachmentKey = "ai.pichi.voice.microphoneAcquisitionInterval" as CFString

    private final class AcquisitionInterval: NSObject {
        let owner: UUID
        let canonicalStart: UInt64
        let canonicalEnd: UInt64
        let acquisitionStart: UInt64
        init(owner: UUID, metadata: SampleMetadata) {
            self.owner = owner
            self.canonicalStart = metadata.canonicalStart
            self.canonicalEnd = metadata.canonicalEnd
            self.acquisitionStart = metadata.start
        }
    }

    struct Configuration: Sendable {
        enum AdmissionPolicy: Equatable, Sendable {
            case freshObservations
            /// A confirmed transition remains effective until another transition or stop.
            case latchedTransitions
        }

        var admissionPolicy: AdmissionPolicy = .freshObservations
        var quarantineSeconds: Double = 1
        var observationLeaseSeconds: Double = 0.75
        var maximumQueuedBytes: Int = 2 * 1024 * 1024
        var maximumQueuedBuffers: Int = 256
        var maximumBufferDurationSeconds: Double = 0.5
        var confirmedPrefixSafetySeconds: Double = 0.05
    }

    struct Statistics: Sendable {
        let retainedBytes: Int
        let retainedBuffers: Int
        let pendingBuffers: Int
        let deliveredBuffers: Int
        let rejectedBuffers: Int
    }

    private struct SampleMetadata {
        let start: UInt64
        let end: UInt64
        let canonicalStart: UInt64
        let canonicalEnd: UInt64
        let hasAcquisitionProof: Bool
        let bytes: Int
        let frames: Int
        let format: CMFormatDescription
        let timing: CMSampleTimingInfo
    }

    private final class Item: @unchecked Sendable {
        enum State { case copying, pending, scheduled, cancelledCopy, completed }
        let metadata: SampleMetadata
        let generation: UInt64
        let queue: DispatchQueue
        let delivery: @Sendable (CMSampleBuffer) -> Void
        var state = State.copying
        var sample: CMSampleBuffer?
        var approvedClosedPrefix = false
        init(metadata: SampleMetadata, generation: UInt64, queue: DispatchQueue,
             delivery: @escaping @Sendable (CMSampleBuffer) -> Void) {
            self.metadata = metadata; self.generation = generation
            self.queue = queue; self.delivery = delivery
        }
    }

    private let lock = NSLock()
    private let owner = UUID()
    private let acquisitionDivergenceTicks = MeetingMicrophonePrivacyGate.ticks(MeetingMicrophonePrivacyGate.maximumAcquisitionDivergenceSeconds)
    private var usesAcquisitionClock = false
    private let configuration: Configuration
    private let clockContext: MeetingRecordingClockContext?
    private let hostTime: @Sendable () -> UInt64
    private let createdAt: UInt64
    private let quarantineTicks: UInt64
    private let leaseTicks: UInt64
    private let prefixSafetyTicks: UInt64
    private let work = DispatchGroup()
    private let timerQueue = DispatchQueue(label: "meeting.microphone.privacy.freshness", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var stopped = false
    private var admitted = false
    private var generation: UInt64 = 0
    private var epochStart: UInt64?
    private var latestObservation: UInt64?
    private var lastNegativeProcessedAt: UInt64?
    private var lastSubmittedEnd: UInt64?
    private var pending: [Item] = []
    private var retainedBytes = 0
    private var retainedBuffers = 0
    private var deliveredBuffers = 0
    private var rejectedBuffers = 0
    /// Only immutable, previously confirmed acquisition intervals survive a negative/ordinary
    /// stop. Retiring old intervals denies their late output rather than allowing a broad prefix.
    private var approvedIntervals: [(start: UInt64, end: UInt64)] = []
    private static let maximumApprovedIntervals = 64

    init(configuration: Configuration = .init(),
         clockContext: MeetingRecordingClockContext? = nil,
         hostTime: @escaping @Sendable () -> UInt64 = { mach_absolute_time() },
         automaticWatchdog: Bool = true) {
        precondition(configuration.quarantineSeconds.isFinite && (1...5).contains(configuration.quarantineSeconds))
        precondition(configuration.observationLeaseSeconds.isFinite && configuration.observationLeaseSeconds > 0
                     && configuration.observationLeaseSeconds < configuration.quarantineSeconds)
        precondition((1...(16 * 1024 * 1024)).contains(configuration.maximumQueuedBytes)
                     && (1...1_024).contains(configuration.maximumQueuedBuffers))
        precondition(configuration.maximumBufferDurationSeconds.isFinite && configuration.maximumBufferDurationSeconds > 0
                     && configuration.maximumBufferDurationSeconds <= 1)
        precondition(configuration.confirmedPrefixSafetySeconds.isFinite && configuration.confirmedPrefixSafetySeconds >= 0
                     && configuration.confirmedPrefixSafetySeconds < configuration.observationLeaseSeconds)
        self.configuration = configuration
        self.clockContext = clockContext
        self.hostTime = hostTime
        self.createdAt = hostTime()
        self.quarantineTicks = Self.ticks(configuration.quarantineSeconds)
        self.leaseTicks = Self.ticks(configuration.observationLeaseSeconds)
        self.prefixSafetyTicks = Self.ticks(configuration.confirmedPrefixSafetySeconds)
        if automaticWatchdog {
            let timer = DispatchSource.makeTimerSource(queue: self.timerQueue)
            timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50), leeway: .milliseconds(5))
            timer.setEventHandler { [weak self] in self?.checkFreshnessAndDrain() }
            self.timer = timer
            timer.resume()
        }
    }

    deinit { self.timer?.cancel() }

    /// Times are mach host units, matching CMClockConvertHostTimeToSystemUnits and capture PTS.
    /// A negative always closes immediately. An old or malformed positive cannot reopen intake.
    /// Latched transitions do not expire, but a newly delivered transition must still be timely.
    func setAdmitted(_ value: Bool, observedAtHostTime observed: UInt64, unsafeStartHostTime: UInt64? = nil) {
        let now = self.hostTime()
        let boundary: UInt64?
        if self.configuration.admissionPolicy == .latchedTransitions {
            let supplied = unsafeStartHostTime ?? observed
            boundary = supplied <= now ? supplied : 0
        } else {
            boundary = unsafeStartHostTime
        }
        self.lock.withLock {
            guard !self.stopped else {
                if !value, let boundary {
                    self.closeEpochLocked(at: now, unsafeStart: boundary)
                    self.drainLocked(now: now)
                }
                return
            }
            if !value {
                self.closeEpochLocked(at: now, unsafeStart: boundary)
                self.drainLocked(now: now)
                return
            }
            guard observed > 0, observed <= now, now - observed <= self.leaseTicks,
                  self.latestObservation.map({ observed >= $0 }) ?? true,
                  self.lastNegativeProcessedAt.map({ observed > $0 }) ?? true else {
                // Rejected evidence is not a mute transition in a state-latched attempt.
                if self.configuration.admissionPolicy == .freshObservations {
                    self.closeEpochLocked(at: now, unsafeStart: unsafeStartHostTime)
                    self.drainLocked(now: now)
                }
                return
            }
            // A delayed timer must not let a fresh positive retroactively fill an observation
            // gap. Close the old epoch before renewing, even if no PCM arrived during that gap.
            if self.configuration.admissionPolicy == .freshObservations,
               self.admitted, let previous = self.latestObservation, now - previous > self.leaseTicks {
                self.closeEpochLocked(at: now)
            }
            self.latestObservation = observed
            if !self.admitted {
                self.admitted = true
                self.epochStart = max(self.createdAt, observed, self.lastNegativeProcessedAt ?? 0)
                self.lastSubmittedEnd = nil
            }
            self.drainLocked(now: now)
        }
    }

    /// Call from the adapter's existing non-real-time sample queue. The small PCM block is copied
    /// only after a bounded reservation; retaining an arbitrary system backing allocation is avoided.
    /// False is an intentional privacy rejection, not writer backpressure or permission to fall back.
    /// The native tap supplies its independently validated acquisition host time. PCM without that
    /// evidence keeps the strict canonical-clock admission path; its timestamps are never relaxed.
    @discardableResult
    func submit(_ sampleBuffer: CMSampleBuffer, acquisitionHostTime: UInt64? = nil,
                deliveryQueue: DispatchQueue, delivery: @escaping @Sendable (CMSampleBuffer) -> Void) -> Bool {
        let now = self.hostTime()
        guard let metadata = self.metadata(sampleBuffer, acquisitionHostTime: acquisitionHostTime) else {
            self.lock.withLock { self.rejectedBuffers += 1 }
            return false
        }
        let item: Item? = self.lock.withLock {
            guard self.freshLocked(now: now), let epochStart = self.epochStart,
                  self.startsInEpochLocked(metadata, epochStart: epochStart), metadata.end <= now,
                  // Independent CoreMedia scale conversions can differ by one native host tick
                  // at a contiguous 44.1 kHz boundary. This is rounding, not a reordered buffer.
                  self.lastSubmittedEnd.map({ metadata.canonicalStart >= $0 || $0 - metadata.canonicalStart <= 1 }) ?? true else {
                self.rejectedBuffers += 1; return nil
            }
            guard metadata.bytes <= self.configuration.maximumQueuedBytes - self.retainedBytes,
                  self.retainedBuffers < self.configuration.maximumQueuedBuffers else {
                self.rejectedBuffers += 1
                // Backpressure drops this block; it must not invent a mute transition.
                if self.configuration.admissionPolicy == .freshObservations { self.closeEpochLocked(at: now) }
                return nil
            }
            let item = Item(metadata: metadata, generation: self.generation, queue: deliveryQueue, delivery: delivery)
            self.lastSubmittedEnd = metadata.canonicalEnd
            self.usesAcquisitionClock = self.usesAcquisitionClock || metadata.hasAcquisitionProof
            self.retainedBytes += metadata.bytes
            self.retainedBuffers += 1
            self.work.enter()
            self.pending.append(item)
            return item
        }
        guard let item else { return false }
        var ownedSample = self.ownedCopy(sampleBuffer, metadata: metadata)
        return self.lock.withLock {
            let current = item.generation == self.generation && self.freshLocked(now: self.hostTime())
            let closedPrefix = item.approvedClosedPrefix && self.isApprovedLocked(item.metadata)
            guard item.state == .copying, current || closedPrefix, ownedSample != nil else {
                if item.state == .copying { self.pending.removeAll { $0 === item } }
                ownedSample = nil
                self.releaseLocked(item, rejected: true)
                return false
            }
            item.sample = ownedSample
            ownedSample = nil
            item.state = .pending
            self.drainLocked(now: self.hostTime())
            return true
        }
    }

    /// Remove a delayed PTT release gap without changing the newer remembered state. A HUD
    /// grant and a later rendered unmute may share one admission epoch, so preserve both safe
    /// sides of the gap, including the currently open epoch, using the existing interval ledger.
    func refineHistoricalRelease(unsafeStartHostTime: UInt64, resumedAtHostTime: UInt64) {
        let now = self.hostTime()
        guard resumedAtHostTime > 0, resumedAtHostTime <= now,
              unsafeStartHostTime <= resumedAtHostTime else { return }
        let safeEnd = unsafeStartHostTime > self.prefixSafetyTicks ? unsafeStartHostTime - self.prefixSafetyTicks : 0
        self.lock.withLock {
            self.approvedIntervals = self.approvedIntervals.flatMap { interval -> [(start: UInt64, end: UInt64)] in
                guard interval.end > safeEnd, interval.start < resumedAtHostTime else { return [interval] }
                var kept: [(start: UInt64, end: UInt64)] = []
                if interval.start < safeEnd { kept.append((interval.start, safeEnd)) }
                if interval.end > resumedAtHostTime { kept.append((resumedAtHostTime, interval.end)) }
                return kept
            }
            if self.admitted, !self.stopped, let start = self.epochStart, start < resumedAtHostTime {
                if start < safeEnd { self.approvedIntervals.append((start, safeEnd)) }
                self.epochStart = resumedAtHostTime
            }
            if self.approvedIntervals.count > Self.maximumApprovedIntervals {
                self.approvedIntervals.removeFirst(self.approvedIntervals.count - Self.maximumApprovedIntervals)
            }
            let items = self.pending
            self.pending.removeAll(keepingCapacity: true)
            for item in items {
                let inCurrentEpoch = !self.stopped && self.admitted
                    && self.epochStart.map({ self.startsInEpochLocked(item.metadata, epochStart: $0) }) == true
                    && item.generation == self.generation
                if inCurrentEpoch || self.isApprovedLocked(item.metadata) {
                    self.pending.append(item)
                } else if item.state == .copying {
                    item.state = .cancelledCopy
                } else {
                    self.releaseLocked(item, rejected: true)
                }
            }
            self.drainLocked(now: now)
        }
    }

    /// Defense for writer/live sinks which receive late buffered AEC or fallback output. It does
    /// not replace ingress quarantine, because diagnostics must never see unadmitted raw PCM.
    func permitsReleasedSample(_ sampleBuffer: CMSampleBuffer) -> Bool {
        guard let metadata = self.metadata(sampleBuffer) else { return false }
        let now = self.hostTime()
        return self.lock.withLock { self.permitsLocked(metadata, now: now) }
    }

    /// Same production path is also driven by a virtual host clock in the synthetic checks.
    func checkFreshnessAndDrain() {
        self.lock.withLock { self.drainLocked(now: self.hostTime()) }
    }

    /// Irreversible abort: drop all pending PCM and revoke prior approvals. This is appropriate
    /// for failed start/aborted attempts. Ordinary end uses `stop()` to preserve confirmed speech.
    func close() {
        self.lock.withLock {
            self.stopped = true
            self.approvedIntervals.removeAll(keepingCapacity: false)
            self.closeEpochLocked(at: self.hostTime(), preserveConfirmedPrefix: false)
            self.timer?.cancel()
        }
    }

    /// Ordinary end closes intake while retaining only confirmed prefix PCM until its existing
    /// quarantine completes. This also gives an earlier, late close boundary time to narrow it.
    func finishInput() {
        self.lock.withLock {
            if !self.stopped {
                self.stopped = true
                self.closeEpochLocked(at: self.hostTime())
                self.drainLocked(now: self.hostTime())
            }
        }
    }

    func stop() async {
        self.finishInput()
        await withCheckedContinuation { continuation in
            self.timerQueue.async { [self] in
                self.work.notify(queue: self.timerQueue) {
                    self.timer?.cancel()
                    self.timerQueue.async { continuation.resume() }
                }
            }
        }
    }

    var statistics: Statistics {
        self.lock.withLock {
            Statistics(retainedBytes: self.retainedBytes, retainedBuffers: self.retainedBuffers,
                       pendingBuffers: self.pending.count, deliveredBuffers: self.deliveredBuffers,
                       rejectedBuffers: self.rejectedBuffers)
        }
    }

    private func freshLocked(now: UInt64) -> Bool {
        if self.configuration.admissionPolicy == .latchedTransitions {
            return !self.stopped && self.admitted
        }
        guard !self.stopped, self.admitted, let observation = self.latestObservation,
              now >= observation, now - observation <= self.leaseTicks else {
            if self.admitted { self.closeEpochLocked(at: now) }
            return false
        }
        return true
    }

    private func permitsLocked(_ metadata: SampleMetadata, now: UInt64) -> Bool {
        // Converted output loses attachments and is checked again on its canonical timeline.
        // Mature the original against both clocks, including that conservative downstream margin,
        // so the second check cannot discard a just-released valid block without a retry.
        let maturityEnd = max(metadata.end, metadata.canonicalEnd)
        let maturityMargin = self.clockContext == nil && self.usesAcquisitionClock ? self.acquisitionDivergenceTicks : 0
        guard maturityEnd <= now, now - maturityEnd >= self.quarantineTicks + maturityMargin else { return false }
        if self.isApprovedLocked(metadata) { return true }
        return self.freshLocked(now: now)
            && self.epochStart.map({ self.startsInEpochLocked(metadata, epochStart: $0) }) == true
            && (self.configuration.admissionPolicy == .latchedTransitions
                || self.latestObservation.map({ $0 >= metadata.end }) == true)
    }

    private func acquisitionMarginLocked(_ metadata: SampleMetadata) -> UInt64 {
        // Resampling can construct a new buffer without the gate-owned attachment. Such output
        // keeps its canonical clock, with conservative edges instead of inventing acquisition proof.
        self.clockContext == nil && self.usesAcquisitionClock && !metadata.hasAcquisitionProof ? self.acquisitionDivergenceTicks : 0
    }

    private func startsInEpochLocked(_ metadata: SampleMetadata, epochStart: UInt64) -> Bool {
        metadata.start >= epochStart && metadata.start - epochStart >= self.acquisitionMarginLocked(metadata)
    }

    private func isApprovedLocked(_ metadata: SampleMetadata) -> Bool {
        let margin = self.acquisitionMarginLocked(metadata)
        return self.approvedIntervals.contains {
            metadata.start >= $0.start && metadata.start - $0.start >= margin
                && metadata.end <= $0.end && $0.end - metadata.end >= margin
        }
    }

    private func closeEpochLocked(at now: UInt64, unsafeStart: UInt64? = nil, preserveConfirmedPrefix: Bool = true) {
        // The adapter permits bounded canonical/acquisition clock divergence. Apply the same
        // safety margin to real key-up boundaries, including already closed prefix grants.
        let safeBoundary = unsafeStart.map { $0 > self.prefixSafetyTicks ? $0 - self.prefixSafetyTicks : 0 }
        if let safeBoundary {
            self.approvedIntervals = self.approvedIntervals.compactMap { interval in
                let end = min(interval.end, safeBoundary)
                return end > interval.start ? (interval.start, end) : nil
            }
        }
        let confirmedThrough: UInt64? = self.configuration.admissionPolicy == .latchedTransitions ? now : self.latestObservation
        if preserveConfirmedPrefix, self.admitted, let start = self.epochStart,
           let confirmedThrough, confirmedThrough <= now, confirmedThrough > self.prefixSafetyTicks {
            var end = confirmedThrough - self.prefixSafetyTicks
            // Lease admission ends at its last positive proof; latched admission ends at the
            // explicit close. An earlier key-up boundary may narrow either policy's grant.
            if let safeBoundary { end = min(end, safeBoundary) }
            if end > start {
                self.approvedIntervals.append((start, end))
                if self.approvedIntervals.count > Self.maximumApprovedIntervals { self.approvedIntervals.removeFirst() }
            }
        }
        self.admitted = false
        self.epochStart = nil
        self.lastSubmittedEnd = nil
        self.generation &+= 1
        self.lastNegativeProcessedAt = max(self.lastNegativeProcessedAt ?? now, now)
        let discarded = self.pending
        self.pending.removeAll(keepingCapacity: true)
        for item in discarded {
            if preserveConfirmedPrefix, self.isApprovedLocked(item.metadata) {
                item.approvedClosedPrefix = true
                self.pending.append(item)
            } else if item.state == .copying { item.state = .cancelledCopy }
            else { self.releaseLocked(item, rejected: true) }
        }
    }

    private func drainLocked(now: UInt64) {
        _ = self.freshLocked(now: now)
        while let item = self.pending.first {
            guard item.state == .pending, self.permitsLocked(item.metadata, now: now) else { break }
            self.pending.removeFirst()
            item.state = .scheduled
            item.queue.async { [self, item] in
                let sample: CMSampleBuffer? = self.lock.withLock {
                    let current = item.generation == self.generation && self.permitsLocked(item.metadata, now: self.hostTime())
                    let approved = self.isApprovedLocked(item.metadata)
                    guard item.state == .scheduled, current || approved else { return nil }
                    return item.sample
                }
                if let sample { item.delivery(sample) }
                self.lock.withLock { self.releaseLocked(item, rejected: sample == nil) }
            }
        }
    }

    private func releaseLocked(_ item: Item, rejected: Bool) {
        guard item.state != .completed else { return }
        item.state = .completed
        item.sample = nil
        self.retainedBytes -= item.metadata.bytes
        self.retainedBuffers -= 1
        if rejected { self.rejectedBuffers += 1 } else { self.deliveredBuffers += 1 }
        self.work.leave()
    }

    private func metadata(_ sample: CMSampleBuffer, acquisitionHostTime: UInt64? = nil) -> SampleMetadata? {
        guard CMSampleBufferDataIsReady(sample),
              let format = CMSampleBufferGetFormatDescription(sample),
              let stream = CMAudioFormatDescriptionGetStreamBasicDescription(format),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let asbd = stream.pointee
        let frames = CMSampleBufferGetNumSamples(sample)
        let bytes = CMBlockBufferGetDataLength(block)
        guard asbd.mFormatID == kAudioFormatLinearPCM, asbd.mSampleRate.isFinite,
              (8_000...192_000).contains(asbd.mSampleRate), (1...8).contains(asbd.mChannelsPerFrame),
              (1...64).contains(asbd.mBitsPerChannel), asbd.mBytesPerFrame > 0,
              asbd.mBytesPerFrame <= 128, asbd.mFramesPerPacket == 1 else { return nil }
        let planes = asbd.mFormatFlags & kAudioFormatFlagIsNonInterleaved == 0 ? 1 : Int(asbd.mChannelsPerFrame)
        let frameBytes = Int(asbd.mBytesPerFrame) * planes
        guard frames > 0, frames <= 65_536,
              frameBytes > 0, frameBytes <= self.configuration.maximumQueuedBytes,
              frames <= self.configuration.maximumQueuedBytes / frameBytes,
              bytes == frames * frameBytes, bytes <= self.configuration.maximumQueuedBytes,
              Double(frames) / asbd.mSampleRate <= self.configuration.maximumBufferDurationSeconds else { return nil }
        var timing = CMSampleTimingInfo()
        guard CMSampleBufferGetSampleTimingInfo(sample, at: 0, timingInfoOut: &timing) == noErr,
              timing.presentationTimeStamp.isNumeric, timing.presentationTimeStamp.epoch == 0,
              timing.presentationTimeStamp > .zero else { return nil }
        let canonicalStart = CMClockConvertHostTimeToSystemUnits(timing.presentationTimeStamp)
        let duration = Self.ticks(Double(frames) / asbd.mSampleRate)
        guard canonicalStart > 0, duration > 0, canonicalStart <= UInt64.max - duration else { return nil }
        let canonicalEnd = canonicalStart + duration
        if let clockContext {
            guard let packet = MeetingCaptureClockMetadata.read(from: sample), clockContext.accepts(packet),
                  let first = packet.mapping.spans.first, let last = packet.mapping.spans.last else { return nil }
            let start = CMClockConvertHostTimeToSystemUnits(CMTime(value: first.hostStart.value,
                timescale: first.hostStart.timescale))
            let end = CMClockConvertHostTimeToSystemUnits(CMTime(value: last.hostEnd.value,
                timescale: last.hostEnd.timescale))
            guard start > 0, end > start else { return nil }
            return SampleMetadata(start: start, end: end, canonicalStart: start, canonicalEnd: end,
                hasAcquisitionProof: true, bytes: bytes, frames: frames, format: format, timing: timing)
        }
        let attached = CMGetAttachment(sample, key: Self.acquisitionAttachmentKey, attachmentModeOut: nil) as? AcquisitionInterval
        let provenStart: UInt64?
        if let acquisitionHostTime {
            let distance = canonicalStart > acquisitionHostTime
                ? canonicalStart - acquisitionHostTime : acquisitionHostTime - canonicalStart
            guard acquisitionHostTime > 0, distance <= self.acquisitionDivergenceTicks else { return nil }
            provenStart = acquisitionHostTime
        } else if let attached, attached.owner == self.owner,
                  attached.canonicalStart == canonicalStart, attached.canonicalEnd == canonicalEnd {
            provenStart = attached.acquisitionStart
        } else {
            provenStart = nil
        }
        let start = provenStart ?? canonicalStart
        guard start <= UInt64.max - duration else { return nil }
        return SampleMetadata(start: start, end: start + duration,
                              canonicalStart: canonicalStart, canonicalEnd: canonicalEnd,
                              hasAcquisitionProof: provenStart != nil, bytes: bytes, frames: frames,
                              format: format, timing: timing)
    }

    private func ownedCopy(_ sample: CMSampleBuffer, metadata: SampleMetadata) -> CMSampleBuffer? {
        guard let source = CMSampleBufferGetDataBuffer(sample) else { return nil }
        var copied: CMBlockBuffer?
        guard CMBlockBufferCreateContiguous(allocator: kCFAllocatorDefault, sourceBuffer: source,
            blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
            dataLength: metadata.bytes, flags: kCMBlockBufferAlwaysCopyDataFlag, blockBufferOut: &copied) == noErr,
              let copied else { return nil }
        var timing = metadata.timing
        var result: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: copied,
            formatDescription: metadata.format, sampleCount: metadata.frames,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr,
              let result else { return nil }
        if metadata.hasAcquisitionProof {
            CMSetAttachment(result, key: Self.acquisitionAttachmentKey,
                value: AcquisitionInterval(owner: self.owner, metadata: metadata),
                attachmentMode: kCMAttachmentMode_ShouldPropagate)
        }
        if self.clockContext != nil {
            do { try MeetingCaptureClockMetadata.copyExact(from: sample, to: result) }
            catch { return nil }
        }
        return result
    }

    private static func ticks(_ seconds: Double) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
}
