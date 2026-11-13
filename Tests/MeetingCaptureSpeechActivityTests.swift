import AVFoundation
import CoreMedia
import Foundation

nonisolated enum PichiLocalization {
    static func text(_ value: String) -> String { value }
    static func format(_ value: String, _ args: CVarArg...) -> String { String(format: value, arguments: args) }
}

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
    static func wait(_ events: Events, count: Int, context: String = "") async throws {
        for _ in 0..<2000 {
            if events.values.count >= count { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "CaptureVADTimeout", code: 1, userInfo: [NSLocalizedDescriptionKey:
            "\(context): expected \(count) callbacks, got \(events.values.count), tail \(events.values.suffix(4))"])
    }
    static func input(_ value: Float, start: Double, count: Int = 4096,
                      sampleRate: Double = 16_000, channels: AVAudioChannelCount = 1,
                      interleaved: Bool = false, signal: ((Int) -> Float)? = nil) throws -> CMSampleBuffer {
        let tag = channels == 1 ? kAudioChannelLayoutTag_Mono :
            (channels == 2 ? kAudioChannelLayoutTag_Stereo : kAudioChannelLayoutTag_DiscreteInOrder | channels)
        let layout = AVAudioChannelLayout(layoutTag: tag)!
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
            interleaved: interleaved, channelLayout: layout)
        let pcm = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(count))!
        pcm.frameLength = AVAudioFrameCount(count)
        if interleaved { pcm.floatChannelData![0].initialize(repeating: value, count: count * Int(channels)) }
        else { for channel in 0..<Int(channels) { pcm.floatChannelData![channel].initialize(repeating: value, count: count) } }
        if let signal {
            for frame in 0..<count {
                let value = signal(frame)
                for channel in 0..<Int(channels) {
                    pcm.floatChannelData![interleaved ? 0 : channel][interleaved ? frame * Int(channels) + channel : frame] = value
                }
            }
        }
        var description: CMAudioFormatDescription?
        try require(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
            formatDescriptionOut: &description) == noErr, "format")
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: Int32(sampleRate)),
            presentationTimeStamp: CMTime(seconds: start, preferredTimescale: 1_000_000_000), decodeTimeStamp: .invalid)
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
    static func waitUntil(_ predicate: @escaping @Sendable () -> Bool) async throws {
        for _ in 0..<2000 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "CaptureVADEvidenceTimeout", code: 1)
    }

    static func independentPhysicalSourceEvidence() async throws {
        let capture = MeetingPendingSpeechCapture(originBox: MeetingLiveOriginBox(),
            activityModel: { Fake() }, activitySources: [.you, .them], onUpdate: { _ in })
        defer { capture.stop() }
        for index in 0..<4 {
            let start = Double(index) * 0.256
            capture.offer(kind: .microphone, sampleBuffer: try input(0, start: start))
            capture.offer(kind: .applicationAudio, sampleBuffer: try input(0.99, start: start))
        }
        try await waitUntil { capture.confidentlyNonSpeech(source: .you, start: 0.256, end: 0.768) }
        try require(!capture.confidentlyNonSpeech(source: .them, start: 0.256, end: 0.768),
            "A quiet microphone cannot suppress actual speech in the meeting-audio source")
        try require(!(await capture.awaitConfidentNonSpeech(source: .them, start: 0.256, end: 0.768)),
            "Waiting cannot turn another source's speech into silence")
        try require(!capture.confidentlyNonSpeech(source: .you, start: 0, end: 0.768),
            "Source-specific queries preserve warmup and full coverage requirements")
        try require(!capture.confidentlyNonSpeech(source: .you, start: 0.256, end: 2),
            "Unreceived source tail remains unknown")
        for index in 4..<8 {
            let start = Double(index) * 0.256
            capture.offer(kind: .microphone, sampleBuffer: try input(0.99, start: start))
            capture.offer(kind: .applicationAudio, sampleBuffer: try input(0, start: start))
        }
        try await waitUntil { capture.confidentlyNonSpeech(source: .them, start: 1.28, end: 1.792) }
        try require(!capture.confidentlyNonSpeech(source: .you, start: 1.28, end: 1.792),
            "A quiet meeting-audio source cannot suppress actual microphone speech")
        capture.offer(kind: .applicationAudio, sampleBuffer: try input(0, start: 4))
        capture.offer(kind: .applicationAudio, sampleBuffer: try input(0, start: 4.256))
        try await waitUntil { capture.confidentlyNonSpeech(source: .them, start: 4.256, end: 4.512) }
        try require(!capture.confidentlyNonSpeech(source: .them, start: 1.28, end: 1.792),
            "An interior source discontinuity invalidates stale silence evidence")
        await capture.stopAndWait()
        try require(!capture.confidentlyNonSpeech(source: .you, start: 0.256, end: 0.768)
            && !capture.confidentlyNonSpeech(source: .them, start: 4.256, end: 4.512),
            "Joined stop retires silence evidence for both physical sources")

        let legacy = MeetingPendingSpeechCapture(originBox: MeetingLiveOriginBox(),
            activityModel: { Fake() }, onUpdate: { _ in })
        for index in 0..<4 {
            let start = Double(index) * 0.256
            legacy.offer(kind: .microphone, sampleBuffer: try input(0, start: start))
            legacy.offer(kind: .applicationAudio, sampleBuffer: try input(0, start: start))
        }
        try await waitUntil { legacy.confidentlyNonSpeech(start: 0.256, end: 0.768) }
        try require(!legacy.confidentlyNonSpeech(source: .them, start: 0.256, end: 0.768),
            "The mobile-compatible default creates only the existing microphone worker")
        await legacy.stopAndWait()
        print("PASS independent source VAD: alternating speech, full coverage, gaps, default compatibility and joined retirement")
    }

    static func joinedPhysicalSourceStop() async throws {
        let began = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0), completed = Events()
        let capture = MeetingPendingSpeechCapture(originBox: MeetingLiveOriginBox(), activityModel: {
            began.signal(); release.wait(); return Fake()
        }, activitySources: [.you, .them], onUpdate: { _ in })
        defer { release.signal(); release.signal(); capture.stop() }
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { began.wait(); began.wait(); continuation.resume() }
        }
        let stopped = Task { await capture.stopAndWait(); completed.add(0, 0, .nonSpeech) }
        release.signal()
        try require(completed.values.isEmpty, "Stop cannot return while either source is still loading its owned VAD")
        release.signal()
        await stopped.value
        try require(completed.values.count == 1, "Both source model loads join before stop returns")
        print("PASS joined two-source VAD preparation and cleanup")
    }

    static func main() async throws {
        try await independentPhysicalSourceEvidence()
        try await joinedPhysicalSourceStop()
        try await nativeCaptureFormats()
        try await sourceIsolation()
        if let model = ProcessInfo.processInfo.environment["PICHI_ACTIVITY_TEST_MODEL"],
           let speech = ProcessInfo.processInfo.environment["PICHI_ACTIVITY_TEST_SYNTHETIC_SPEECH"] {
            try await realModelAcceptance(model: URL(fileURLWithPath: model), speech: URL(fileURLWithPath: speech))
        }
        try await budgetRecovery()
        try await delayedRightTail()
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
        try require(!worker.confidentlyNonSpeech(start: 0, end: 0.000_000_1)
                    && !worker.confidentlyNonSpeech(start: 20, end: 20.000_000_1),
                    "Sub-microsecond unknown/unscored ranges cannot manufacture silence through rounding tolerance")
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

    static func nativeCaptureFormats() async throws {
        for (rate, channels, interleaved) in [(16_000.0, 1, false), (44_100, 1, false),
                                             (48_000, 2, true), (48_000, 3, false)] {
            let script = Script([])
            let events = Events()
            let worker = MeetingCaptureSpeechActivityWorker(factory: { ScriptedModel(script: script) }, publish: events.add)
            let packet = Int(rate * 0.256)
            for index in 0..<8 {
                let start = 2 + Double(index * packet) / rate
                worker.offer(try input(0.02, start: 600 + start, count: packet,
                    sampleRate: rate, channels: AVAudioChannelCount(channels), interleaved: interleaved), start: start)
                // Feed faster than real time without deliberately saturating the bounded
                // intake. The separate overflow probe owns saturation/unknown semantics.
                if index > 0 { try await wait(events, count: index) }
            }
            try await wait(events, count: rate == 16_000 ? 8 : 7, context: "native \(rate)/\(channels)/\(interleaved)")
            try require(abs(events.values[0].0 - 2) < 0.000_001,
                        "Native normalization preserves capture-relative clock rather than host PTS")
            try require(events.values[0].2 == .unknown && events.values.dropFirst().allSatisfy { $0.2 == .nonSpeech },
                        "Every native format reaches the existing detector after one warmup")
            try require(worker.confidentlyNonSpeech(start: 2.256, end: 3.5), "Resampled evidence stays on the original source timeline")
            let prior = events.values.count
            let nativeEnd = 2 + Double(8 * packet) / rate
            worker.offer(try input(0, start: 600 + nativeEnd, sampleRate: 16_000), start: nativeEnd)
            try await wait(events, count: prior + 1)
            if rate != 16_000 || channels != 1 {
                try require(events.values.last!.2 == .unknown && script.resetFlags.last == true,
                            "A contiguous native format change resets recurrent and resampling state")
            }
            worker.stop(); await worker.join()
        }
        print("PASS native 16/44.1/48k, mono/stereo/three-channel planar/interleaved, source PTS and format reset")
    }

    static func sourceIsolation() async throws {
        let capture = MeetingPendingSpeechCapture(originBox: MeetingLiveOriginBox(), activityModel: { Fake() }, activitySources: [.you, .them], onUpdate: { _ in })
        for index in 0..<8 {
            let start = Double(index) * 0.256
            capture.offer(kind: .microphone, sampleBuffer: try input(0.02, start: 600 + start))
            capture.offer(kind: .applicationAudio, sampleBuffer: try input(0.99, start: 600 + start))
            try await Task.sleep(for: .milliseconds(2))
        }
        var snapshot = capture.reconcile(visible: .empty)
        for _ in 0..<2000 {
            snapshot = capture.reconcile(visible: .empty)
            if snapshot.activityBySource[.you] == .nonSpeech,
               snapshot.tokens.contains(where: { $0.source == .them }),
               capture.confidentlyNonSpeech(start: 0.256, end: 1.5) { break }
            try await Task.sleep(for: .milliseconds(1))
        }
        try require(snapshot.activityBySource[.you] == .nonSpeech && !snapshot.tokens.isEmpty
                    && snapshot.tokens.allSatisfy { $0.source == .them },
                    "Quiet microphone cannot inherit application speech or mint waves through the scalar fallback")
        // Latest activity may arrive before the worker has scored the complete requested interval.
        // Use its existing bounded coverage acknowledgement rather than assuming two milliseconds drained it.
        let quietCoverage = await capture.awaitConfidentNonSpeech(start: 0.256, end: 1.5)
        try require(quietCoverage,
                    "Application speech does not contaminate microphone-only negative evidence")
        await capture.stopAndWait()
        try require(capture.reconcile(visible: .empty).tokens.isEmpty, "Both source workers join and close with the capture")
        print("PASS independent source models, quiet microphone, application speech and joined source teardown")
    }

    /// Opt-in real model check. Inputs are the pinned public VAD and locally synthesized
    /// speech only; it never opens the microphone or the user's recording/history store.
    static func realModelAcceptance(model: URL, speech: URL) async throws {
        func run(_ values: [Float], rate: Double) async throws -> [(Double, Double, MeetingSpeechActivity)] {
            let events = Events(), loaded = Events()
            let worker = MeetingCaptureSpeechActivityWorker(factory: {
                let result = try MeetingLocalSileroActivityModel(modelURL: model)
                loaded.add(0, 0, .unknown)
                return result
            }, publish: events.add)
            do {
                try await wait(loaded, count: 1)
                let packet = Int(rate * 0.256)
                for offset in stride(from: 0, to: values.count, by: packet) {
                    let count = min(packet, values.count - offset)
                    worker.offer(try input(0, start: 600 + Double(offset) / rate, count: count,
                        sampleRate: rate, channels: 2, interleaved: true, signal: { values[offset + $0] }),
                        start: Double(offset) / rate)
                    // The final native packet and converter tail may be shorter than a
                    // complete real model window. Never pad it or wait for a fake score.
                    let complete = max(0, Int((Double(offset + count) / rate / 0.256).rounded(.down)) - 1)
                    if complete > 0 { try await wait(events, count: complete) }
                }
                worker.stop(); await worker.join()
                return events.values
            } catch { worker.stop(); await worker.join(); throw error }
        }
        var random: UInt64 = 19
        var lowPass: Float = 0
        let noise: [Float] = (0..<192_000).map { frame in
            random = random &* 6_364_136_223_846_793_005 &+ 1
            let white = Float((random >> 40) & 0xFF_FFFF) / Float(0xFF_FFFF) * 2 - 1
            lowPass = 0.85 * lowPass + 0.15 * white
            let t = Double(frame) / 48_000
            // A modulated mechanical tone plus seeded filtered noise, with no speech.
            return 0.04 * lowPass + Float((0.025 + 0.015 * sin(t * 6 * .pi)) * sin(t * 440 * .pi))
        }
        let legacy = MeetingPendingSpeechCapture(originBox: MeetingLiveOriginBox(), onUpdate: { _ in })
        for offset in stride(from: 0, to: noise.count, by: 960) {
            legacy.offer(kind: .microphone, sampleBuffer: try input(0, start: Double(offset) / 48_000,
                count: 960, sampleRate: 48_000, channels: 2, interleaved: true, signal: { noise[offset + $0] }))
        }
        try require(!legacy.reconcile(visible: .empty).tokens.isEmpty, "Negative control reproduces false waves from modulated mechanical noise")
        await legacy.stopAndWait()
        let noiseEvents = try await run(noise, rate: 48_000)
        try require(noiseEvents.count >= 12 && !noiseEvents.contains { $0.2 == .speech },
                    "The actual VAD rejects noise that triggers the old heuristic")
        let file = try AVAudioFile(forReading: speech)
        try require(file.length > 0 && Double(file.length) / file.processingFormat.sampleRate <= 30,
                    "Synthetic speech fixture is bounded to thirty seconds")
        var speechSamples: [Float] = []
        while file.framePosition < file.length {
            let pcm = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 4096)!
            try file.read(into: pcm, frameCount: 4096)
            let mono = try MeetingCapturePCMConverter.ownedMonoCopy(of: pcm)
            speechSamples.append(contentsOf: UnsafeBufferPointer(start: mono.floatChannelData![0], count: Int(mono.frameLength)))
        }
        for attenuation: Float in [1, 0.25] {
            let input = speechSamples.map { $0 * attenuation } + [Float](repeating: 0, count: Int(file.processingFormat.sampleRate * 2))
            let events = try await run(input, rate: file.processingFormat.sampleRate)
            try require(events.contains { $0.2 == .speech }, "Real VAD keeps ordinary and four-times-attenuated synthetic speech")
            try require(events.suffix(3).allSatisfy { $0.2 == .nonSpeech }, "Real VAD stops activity after speech gives way to silence")
        }
        print("PASS real pinned VAD: legacy noise false-positive reproduced and rejected, ordinary/quiet synthetic speech retained, trailing silence inactive")
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
            try require(frame.budgetExceeded && (index == 0 ? frame.unknown == .contextWarmup : frame.probability == 0),
                        "late valid output is measured after fresh warmup")
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
        try require(script.resetFlags == [true, false, false, true, false], "late valid calls preserve recurrence until actual cooldown")
        print("PASS valid late quiet telemetry, preserved recurrence, bounded cooldown and fresh-context recovery")

        let speech = Script([.probability(0, seconds: 0.2), .probability(0.99, seconds: 0.2)])
        var speechDetector = MeetingSpeechActivityDetector(model: ScriptedModel(script: speech), clock: { speech.now })
        let lateWarmup = speechDetector.process(samples: samples, valid: valid, start: 0, session: session, epoch: 0, route: "mic")
        let lateSpeech = speechDetector.process(samples: samples, valid: valid, start: 0.256, session: session, epoch: 0, route: "mic")
        try require(lateWarmup.unknown == .contextWarmup && lateWarmup.budgetExceeded && lateWarmup.probability == nil,
                    "late initial warmup remains unknown")
        try require(lateSpeech.probability == 0.99 && lateSpeech.active == true && lateSpeech.unknown == nil && lateSpeech.budgetExceeded,
                    "late speech remains speech and cannot suppress recognition")
        try require(speech.resetFlags == [true, false], "wall contention does not reset valid speech recurrence")
        var invalidClockCalls = 0
        let clockScript = Script([])
        var invalidClock = MeetingSpeechActivityDetector(model: ScriptedModel(script: clockScript), clock: {
            invalidClockCalls += 1; return invalidClockCalls == 1 ? 0 : .nan
        })
        try require(invalidClock.process(samples: samples, valid: valid, start: 0, session: session, epoch: 0,
                    route: "mic").unknown == .invalidClock, "invalid post-inference clock never classifies")
        try require(invalidClock.process(samples: samples, valid: valid, start: 0.256, session: session, epoch: 0,
                    route: "mic").unknown == .invalidClock && clockScript.resetFlags.count == 1,
                    "invalid initial clock cannot run another prediction")
        print("PASS late speech, late warmup and invalid monotonic clock safety")

        let slow = Script(Array(repeating: .probability(0, seconds: 0.2), count: 100))
        var throttled = MeetingSpeechActivityDetector(model: ScriptedModel(script: slow), clock: { slow.now })
        var cooling = 0
        for index in 0..<93 {
            let frame = throttled.process(samples: samples, valid: valid, start: Double(index) * 0.256,
                                          session: session, epoch: 0, route: "mic")
            try require((index == 1 || index == 2 ? frame.probability == 0 : frame.probability == nil)
                        && frame.unknown != .disabled, "only measured frames classify; repeated slow recovery warmup stays unknown")
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
        let newSession = throttled.process(samples: samples, valid: valid, start: 0,
                    session: UUID(), epoch: 0, route: "mic")
        try require(newSession.unknown == .contextWarmup && newSession.budgetExceeded,
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
        try require(recovered.values.enumerated().allSatisfy { index, event in
                        event.2 == ([1, 2, 12].contains(index) ? .nonSpeech : .unknown)
                    }, "worker publishes valid late quiet and excludes cooldown/warmup")
        try require(!worker.confidentlyNonSpeech(start: 0, end: 12 * 0.256)
                    && !worker.confidentlyNonSpeech(start: 3 * 0.256, end: 11 * 0.256),
                    "cooldown and warmup ranges never authorize ASR suppression")
        try require(worker.confidentlyNonSpeech(start: 0.256, end: 0.768), "valid late quiet coverage can authorize ASR suppression")
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

    static func delayedRightTail() async throws {
        for tailProbability in [Float(0), 0.99, 0.5] {
            let events = Events()
            let worker = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: events.add)
            for index in 0..<2 {
                let start = Double(index) * 0.256
                worker.offer(try input(0, start: start), start: start)
                try await wait(events, count: index + 1)
            }
            try require(!worker.confidentlyNonSpeech(start: 0.256, end: 0.768), "sync assessment never invents the missing frame")
            let delayed = Task {
                try await Task.sleep(for: .milliseconds(40))
                worker.offer(try input(tailProbability, start: 0.512), start: 0.512)
            }
            let began = ProcessInfo.processInfo.systemUptime
            let accepted = await worker.awaitConfidentNonSpeech(start: 0.256, end: 0.768)
            try await delayed.value
            try require(accepted == (tailProbability == 0), "only a measured quiet right frame completes the negative proof")
            try require(ProcessInfo.processInfo.systemUptime - began >= 0.03, "query waited for the actual frame")
            worker.stop(); await worker.join()
        }
        print("PASS async negative proof waits for one delayed real frame and rejects speech/unknown")

        // One queued capture block plus the partial neural frame can leave more than one
        // 256ms frame unscored. Waiting never grants proof until both real frames arrive.
        for tailProbability in [Float(0), 0.99, 0.5] {
            let events = Events()
            let worker = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: events.add)
            for index in 0..<4 {
                let start = Double(index) * 0.256
                worker.offer(try input(0, start: start), start: start)
                try await wait(events, count: index + 1)
            }
            try require(worker.confidentlyNonSpeech(start: 0.768, end: 1.024), "measured quiet prefix is eligible for a bounded right-tail wait")
            try require(!worker.confidentlyNonSpeech(start: 0.768, end: 1.36), "336ms missing right tail cannot supply negative proof")
            let delayed = Task {
                try await Task.sleep(for: .milliseconds(40))
                worker.offer(try input(0, start: 1.024), start: 1.024)
                try await wait(events, count: 5)
                try require(!worker.confidentlyNonSpeech(start: 0.768, end: 1.36), "first arriving frame still leaves an unscored right edge")
                try await Task.sleep(for: .milliseconds(40))
                worker.offer(try input(tailProbability, start: 1.28), start: 1.28)
            }
            let began = ProcessInfo.processInfo.systemUptime
            let accepted = await worker.awaitConfidentNonSpeech(start: 0.768, end: 1.36)
            let elapsed = ProcessInfo.processInfo.systemUptime - began
            try await delayed.value
            try require(accepted == (tailProbability == 0), "two delayed frames complete proof only if the entire right tail is measured quiet")
            try require(elapsed >= 0.06 && elapsed < 0.35, "two-frame right tail resolves inside the unchanged 350ms budget")
            worker.stop(); await worker.join()
        }
        print("PASS bounded negative proof waits across capture-block and partial-frame lag, rejecting new speech/unknown")

        let missingEvents = Events()
        let missingWorker = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: missingEvents.add)
        for index in 0..<4 {
            let start = Double(index) * 0.256
            missingWorker.offer(try input(0, start: start), start: start)
            try await wait(missingEvents, count: index + 1)
        }
        let missingBegan = ProcessInfo.processInfo.systemUptime
        try require(!(await missingWorker.awaitConfidentNonSpeech(start: 0.768, end: 1.36)),
                    "two-frame eligibility never turns a missing tail into measured silence")
        let missingElapsed = ProcessInfo.processInfo.systemUptime - missingBegan
        try require(missingElapsed >= 0.34 && missingElapsed < 1.5, "missing two-frame tail retains the 350ms timeout")
        missingWorker.stop(); await missingWorker.join()

        let events = Events()
        let worker = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: events.add)
        for index in 0..<3 {
            let start = Double(index) * 0.256
            worker.offer(try input(index == 2 ? 0.5 : 0, start: start), start: start)
            try await wait(events, count: index + 1)
        }
        for range in [(0.0, 0.512), (0.256, 1.024), (0.8, 1.0), (0.256, 2.0)] {
            let began = ProcessInfo.processInfo.systemUptime
            try require(!(await worker.awaitConfidentNonSpeech(start: range.0, end: range.1)),
                        "warmup, unknown, empty coverage and large tail never wait into silence proof")
            try require(ProcessInfo.processInfo.systemUptime - began < 0.2, "ineligible coverage returns before the wait budget")
        }
        worker.stop(); await worker.join()

        let timeoutEvents = Events()
        let timeoutWorker = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: timeoutEvents.add)
        for index in 0..<2 {
            let start = Double(index) * 0.256
            timeoutWorker.offer(try input(0, start: start), start: start)
            try await wait(timeoutEvents, count: index + 1)
        }
        let tooLarge = ProcessInfo.processInfo.systemUptime
        try require(!(await timeoutWorker.awaitConfidentNonSpeech(start: 0.256, end: 1.025)),
                    "an entirely quiet prefix cannot wait for more than two missing frames")
        try require(ProcessInfo.processInfo.systemUptime - tooLarge < 0.2, "oversized quiet tail returns without polling")
        let began = ProcessInfo.processInfo.systemUptime
        try require(!(await timeoutWorker.awaitConfidentNonSpeech(start: 0.256, end: 0.768)), "unreceived tail times out without false skip")
        let elapsed = ProcessInfo.processInfo.systemUptime - began
        try require(elapsed >= 0.34 && elapsed < 1.5, "wait has a bounded 350ms budget")
        let stopping = Task { await timeoutWorker.awaitConfidentNonSpeech(start: 0.256, end: 0.768) }
        try await Task.sleep(for: .milliseconds(15))
        let stopped = ProcessInfo.processInfo.systemUptime
        timeoutWorker.stop()
        try require(!(await stopping.value) && ProcessInfo.processInfo.systemUptime - stopped < 0.2,
                    "Stop immediately invalidates an active negative proof wait")
        await timeoutWorker.join()
        print("PASS ineligible evidence returns immediately, tail timeout never skips and Stop invalidates wait")

        let cancelEvents = Events()
        let cancelWorker = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: cancelEvents.add)
        for index in 0..<2 {
            let start = Double(index) * 0.256
            cancelWorker.offer(try input(0, start: start), start: start)
            try await wait(cancelEvents, count: index + 1)
        }
        let cancelling = Task { await cancelWorker.awaitConfidentNonSpeech(start: 0.256, end: 0.768) }
        try await Task.sleep(for: .milliseconds(15)); cancelling.cancel()
        try require(!(await cancelling.value), "task cancellation cannot grant a pending negative proof")
        let sourceReset = Task { await cancelWorker.awaitConfidentNonSpeech(start: 0.256, end: 0.768) }
        try await Task.sleep(for: .milliseconds(15))
        cancelWorker.offer(try input(0, start: 3), start: 3)
        try require(!(await sourceReset.value), "source gap invalidates pinned evidence generation")
        cancelWorker.stop(); await cancelWorker.join()
        print("PASS negative proof task cancellation and source reset")
    }
}
