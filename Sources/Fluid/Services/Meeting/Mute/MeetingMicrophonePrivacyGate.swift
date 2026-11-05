@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Quarantines microphone PCM before diagnostics, processing, persistence and live ASR. This
/// bounds the response to observed mute state; visual polling is not an audio-source attestation.
/// One owner must call `stop()` before retiring the capture attempt or its delivery queues.
final nonisolated class MeetingMicrophonePrivacyGate: @unchecked Sendable {
    struct Configuration: Sendable {
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
    private let configuration: Configuration
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
    func setAdmitted(_ value: Bool, observedAtHostTime observed: UInt64, unsafeStartHostTime: UInt64? = nil) {
        let now = self.hostTime()
        self.lock.withLock {
            guard !self.stopped else {
                if !value, let unsafeStartHostTime {
                    self.closeEpochLocked(at: now, unsafeStart: unsafeStartHostTime)
                    self.drainLocked(now: now)
                }
                return
            }
            guard value, observed > 0, observed <= now, now - observed <= self.leaseTicks,
                  self.latestObservation.map({ observed >= $0 }) ?? true,
                  self.lastNegativeProcessedAt.map({ observed > $0 }) ?? true else {
                self.closeEpochLocked(at: now, unsafeStart: unsafeStartHostTime)
                self.drainLocked(now: now)
                return
            }
            // A delayed timer must not let a fresh positive retroactively fill an observation
            // gap. Close the old epoch before renewing, even if no PCM arrived during that gap.
            if self.admitted, let previous = self.latestObservation, now - previous > self.leaseTicks {
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
    @discardableResult
    func submit(_ sampleBuffer: CMSampleBuffer, deliveryQueue: DispatchQueue,
                delivery: @escaping @Sendable (CMSampleBuffer) -> Void) -> Bool {
        let now = self.hostTime()
        guard let metadata = self.metadata(sampleBuffer) else {
            self.lock.withLock { self.rejectedBuffers += 1 }
            return false
        }
        let item: Item? = self.lock.withLock {
            guard self.freshLocked(now: now), let epochStart = self.epochStart,
                  metadata.start >= epochStart, metadata.end <= now,
                  // Independent CoreMedia scale conversions can differ by one native host tick
                  // at a contiguous 44.1 kHz boundary. This is rounding, not a reordered buffer.
                  self.lastSubmittedEnd.map({ metadata.start >= $0 || $0 - metadata.start <= 1 }) ?? true else {
                self.rejectedBuffers += 1; return nil
            }
            guard metadata.bytes <= self.configuration.maximumQueuedBytes - self.retainedBytes,
                  self.retainedBuffers < self.configuration.maximumQueuedBuffers else {
                self.rejectedBuffers += 1
                self.closeEpochLocked(at: now)
                return nil
            }
            let item = Item(metadata: metadata, generation: self.generation, queue: deliveryQueue, delivery: delivery)
            self.lastSubmittedEnd = metadata.end
            self.retainedBytes += metadata.bytes
            self.retainedBuffers += 1
            self.work.enter()
            self.pending.append(item)
            return item
        }
        guard let item else { return false }
        var ownedSample = Self.ownedCopy(sampleBuffer, metadata: metadata)
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
        guard !self.stopped, self.admitted, let observation = self.latestObservation,
              now >= observation, now - observation <= self.leaseTicks else {
            if self.admitted { self.closeEpochLocked(at: now) }
            return false
        }
        return true
    }

    private func permitsLocked(_ metadata: SampleMetadata, now: UInt64) -> Bool {
        guard metadata.end <= now, now - metadata.end >= self.quarantineTicks else { return false }
        if self.isApprovedLocked(metadata) { return true }
        return self.freshLocked(now: now) && self.epochStart.map({ metadata.start >= $0 }) == true
            && metadata.end <= now && now - metadata.end >= self.quarantineTicks
            && self.latestObservation.map({ $0 >= metadata.end }) == true
    }

    private func isApprovedLocked(_ metadata: SampleMetadata) -> Bool {
        self.approvedIntervals.contains { metadata.start >= $0.start && metadata.end <= $0.end }
    }

    private func closeEpochLocked(at now: UInt64, unsafeStart: UInt64? = nil, preserveConfirmedPrefix: Bool = true) {
        if let unsafeStart {
            self.approvedIntervals = self.approvedIntervals.compactMap { interval in
                let end = min(interval.end, unsafeStart)
                return end > interval.start ? (interval.start, end) : nil
            }
        }
        if preserveConfirmedPrefix, self.admitted, let start = self.epochStart,
           let observed = self.latestObservation, observed <= now, observed > self.prefixSafetyTicks {
            var end = observed - self.prefixSafetyTicks
            // A key-up or another early close boundary may narrow a grant; it can never extend
            // conference proof beyond the last positive visual observation.
            if let unsafeStart { end = min(end, unsafeStart) }
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

    private func metadata(_ sample: CMSampleBuffer) -> SampleMetadata? {
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
        let start = CMClockConvertHostTimeToSystemUnits(timing.presentationTimeStamp)
        let duration = Self.ticks(Double(frames) / asbd.mSampleRate)
        guard start > 0, duration > 0, start <= UInt64.max - duration else { return nil }
        return SampleMetadata(start: start, end: start + duration, bytes: bytes, frames: frames,
                              format: format, timing: timing)
    }

    private static func ownedCopy(_ sample: CMSampleBuffer, metadata: SampleMetadata) -> CMSampleBuffer? {
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
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &result) == noErr else { return nil }
        return result
    }

    private static func ticks(_ seconds: Double) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
}
