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
        let events = Events()
        let worker = MeetingCaptureSpeechActivityWorker(factory: { Fake() }, publish: events.add)
        for (i, value) in [Float(0), 0, 0.5, 0.99, -1, 0].enumerated() {
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
}
