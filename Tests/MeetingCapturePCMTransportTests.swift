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
        print("Meeting PCM transport: admission, conversion, ownership, timeline, bounded inference, overload, joined finish and checkpoint failure passed.")
    }

    private static func awaitEntered(_ latch: Latch, _ detail: String) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        while ProcessInfo.processInfo.systemUptime < deadline {
            if await latch.entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        try require(false, detail)
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
