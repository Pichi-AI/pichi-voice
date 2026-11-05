@preconcurrency import AVFoundation
import CoreMedia
import Foundation

private actor MultiTrackFinishBarrier {
    var entered = 0
    var waiting: [CheckedContinuation<Void, Never>] = []
    func join() async {
        entered += 1
        if entered == 2 { waiting.forEach { $0.resume() }; waiting = []; return }
        await withCheckedContinuation { waiting.append($0) }
    }
}

private final nonisolated class MultiTrackSink: MeetingMemoryAudioConsuming, @unchecked Sendable {
    let lock = NSLock()
    let barrier: MultiTrackFinishBarrier?
    let reject: Bool
    var count = 0
    var nonzeroFrames: [Int] = []
    var timelineValid = true
    var end: CMTime?
    var finishCount = 0
    init(barrier: MultiTrackFinishBarrier? = nil, reject: Bool = false) { self.barrier = barrier; self.reject = reject }
    func enqueue(_ sample: CMSampleBuffer) -> Bool {
        guard let copy = MeetingLiveSampleCopy.copy(sample), let data = copy.buffer.floatChannelData?[0] else { return false }
        return lock.withLock {
            timelineValid = timelineValid && copy.buffer.format.channelCount == 1 && copy.buffer.format.sampleRate == 16_000
            if let end { timelineValid = timelineValid && CMTimeGetSeconds(copy.pts - end) >= -0.00001 }
            for index in 0..<Int(copy.buffer.frameLength) where abs(data[index]) > 0.01 { nonzeroFrames.append(count + index) }
            count += Int(copy.buffer.frameLength)
            end = copy.pts + CMTime(value: Int64(copy.buffer.frameLength), timescale: 16_000)
            return !reject
        }
    }
    func finish() async throws { lock.withLock { finishCount += 1 }; await barrier?.join() }
    var snapshot: (Int, [Int], Bool, Int) { lock.withLock { (count, nonzeroFrames, timelineValid, finishCount) } }
    var measuredEnd: Double? { lock.withLock { end.map(CMTimeGetSeconds) } }
}

private final nonisolated class MultiTrackAdmissionProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var microphoneChecks = 0
    private var microphoneLiveFrames = 0
    private var applicationLiveFrames = 0
    func admits(_ kind: MeetingAudioTrackKind) -> Bool {
        lock.withLock {
            guard kind == .microphone else { return true }
            microphoneChecks += 1
            return microphoneChecks == 1
        }
    }
    func live(_ kind: MeetingAudioTrackKind, sample: CMSampleBuffer) {
        lock.withLock {
            if kind == .microphone { microphoneLiveFrames += CMSampleBufferGetNumSamples(sample) }
            else { applicationLiveFrames += CMSampleBufferGetNumSamples(sample) }
        }
    }
    var snapshot: (Int, Int, Int) { lock.withLock { (microphoneChecks, microphoneLiveFrames, applicationLiveFrames) } }
}

extension MeetingCapturePCMTransportTests {
    static func testMultiTrackCaptureTee() async throws {
        let barrier = MultiTrackFinishBarrier()
        let microphone = MultiTrackSink(barrier: barrier), application = MultiTrackSink(barrier: barrier)
        let originSeconds = 100.0
        let origin = AVAudioTime.hostTime(forSeconds: originSeconds)
        let tee = try MeetingMultiTrackCaptureTee(consumers: [.microphone: microphone, .applicationAudio: application],
            originHostTime: origin, eventHandler: { _ in }, liveAudioHandler: nil)
        func input(start: Double, frames: Int) throws -> CMSampleBuffer {
            try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm(frames: frames),
                presentationTime: CMTime(seconds: originSeconds + start, preferredTimescale: 1_000_000_000))
        }
        tee.offer(kind: .microphone, sample: try input(start: 0.25, frames: 1_600))
        tee.offer(kind: .applicationAudio, sample: try input(start: 0.5, frames: 1_600))
        tee.offer(kind: .microphone, sample: try input(start: 0.6, frames: 800))
        async let first: Void = tee.finish()
        async let second: Void = tee.finish()
        try await first; try await second
        let mic = microphone.snapshot, app = application.snapshot
        try require(mic.2 && app.2, "Independent sources preserve monotonic measured mono16k timelines")
        try require(mic.0 == 2_400 && app.0 == 1_600, "Only real source PCM is retained across initial delay and admission gaps")
        try require(mic.1.first == 0 && app.1.first == 0, "No synthetic prefix precedes actual opening speech")
        try require(mic.1.last == 2_399 && mic.3 == 1 && app.3 == 1, "Stop joins both consumers concurrently and exactly once")
        try require(abs((microphone.measuredEnd ?? 0) - 100.65) < 0.00001
            && abs((application.measuredEnd ?? 0) - 100.6) < 0.00001,
            "Different source delays and gaps retain measured common-clock presentation timestamps")
        let nativeSink = MultiTrackSink()
        let native = try MeetingMultiTrackCaptureTee(consumers: [.applicationAudio: nativeSink], originHostTime: origin,
            eventHandler: { _ in }, liveAudioHandler: nil)
        for index in 0..<10 {
            let buffer = pcm(frames: 4_800, sampleRate: 48_000, channels: 2)
            var format: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription,
                layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
            var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                presentationTimeStamp: CMTime(seconds: originSeconds + Double(index) / 10, preferredTimescale: 48_000), decodeTimeStamp: .invalid)
            var sample: CMSampleBuffer?
            CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false, makeDataReadyCallback: nil,
                refcon: nil, formatDescription: format, sampleCount: 4_800, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
            let owned = sample!
            CMSampleBufferSetDataBufferFromAudioBufferList(owned, blockBufferAllocator: kCFAllocatorDefault,
                blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList)
            CMSampleBufferSetDataReady(owned)
            native.offer(kind: .applicationAudio, sample: owned)
        }
        try await native.finish()
        try require(abs(nativeSink.snapshot.0 - 16_000) <= 1 && nativeSink.snapshot.2,
            "Native-rate stereo application source downmixes, resamples and joins its complete converter tail")
        let badSink = MultiTrackSink()
        let bad = try MeetingMultiTrackCaptureTee(consumers: [.microphone: badSink], originHostTime: origin,
            eventHandler: { _ in }, liveAudioHandler: nil)
        bad.offer(kind: .microphone, sample: try input(start: 61, frames: 10))
        bad.offer(kind: .microphone, sample: try input(start: 123, frames: 10))
        try await bad.finish()
        try require(badSink.snapshot.0 == 20 && badSink.snapshot.3 == 1,
            "A first source at 61s and another minute of source absence retain every actual frame without padding")
        let rejectedSink = MultiTrackSink(reject: true)
        let rejected = try MeetingMultiTrackCaptureTee(consumers: [.microphone: rejectedSink], originHostTime: origin,
            eventHandler: { _ in }, liveAudioHandler: nil)
        rejected.offer(kind: .microphone, sample: try input(start: 0, frames: 160))
        do { try await rejected.finish(); try require(false, "A rejected accepted source cannot complete") }
        catch MeetingCapturePCMError.transcriptionStopped { }
        try require(rejectedSink.snapshot.3 == 1, "Rejected input still joins the shared consumer")
        let revokedMicrophone = MultiTrackSink(), continuingApplication = MultiTrackSink()
        let admission = MultiTrackAdmissionProbe()
        let privacy = try MeetingMultiTrackCaptureTee(
            consumers: [.microphone: revokedMicrophone, .applicationAudio: continuingApplication], originHostTime: origin,
            eventHandler: { _ in }, liveAudioHandler: { kind, sample in admission.live(kind, sample: sample) },
            sampleAdmission: { kind, _ in admission.admits(kind) })
        privacy.offer(kind: .microphone, sample: try input(start: 0.25, frames: 1_600))
        privacy.offer(kind: .applicationAudio, sample: try input(start: 0.5, frames: 1_600))
        try await privacy.finish()
        try require(admission.snapshot.0 >= 2 && revokedMicrophone.snapshot.0 == 0 && admission.snapshot.1 == 0,
            "A revoked microphone grant is rechecked after conversion before ASR and source VAD")
        try require(continuingApplication.snapshot.0 == 1_600 && admission.snapshot.2 == 1_600,
            "Revoked microphone input never blocks the application source")
        try require(revokedMicrophone.snapshot.3 == 1 && continuingApplication.snapshot.3 == 1,
            "Privacy exclusion still joins both consumers")
        print("Desktop multi-track PCM: common clock, source gaps, opening/final speech, concurrent Stop, bounded rejection and joined cleanup passed.")
    }
}

private final nonisolated class SourceTimelineProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var windows: [(Double, Int)] = []
    private var queries: [(Double, Double)] = []
    func window(_ start: Double, frames: Int) { lock.withLock { windows.append((start, frames)) } }
    func query(_ start: Double, _ end: Double) { lock.withLock { queries.append((start, end)) } }
    var snapshot: ([(Double, Int)], [(Double, Double)]) { lock.withLock { (windows, queries) } }
}

extension MeetingCapturePCMTransportTests {
    static func testSourceTimeline() async throws {
        let timeline = try MeetingPCMSourceTimeline(originSeconds: 100)
        let firstGap = try timeline.record(sourceStartSample: 0, frameCount: 8_000, presentationTime: 161)
        try require(!firstGap && !timeline.hasGaps, "First capture starts on a measured offset without claiming earlier source loss")
        try require(try timeline.record(sourceStartSample: 8_000, frameCount: 8_000, presentationTime: 223), "A minute without source PCM is a new physical span")
        try require(timeline.retainedSpanCount == 2 && timeline.hasGaps, "Missing source packets retain scalar spans only")
        try require(timeline.mapTime(0) == 61 && timeline.mapEndTime(0.5) == 61.5
            && timeline.mapTime(0.5) == 123 && timeline.mapEndTime(1) == 123.5,
            "Shared compact boundaries have distinct physical start/end sides")
        try require(timeline.mapInterval(start: 0.25, end: 0.5)?.end == 61.5
            && timeline.mapInterval(start: 0.5, end: 0.75)?.start == 123
            && timeline.mapInterval(start: 0.25, end: 0.75) == nil,
            "A native word or VAD interval cannot cross unmeasured source time")
        do { try timeline.record(sourceStartSample: 15_999, frameCount: 1, presentationTime: 224); try require(false, "Compact input remains contiguous") }
        catch MeetingPCMSourceTimeline.Failure.nonContiguousInput { }
        let limited = try MeetingPCMSourceTimeline(originSeconds: 0, maximumSpans: 2)
        try limited.record(sourceStartSample: 0, frameCount: 160, presentationTime: 0)
        try limited.record(sourceStartSample: 160, frameCount: 160, presentationTime: 2)
        do { try limited.record(sourceStartSample: 320, frameCount: 160, presentationTime: 4); try require(false, "Pending scalar metadata has a hard budget") }
        catch MeetingPCMSourceTimeline.Failure.spanBudgetExceeded { }
        limited.discard(beforeSample: 321)
        try limited.record(sourceStartSample: 320, frameCount: 160, presentationTime: 4)
        try require(limited.retainedSpanCount == 2 && limited.mapTime(0) == nil, "Acknowledged mappings retire without deleting needed tail context")
        let continuous = try MeetingPCMSourceTimeline(originSeconds: 100)
        for second in 0..<(8 * 3_600) {
            try continuous.record(sourceStartSample: second * 16_000, frameCount: 16_000, presentationTime: Double(100 + second))
        }
        try require(continuous.retainedSpanCount == 1 && !continuous.hasGaps, "Eight hours of continuous source time coalesce to one scalar span")

        let transportTimeline = try MeetingPCMSourceTimeline(originSeconds: 100)
        let probe = SourceTimelineProbe()
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            chunkSeconds: 20, initialPreviewSeconds: 0.25, previewIntervalSeconds: 0.25,
            confidentlyNonSpeech: { start, end in probe.query(start, end); return true },
            sourceTimeline: transportTimeline,
            recognize: { window, offset in
                var frames = 0
                while let update = try await window.next() { frames += update.samples.count }
                probe.window(offset, frames: frames)
                _ = await window.confidentlyNonSpeech(start: offset, end: offset + Double(frames) / 16_000)
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in }, failure: { _ in })
        let first = try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm(frames: 8_000), presentationTime: CMTime(seconds: 161, preferredTimescale: 16_000))
        let last = try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm(frames: 8_000), presentationTime: CMTime(seconds: 223, preferredTimescale: 16_000))
        try require(consumer.enqueue(first) && consumer.enqueue(last), "Actual packets separated by a minute are both accepted")
        try await consumer.finish()
        let result = probe.snapshot
        try require(result.0.count == 2 && result.0[0].0 == 0 && result.0[0].1 == 8_000
            && result.0[1].0 == 0.5 && result.0[1].1 == 8_000,
            "Source gaps seal ASR windows without adding PCM or changing compact native offsets")
        try require(result.1.count == 2 && result.1[0].0 == 61 && result.1[0].1 == 61.5
            && result.1[1].0 == 123 && result.1[1].1 == 123.5,
            "Source VAD is queried only on measured physical intervals")
        print("Source timeline: 61s first speech, minute source gaps, compact ASR boundary, native-word/VAD mapping, bounded retirement and eight-hour coalescing passed.")
    }
}
