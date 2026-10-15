import AVFoundation
import CoreMedia
import Foundation

// Headless test context for the production live-model file. No app host, audio hardware,
// model weights, transcript store or privacy service is constructed by this probe.
nonisolated enum MeetingAudioTrackKind: Sendable { case microphone, applicationAudio }
nonisolated enum MeetingEchoDetector {
    static func isLikelyEcho(micText: String, remoteText: String) -> Bool { false }
}

@main
struct MeetingPendingSpeechProjectionTests {
    static func require(_ value: Bool, _ description: String) throws {
        if !value { throw NSError(domain: "PendingCapture", code: 1, userInfo: [NSLocalizedDescriptionKey: description]) }
    }
    static func feed(_ projection: inout MeetingPendingSpeechProjection, start: Double = 0,
                     duration: Double, source: MeetingLiveSpeaker = .you,
                     rms: (Double) -> Float, crossing: Float = 0.12, crest: Float = 3) {
        for frame in 0..<Int((duration / 0.02).rounded()) {
            let time = start + Double(frame) * 0.02
            let level = rms(time)
            projection.observe(source: source, start: time, end: time + 0.02,
                rms: level, peak: level * crest, zeroCrossingRate: crossing)
        }
    }
    static func speech(_ time: Double) -> Float { 0.018 + 0.011 * Float(sin(time * 2 * .pi * 3)) }
    static func main() throws {
        var speech = MeetingPendingSpeechProjection()
        var first: Double?
        for frame in 0..<400 {
            let time = Double(frame) * 0.02, level = Self.speech(time)
            speech.observe(source: .you, start: time, end: time + 0.02, rms: level, peak: level * 3, zeroCrossingRate: 0.12)
            if first == nil, !speech.snapshot.tokens.isEmpty { first = time + 0.02 }
        }
        try require(first != nil && first! <= 0.8, "Sustained speech candidate gives visible progress within 0.8s")
        try require((12...20).contains(speech.snapshot.tokens.count), "Cadence is bounded around 150 visual words/minute")
        try require(Set(speech.snapshot.tokens.map(\.id)).count == speech.snapshot.tokens.count, "Token IDs remain unique")
        try require(Set(speech.snapshot.tokens.map(\.widthHint)).count > 3, "Variable widths are deterministic")
        print("PASS speech onset, cadence and identity")
        for (name, level, crossing, crest) in [("silence", Float(0), Float(0), Float(0)),
            ("steady fan", 0.02, 0.12, 3), ("steady tone", 0.02, 0.04, 1.5), ("broadband hiss", 0.02, 0.5, 3)] {
            var projection = MeetingPendingSpeechProjection()
            feed(&projection, duration: 4, rms: { _ in level }, crossing: crossing, crest: crest)
            try require(projection.snapshot.tokens.isEmpty, "\(name) must not mint pending words")
            print("PASS \(name) rejection")
        }
        var clicks = MeetingPendingSpeechProjection()
        feed(&clicks, duration: 4, rms: { time in Int((time / 0.02).rounded()) % 50 == 0 ? 0.02 : 0 }, crest: 12)
        try require(clicks.snapshot.tokens.isEmpty, "Isolated clicks cannot mint progress")
        var hiss = MeetingPendingSpeechProjection()
        feed(&hiss, duration: 4, rms: Self.speech, crossing: 0.5)
        try require(hiss.snapshot.tokens.isEmpty, "Modulated high-frequency hiss cannot mint progress")
        print("PASS impulse and modulated hiss rejection")
        var roomNoise = MeetingPendingSpeechProjection()
        feed(&roomNoise, duration: 20, rms: { time in 0.0025 + 0.0015 * Float(sin(time * 2 * .pi * 3)) })
        try require(roomNoise.snapshot.tokens.isEmpty, "Quiet variable room noise must not mint words")
        var bumps = MeetingPendingSpeechProjection()
        feed(&bumps, duration: 20, rms: { time in
            time.truncatingRemainder(dividingBy: 1) < 0.24 ? Self.speech(time) : 0.001
        })
        try require(bumps.snapshot.tokens.isEmpty, "Separated short bumps must not accumulate cadence debt")
        print("PASS raised quiet threshold and separated bump rejection")
        var quietSpeech = MeetingPendingSpeechProjection()
        feed(&quietSpeech, duration: 8, rms: { Self.speech($0) * 0.25 })
        try require(quietSpeech.snapshot.tokens.count >= 3, "Speech attenuated four times must still show pending capture")
        var consonants = MeetingPendingSpeechProjection()
        for frame in 0..<400 {
            let time = Double(frame) * 0.02, level = Self.speech(time)
            consonants.observe(source: .you, start: time, end: time + 0.02, rms: level,
                peak: level * 3, zeroCrossingRate: frame % 8 < 2 ? 0.5 : 0.12)
        }
        try require(consonants.snapshot.tokens.count >= 3, "Short consonants cannot reset every voiced syllable")
        print("PASS attenuated speech and short consonants")
        let original = speech.snapshot.tokens
        feed(&speech, start: 8, duration: 2, rms: { _ in 0 })
        try require(speech.snapshot.tokens == original, "A pause neither adds nor erases waiting audio")
        feed(&speech, start: 10, duration: 2, rms: Self.speech)
        try require(speech.snapshot.tokens.starts(with: original), "Resuming preserves prior stable identities")
        print("PASS pause and resume")
        let beforeQuiet = speech.snapshot.tokens
        var bumpsAfterSpeech = speech
        feed(&bumpsAfterSpeech, start: 12, duration: 20, rms: { time in
            (time - 12).truncatingRemainder(dividingBy: 1) < 0.24 ? Self.speech(time) : 0.001
        })
        try require(bumpsAfterSpeech.snapshot.tokens.starts(with: beforeQuiet)
                    && bumpsAfterSpeech.snapshot.tokens.count <= beforeQuiet.count + 1,
                    "Noise bumps cannot erase earlier speech or accumulate waves across quiet gaps")
        var isolatedDuringQuiet = speech
        feed(&isolatedDuringQuiet, start: 12, duration: 6, rms: { time in
            Int(((time - 12) / 0.02).rounded()) % 50 == 0 ? 0.02 : 0.001
        }, crest: 12)
        try require(isolatedDuringQuiet.snapshot.tokens == beforeQuiet, "Clicks cannot clear waiting speech or mint more waves")
        feed(&speech, start: 12, duration: 6, rms: { _ in 0.001 })
        try require(!beforeQuiet.isEmpty && speech.snapshot.tokens == beforeQuiet, "Quiet must retain speech until visible text covers it")
        var lateText = MeetingLiveTranscriptSnapshot.empty
        lateText.revision = 1
        lateText.utterances = [.init(id: UUID(), speaker: .you, text: "Late approved words", start: 0, end: 12)]
        speech.reconcile(visible: lateText)
        try require(speech.snapshot.tokens.isEmpty, "Late approved text replaces exactly the earlier captured speech")
        feed(&speech, start: 18, duration: 2, rms: Self.speech)
        try require(!speech.snapshot.tokens.isEmpty && speech.snapshot.tokens.allSatisfy { $0.start >= 18 },
                    "Resumed speech starts fresh after approved coverage")
        print("PASS quiet waiting, late text replacement and fresh speech")
        var cap = MeetingPendingSpeechProjection()
        feed(&cap, duration: 120, rms: Self.speech)
        try require(cap.snapshot.tokens.count == 64, "Long recognition delays keep exactly the bounded token cap")
        let captured = cap.snapshot.tokens
        var visible = MeetingLiveTranscriptSnapshot.empty
        visible.revision = 1
        visible.utterances = [.init(id: UUID(), speaker: .you, text: "Approved synthetic caption", start: 0, end: 3)]
        cap.reconcile(visible: visible)
        try require(cap.snapshot.tokens.map(\.id) == captured.filter { $0.end > 3 }.map(\.id)
                    && cap.snapshot.tokens.allSatisfy { $0.start >= 3 },
                    "Timed recognition replaces only its captured coverage and retains an uncovered boundary")
        print("PASS bounded state and timed replacement")
        var partials = MeetingPendingSpeechProjection()
        feed(&partials, duration: 4, rms: Self.speech)
        let before = partials.snapshot.tokens, turnID = UUID()
        var partial = MeetingLiveTranscriptSnapshot.empty
        partial.revision = 1
        partial.partials[.you] = .init(id: turnID, text: "Approved words", start: 0)
        partials.reconcile(visible: partial)
        try require(partials.snapshot.tokens == before, "Untimed partial must not erase unknown audio coverage")
        partial.revision = 2
        partial.partials[.you]?.end = 1.5
        partials.reconcile(visible: partial)
        try require(partials.snapshot.tokens.map(\.id) == before.filter { $0.end > 1.5 }.map(\.id), "Timed partial replaces only processed coverage")
        try require(partials.snapshot.tokens.allSatisfy { $0.start >= 1.5 }, "A boundary-straddling estimate retains only uncovered audio")
        partial.revision = 3
        partial.partials[.you]?.text = String(repeating: "Approved word ", count: 80)
        partials.reconcile(visible: partial)
        try require(partials.snapshot.tokens.map(\.id) == before.filter { $0.end > 1.5 }.map(\.id), "Many delayed words cannot erase newly captured audio")
        let afterGrowth = partials.snapshot
        partial.revision = 2
        partial.partials[.you]?.text = "Older revision with many invented words"
        partials.reconcile(visible: partial)
        try require(partials.snapshot == afterGrowth, "Late recognition revisions cannot erase progress")
        print("PASS timed partial coverage and stale revisions")
        partial.revision = 4
        partial.utterances = (0..<200).map { _ in
            .init(id: UUID(), speaker: .you, text: "Older approved turn", start: 0, end: 0.1)
        }
        partial.partials[.you]?.text = "Approved words now"
        partials.reconcile(visible: partial)
        partial.revision = 5
        partial.partials[.you] = .init(id: turnID, text: "Next window", start: 1.5, end: 3)
        partials.reconcile(visible: partial)
        try require(partials.snapshot.tokens.map(\.id) == before.filter { $0.end > 3 }.map(\.id), "Reused preview identity with fewer words still replaces the next window")
        let afterNextWindow = partials.snapshot.tokens
        print("PASS next-window and long-session partial coverage")
        var empty = MeetingLiveTranscriptSnapshot.empty
        empty.revision = 6
        partials.reconcile(visible: empty)
        try require(partials.snapshot.tokens == afterNextWindow, "Empty or privacy-held recognition leaves pending capture visible")
        print("PASS held privacy and empty hypotheses")
        var sources = MeetingPendingSpeechProjection()
        feed(&sources, duration: 3, rms: Self.speech)
        feed(&sources, duration: 3, source: .them, rms: Self.speech)
        let them = sources.snapshot.tokens.filter { $0.source == .them }
        var quietSource = sources
        feed(&quietSource, start: 3, duration: 6, rms: { _ in 0 })
        try require(quietSource.snapshot.tokens == sources.snapshot.tokens, "Quiet cannot erase either source before recognition")
        print("PASS source-specific quiet waiting")
        visible.revision = 2
        visible.utterances[0].end = 4
        sources.reconcile(visible: visible)
        try require(sources.snapshot.tokens == them, "Microphone captions cannot clear the other source")
        print("PASS source-specific coverage")
        let revision = sources.snapshot.revision
        sources.observe(source: .them, start: 0, end: 0.02, rms: 0.02, peak: 0.04, zeroCrossingRate: 0.1)
        sources.observe(source: .them, start: .nan, end: 4, rms: 0.02, peak: 0.04, zeroCrossingRate: 0.1)
        try require(sources.snapshot.revision == revision, "Duplicate and invalid timestamps cannot mint progress")
        sources.stop()
        feed(&sources, start: 4, duration: 4, rms: Self.speech)
        try require(sources.snapshot.tokens.isEmpty && !sources.snapshot.isCapturing, "Stopped generations cannot resurrect progress")
        print("PASS invalid PTS, duplicates and terminal intake")
        try testDelayedReplacementDiagnostics()
        try testCaptureTee()
    }

    static func testDelayedReplacementDiagnostics() throws {
        final nonisolated class Receipt: @unchecked Sendable {
            private let lock = NSLock()
            private var events: [MeetingPendingSpeechProjection.DiagnosticEvent] = []
            func append(_ event: MeetingPendingSpeechProjection.DiagnosticEvent) { lock.withLock { events.append(event) } }
            func values() -> [MeetingPendingSpeechProjection.DiagnosticEvent] { lock.withLock { events } }
        }
        let receipt = Receipt()
        var projection = MeetingPendingSpeechProjection(diagnostics: { receipt.append($0) })
        feed(&projection, duration: 2, rms: Self.speech)
        let original = projection.snapshot
        feed(&projection, start: 2, duration: 18, rms: { _ in 0.001 })
        try require(projection.snapshot == original, "Even an 18-second ASR delay cannot erase earlier speech during silence")
        let quiet = receipt.values()
        try require(quiet.filter { $0.kind == .quietWaiting }.count == 1, "One quiet transition produces one diagnostic, not a PCM-frame log flood")
        try require(!quiet.contains { $0.kind == .replaced }, "Quiet is never logged as replacement")
        var held = MeetingLiveTranscriptSnapshot.empty
        held.revision = 1
        projection.reconcile(visible: held)
        try require(projection.snapshot == original, "An empty/privacy-held update cannot remove pending audio")
        held.revision = 2
        held.partials[.you] = .init(id: UUID(), text: "SYNTHETIC_CONTENT_MUST_NOT_ENTER_DIAGNOSTICS", start: 0, end: 2)
        projection.reconcile(visible: held)
        try require(projection.snapshot.tokens.isEmpty, "Approved visible words replace the held interval")
        let events = receipt.values()
        let replaced = events.filter { $0.kind == .replaced }
        try require(replaced.flatMap(\.tokens).map(\.id) == original.tokens.map(\.id), "Diagnostic removal IDs match the actual replaced waveform IDs")
        try require(replaced.allSatisfy { $0.captionID == held.partials[.you]?.id && $0.start == 0 && $0.end == 2 }, "Replacement is correlated with the displayed caption and exact coverage")
        try require(events.allSatisfy { !$0.logFields.contains("SYNTHETIC_CONTENT_MUST_NOT_ENTER_DIAGNOSTICS") && $0.uptime.isFinite }, "Diagnostic fields contain timing and counts, never transcript content")
        projection.stop()
        try require(receipt.values().last?.kind == .stopped, "Terminal cleanup has an explicit reason distinct from replacement")
        print("PASS delayed speech replacement and bounded content-free diagnostics")
    }
    static func testCaptureTee() throws {
        final nonisolated class Receipt: @unchecked Sendable {
            let lock = NSLock(); var snapshots: [MeetingPendingSpeechSnapshot] = []
            func append(_ value: MeetingPendingSpeechSnapshot) { lock.withLock { snapshots.append(value) } }
        }
        for (sampleRate, frames, channels) in [(Double(16_000), 640, 1), (Double(48_000), 1024, 2)] {
            let receipt = Receipt()
            let capture = MeetingPendingSpeechCapture(originBox: MeetingLiveOriginBox()) { receipt.append($0) }
            let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels), interleaved: false)!
            for chunk in 0..<100 {
                let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
                buffer.frameLength = AVAudioFrameCount(frames)
                for frame in 0..<frames {
                    let time = Double(chunk * frames + frame) / sampleRate
                    let value = Self.speech(time) * 1.414 * Float(sin(time * 2 * .pi * 250))
                    for channel in 0..<channels { buffer.floatChannelData![channel][frame] = value }
                }
                let sample = try sampleBuffer(buffer, pts: CMTime(seconds: 77 + Double(chunk * frames) / sampleRate,
                                                                 preferredTimescale: 1_000_000_000))
                capture.offer(kind: .microphone, sampleBuffer: sample)
            }
            // Even if UI delivery is delayed, only one scalar snapshot is scheduled, no PCM.
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
            try require(receipt.snapshots.count == 1, "Main-runloop publication is coalesced, not an unbounded callback queue")
            let snapshot = receipt.snapshots[0]
            let duration = Double(frames * 100) / sampleRate
            try require(!snapshot.tokens.isEmpty && snapshot.tokens.allSatisfy { $0.start >= 0 && $0.end <= duration + 0.01 },
                        "Native PCM tee uses capture-relative time even for non-divisible callback frames")
            let quiet = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames))!
            quiet.frameLength = AVAudioFrameCount(frames)
            for channel in 0..<channels {
                for frame in 0..<frames { quiet.floatChannelData![channel][frame] = 0.001 }
            }
            let quietChunkCount = Int((6 * sampleRate / Double(frames)).rounded(.up))
            for chunk in 0..<quietChunkCount {
                capture.offer(kind: .microphone, sampleBuffer: try sampleBuffer(quiet,
                    pts: CMTime(seconds: 77 + duration + Double(chunk * frames) / sampleRate,
                                preferredTimescale: 1_000_000_000)))
            }
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
            let afterQuiet = receipt.snapshots.last!
            // Non-divisible callbacks can finish one 20ms meter containing the
            // final speech samples. That mixed boundary is not six seconds of noise.
            try require(afterQuiet.tokens.starts(with: snapshot.tokens)
                        && afterQuiet.tokens.count <= snapshot.tokens.count + 1
                        && afterQuiet.tokens.allSatisfy { $0.end <= duration + 0.04 },
                        "Quiet retains speech, with at most its final mixed-meter boundary")
            let publicationCount = receipt.snapshots.count
            for chunk in quietChunkCount..<(quietChunkCount + 50) {
                capture.offer(kind: .microphone, sampleBuffer: try sampleBuffer(quiet,
                    pts: CMTime(seconds: 77 + duration + Double(chunk * frames) / sampleRate,
                                preferredTimescale: 1_000_000_000)))
            }
            CFRunLoopRunInMode(.defaultMode, 0.01, false)
            try require(receipt.snapshots.count == publicationCount,
                        "Entirely quiet PCM cannot mint waves or trigger repeated UI publication")
            var approved = MeetingLiveTranscriptSnapshot.empty
            approved.revision = 1
            approved.utterances = [.init(id: UUID(), speaker: .you, text: "Approved captured speech", start: 0, end: duration + 0.04)]
            try require(capture.reconcile(visible: approved).tokens.isEmpty,
                        "The capture tee retires its held waves only when visible words cover that audio")
            capture.stop()
            print("PASS native \(Int(sampleRate))Hz \(channels)-channel speech/quiet PCM and bounded UI publication")
        }
    }
    static func sampleBuffer(_ buffer: AVAudioPCMBuffer, pts: CMTime) throws -> CMSampleBuffer {
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: buffer.format.streamDescription,
            layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &description)
        try require(status == noErr && description != nil, "Synthetic PCM description")
        var sample: CMSampleBuffer?
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(buffer.format.sampleRate)), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        let create = CMSampleBufferCreate(allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: false,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: description, sampleCount: Int(buffer.frameLength),
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample)
        try require(create == noErr && sample != nil, "Synthetic PCM sample buffer")
        let data = CMSampleBufferSetDataBufferFromAudioBufferList(sample!, blockBufferAllocator: kCFAllocatorDefault,
            blockBufferMemoryAllocator: kCFAllocatorDefault, flags: 0, bufferList: buffer.audioBufferList)
        try require(data == noErr && CMSampleBufferSetDataReady(sample!) == noErr, "Synthetic PCM readiness")
        return sample!
    }
}
