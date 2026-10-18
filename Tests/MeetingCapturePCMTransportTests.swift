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

private actor FinalizerProbe {
    private(set) var count = 0
    private(set) var checkpoints: [[String]] = []
    func started() { count += 1 }
    func saved(_ values: [String]) { checkpoints.append(values) }
}

private final class DiagnosticProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    func record(_ line: String) { lock.withLock { lines.append(line) } }
    var snapshot: [String] { lock.withLock { lines } }
}

/// Scalar-only observations: the stress harness must not retain the audio it checks.
private final class LongRunProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var frames = 0
    private var windows = 0
    private var saved = 0
    private var rejected = false
    private var contiguous = true
    func recognized(_ count: Int, start: Double) {
        lock.withLock {
            contiguous = contiguous && abs(start - Double(frames) / 16_000) < 0.0001
            frames += count
            windows += 1
        }
    }
    func checkpointed() { lock.withLock { saved += 1 } }
    func failed() { lock.withLock { rejected = true } }
    var snapshot: (frames: Int, windows: Int, saved: Int, rejected: Bool, contiguous: Bool) {
        lock.withLock { (frames, windows, saved, rejected, contiguous) }
    }
}

private final class ProgressiveProbe: @unchecked Sendable {
    struct Update: Sendable, Equatable {
        let start: Double
        let delta: Int
        let total: Int
        let final: Bool
    }
    private let lock = NSLock()
    private var updates: [Update] = []
    private var starts: [Double] = []
    private var checkpoints = 0
    private var failures = 0
    private var returned = 0
    private var finishReturned = false
    func begin(_ start: Double) { lock.withLock { starts.append(start) } }
    func record(_ update: MeetingPCMWindowUpdate, start: Double) {
        lock.withLock { updates.append(Update(start: start, delta: update.samples.count, total: update.totalFrames, final: update.isFinal)) }
    }
    func checkpoint() { lock.withLock { checkpoints += 1 } }
    func failed() { lock.withLock { failures += 1 } }
    func didReturn() { lock.withLock { returned += 1 } }
    func didFinish() { lock.withLock { finishReturned = true } }
    var snapshot: ([Update], [Double], Int, Int, Int, Bool) { lock.withLock { (updates, starts, checkpoints, failures, returned, finishReturned) } }
}

private struct StartupPrepared: MeetingPreparedStreamingPCMProcessing {
    let probe: LongRunProbe
    func recognize(window: MeetingPCMProgressiveWindow, offset: TimeInterval,
                   preview: (@Sendable (MeetingPCMTranscriptBatch) async throws -> Void)?) async throws -> MeetingStreamingPCMObservation {
        var frames = 0
        while let update = try await window.next() { frames += update.samples.count }
        self.probe.recognized(frames, start: offset)
        return .init(batch: .init(segments: [], speakers: []), activity: [],
                     acceptedThroughSample: frames, processedThroughSample: frames,
                     retainedFromSample: 0, isFinal: false)
    }
    func finishStreaming() async throws -> MeetingStreamingPCMObservation {
        .init(batch: .init(segments: [], speakers: []), activity: [],
              acceptedThroughSample: 0, processedThroughSample: 0, retainedFromSample: 0, isFinal: true)
    }
    func discardActivity(beforeSample: Int) async throws {}
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

    /// Native-rate source buffers exercise the desktop callback without opening a microphone.
    static func nativeSample(frames: Int, startFrame: Int64, sampleRate: Int32 = 48_000) throws -> CMSampleBuffer {
        let buffer = pcm(frames: frames, sampleRate: Double(sampleRate))
        var description: CMAudioFormatDescription?
        let format = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault,
            asbd: buffer.format.streamDescription, layoutSize: 0, layout: nil,
            magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        try require(format == noErr && description != nil, "native source format is valid")
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: sampleRate),
            presentationTimeStamp: CMTime(value: Int64(100 * sampleRate) + startFrame, timescale: sampleRate),
            decodeTimeStamp: .invalid)
        let created = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil,
            dataReady: false, makeDataReadyCallback: nil, refcon: nil, formatDescription: description!,
            sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        try require(created == noErr && sample != nil, "native source buffer is valid")
        let copied = CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList)
        try require(copied == noErr && CMSampleBufferSetDataReady(sample!) == noErr, "native source PCM is owned")
        return sample!
    }

    static func testDesktopWriterRejection() async throws {
        let writer = MeetingMacCaptureWriterProbe(rejectCall: 2)
        let consumer = MeetingMacCaptureConsumerProbe()
        let events = MeetingMacCaptureEventProbe()
        let tee = try MeetingMacCaptureTeeProbe(writer: writer, consumer: consumer,
            event: { events.record($0) }, live: { _, _ in events.presented() })
        tee.deliver(try nativeSample(frames: 2048, startFrame: 0))
        let accepted = consumer.received
        try require(!accepted.isEmpty && accepted.allSatisfy { $0 > 0 }, "the first native buffer reaches converted streaming PCM")
        // 512/48k is 10.7 ms, smaller than the converter's 20 ms discontinuity guard.
        tee.deliver(try nativeSample(frames: 512, startFrame: 2048))
        tee.deliver(try nativeSample(frames: 512, startFrame: 2560))
        tee.deliver(try nativeSample(frames: 512, startFrame: 3072))
        try require(tee.isTerminal, "writer rejection must close streaming admission and retain a Stop failure")
        try require(writer.calls == 2 && consumer.received == accepted,
            "PCM after the rejected buffer must never be compressed onto the previous streaming prefix")
        try require(events.snapshot.0 == [.writerBackpressure, .captureStoppedUnexpectedly] && events.snapshot.1 == 1,
            "writer rejection emits one terminal interruption and no later live progress")

        let legacyWriter = MeetingMacCaptureWriterProbe(rejectCall: 2)
        let legacyEvents = MeetingMacCaptureEventProbe()
        let legacy = try MeetingMacCaptureTeeProbe(writer: legacyWriter, consumer: nil,
            event: { legacyEvents.record($0) }, live: { _, _ in legacyEvents.presented() })
        for (frames, start) in [(2048, 0), (512, 2048), (512, 2560)] {
            legacy.deliver(try nativeSample(frames: frames, startFrame: Int64(start)))
        }
        try require(legacyWriter.calls == 3 && !legacy.isTerminal && legacyEvents.snapshot.0.isEmpty
            && legacyEvents.snapshot.1 == 2, "legacy writer-only rejection behavior remains unchanged")

        let rejected = MeetingMacCaptureConsumerProbe(accepts: false)
        let rejectingWriter = MeetingMacCaptureWriterProbe(rejectCall: 0)
        let rejectedEvents = MeetingMacCaptureEventProbe()
        let failed = try MeetingMacCaptureTeeProbe(writer: rejectingWriter, consumer: rejected,
            event: { rejectedEvents.record($0) }, live: { _, _ in rejectedEvents.presented() })
        failed.deliver(try nativeSample(frames: 2048, startFrame: 0))
        failed.deliver(try nativeSample(frames: 512, startFrame: 2048))
        try require(failed.isTerminal && rejectingWriter.calls == 1 && rejected.received.count == 1
            && rejectedEvents.snapshot.0 == [.writerBackpressure, .captureStoppedUnexpectedly],
            "writer and consumer rejection share identical once-only terminal semantics")
        let enteredWriter = DispatchSemaphore(value: 0)
        let resumeWriter = DispatchSemaphore(value: 0)
        let closingWriter = MeetingMacCaptureWriterProbe(rejectCall: 1, beforeEnqueue: {
            enteredWriter.signal()
            _ = resumeWriter.wait(timeout: .now() + 3)
        })
        let closingEvents = MeetingMacCaptureEventProbe()
        let closingConsumer = MeetingMacCaptureConsumerProbe()
        let closing = try MeetingMacCaptureTeeProbe(writer: closingWriter, consumer: closingConsumer,
            event: { closingEvents.record($0) }, live: { _, _ in closingEvents.presented() })
        let admitted = Task.detached {
            closing.deliver(try nativeSample(frames: 512, startFrame: 0))
        }
        defer { resumeWriter.signal() }
        let writerReached = await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                continuation.resume(returning: enteredWriter.wait(timeout: .now() + 2) == .success)
            }
        }
        try require(writerReached, "the callback reaches its writer after intake admission")
        closing.closeForStop()
        resumeWriter.signal()
        try await admitted.value
        try require(closing.hasFailureForStop && closingConsumer.received.isEmpty,
            "an already admitted sink rejection remains visible to Stop after it closes intake")
        try require(closingEvents.snapshot.0.isEmpty && closingEvents.snapshot.1 == 0,
            "normal Stop suppresses duplicate interruption events without suppressing the PCM failure")
        print("Desktop source callback: native-rate writer rejection, Stop race, closed intake, terminal evidence and unchanged legacy path passed.")
    }

    static func main() async throws {
        try await testDesktopWriterRejection()
        try await testCaptureBeforePreparation()

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
        // The desktop tee preserves the writer's native PCM and converts only the bounded
        // consumer copy. Exercise raw stereo input rather than the iOS-owned mono tap path.
        for rate in [44_100, 48_000] {
            for interleaved in [false, true] {
                let nativeConverter = try MeetingCapturePCMConverter()
                var count = 0
                var expected = CMTime(seconds: 200, preferredTimescale: 16_000)
                var offset = 0
                func accept(_ output: CMSampleBuffer) throws {
                    let contract = try MeetingPCMFormatContract(formatDescription: CMSampleBufferGetFormatDescription(output)!)
                    try require(contract.sampleRate == 16_000 && contract.channelCount == 1,
                        "native-rate stereo tee must satisfy the strict consumer contract")
                    try require(abs(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(output) - expected)) < 1.0 / 16_000,
                        "native-rate tee keeps one continuous physical clock")
                    let frames = CMSampleBufferGetNumSamples(output)
                    count += frames
                    expected = expected + CMTime(value: Int64(frames), timescale: 16_000)
                    let copied = MeetingLiveSampleCopy.copy(output)!
                    try require((0..<Int(copied.buffer.frameLength)).allSatisfy { copied.buffer.floatChannelData![0][$0].isFinite },
                        "native-rate tee output remains finite")
                }
                while offset < rate {
                    let frames = min(1024, rate - offset)
                    let native = pcm(frames: frames, sampleRate: Double(rate), channels: 2, interleaved: interleaved)
                    if let output = try nativeConverter.convert(native,
                        presentationTime: CMTime(value: Int64(200 * rate + offset), timescale: CMTimeScale(rate))) {
                        try accept(output)
                    }
                    offset += frames
                }
                if let tail = try nativeConverter.finish() { try accept(tail) }
                try require(abs(count - 16_000) <= 1, "native-rate tee joins the complete one-second converter tail")
            }
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

        let initialProbe = Probe()
        let initial = try MeetingProcessingPipeline.makeMemoryAudioConsumer(chunkSeconds: 0.5, maximumPendingSeconds: 1,
            initialChunkSeconds: 0.25,
            recognize: { samples, start in initialProbe.begin(samples, at: start); return MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in initialProbe.checkpoint() }, failure: { _ in initialProbe.failed() })
        for start in stride(from: 0, to: 12_000, by: 4_000) {
            try require(initial.enqueue(try sample(frames: 4_000, startFrame: Int64(start))), "bounded startup PCM accepted")
        }
        try await initial.finish()
        try require(initialProbe.snapshot.0.map(\.1) == [4_000, 8_000], "only the initial window uses the shorter startup cadence")
        try require(initialProbe.snapshot.0.map(\.0) == [0, 0.25], "startup transition preserves complete contiguous media time")

        let latch = Latch()
        let overloadedProbe = Probe()
        let diagnostics = DiagnosticProbe()
        let overloaded = try MeetingProcessingPipeline.makeMemoryAudioConsumer(chunkSeconds: 0.25, maximumPendingSeconds: 0.5,
            recognize: { samples, start in overloadedProbe.begin(samples, at: start); await latch.wait(); return MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in overloadedProbe.checkpoint() }, diagnostic: { diagnostics.record($0) }, failure: { _ in overloadedProbe.failed() })
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
        try require(diagnostics.snapshot.count == 1, "one terminal diagnostic for overloaded intake")
        try require(diagnostics.snapshot[0].contains("errorKind=overload")
                    && diagnostics.snapshot[0].contains("pendingFrames=8000")
                    && diagnostics.snapshot[0].contains("budgetFrames=8000"), "log the actual saturated budget before discarding pending PCM")
        try require(overloaded.rejectionReason == MeetingMemoryAudioError.overload.localizedDescription,
                    "capture must distinguish a saturated audio queue from unavailable RAM")

        let failureProbe = Probe()
        let failureDiagnostics = DiagnosticProbe()
        let checkpointFailure = try MeetingProcessingPipeline.makeMemoryAudioConsumer(chunkSeconds: 0.25, maximumPendingSeconds: 1,
            recognize: { _, _ in MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in throw NSError(domain: "CheckpointFailure", code: 42,
                userInfo: [NSLocalizedDescriptionKey: "Synthetic sensitive transcript fragment"]) },
            diagnostic: { failureDiagnostics.record($0) }, failure: { _ in failureProbe.failed() })
        _ = checkpointFailure.enqueue(try sample(frames: 4_000))
        do { try await checkpointFailure.finish(); throw NSError(domain: "ExpectedCheckpointError", code: 1) }
        catch let error as NSError where error.domain == "CheckpointFailure" { }
        try require(!failureDiagnostics.snapshot.isEmpty, "failed checkpoints must have a bounded diagnostic")
        try require(failureDiagnostics.snapshot.allSatisfy { !$0.contains("sensitive transcript") && !$0.contains("CheckpointFailure") },
                    "provider and checkpoint error contents must never enter support logs")
        try require(failureProbe.snapshot.2 == 1, "checkpoint failure closes strict intake")
        try require(checkpointFailure.rejectionReason == nil, "untrusted checkpoint payloads never become capture errors")
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

        let finalizerProbe = FinalizerProbe()
        let finalizerLatch = Latch()
        let finalizing = try MeetingProcessingPipeline.makeMemoryAudioConsumer(
            recognize: { _, _ in MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { batch in await finalizerProbe.saved(batch.segments) },
            finalize: {
                await finalizerProbe.started()
                await finalizerLatch.wait()
                return MeetingPCMTranscriptBatch(segments: ["safe pending privacy tail"], speakers: [])
            }, failure: { _ in })
        let firstFinalizing = Task { try await finalizing.finish() }
        for _ in 0..<1000 { if await finalizerLatch.entered { break }; await Task.yield() }
        firstFinalizing.cancel()
        let secondFinalizing = Task { try await finalizing.finish() }
        try require(await finalizerProbe.count == 1, "concurrent finish callers share one privacy finalization")
        try require(await finalizerProbe.checkpoints.isEmpty, "cancelled caller does not abandon or prematurely persist privacy tail")
        await finalizerLatch.release()
        try await firstFinalizing.value
        try await secondFinalizing.value
        try require(await finalizerProbe.checkpoints == [["safe pending privacy tail"]], "pending redacted tail checkpoints exactly once")

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
        try await progressiveTransport()
        try await checkpointReleasesPCM()
        try await longMeetingTransport()
        try await archivedRecordingSurvivesSlowLiveSpeech()
        print("Meeting PCM transport: admission, conversion, ownership, timeline, bounded inference, overload, joined finish and checkpoint failure passed.")
    }

    static func testCaptureBeforePreparation() async throws {
        let preparation = Latch(), probe = LongRunProbe(), finishProbe = ProgressiveProbe()
        let controller = MeetingStreamingPCMController.deferred { body in
            await preparation.wait()
            try await body(StartupPrepared(probe: probe))
        }
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            chunkSeconds: 1, maximumPendingSeconds: 2, initialPreviewSeconds: 0.25, previewIntervalSeconds: 0.25,
            recognize: { window, offset in try await controller.recognize(window: window, offset: offset).batch },
            checkpoint: { _ in probe.checkpointed() },
            finalize: { try await controller.finishStreaming().batch },
            failure: { _ in probe.failed() })
        try require(consumer.enqueue(try sample(frames: 4_000)), "Microphone PCM is admitted before either native model is ready")
        try await awaitEntered(preparation, "First PCM window starts the deferred preparation owner")
        for start in stride(from: 4_000, to: 24_000, by: 4_000) {
            try require(consumer.enqueue(try sample(frames: 4_000, startFrame: Int64(start))),
                        "Initial and subsequent microphone samples stay inside the existing bounded queue")
        }
        let finishing = Task { try await consumer.finish(); finishProbe.didFinish() }
        for _ in 0..<50 { await Task.yield() }
        try require(probe.snapshot.frames == 0 && !finishProbe.snapshot.5,
                    "Early Stop retains all accepted PCM and joins pending native preparation")
        await preparation.release()
        try await finishing.value
        try require(probe.snapshot.frames == 24_000 && probe.snapshot.windows == 2
                    && probe.snapshot.contiguous && !probe.snapshot.rejected,
                    "Every sample accepted during preparation is transcribed exactly once after readiness")

        let slowPreparation = Latch(), boundedProbe = LongRunProbe(), boundedFinish = ProgressiveProbe()
        let boundedController = MeetingStreamingPCMController.deferred { body in
            await slowPreparation.wait()
            try await body(StartupPrepared(probe: boundedProbe))
        }
        let bounded = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            chunkSeconds: 0.5, maximumPendingSeconds: 0.5, initialPreviewSeconds: 0.25, previewIntervalSeconds: 0.25,
            recognize: { window, offset in try await boundedController.recognize(window: window, offset: offset).batch },
            checkpoint: { _ in boundedProbe.checkpointed() }, failure: { _ in boundedProbe.failed() })
        try require(bounded.enqueue(try sample(frames: 4_000)), "Initial preparation sample is inside budget")
        try await awaitEntered(slowPreparation, "Slow native preparation is owned")
        try require(bounded.enqueue(try sample(frames: 4_000, startFrame: 4_000)), "Exact preparation PCM budget remains accepted")
        try require(!bounded.enqueue(try sample(frames: 1, startFrame: 8_000)), "Preparation does not create an unbounded second queue")
        let closed = Task { try await bounded.finish(); boundedFinish.didFinish() }
        for _ in 0..<50 { await Task.yield() }
        try require(!boundedFinish.snapshot.5, "Overload still joins pending native preparation")
        await slowPreparation.release()
        do { try await closed.value; throw NSError(domain: "ExpectedStartupOverload", code: 1) }
        catch MeetingMemoryAudioError.overload {}
        try require(boundedProbe.snapshot.frames == 0 && boundedProbe.snapshot.rejected,
                    "Overload cannot publish cancelled initial speech or silently drop its queue")
        await boundedController.cancelAndWait()
    }

    private static func awaitEntered(_ latch: Latch, _ detail: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await latch.entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try require(false, detail)
    }

    static func checkpointReleasesPCM() async throws {
        let saving = Latch()
        let probe = Probe()
        let consumer = try MeetingProcessingPipeline.makeMemoryAudioConsumer(
            chunkSeconds: 0.25, maximumPendingSeconds: 0.5,
            recognize: { samples, start in
                probe.begin(samples, at: start)
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in await saving.wait(); probe.checkpoint() }, failure: { _ in probe.failed() })
        try require(consumer.enqueue(try sample(frames: 4_000)), "checkpoint fixture accepts initial audio")
        try await awaitEntered(saving, "checkpoint is holding text only")
        try require(consumer.enqueue(try sample(frames: 4_000, startFrame: 4_000)), "queue accepts audio during durable save")
        try require(consumer.enqueue(try sample(frames: 4_000, startFrame: 8_000)), "consumed PCM no longer consumes queue credit during IO")
        try require(probe.snapshot.0.count == 1, "save remains serialized with the next inference")
        await saving.release()
        try await consumer.finish()
        try require(probe.snapshot.1 == 3 && probe.snapshot.2 == 0, "save delay preserves every accepted frame without parallel inference")

        // A late native operation may briefly outlast its 12-second input. The reserve is
        // constant, and remains a hard stop if work never makes progress.
        let native = Latch()
        let burst = Probe()
        let buffered = try MeetingProcessingPipeline.makeMemoryAudioConsumer(
            recognize: { samples, start in
                burst.begin(samples, at: start); await native.wait()
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in burst.checkpoint() }, failure: { _ in burst.failed() })
        for start in stride(from: 0, to: 480_000, by: 48_000) {
            try require(buffered.enqueue(try sample(frames: 48_000, startFrame: Int64(start))), "a transient 30-second native stall fits the fixed burst reserve")
        }
        try await awaitEntered(native, "burst inference started")
        await native.release()
        try await buffered.finish()
        try require(burst.snapshot.0.reduce(0) { $0 + $1.1 } == 480_000 && burst.snapshot.2 == 0,
                    "burst catch-up must preserve all PCM")
    }

    static func archivedRecordingSurvivesSlowLiveSpeech() async throws {
        let native = Latch()
        let probe = Probe()
        let live = try MeetingProcessingPipeline.makeMemoryAudioConsumer(maximumPendingSeconds: 24,
            recognize: { samples, start in
                probe.begin(samples, at: start); await native.wait()
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in probe.checkpoint() }, failure: { _ in probe.failed() })
        let archive = MeetingMemoryAudioArchive()
        let recording = MeetingArchivedMemoryAudioConsumer(archive: archive, speech: live)
        for start in stride(from: 0, to: 192_000, by: 48_000) {
            try require(recording.enqueue(try sample(frames: 48_000, startFrame: Int64(start))), "RAM recording accepts startup audio")
        }
        try await awaitEntered(native, "synthetic slow live recognizer owns a window")
        for start in stride(from: 192_000, to: 1_440_000, by: 48_000) {
            try require(recording.enqueue(try sample(frames: 48_000, startFrame: Int64(start))), "recording continues when live speech falls behind")
        }
        try require(recording.requiresSpeechReplay && recording.rejectionReason == nil,
                    "live overload requests post-stop speech replay without rejecting capture")
        try require(archive.totalSampleCount == 1_440_000, "all ninety seconds remain in the authoritative archive")
        let finishing = Task { try await recording.finish() }
        await native.release()
        try await finishing.value
        try require(probe.snapshot.2 == 1 && recording.requiresSpeechReplay,
                    "finish joins the rejected recognizer and retains the complete replay requirement")
    }

    static func longMeetingTransport() async throws {
        let probe = LongRunProbe()
        let consumer = try MeetingProcessingPipeline.makeMemoryAudioConsumer(
            chunkSeconds: 20,
            recognize: { samples, start in
                probe.recognized(samples.count, start: start)
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in probe.checkpointed() }, failure: { _ in probe.failed() })
        let prototype = try sample(frames: 16_000)
        let totalFrames = 8 * 60 * 60 * 16_000
        var position = 0
        for window in 0..<1_440 {
            for _ in 0..<20 {
                var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
                    presentationTimeStamp: CMTime(value: 1_600_000 + Int64(position), timescale: 16_000),
                    decodeTimeStamp: .invalid)
                var copy: CMSampleBuffer?
                let status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault,
                    sampleBuffer: prototype, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                    sampleBufferOut: &copy)
                try require(status == noErr && copy != nil, "stress PCM timing copy")
                try require(consumer.enqueue(copy!), "eight-hour transport accepts contiguous PCM")
                position += 16_000
            }
            let deadline = ProcessInfo.processInfo.systemUptime + 5
            while probe.snapshot.saved <= window && ProcessInfo.processInfo.systemUptime < deadline {
                try await Task.sleep(for: .milliseconds(1))
            }
            try require(probe.snapshot.saved == window + 1, "each stress window checkpoints before continuing")
        }
        try await consumer.finish()
        let result = probe.snapshot
        try require(result.frames == totalFrames && result.windows == 1_440 && result.saved == 1_440,
                    "eight simulated hours are consumed and checkpointed exactly once")
        try require(!result.rejected && result.contiguous, "duration does not grow the audio queue or change its timeline")
        print("Eight-hour accelerated transport: 460800000 frames, 1440 twenty-second windows, no discarded audio or queue overflow. This is synthetic transport, not an eight-hour model/device run.")
    }

    static func progressiveTransport() async throws {
        // The initial preview and subsequent coalesced updates belong to ONE attribution window.
        let probe = ProgressiveProbe()
        let first = Latch()
        let second = Latch()
        let consumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, start in
                probe.begin(start)
                var prefix: [Float] = []
                while let update = try await window.next() {
                    // No samples survive this callback. The accumulator is changed only after the
                    // prior mock inference has joined, matching the native inference contract.
                    prefix.append(contentsOf: update.samples)
                    try require(prefix.count == update.totalFrames, "progressive delta frame accounting")
                    try require(prefix.allSatisfy { abs($0 - 0.8) < 0.001 }, "immutable prefix survives subsequent microphone callbacks")
                    probe.record(update, start: start)
                    if start == 0 && update.totalFrames == 48_000 { await first.wait() }
                    if start == 0 && update.totalFrames == 144_000 { await second.wait() }
                }
                probe.didReturn()
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in probe.checkpoint() }, failure: { _ in probe.failed() })
        try require(consumer.enqueue(try sample(frames: 48_000)), "first three-second preview accepted")
        try await awaitEntered(first, "progressive worker begins before twelve-second seal")
        try require(probe.snapshot.1 == [0] && probe.snapshot.2 == 0, "open attribution window has one worker and no early checkpoint")
        for start in [48_000, 96_000] {
            try require(consumer.enqueue(try sample(frames: 48_000, startFrame: Int64(start))), "pending deltas accepted while inference owns prefix")
        }
        await first.release()
        try await awaitEntered(second, "ready worker coalesces all six available seconds")
        try require(probe.snapshot.0.map(\.delta) == [48_000, 96_000], "coalescing uses deltas, not repeated whole-prefix copies")
        // One microphone callback crosses the attribution boundary, leaving a finite half-second
        // next-window tail. Finish starts that next window even below the preview threshold.
        try require(consumer.enqueue(try sample(frames: 56_000, startFrame: 144_000)), "cross-window PCM seals twelve seconds and preserves finite next-window tail")
        let finish = Task { try await consumer.finish(); probe.didFinish() }
        finish.cancel()
        for _ in 0..<50 { await Task.yield() }
        try require(!probe.snapshot.5, "cancelled finish caller still joins the progressive inference")
        await second.release()
        try await finish.value
        let snapshot = probe.snapshot
        try require(snapshot.1 == [0, 12] && snapshot.2 == 2 && snapshot.3 == 0 && snapshot.4 == 2,
                    "one final checkpoint per attribution window, serial ownership and exact media offsets")
        try require(snapshot.0.last == .init(start: 12, delta: 8_000, total: 8_000, final: true), "stop below three seconds seals every accepted frame")
        let firstWindow = snapshot.0.filter { $0.start == 0 }
        try require(firstWindow.map(\.delta).reduce(0, +) == 192_000 && firstWindow.last?.final == true,
                    "growing three-to-twelve window forwards all frames exactly once")
        try require(firstWindow.map(\.total).prefix(2) == [48_000, 144_000], "total frames describe attribution window, not inference delta")

        // Finishing a prefix already delivered to inference must provide an empty final marker.
        let emptyProbe = ProgressiveProbe()
        let emptyLatch = Latch()
        let emptyFinal = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, start in
                emptyProbe.begin(start)
                let initial = try await window.next()!
                emptyProbe.record(initial, start: start)
                await emptyLatch.wait()
                let final = try await window.next()!
                emptyProbe.record(final, start: start)
                try require(final.samples.isEmpty && final.totalFrames == 48_000 && final.isFinal, "final empty update preserves previously decoded prefix")
                try require(try await window.next() == nil, "next after final is nil")
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in emptyProbe.checkpoint() }, failure: { _ in emptyProbe.failed() })
        _ = emptyFinal.enqueue(try sample(frames: 48_000))
        try await awaitEntered(emptyLatch, "empty final fixture owns initial prefix")
        let emptyFinish = Task { try await emptyFinal.finish() }
        // finish closes synchronously once its task enters. New PCM must be rejected before releasing inference.
        for _ in 0..<50 { await Task.yield() }
        await emptyLatch.release()
        try await emptyFinish.value
        try require(emptyProbe.snapshot.2 == 1 && emptyProbe.snapshot.3 == 0, "empty seal checkpoints exactly once")

        // Accepted PCM includes in-flight accumulator, pending deltas and the queued next window.
        let overload = ProgressiveProbe()
        let overloadLatch = Latch()
        let overloadDiagnostic = DiagnosticProbe()
        let bounded = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            maximumPendingSeconds: 24,
            recognize: { window, start in
                overload.begin(start)
                if let update = try await window.next() { overload.record(update, start: start) }
                await overloadLatch.wait()
                _ = try await window.next()
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in overload.checkpoint() }, diagnostic: { overloadDiagnostic.record($0) }, failure: { _ in overload.failed() })
        _ = bounded.enqueue(try sample(frames: 48_000))
        try await awaitEntered(overloadLatch, "budget fixture owns initial accumulator")
        for start in stride(from: 48_000, to: 384_000, by: 48_000) {
            try require(bounded.enqueue(try sample(frames: 48_000, startFrame: Int64(start))), "exact twenty-four second budget remains accepted")
        }
        try require(!bounded.enqueue(try sample(frames: 1, startFrame: 384_000)), "one frame above twenty-four seconds terminates intake")
        let overloadFinish = Task { try await bounded.finish(); overload.didFinish() }
        for _ in 0..<50 { await Task.yield() }
        try require(!overload.snapshot.5, "failure must join active inference before finish returns")
        await overloadLatch.release()
        do { try await overloadFinish.value; throw NSError(domain: "ExpectedProgressiveOverload", code: 1) }
        catch MeetingMemoryAudioError.overload { }
        try require(overload.snapshot.1.count == 1 && overload.snapshot.2 == 0 && overload.snapshot.3 == 1,
                    "overflow cancels queued windows and cannot publish cancelled prefix")
        try require(overloadDiagnostic.snapshot.count == 1
                    && overloadDiagnostic.snapshot[0].contains("pendingFrames=384000")
                    && overloadDiagnostic.snapshot[0].contains("budgetFrames=384000"), "progressive transport keeps original total PCM budget")

        // A terminal microphone error wakes next() once and finish joins the recognizer cleanup.
        let waiting = ProgressiveProbe()
        let aboutToWait = Latch()
        let cleanup = Latch()
        let waitingConsumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, start in
                waiting.begin(start)
                _ = try await window.next()
                await aboutToWait.wait()
                do { _ = try await window.next(); throw NSError(domain: "ExpectedWaitFailure", code: 1) }
                catch {
                    waiting.didReturn()
                    await cleanup.wait()
                    throw error
                }
            }, checkpoint: { _ in waiting.checkpoint() }, failure: { _ in waiting.failed() })
        _ = waitingConsumer.enqueue(try sample(frames: 48_000))
        try await awaitEntered(aboutToWait, "first prefix before wait")
        await aboutToWait.release()
        for _ in 0..<50 { await Task.yield() }
        try require(!waitingConsumer.enqueue(try sample(frames: 1, startFrame: 48_002)), "timeline failure wakes a pending progressive next")
        try await awaitEntered(cleanup, "cancelled progressive waiter enters joined cleanup")
        let waitingFinish = Task { try await waitingConsumer.finish(); waiting.didFinish() }
        for _ in 0..<50 { await Task.yield() }
        try require(!waiting.snapshot.5 && waiting.snapshot.4 == 1 && waiting.snapshot.3 == 1,
                    "terminal failure wakes waiter exactly once without abandoning cleanup")
        await cleanup.release()
        do { try await waitingFinish.value; throw NSError(domain: "ExpectedProgressiveTimelineFailure", code: 1) }
        catch MeetingMemoryAudioError.timelineDiscontinuity { }
        try require(waiting.snapshot.2 == 0, "cancelled window cannot checkpoint")

        // Provider cancellation of next closes its window and propagates through the same failure path.
        let cancelled = ProgressiveProbe()
        let cancelWait = Latch()
        let cancelConsumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, _ in
                _ = try await window.next()
                let pending = Task { await cancelWait.wait(); return try await window.next() }
                try await awaitEntered(cancelWait, "nested waiter owns window")
                await cancelWait.release()
                pending.cancel()
                _ = try await pending.value
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in cancelled.checkpoint() }, failure: { _ in cancelled.failed() })
        _ = cancelConsumer.enqueue(try sample(frames: 48_000))
        // Wait for cancellation to finish before finish could seal the window successfully.
        let cancellationDeadline = ProcessInfo.processInfo.systemUptime + 5
        while cancelled.snapshot.3 == 0 && ProcessInfo.processInfo.systemUptime < cancellationDeadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        try require(cancelled.snapshot.3 == 1, "next cancellation propagates one terminal failure")
        do { try await cancelConsumer.finish(); throw NSError(domain: "ExpectedProgressiveCancellation", code: 1) }
        catch is CancellationError { }
        try require(cancelled.snapshot.2 == 0, "next cancellation never persists unsealed prefix")

        let shortProbe = ProgressiveProbe()
        let shortFinalize = FinalizerProbe()
        let finalizeLatch = Latch()
        let short = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, start in
                shortProbe.begin(start)
                while let update = try await window.next() { shortProbe.record(update, start: start) }
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { batch in shortProbe.checkpoint(); await shortFinalize.saved(batch.segments) },
            finalize: {
                await shortFinalize.started()
                await finalizeLatch.wait()
                return MeetingPCMTranscriptBatch(segments: ["safe final privacy tail"], speakers: [])
            }, failure: { _ in shortProbe.failed() })
        try require(short.enqueue(try sample(frames: 24_001)), "first short window is accepted before preview threshold")
        try require(shortProbe.snapshot.1.isEmpty, "no worker before initial preview threshold")
        let shortFinish = Task { try await short.finish() }
        try await awaitEntered(finalizeLatch, "short tail finishes before privacy finalizer")
        shortFinish.cancel()
        let repeatedShortFinish = Task { try await short.finish() }
        try require(shortProbe.snapshot.0 == [.init(start: 0, delta: 24_001, total: 24_001, final: true)], "stop before initial preview transfers exact finite frame count")
        try require(await shortFinalize.count == 1, "progressive finish shares one privacy finalizer")
        await finalizeLatch.release()
        try await shortFinish.value
        try await repeatedShortFinish.value
        try require(await shortFinalize.checkpoints == [[], ["safe final privacy tail"]], "progressive finalization joins and publishes protected tail once")

        let early = ProgressiveProbe()
        let earlyConsumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { _, _ in MeetingPCMTranscriptBatch(segments: [], speakers: []) },
            checkpoint: { _ in early.checkpoint() }, failure: { _ in early.failed() })
        _ = earlyConsumer.enqueue(try sample(frames: 48_000))
        do { try await earlyConsumer.finish(); throw NSError(domain: "ExpectedUnconsumedWindow", code: 1) }
        catch MeetingMemoryAudioError.invalidPCM { }
        try require(early.snapshot.2 == 0 && early.snapshot.3 == 1, "provider cannot retire a window before consuming its final update")

        let failedCheckpoint = ProgressiveProbe()
        let checkpointConsumer = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(
            recognize: { window, _ in
                while let _ = try await window.next() { }
                return MeetingPCMTranscriptBatch(segments: [], speakers: [])
            }, checkpoint: { _ in throw NSError(domain: "SyntheticProgressiveCheckpointFailure", code: 1) },
            failure: { _ in failedCheckpoint.failed() })
        _ = checkpointConsumer.enqueue(try sample(frames: 16_000))
        do { try await checkpointConsumer.finish(); throw NSError(domain: "ExpectedProgressiveCheckpointFailure", code: 1) }
        catch let error as NSError where error.domain == "SyntheticProgressiveCheckpointFailure" { }
        try require(failedCheckpoint.snapshot.3 == 1, "progressive checkpoint failure follows existing terminal ownership path")

        for invalidInterval in [Double.nan, 0.1, 13] {
            do {
                _ = try MeetingProcessingPipeline.makeProgressiveMemoryAudioConsumer(previewIntervalSeconds: invalidInterval,
                    recognize: { _, _ in MeetingPCMTranscriptBatch(segments: [], speakers: []) }, checkpoint: { _ in }, failure: { _ in })
                throw NSError(domain: "ExpectedProgressiveBudgetError", code: 1)
            } catch MeetingMemoryAudioError.invalidBudget { }
        }
        print("Progressive PCM: growing windows, delta coalescing, empty seal, exact budget, waiter cancellation and joined cleanup passed.")
    }

}
