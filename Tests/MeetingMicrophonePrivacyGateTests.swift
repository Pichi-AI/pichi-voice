@preconcurrency import AVFoundation
import CoreMedia
import Foundation

private final class HostClock: @unchecked Sendable {
    private let lock = NSLock()
    private var time: UInt64
    init(_ seconds: Double = 1_000) { self.time = Self.ticks(seconds) }
    func set(_ seconds: Double) { self.lock.withLock { self.time = Self.ticks(seconds) } }
    func now() -> UInt64 { self.lock.withLock { self.time } }
    static func ticks(_ seconds: Double) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
}

private final class Sink: @unchecked Sendable {
    let queue = DispatchQueue(label: "privacy.tests.sink")
    private let key = DispatchSpecificKey<Int>()
    private let lock = NSLock()
    private var values: [Float] = []
    private var endings: [Float] = []
    private var correctQueue = true
    init() { self.queue.setSpecific(key: self.key, value: 1) }
    func receive(_ sample: CMSampleBuffer) {
        var value: Float = 0
        var ending: Float = 0
        if let block = CMSampleBufferGetDataBuffer(sample) {
            withUnsafeMutableBytes(of: &value) {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: MemoryLayout<Float>.size, destination: $0.baseAddress!)
            }
            withUnsafeMutableBytes(of: &ending) {
                _ = CMBlockBufferCopyDataBytes(block, atOffset: CMBlockBufferGetDataLength(block) - 4,
                    dataLength: 4, destination: $0.baseAddress!)
            }
        }
        self.lock.withLock {
            self.correctQueue = self.correctQueue && DispatchQueue.getSpecific(key: self.key) == 1
            self.values.append(value)
            self.endings.append(ending)
        }
    }
    func joined() { self.queue.sync {} }
    var snapshot: ([Float], Bool) { self.lock.withLock { (self.values, self.correctQueue) } }
    var tailValues: [Float] { self.lock.withLock { self.endings } }
}

private final class Checks {
    private(set) var count = 0
    func require(_ condition: Bool, _ detail: String) throws {
        self.count += 1
        guard condition else { throw NSError(domain: "PrivacyGateTests", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
    }
}

private final class Signal: @unchecked Sendable {
    private let lock = NSLock()
    private var signalled = false
    private var continuation: CheckedContinuation<Void, Never>?
    func signal() {
        let continuation = self.lock.withLock {
            self.signalled = true
            let continuation = self.continuation; self.continuation = nil
            return continuation
        }
        continuation?.resume()
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            let resume = self.lock.withLock {
                if self.signalled { return true }
                self.continuation = continuation
                return false
            }
            if resume { continuation.resume() }
        }
    }
    var value: Bool { self.lock.withLock { self.signalled } }
}

private enum Fixture {
    static func sample(_ marker: Float, at seconds: Double, frames: Int = 80,
                       channels: UInt32 = 1, rate: Double = 8_000, pts: CMTime? = nil,
                       includeData: Bool = true, planar: Bool = false, lastMarker: Float? = nil) throws -> CMSampleBuffer {
        let formatChannels = planar ? 1 : channels
        var asbd = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: 4 * formatChannels, mFramesPerPacket: 1, mBytesPerFrame: 4 * formatChannels,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
        var format: CMAudioFormatDescription?
        guard CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &format) == noErr, let format else {
            throw NSError(domain: "Fixture", code: 1)
        }
        var values = [Float](repeating: marker, count: frames * Int(channels))
        if let lastMarker { values[values.count - 1] = lastMarker }
        var block: CMBlockBuffer?
        if includeData {
            guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                blockLength: values.count * 4, blockAllocator: kCFAllocatorDefault, customBlockSource: nil,
                offsetToData: 0, dataLength: values.count * 4, flags: 0, blockBufferOut: &block) == noErr,
                  let block else { throw NSError(domain: "Fixture", code: 2) }
            let result = values.withUnsafeBytes {
                CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                    offsetIntoDestination: 0, dataLength: $0.count)
            }
            guard result == noErr else { throw NSError(domain: "Fixture", code: 3) }
        }
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(rate)),
            presentationTimeStamp: pts ?? CMClockMakeHostTimeFromSystemUnits(HostClock.ticks(seconds)),
            decodeTimeStamp: .invalid)
        var size = Int(asbd.mBytesPerFrame)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
            formatDescription: format, sampleCount: frames, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size,
            sampleBufferOut: &sample) == noErr, let sample else { throw NSError(domain: "Fixture", code: 4) }
        return sample
    }

    static func overwrite(_ sample: CMSampleBuffer, marker: Float) {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return }
        let values = [Float](repeating: marker, count: CMBlockBufferGetDataLength(block) / 4)
        values.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                offsetIntoDestination: 0, dataLength: $0.count)
        }
    }
}

@main private enum MeetingMicrophonePrivacyGateTests {
    static func refresh(_ gate: MeetingMicrophonePrivacyGate, _ clock: HostClock, at times: [Double]) {
        for time in times { clock.set(time); gate.setAdmitted(true, observedAtHostTime: clock.now()) }
    }

    static func main() async {
        let checks = Checks()
        do {
            try await self.closedAndFreshDelivery(checks)
            try await self.muteDropsAndEpochs(checks)
            try await self.staleAndMalformed(checks)
            try await self.delayedWatchdogCannotFillGap(checks)
            try await self.confirmedPrefixAndStop(checks)
            try await self.lateUnsafeBoundary(checks)
            try await self.unsafeBoundaryIncludesAcquisitionSafety(checks)
            try await self.contiguousFractionalRate(checks)
            try await self.planarPCM(checks)
            try await self.boundedApprovalHistory(checks)
            try await self.boundedQueuedDelivery(checks)
            try await self.joinedStop(checks)
            print("MeetingMicrophonePrivacyGate: \(checks.count) assertions passed; synthetic PCM only, no hardware or files")
        } catch { fputs("\(error.localizedDescription)\n", stderr); exit(1) }
    }

    static func closedAndFreshDelivery(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        clock.set(1_000.03)
        let first = try Fixture.sample(11, at: 1_000.01)
        try checks.require(!gate.submit(first, deliveryQueue: sink.queue, delivery: sink.receive), "initially closed microphone leaked")
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_000.06)
        let owned = try Fixture.sample(22, at: 1_000.04)
        try checks.require(gate.submit(owned, deliveryQueue: sink.queue, delivery: sink.receive), "fresh PCM not quarantined")
        Fixture.overwrite(owned, marker: 99)
        self.refresh(gate, clock, at: [1_000.4, 1_000.8])
        sink.joined()
        try checks.require(sink.snapshot.0.isEmpty, "quarantine released before one second")
        try checks.require(!gate.permitsReleasedSample(owned), "writer defense admitted early PCM")
        self.refresh(gate, clock, at: [1_001.1])
        sink.joined()
        try checks.require(sink.snapshot.0 == [22], "copy retained source storage or wrong PCM delivered")
        try checks.require(sink.snapshot.1, "delivery ran outside source callback queue")
        try checks.require(gate.permitsReleasedSample(owned), "mature current-epoch sample rejected by writer defense")
        gate.checkFreshnessAndDrain(); sink.joined()
        try checks.require(sink.snapshot.0 == [22], "PCM delivered twice")
        try checks.require(gate.statistics.retainedBytes == 0, "delivered PCM reservation leaked")
        await gate.stop()
    }

    static func muteDropsAndEpochs(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_000.1)
        let privatePCM = try Fixture.sample(31, at: 1_000.07)
        try checks.require(gate.submit(privatePCM, deliveryQueue: sink.queue, delivery: sink.receive), "setup PCM missing")
        clock.set(1_000.2); gate.setAdmitted(false, observedAtHostTime: clock.now())
        try checks.require(gate.statistics.retainedBytes == 0, "mute retained quarantined private PCM")
        self.refresh(gate, clock, at: [1_000.3, 1_000.7, 1_001.1, 1_001.5])
        sink.joined()
        try checks.require(sink.snapshot.0.isEmpty, "reopen rescued private PCM from prior epoch")
        try checks.require(!gate.permitsReleasedSample(privatePCM), "writer accepted prior-epoch PCM after reopen")
        clock.set(1_001.6); gate.setAdmitted(false, observedAtHostTime: clock.now())
        clock.set(1_001.7); gate.setAdmitted(true, observedAtHostTime: HostClock.ticks(1_001.5))
        let stale = try Fixture.sample(32, at: 1_001.65)
        try checks.require(!gate.submit(stale, deliveryQueue: sink.queue, delivery: sink.receive), "old positive observation reopened mute")
        clock.set(1_001.8); gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_001.9)
        let valid = try Fixture.sample(33, at: 1_001.85, channels: 2)
        try checks.require(gate.submit(valid, deliveryQueue: sink.queue, delivery: sink.receive), "stereo host PCM rejected")
        self.refresh(gate, clock, at: [1_002.2, 1_002.6, 1_003.0])
        sink.joined()
        try checks.require(sink.snapshot.0 == [33], "fresh epoch PCM missing or private markers leaked")
        // Rapid temporary unmute/release must discard its entire quarantined span.
        clock.set(1_003.1); gate.setAdmitted(false, observedAtHostTime: clock.now())
        clock.set(1_003.2); gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_003.24)
        try checks.require(gate.submit(try Fixture.sample(34, at: 1_003.22), deliveryQueue: sink.queue, delivery: sink.receive), "PTT setup missing")
        clock.set(1_003.25); gate.setAdmitted(false, observedAtHostTime: clock.now())
        self.refresh(gate, clock, at: [1_003.3, 1_003.7, 1_004.1, 1_004.5]); sink.joined()
        try checks.require(sink.snapshot.0 == [33], "rapid PTT release leaked quarantined audio")
        await gate.stop()
    }

    static func staleAndMalformed(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_000.1)
        try checks.require(gate.submit(try Fixture.sample(41, at: 1_000.05), deliveryQueue: sink.queue, delivery: sink.receive), "lease setup missing")
        clock.set(1_001.2); gate.checkFreshnessAndDrain(); sink.joined()
        try checks.require(sink.snapshot.0.isEmpty && gate.statistics.retainedBytes == 0, "stale observation without new input did not close")
        gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_001.23)
        try checks.require(!gate.submit(try Fixture.sample(40, at: 1_001.21), deliveryQueue: sink.queue, delivery: sink.receive), "same-timestamp positive reopened a stale close")
        clock.set(1_001.24); gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_001.3)
        for sample in [try Fixture.sample(42, at: 1_002), try Fixture.sample(43, at: 1_000),
                       try Fixture.sample(44, at: 1_001.25, pts: .invalid),
                       try Fixture.sample(45, at: 1_001.25, includeData: false),
                       try Fixture.sample(46, at: 1_001.25, channels: 9)] {
            try checks.require(!gate.submit(sample, deliveryQueue: sink.queue, delivery: sink.receive), "malformed/future/old-domain PCM admitted")
        }
        try checks.require(gate.submit(try Fixture.sample(47, at: 1_001.25), deliveryQueue: sink.queue, delivery: sink.receive), "valid ordered PCM missing")
        try checks.require(!gate.submit(try Fixture.sample(48, at: 1_001.24), deliveryQueue: sink.queue, delivery: sink.receive), "out-of-order PCM admitted")
        clock.set(1_001.4); gate.setAdmitted(true, observedAtHostTime: HostClock.ticks(1_001.6))
        try checks.require(gate.statistics.pendingBuffers == 0, "future observation retained pending PCM")
        await gate.stop()
    }

    static func boundedQueuedDelivery(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        var config = MeetingMicrophonePrivacyGate.Configuration(); config.maximumQueuedBytes = 640
        let gate = MeetingMicrophonePrivacyGate(configuration: config, hostTime: { clock.now() }, automaticWatchdog: false)
        let unblock = DispatchSemaphore(value: 0), entered = Signal()
        sink.queue.async { entered.signal(); unblock.wait() }
        await entered.wait()
        gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_000.1)
        try checks.require(gate.submit(try Fixture.sample(51, at: 1_000.05), deliveryQueue: sink.queue, delivery: sink.receive), "bound setup missing")
        self.refresh(gate, clock, at: [1_000.4, 1_000.8, 1_001.1])
        try checks.require(gate.statistics.retainedBytes == 320 && gate.statistics.pendingBuffers == 0, "queued delivery stopped counting against byte cap")
        clock.set(1_001.2)
        try checks.require(gate.submit(try Fixture.sample(52, at: 1_001.15), deliveryQueue: sink.queue, delivery: sink.receive), "second bounded sample rejected")
        clock.set(1_001.3)
        try checks.require(!gate.submit(try Fixture.sample(53, at: 1_001.25), deliveryQueue: sink.queue, delivery: sink.receive), "byte budget overflow admitted")
        try checks.require(gate.statistics.retainedBytes == 320, "overflow did not drop pending while retaining in-flight accounting")
        unblock.signal(); sink.joined()
        try checks.require(sink.snapshot.0 == [51] && gate.statistics.retainedBytes == 0, "confirmed queued prefix was lost, uncertain PCM leaked, or quota leaked")
        await gate.stop()
        var countConfig = MeetingMicrophonePrivacyGate.Configuration(); countConfig.maximumQueuedBuffers = 1
        let countGate = MeetingMicrophonePrivacyGate(configuration: countConfig, hostTime: { clock.now() }, automaticWatchdog: false)
        countGate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_001.4)
        try checks.require(countGate.submit(try Fixture.sample(54, at: 1_001.35), deliveryQueue: sink.queue, delivery: sink.receive), "count setup missing")
        clock.set(1_001.5)
        try checks.require(!countGate.submit(try Fixture.sample(55, at: 1_001.45), deliveryQueue: sink.queue, delivery: sink.receive), "buffer count budget overflow admitted")
        try checks.require(countGate.statistics.retainedBytes == 0, "count overflow retained pending bytes")
        await countGate.stop()
    }

    static func delayedWatchdogCannotFillGap(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_000.1)
        let old = try Fixture.sample(71, at: 1_000.05)
        try checks.require(gate.submit(old, deliveryQueue: sink.queue, delivery: sink.receive), "gap setup missing")
        // No timer sweep or new audio input occurs before a delayed fresh observation arrives.
        clock.set(1_001.2); gate.setAdmitted(true, observedAtHostTime: clock.now()); sink.joined()
        try checks.require(sink.snapshot.0.isEmpty && gate.statistics.retainedBytes == 0, "fresh positive filled an unobserved gap and leaked old PCM")
        try checks.require(!gate.permitsReleasedSample(old), "writer defense rescued a pre-gap sample")
        clock.set(1_001.24)
        try checks.require(!gate.submit(try Fixture.sample(72, at: 1_001.1), deliveryQueue: sink.queue, delivery: sink.receive), "sample acquired in gap admitted")
        try checks.require(gate.submit(try Fixture.sample(73, at: 1_001.21), deliveryQueue: sink.queue, delivery: sink.receive), "post-gap fresh sample missing")
        self.refresh(gate, clock, at: [1_001.6, 1_002.0, 1_002.4]); sink.joined()
        try checks.require(sink.snapshot.0 == [73], "post-gap epoch did not isolate delivered PCM")
        await gate.stop()
    }

    static func confirmedPrefixAndStop(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_000.22)
        let shortSpeech = try Fixture.sample(81, at: 1_000.1, frames: 800)
        try checks.require(gate.submit(shortSpeech, deliveryQueue: sink.queue, delivery: sink.receive), "short utterance setup missing")
        self.refresh(gate, clock, at: [1_000.4]); clock.set(1_000.48)
        let uncertain = try Fixture.sample(82, at: 1_000.42)
        try checks.require(gate.submit(uncertain, deliveryQueue: sink.queue, delivery: sink.receive), "uncertain tail setup missing")
        clock.set(1_000.5); gate.setAdmitted(false, observedAtHostTime: clock.now(), unsafeStartHostTime: HostClock.ticks(1_000.25))
        sink.joined()
        try checks.require(sink.snapshot.0.isEmpty && gate.statistics.pendingBuffers == 1, "closed prefix bypassed quarantine or uncertain tail remained")
        try checks.require(!gate.permitsReleasedSample(shortSpeech), "closed prefix bypassed writer quarantine")
        try checks.require(!gate.permitsReleasedSample(uncertain), "writer granted post-confirmation uncertain tail")
        clock.set(1_000.6); gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_000.72)
        let next = try Fixture.sample(83, at: 1_000.62, frames: 400)
        try checks.require(gate.submit(next, deliveryQueue: sink.queue, delivery: sink.receive), "stop prefix setup missing")
        self.refresh(gate, clock, at: [1_001.0, 1_001.25]); sink.joined()
        try checks.require(sink.snapshot.0 == [81] && gate.permitsReleasedSample(shortSpeech), "mature confirmed subsecond prefix was lost")
        clock.set(1_001.34)
        let tail = try Fixture.sample(84, at: 1_001.3)
        try checks.require(gate.submit(tail, deliveryQueue: sink.queue, delivery: sink.receive), "stop tail setup missing")
        gate.finishInput()
        clock.set(1_001.8); gate.checkFreshnessAndDrain()
        await gate.stop(); sink.joined()
        try checks.require(sink.snapshot.0 == [81, 83], "ordinary stop did not join only confirmed prefix")
        try checks.require(gate.permitsReleasedSample(next) && !gate.permitsReleasedSample(tail), "writer stop handoff ignored immutable approved intervals")
        try checks.require(!gate.submit(next, deliveryQueue: sink.queue, delivery: sink.receive), "ordinary stop reopened intake")
        try checks.require(gate.statistics.retainedBytes == 0, "stop prefix retained PCM after join")
        gate.close()
        try checks.require(!gate.permitsReleasedSample(next), "abort after ordinary stop did not revoke approvals")
    }

    static func lateUnsafeBoundary(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_000.3)
        let latePrivate = try Fixture.sample(91, at: 1_000.25)
        try checks.require(gate.submit(latePrivate, deliveryQueue: sink.queue, delivery: sink.receive), "late boundary setup missing")
        self.refresh(gate, clock, at: [1_000.4])
        clock.set(1_000.5); gate.setAdmitted(false, observedAtHostTime: clock.now())
        clock.set(1_000.55); gate.setAdmitted(true, observedAtHostTime: clock.now())
        clock.set(1_000.6); gate.setAdmitted(false, observedAtHostTime: clock.now(), unsafeStartHostTime: HostClock.ticks(1_000.2))
        try checks.require(gate.statistics.retainedBytes == 0, "late earlier boundary did not revoke a prior closed interval")
        clock.set(1_002); gate.checkFreshnessAndDrain(); sink.joined()
        try checks.require(sink.snapshot.0.isEmpty && !gate.permitsReleasedSample(latePrivate), "late boundary after reopen rescued unsafe PCM")
        await gate.stop()
    }

    static func unsafeBoundaryIncludesAcquisitionSafety(_ checks: Checks) async throws {
        for alreadyClosed in [false, true] {
            let clock = HostClock(), sink = Sink()
            let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
            gate.setAdmitted(true, observedAtHostTime: clock.now())
            clock.set(1_000.25)
            let confirmed = try Fixture.sample(101, at: 1_000.08)
            let nearRelease = try Fixture.sample(102, at: 1_000.18)
            try checks.require(gate.submit(confirmed, deliveryQueue: sink.queue, delivery: sink.receive), "safe boundary setup missing")
            try checks.require(gate.submit(nearRelease, deliveryQueue: sink.queue, delivery: sink.receive), "near boundary setup missing")
            self.refresh(gate, clock, at: [1_000.4])
            if alreadyClosed {
                clock.set(1_000.45); gate.setAdmitted(false, observedAtHostTime: clock.now())
                clock.set(1_000.46); gate.setAdmitted(true, observedAtHostTime: clock.now())
            }
            clock.set(1_000.5)
            gate.setAdmitted(false, observedAtHostTime: clock.now(), unsafeStartHostTime: HostClock.ticks(1_000.2))
            clock.set(1_002); gate.checkFreshnessAndDrain(); sink.joined()
            try checks.require(sink.snapshot.0 == [101], "near-release PCM bypassed acquisition clock safety margin")
            try checks.require(!gate.permitsReleasedSample(nearRelease), "writer rescued a block inside release safety margin")
            await gate.stop()
        }
    }

    static func contiguousFractionalRate(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        for index in 0..<32 {
            let start = 1_000.01 + Double(index * 256) / 44_100
            clock.set(start + 0.007)
            let sample = try Fixture.sample(Float(100 + index), at: start, frames: 256, rate: 44_100)
            try checks.require(gate.submit(sample, deliveryQueue: sink.queue, delivery: sink.receive), "contiguous 44.1 kHz buffer rejected by independent host rounding")
        }
        self.refresh(gate, clock, at: [1_000.4, 1_000.8, 1_001.3]); sink.joined()
        try checks.require(sink.snapshot.0 == (0..<32).map { Float(100 + $0) }, "44.1 kHz PCM order/count changed")
        await gate.stop()
    }

    static func boundedApprovalHistory(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        var first: CMSampleBuffer?, last: CMSampleBuffer?
        for index in 0..<70 {
            let start = 1_000 + Double(index) * 0.25
            clock.set(start); gate.setAdmitted(true, observedAtHostTime: clock.now())
            let sample = try Fixture.sample(Float(200 + index), at: start + 0.02)
            if first == nil { first = sample }; last = sample
            clock.set(start + 0.04)
            try checks.require(gate.submit(sample, deliveryQueue: sink.queue, delivery: sink.receive), "approval history setup missing")
            self.refresh(gate, clock, at: [start + 0.15])
            clock.set(start + 0.16); gate.setAdmitted(false, observedAtHostTime: clock.now()); sink.joined()
        }
        clock.set(1_019); gate.checkFreshnessAndDrain(); sink.joined()
        try checks.require(sink.snapshot.0.count == 70, "closed confirmed intervals dropped timely prefix deliveries")
        try checks.require(!gate.permitsReleasedSample(first!) && gate.permitsReleasedSample(last!), "retired history widened into an unsafe prefix or latest grant lost")
        gate.close()
        try checks.require(!gate.permitsReleasedSample(last!), "abort did not revoke closed prefix approvals")
        await gate.stop()
    }

    static func planarPCM(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_000.1)
        let sample = try Fixture.sample(301, at: 1_000.05, channels: 2, planar: true, lastMarker: 302)
        try checks.require(gate.submit(sample, deliveryQueue: sink.queue, delivery: sink.receive), "planar stereo PCM rejected")
        Fixture.overwrite(sample, marker: 399)
        self.refresh(gate, clock, at: [1_000.4, 1_000.8, 1_001.2]); sink.joined()
        try checks.require(sink.snapshot.0 == [301] && sink.tailValues == [302], "planar PCM planes were truncated or retained source allocation")
        await gate.stop()
    }

    static func joinedStop(_ checks: Checks) async throws {
        let clock = HostClock(), sink = Sink()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { clock.now() }, automaticWatchdog: false)
        let unblock = DispatchSemaphore(value: 0), entered = Signal()
        sink.queue.async { entered.signal(); unblock.wait() }; await entered.wait()
        gate.setAdmitted(true, observedAtHostTime: clock.now()); clock.set(1_000.1)
        let sample = try Fixture.sample(61, at: 1_000.05)
        try checks.require(gate.submit(sample, deliveryQueue: sink.queue, delivery: sink.receive), "stop setup missing")
        self.refresh(gate, clock, at: [1_000.4, 1_000.8, 1_001.1])
        gate.close()
        let stopBegan = Signal(), stopDone = Signal()
        let task = Task { stopBegan.signal(); await gate.stop(); stopDone.signal() }
        await stopBegan.wait()
        let finishedEarly: Bool = await withCheckedContinuation { continuation in
            DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(20)) {
                continuation.resume(returning: stopDone.value)
            }
        }
        try checks.require(!finishedEarly, "stop failed to join outstanding source-queue work")
        unblock.signal(); await task.value; sink.joined()
        try checks.require(sink.snapshot.0.isEmpty, "late delivery ran after close")
        try checks.require(gate.statistics.retainedBytes == 0 && gate.statistics.retainedBuffers == 0, "joined stop retained PCM")
        try checks.require(!gate.permitsReleasedSample(sample), "stopped writer defense reopened")
        gate.setAdmitted(true, observedAtHostTime: clock.now())
        try checks.require(!gate.submit(sample, deliveryQueue: sink.queue, delivery: sink.receive), "stopped intake reopened")
    }
}
