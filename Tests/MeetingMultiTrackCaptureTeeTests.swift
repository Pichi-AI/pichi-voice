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
            if let end { timelineValid = timelineValid && abs(CMTimeGetSeconds(copy.pts - end)) < 0.00001 }
            for index in 0..<Int(copy.buffer.frameLength) where abs(data[index]) > 0.01 { nonzeroFrames.append(count + index) }
            count += Int(copy.buffer.frameLength)
            end = copy.pts + CMTime(value: Int64(copy.buffer.frameLength), timescale: 16_000)
            return !reject
        }
    }
    func finish() async throws { lock.withLock { finishCount += 1 }; await barrier?.join() }
    var snapshot: (Int, [Int], Bool, Int) { lock.withLock { (count, nonzeroFrames, timelineValid, finishCount) } }
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
        try require(mic.2 && app.2, "Independent sources share a contiguous mono16k timeline")
        try require(mic.0 == 10_400 && app.0 == 9_600, "Prefix and source-admission gap preserve common source time and final tail")
        try require(mic.1.first == 4_000 && app.1.first == 8_000, "Initial speech is aligned across sources without losing opening frames")
        try require(mic.1.last == 10_399 && mic.3 == 1 && app.3 == 1, "Stop joins both consumers concurrently and exactly once")
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
        do { try await bad.finish(); try require(false, "An unbounded source gap must fail") }
        catch MeetingCapturePCMError.timelineDiscontinuity { }
        try require(badSink.snapshot.0 == 0 && badSink.snapshot.3 == 1, "Long-gap failure still joins cleanup without allocating its silence")
        let rejectedSink = MultiTrackSink(reject: true)
        let rejected = try MeetingMultiTrackCaptureTee(consumers: [.microphone: rejectedSink], originHostTime: origin,
            eventHandler: { _ in }, liveAudioHandler: nil)
        rejected.offer(kind: .microphone, sample: try input(start: 0, frames: 160))
        do { try await rejected.finish(); try require(false, "A rejected accepted source cannot complete") }
        catch MeetingCapturePCMError.transcriptionStopped { }
        try require(rejectedSink.snapshot.3 == 1, "Rejected input still joins the shared consumer")
        print("Desktop multi-track PCM: common clock, source gaps, opening/final speech, concurrent Stop, bounded rejection and joined cleanup passed.")
    }
}
