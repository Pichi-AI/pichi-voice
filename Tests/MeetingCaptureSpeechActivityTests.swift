import AVFoundation
import CoreMedia
import Foundation

typealias SessionSpeakerID = UUID
nonisolated enum MeetingAudioTrackKind: Sendable { case microphone, applicationAudio }
nonisolated enum MeetingEchoDetector {
    static func isLikelyEcho(micText: String, remoteText: String) -> Bool { false }
}

@main
struct MeetingCaptureSpeechActivityTests {
    nonisolated struct Fake: MeetingSpeechActivityFrameModel {
        mutating func probability(samples: [Float], reset: Bool) throws -> Float {
            if samples[0] < 0 { throw CocoaError(.fileReadCorruptFile) }
            return samples[0]
        }
    }
    nonisolated final class Script: @unchecked Sendable {
        enum Output { case probability(Float, seconds: Double), failure }
        private let lock = NSLock()
        private var time = 0.0
        private var outputs: [Output]
        private var resets: [Bool] = []
        init(_ outputs: [Output]) { self.outputs = outputs }
        var now: Double { lock.withLock { time } }
        var resetFlags: [Bool] { lock.withLock { resets } }
        func predict(reset: Bool) throws -> Float {
            try lock.withLock {
                resets.append(reset)
                let output = outputs.isEmpty ? .probability(0, seconds: 0.005) : outputs.removeFirst()
                switch output {
                case let .probability(p, seconds): time += seconds; return p
                case .failure: throw CocoaError(.fileReadCorruptFile)
                }
            }
        }
    }
    nonisolated struct ScriptedModel: MeetingSpeechActivityFrameModel {
        let script: Script
        mutating func probability(samples: [Float], reset: Bool) throws -> Float { try script.predict(reset: reset) }
    }
    nonisolated struct BlockingModel: MeetingSpeechActivityFrameModel {
        let began: DispatchSemaphore
        let release: DispatchSemaphore
        mutating func probability(samples: [Float], reset: Bool) throws -> Float {
            began.signal(); release.wait(); return 0
        }
    }
    nonisolated final class Events: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [(Double, Double, MeetingSpeechActivity)] = []
        func add(_ start: Double, _ end: Double, _ activity: MeetingSpeechActivity) { lock.withLock { items.append((start, end, activity)) } }
        var values: [(Double, Double, MeetingSpeechActivity)] { lock.withLock { items } }
    }
    static func require(_ value: Bool, _ text: String) throws {
        if !value { throw NSError(domain: "CaptureVAD", code: 1, userInfo: [NSLocalizedDescriptionKey: text]) }
    }
    static func wait(_ events: Events, count: Int) async throws {
        for _ in 0..<2000 {
            if events.values.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw CocoaError(.coderReadCorrupt)
    }
    static func input(_ value: Float, start: Double, count: Int = 4096) throws -> CMSampleBuffer {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        pcm.frameLength = AVAudioFrameCount(count)
        pcm.floatChannelData![0].initialize(repeating: value, count: count)
        var description: CMAudioFormatDescription?
        try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, "format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 16_000), decodeTimeStamp: .invalid)
        var result: CMSampleBuffer?
        try require(CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: count,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &result) == noErr, "sample")
        try require(CMSampleBufferSetDataBufferFromAudioBufferList(result!, blockBufferAllocator: nil,
            blockBufferMemoryAllocator: nil, flags: 0, bufferList: pcm.audioBufferList) == noErr, "data")
        try require(CMSampleBufferSetDataReady(result!) == noErr, "ready")
        return result!
    }
    static func main() async throws {
        try await budgetRecovery()
        let events = Events()
        let worker = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: events.add)
        for (i, value) in [Float(0), 0.1, 0.5, 0.99, -1, 0].enumerated() {
            worker.offer(try input(value, start: Double(i) * 0.256), start: Double(i) * 0.256)
        }
        try await wait(events, count: 6)
        try require(events.values.map { $0.2 } == [.unknown, .nonSpeech, .unknown, .speech, .unknown, .unknown],
            "warmup, conservative silence, ambiguous, speech, failure and renewed warmup")
        try require(worker.confidentlyNonSpeech(start: 0.256, end: 0.512), "fully covered quiet window")
        try require(!worker.confidentlyNonSpeech(start: 0, end: 0.512), "warmup fails open")
        try require(!worker.confidentlyNonSpeech(start: 0.256, end: 0.6), "unknown coverage fails open")
        try require(!worker.confidentlyNonSpeech(start: 0.256, end: 20), "unprocessed tail fails open")
        worker.offer(try input(0, start: 5), start: 5)
        try await wait(events, count: 7)
        try require(events.values.last!.2 == .unknown, "capture gap resets model warmup")
        try require(!worker.confidentlyNonSpeech(start: 0.256, end: 0.512), "gap invalidates old evidence")
        worker.stop(); await worker.join()
        try require(!worker.confidentlyNonSpeech(start: 0.256, end: 0.512), "closed model never supplies stale evidence")
        print("PASS activity thresholds, full coverage, gap reset and joined close")

        let missing = Events()
        let unavailable = MeetingCaptureSpeechActivityWorker(factory: { throw CocoaError(.fileNoSuchFile) }, publish: missing.add)
        unavailable.offer(try input(0.99, start: 0), start: 0)
        try await wait(missing, count: 1)
        try require(missing.values[0].2 == .unknown && !unavailable.confidentlyNonSpeech(start: 0, end: 0.256), "missing model fails open")
        unavailable.stop(); await unavailable.join()
        print("PASS unavailable model does not block or infer silence")

        let fallbackEvents = Events()
        let capture = MeetingPendingSpeechCapture(originBox: MeetingLiveOriginBox(),
            activityModel: { throw CocoaError(.fileNoSuchFile) }, onUpdate: { snapshot in
                if !snapshot.tokens.isEmpty { fallbackEvents.add(0, 0, .speech) }
            })
        for frame in 0..<200 {
            let start = Double(frame) * 0.02
            let level = Float(0.02 + 0.012 * sin(start * 2 * .pi * 3))
            capture.offer(kind: .microphone, sampleBuffer: try input(level, start: start, count: 320))
            if frame % 10 == 0 { try await Task.sleep(for: .milliseconds(1)) }
        }
        let fallback = capture.reconcile(visible: .empty)
        try require(!fallback.tokens.isEmpty, "Missing optional model keeps capture-only waveform feedback")
        try require(!capture.confidentlyNonSpeech(start: 1, end: 2),
                    "Heuristic UI activity must never authorize skipping recognition")
        await capture.stopAndWait()
        print("PASS missing optional VAD restores UI-only feedback while ASR stays fail-open")

        let gate = DispatchSemaphore(value: 0), loading = DispatchSemaphore(value: 0)
        let backlog = Events()
        let bounded = MeetingCaptureSpeechActivityWorker(factory: { loading.signal(); gate.wait(); return Fake() }, publish: backlog.add)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { loading.wait(); continuation.resume() }
        }
        for i in 0..<100 { bounded.offer(try input(0, start: Double(i) * 0.256), start: Double(i) * 0.256) }
        try require(backlog.values.isEmpty, "capture admission is independent of blocked model loading")
        gate.signal()
        try await wait(backlog, count: 1)
        // Allow the bounded worker to finish. At most seven 4096-sample frames survive
        // its 32000-sample cap; earlier overflow epochs cannot publish.
        for _ in 0..<30 { try await Task.sleep(for: .milliseconds(1)) }
        try require(backlog.values.count <= 7 && backlog.values.first!.2 == .unknown, "overflow bounds queue and resets recurrent state")
        try require(!bounded.confidentlyNonSpeech(start: 0, end: 25), "dropped activity coverage never suppresses ASR")
        bounded.stop(); await bounded.join()
        print("PASS slow preparation, bounded backlog and overflow fail-open")

        let release = DispatchSemaphore(value: 0), began = DispatchSemaphore(value: 0)
        let cancelled = Events()
        let stopping = MeetingCaptureSpeechActivityWorker(factory: { began.signal(); release.wait(); return Fake() }, publish: cancelled.add)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { began.wait(); continuation.resume() }
        }
        stopping.offer(try input(0.99, start: 0), start: 0)
        stopping.stop()
        let joined = Task { await stopping.join() }
        release.signal()
        await joined.value
        try require(cancelled.values.isEmpty, "cancel during preparation joins and suppresses queued callbacks")
        print("PASS cancellation during model preparation is joined")

        let history = Events()
        let rolling = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: history.add)
        for i in 0..<360 {
            rolling.offer(try input(0, start: Double(i) * 0.256), start: Double(i) * 0.256)
            try await wait(history, count: i + 1)
        }
        try require(!rolling.confidentlyNonSpeech(start: 0.256, end: 0.512), "old evidence evicted after bounded ninety-second horizon")
        try require(rolling.confidentlyNonSpeech(start: 91, end: 92), "recent measured quiet retained")
        rolling.offer(try input(0, start: 92.16, count: 512), start: 92.16)
        try require(!rolling.confidentlyNonSpeech(start: 92.16, end: 92.192), "partial model frame not padded into silence proof")
        rolling.stop(); await rolling.join()
        print("PASS bounded scalar history and unscored tail")

        var projection = MeetingPendingSpeechProjection()
        projection.observeSpeechActivity(source: .you, start: 0, end: 0.256, activity: .speech)
        projection.observeSpeechActivity(source: .you, start: 0.256, end: 0.512, activity: .speech)
        try require(projection.snapshot.tokens.count == 1, "aggregate 256ms activity uses window cadence without pretending eight independent frames")
        let prior = projection.snapshot.tokens
        projection.observeSpeechActivity(source: .you, start: 0.512, end: 0.768, activity: .nonSpeech)
        try require(projection.snapshot.tokens == prior && projection.snapshot.animatedTokenIDs.isEmpty, "pause stops animation and retains pending speech")
        print("PASS actual aggregate activity projection and quiet pause")
    }

    static func budgetRecovery() async throws {
        let samples = [Float](repeating: 0, count: 4096)
        let valid = [Bool](repeating: true, count: 4096)
        let session = UUID()
        let script = Script([.probability(0, seconds: 0.2), .probability(0, seconds: 0.2), .probability(0, seconds: 0.2)])
        var detector = MeetingSpeechActivityDetector(model: ScriptedModel(script: script), clock: { script.now })
        for index in 0..<3 {
            let frame = detector.process(samples: samples, valid: valid, start: Double(index) * 0.256,
                                         session: session, epoch: 0, route: "mic")
            try require(frame.unknown == .overBudget && frame.probability == nil, "slow output is never classified")
        }
        for index in 3..<11 {
            let frame = detector.process(samples: samples, valid: valid, start: Double(index) * 0.256,
                                         session: session, epoch: 0, route: "mic")
            try require(frame.unknown == .budgetCooldown && frame.probability == nil, "cooldown is explicit unknown")
        }
        try require(script.resetFlags.count == 3, "cooldown consumes new PCM without inference")
        let warmup = detector.process(samples: samples, valid: valid, start: 11 * 0.256, session: session, epoch: 0, route: "mic")
        let measured = detector.process(samples: samples, valid: valid, start: 12 * 0.256, session: session, epoch: 0, route: "mic")
        try require(warmup.unknown == .contextWarmup && measured.probability == 0,
                    "first fast recovery resets context before publishing the next frame")
        try require(script.resetFlags == [true, true, true, true, false], "recovery does not reuse pre-budget recurrent state")
        print("PASS transient budget cooldown, no inference while cooling and fresh-context recovery")

        let slow = Script(Array(repeating: .probability(0, seconds: 0.2), count: 100))
        var throttled = MeetingSpeechActivityDetector(model: ScriptedModel(script: slow), clock: { slow.now })
        var cooling = 0
        for index in 0..<93 {
            let frame = throttled.process(samples: samples, valid: valid, start: Double(index) * 0.256,
                                          session: session, epoch: 0, route: "mic")
            try require(frame.probability == nil && frame.unknown != .disabled, "persistently slow model stays fail-open")
            if frame.unknown == .budgetCooldown { cooling += 1 }
        }
        try require(slow.resetFlags.count == 13 && cooling == 80,
                    "persistent contention permits only one recovery call per eight new 256ms frames")
        // A replay/new epoch must cover a fresh cooldown, not reuse a previous epoch's
        // source timestamp or count replayed input toward recovery.
        for _ in 0..<12 {
            try require(throttled.process(samples: samples, valid: valid, start: 0,
                        session: session, epoch: 1, route: "mic").unknown == .budgetCooldown,
                        "replayed frames cannot shorten cooldown")
        }
        try require(slow.resetFlags.count == 13, "no recovery inference on repeated source frames")
        var masked = valid; masked[0] = false
        try require(throttled.process(samples: samples, valid: masked, start: 0.256,
                    session: session, epoch: 1, route: "mic").unknown == .unscoredCoverage,
                    "unscored coverage remains unknown during recovery")
        try require(throttled.process(samples: samples, valid: valid, start: 0.512,
                    session: session, epoch: 1, route: "mic", cancelled: { true }).unknown == .cancelled,
                    "cancellation suppresses inference during recovery")
        try require(slow.resetFlags.count == 13, "invalid coverage and cancellation do not predict")
        try require(throttled.process(samples: samples, valid: valid, start: 0,
                    session: UUID(), epoch: 0, route: "mic").unknown == .overBudget,
                    "new attempt receives its own budget allowance")
        print("PASS bounded repeated retries, replay/epoch safety, unscored input and cancellation")

        let broken = Script([.failure, .probability(.nan, seconds: 0.2), .failure])
        var failed = MeetingSpeechActivityDetector(model: ScriptedModel(script: broken), clock: { broken.now })
        for index in 0..<3 {
            try require(failed.process(samples: samples, valid: valid, start: Double(index) * 0.256,
                        session: session, epoch: 0, route: "mic").unknown == .modelFailure,
                        "thrown and invalid outputs are hard model failures even if slow")
        }
        try require(failed.process(samples: samples, valid: valid, start: 0.768,
                    session: session, epoch: 0, route: "mic").unknown == .disabled,
                    "three actual model failures disable the attempt")
        try require(failed.process(samples: samples, valid: valid, start: 1.024,
                    session: session, epoch: 1, route: "other").unknown == .disabled,
                    "route or epoch cannot revive a broken model")
        try require(failed.process(samples: samples, valid: valid, start: 0,
                    session: UUID(), epoch: 0, route: "mic").unknown == .contextWarmup,
                    "new session clears hard failure latch and warms up")
        print("PASS hard model failures stay disabled for the attempt and reset only for new session")

        let workerScript = Script([.probability(0, seconds: 0.2), .probability(0, seconds: 0.2), .probability(0, seconds: 0.2)])
        let recovered = Events()
        let worker = MeetingCaptureSpeechActivityWorker(factory: { ScriptedModel(script: workerScript) },
                                                        clock: { workerScript.now }, publish: recovered.add)
        for index in 0..<13 {
            let start = Double(index) * 0.256
            worker.offer(try input(0, start: start), start: start)
            try await wait(recovered, count: index + 1)
            try require(!worker.isUnavailable, "recoverable budget failure must not permanently drop worker")
        }
        try require(recovered.values.prefix(12).allSatisfy { $0.2 == .unknown }
                    && recovered.values.last!.2 == .nonSpeech, "worker publishes only measured recovery after unknown/warmup")
        try require(!worker.confidentlyNonSpeech(start: 0, end: 12 * 0.256)
                    && !worker.confidentlyNonSpeech(start: 3 * 0.256, end: 11 * 0.256),
                    "over-budget, cooldown and warmup ranges never authorize ASR suppression")
        try require(worker.confidentlyNonSpeech(start: 12 * 0.256, end: 13 * 0.256),
                    "fully measured quiet resumes after recovery")
        worker.stop(); await worker.join()
        try require(!worker.confidentlyNonSpeech(start: 12 * 0.256, end: 13 * 0.256), "joined close invalidates recovered evidence")
        print("PASS real worker remains available, excludes all unknown ASR coverage and joins recovered model")

        let hardScript = Script([.failure, .failure, .failure])
        let hardEvents = Events()
        let hardWorker = MeetingCaptureSpeechActivityWorker(factory: { ScriptedModel(script: hardScript) }, publish: hardEvents.add)
        for index in 0..<3 {
            let start = Double(index) * 0.256
            hardWorker.offer(try input(0, start: start), start: start)
            try await wait(hardEvents, count: index + 1)
        }
        hardWorker.offer(try input(0, start: 0.768), start: 0.768)
        for _ in 0..<2000 {
            if hardWorker.isUnavailable { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try require(hardWorker.isUnavailable && hardScript.resetFlags.count == 3,
                    "worker retires repeated actual model failure without another inference")
        try require(!hardWorker.confidentlyNonSpeech(start: 0, end: 1.024), "failed worker cannot authorize ASR suppression")
        hardWorker.stop(); await hardWorker.join()

        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
        let stoppedEvents = Events()
        let stopping = MeetingCaptureSpeechActivityWorker(factory: { BlockingModel(began: began, release: release) },
                                                          publish: stoppedEvents.add)
        stopping.offer(try input(0, start: 0), start: 0)
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { began.wait(); continuation.resume() }
        }
        stopping.stop()
        let joined = Task { await stopping.join() }
        release.signal(); await joined.value
        try require(stoppedEvents.values.isEmpty && !stopping.confidentlyNonSpeech(start: 0, end: 0.256),
                    "stop joins in-flight prediction and prevents stale publication")
        print("PASS actual worker hard disable and joined cancellation during inference")
    }
}
