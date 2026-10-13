@preconcurrency import AVFoundation
import CoreMedia
import Foundation

private final class Probe: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [(Double, Int)] = []
    private var checkpoints = 0
    private var failures = 0
    private var concurrent = 0
    private var peak = 0
    func begin(_ samples: [Float], at start: Double) {
        self.lock.withLock { self.values.append((start, samples.count)); self.concurrent += 1; self.peak = max(self.peak, self.concurrent) }
    }
    func checkpoint() { self.lock.withLock { self.checkpoints += 1; self.concurrent -= 1 } }
    func failed() { self.lock.withLock { self.failures += 1 } }
    var snapshot: ([(Double, Int)], Int, Int, Int) { self.lock.withLock { (self.values, self.checkpoints, self.failures, self.peak) } }
}

private actor Latch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        self.entered = true
        await withCheckedContinuation { continuation in
            if self.released { continuation.resume() } else { self.continuation = continuation }
        }
    }
    func release() { self.released = true; self.continuation?.resume(); self.continuation = nil }
}

@main
struct MeetingCapturePCMTransportTests {
    static func require(_ condition: Bool, _ detail: String) throws {
        if !condition { throw NSError(domain: "PCMTests", code: 1, userInfo: [NSLocalizedDescriptionKey: detail]) }
    }

    static func pcm(frames: Int, sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1, interleaved: Bool = false) -> AVAudioPCMBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: channels, interleaved: interleaved)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
        buffer.frameLength = AVAudioFrameCount(frames)
        let input = buffer.floatChannelData!
        for frame in 0..<frames {
            for channel in 0..<Int(channels) {
                if interleaved { input[0][frame * Int(channels) + channel] = channel == 0 ? 0.8 : -0.4 }
                else { input[channel][frame] = channel == 0 ? 0.8 : -0.4 }
            }
        }
        return buffer
    }

    static func sample(frames: Int, startFrame: Int64 = 0) throws -> CMSampleBuffer {
        try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm(frames: frames),
                                                   presentationTime: CMTime(value: 1_600_000 + startFrame, timescale: 16_000))
    }

    static func main() async throws {
        let gate = MeetingPCMIntakeGate(maximumBytes: 16_000 * 4, maximumSeconds: 1)
        let reservation = gate.reserve(frames: 12_000, channels: 1, sampleRate: 16_000)!
        try require(gate.retainedBytes == 48_000, "gate must include accepted PCM")
        try require(gate.reserve(frames: 4_001, channels: 1, sampleRate: 16_000) == nil, "duration overflow must close capture")
        gate.release(reservation)
        try require(gate.retainedBytes == 0, "all reservations release")
        try require(gate.reserve(frames: 1, channels: 1, sampleRate: 16_000) == nil, "overload must not silently recover/drop")
        let invalid = MeetingPCMIntakeGate()
        try require(invalid.reserve(frames: Int.max, channels: 1, sampleRate: .nan) == nil, "malformed admission must be bounded")

        for interleaved in [false, true] {
            let original = pcm(frames: 1024, sampleRate: 48_000, channels: 2, interleaved: interleaved)
            let mono = try MeetingCapturePCMConverter.ownedMonoCopy(of: original)
            try require(mono.format.channelCount == 1 && abs(mono.floatChannelData![0][10] - 0.2) < 0.001, "stereo downmix")
            original.floatChannelData![0][10] = 0
            try require(abs(mono.floatChannelData![0][10] - 0.2) < 0.001, "tap PCM must be owned before tap reuse")
        }
        let nan = pcm(frames: 100)
        nan.floatChannelData![0][0] = .nan
        do { _ = try MeetingCapturePCMConverter.ownedMonoCopy(of: nan); throw NSError(domain: "ExpectedFiniteError", code: 1) }
        catch MeetingCapturePCMError.nonFiniteSample { }

        let converter = try MeetingCapturePCMConverter()
        var outputs: [CMSampleBuffer] = []
        var position = 0
        while position < 48_000 {
            let frames = min(1024, 48_000 - position)
            let owned = try MeetingCapturePCMConverter.ownedMonoCopy(of: pcm(frames: frames, sampleRate: 48_000, channels: 2))
            if let output = try converter.convert(owned, presentationTime: CMTime(value: 4_800_000 + Int64(position), timescale: 48_000)) { outputs.append(output) }
            position += frames
        }
        if let tail = try converter.finish() { outputs.append(tail) }
        let totalFrames = outputs.reduce(0) { $0 + CMSampleBufferGetNumSamples($1) }
        try require(abs(totalFrames - 16_000) <= 1, "one second 48k audio must produce one second 16k PCM, including resampling tail")
        var nextPTS = CMTime(seconds: 100, preferredTimescale: 16_000)
        for output in outputs {
            let contract = try MeetingPCMFormatContract(formatDescription: CMSampleBufferGetFormatDescription(output)!)
            try require(contract.sampleRate == 16_000 && contract.channelCount == 1, "shared PCM contract")
            try require(CMSampleBufferDataIsReady(output), "sample ready")
            try require(abs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(output) - nextPTS)) < 1.0 / 16_000, "contiguous capture PTS")
            nextPTS = nextPTS + CMTime(value: Int64(CMSampleBufferGetNumSamples(output)), timescale: 16_000)
            let copy = MeetingLiveSampleCopy.copy(output)!
            let mid = Int(copy.buffer.frameLength) / 2
            try require(abs(copy.buffer.floatChannelData![0][mid] - 0.2) < 0.01, "converter preserves downmixed signal at \(mid): \(copy.buffer.floatChannelData![0][mid]), frames \(copy.buffer.frameLength)")
        }
        let discontinuous = try MeetingCapturePCMConverter()
        _ = try discontinuous.convert(pcm(frames: 100), presentationTime: CMTime(seconds: 1, preferredTimescale: 16_000))
        do {
            _ = try discontinuous.convert(pcm(frames: 100), presentationTime: CMTime(seconds: 5, preferredTimescale: 16_000))
            throw NSError(domain: "ExpectedTimelineError", code: 1)
        } catch MeetingCapturePCMError.timelineDiscontinuity { }

        let probe = Probe()
        let consumer = try MeetingProcessingPipeline.makeMemoryAudioConsumer(chunkSeconds: 0.25, maximumPendingSeconds: 1,
            recognize: { samples, start in probe.begin(samples, at: start); return MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in probe.checkpoint() }, failure: { _ in probe.failed() })
        try require(consumer.enqueue(try sample(frames: 4_000)), "accept first block")
        try require(consumer.enqueue(try sample(frames: 4_000, startFrame: 4_000)), "accept second block")
        try require(consumer.enqueue(try sample(frames: 1_000, startFrame: 8_000)), "accept finite tail")
        async let firstFinish: Void = consumer.finish()
        async let secondFinish: Void = consumer.finish()
        try await firstFinish
        try await secondFinish
        let normal = probe.snapshot
        try require(normal.0.map(\.1) == [4000, 4000, 1000], "finish joins every accepted frame exactly once")
        try require(normal.0.map(\.0) == [0, 0.25, 0.5], "chunk start timestamps")
        try require(normal.1 == 3 && normal.2 == 0 && normal.3 == 1, "serial recognition and checkpoint ownership")
        try require(!consumer.enqueue(try sample(frames: 1, startFrame: 9_000)), "finish closes intake")

        let latch = Latch()
        let overloadedProbe = Probe()
        let overloaded = try MeetingProcessingPipeline.makeMemoryAudioConsumer(chunkSeconds: 0.25, maximumPendingSeconds: 0.5,
            recognize: { samples, start in overloadedProbe.begin(samples, at: start); await latch.wait(); return MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in overloadedProbe.checkpoint() }, failure: { _ in overloadedProbe.failed() })
        try require(overloaded.enqueue(try sample(frames: 4_000)), "first in-flight batch")
        for _ in 0..<1000 { if await latch.entered { break }; await Task.yield() }
        try require(await latch.entered, "worker started")
        try require(overloaded.enqueue(try sample(frames: 4_000, startFrame: 4_000)), "queued batch counted")
        try require(!overloaded.enqueue(try sample(frames: 1, startFrame: 8_000)), "in-flight PCM counts in overload budget")
        let finishing = Task { try await overloaded.finish() }
        for _ in 0..<50 { await Task.yield() }
        await latch.release()
        do { try await finishing.value; throw NSError(domain: "ExpectedOverload", code: 1) }
        catch MeetingMemoryAudioError.overload { }
        try require(overloadedProbe.snapshot.1 == 0 && overloadedProbe.snapshot.2 == 1, "cancelled inference cannot publish unsaved partial output, one failure")

        let failureProbe = Probe()
        let checkpointFailure = try MeetingProcessingPipeline.makeMemoryAudioConsumer(chunkSeconds: 0.25, maximumPendingSeconds: 1,
            recognize: { _, _ in MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in throw NSError(domain: "CheckpointFailure", code: 42) }, failure: { _ in failureProbe.failed() })
        _ = checkpointFailure.enqueue(try sample(frames: 4_000))
        do { try await checkpointFailure.finish(); throw NSError(domain: "ExpectedCheckpointError", code: 1) }
        catch let error as NSError where error.domain == "CheckpointFailure" { }
        try require(failureProbe.snapshot.2 == 1, "checkpoint failure closes strict intake")
        let cancelLatch = Latch()
        let cancelProbe = Probe()
        let joined = try MeetingProcessingPipeline.makeMemoryAudioConsumer(chunkSeconds: 0.25, maximumPendingSeconds: 1,
            recognize: { samples, start in cancelProbe.begin(samples, at: start); await cancelLatch.wait(); return MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in cancelProbe.checkpoint() }, failure: { _ in cancelProbe.failed() })
        _ = joined.enqueue(try sample(frames: 4_000))
        for _ in 0..<1000 { if await cancelLatch.entered { break }; await Task.yield() }
        try require(await cancelLatch.entered, "inference owns its PCM")
        let cancelledFinish = Task { try await joined.finish() }
        cancelledFinish.cancel()
        for _ in 0..<50 { await Task.yield() }
        try require(cancelProbe.snapshot.1 == 0, "cancelled caller cannot publish or abandon in-flight PCM")
        await cancelLatch.release()
        try await cancelledFinish.value
        try require(cancelProbe.snapshot.1 == 1 && cancelProbe.snapshot.2 == 0, "cancelled finish caller still joins owned recognition/checkpoint")

        let wrongFormatProbe = Probe()
        let wrongFormat = try MeetingProcessingPipeline.makeMemoryAudioConsumer(chunkSeconds: 0.25, maximumPendingSeconds: 1,
            recognize: { _, _ in MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in }, failure: { _ in wrongFormatProbe.failed() })
        let badPCM = try sample(frames: 100)
        var badDescription: CMAudioFormatDescription?
        let stereo = pcm(frames: 100, channels: 2)
        _ = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: stereo.format.streamDescription,
                                           layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
                                           extensions: nil, formatDescriptionOut: &badDescription)
        var malformed: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        _ = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: CMSampleBufferGetDataBuffer(badPCM),
                                 dataReady: true, makeDataReadyCallback: nil, refcon: nil, formatDescription: badDescription,
                                 sampleCount: 100, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                 sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &malformed)
        try require(malformed != nil, "wrong-format fixture constructed")
        try require(!wrongFormat.enqueue(malformed!), "strict consumer rejects stereo metadata without attempting ASR")
        do { try await wrongFormat.finish(); throw NSError(domain: "ExpectedInvalidPCM", code: 1) }
        catch MeetingMemoryAudioError.invalidPCM { }
        try require(wrongFormatProbe.snapshot.2 == 1, "malformed PCM emits one terminal event")
        print("Meeting PCM transport: admission, conversion, ownership, timeline, bounded inference, overload, joined finish and checkpoint failure passed.")
    }
}
