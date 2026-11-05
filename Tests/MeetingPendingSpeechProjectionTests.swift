import AVFoundation
import CoreMedia
import Foundation

// Headless test context for the production live-model file. No app host, audio hardware,
// model weights, transcript store or privacy service is constructed by this probe.
typealias SessionSpeakerID = UUID
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
        try testReadableParticipantContinuity()
        try testReadableParticipantCorrectionsAndSources()
        try testElapsedParticipantTurnTimes()
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
        func confirmedSpeech(_ projection: inout MeetingPendingSpeechProjection, from: Double, seconds: Double) {
            for frame in 0..<Int((seconds / 0.02).rounded()) {
                let start = from + Double(frame) * 0.02
                projection.observeSpeechActivity(source: .you, start: start, end: start + 0.02, activity: .speech)
            }
        }
        var processed = MeetingPendingSpeechProjection()
        confirmedSpeech(&processed, from: 0, seconds: 20)
        let queuedSpeech = processed.snapshot.tokens
        for frame in 0..<1_000 {
            let start = 20 + Double(frame) * 0.02
            processed.observeSpeechActivity(source: .you, start: start, end: start + 0.02, activity: .nonSpeech)
        }
        try require(processed.snapshot.tokens == queuedSpeech, "Quiet cannot hide outstanding speech before processing")
        var protected = MeetingLiveTranscriptSnapshot.empty
        protected.revision = 1
        processed.reconcile(visible: protected)
        processed.acknowledgeProtectedSource(source: .them, throughSample: 640_000, transcriptRevision: 1)
        try require(processed.snapshot.tokens == queuedSpeech, "Another source cannot retire microphone waves")
        processed.acknowledgeProtectedSource(source: .you, throughSample: 3_200, transcriptRevision: 1)
        try require(processed.snapshot.tokens.first?.id == queuedSpeech.first?.id
            && processed.snapshot.tokens.first?.start == 0.2,
            "A partial acknowledged prefix must trim its token and preserve identity")
        processed.acknowledgeProtectedSource(source: .you, throughSample: 640_000, transcriptRevision: 0)
        try require(!processed.snapshot.tokens.isEmpty, "A stale transcript cannot acknowledge processed audio")
        processed.acknowledgeProtectedSource(source: .you, throughSample: 640_000, transcriptRevision: 1)
        try require(processed.snapshot.tokens.isEmpty, "Joined protected progress must retire every processed speech estimate")
        processed.acknowledgeProtectedSource(source: .you, throughSample: 0, transcriptRevision: 1)
        confirmedSpeech(&processed, from: 40, seconds: 2)
        try require(!processed.snapshot.tokens.isEmpty
            && processed.snapshot.tokens.allSatisfy { $0.start >= 40 && !queuedSpeech.map(\.id).contains($0.id) },
            "New speech must mint new IDs after complete quiet catch-up")
        var delayed = MeetingPendingSpeechProjection()
        delayed.reconcile(visible: protected)
        delayed.acknowledgeProtectedSource(source: .you, throughSample: 640_000, transcriptRevision: 1)
        confirmedSpeech(&delayed, from: 0, seconds: 40)
        try require(delayed.snapshot.tokens.isEmpty, "Delayed detector output cannot recreate already processed speech")
        var bounded = MeetingPendingSpeechProjection()
        confirmedSpeech(&bounded, from: 0, seconds: 30)
        let boundedIDs = bounded.snapshot.tokens.map(\.id)
        confirmedSpeech(&bounded, from: 30, seconds: 30)
        try require(bounded.snapshot.tokens.count == MeetingPendingSpeechProjection.maximumTokens
            && bounded.snapshot.tokens.map(\.id) == boundedIDs
            && bounded.snapshot.tokens.last!.end > 59,
            "A full wave budget must extend an existing source range without dropping later queued audio")
        bounded.reconcile(visible: protected)
        let lastID = bounded.snapshot.tokens.last!.id
        bounded.acknowledgeProtectedSource(source: .you, throughSample: 640_000, transcriptRevision: 1)
        try require(bounded.snapshot.tokens.count == 1 && bounded.snapshot.tokens[0].id == lastID
            && bounded.snapshot.tokens[0].start == 40 && bounded.snapshot.tokens[0].end > 59,
            "Partial progress must preserve the unprocessed suffix of a coalesced range")
        print("PASS20s speech/20s quiet protected-prefix retirement, trim, stale/source guards, delayed VAD and64-token coalescing")
        var emptyFinal = MeetingPendingSpeechProjection()
        confirmedSpeech(&emptyFinal, from: 0, seconds: 4)
        feed(&emptyFinal, duration: 4, source: .them, rms: Self.speech)
        let beforeEmptyFinal = emptyFinal.snapshot.tokens
        emptyFinal.acknowledgeEmptyRecognition(source: .you, start: 0.6, end: 2.2)
        let remainingEmptyFinal = emptyFinal.snapshot.tokens
        try require(remainingEmptyFinal.filter { $0.source == .them } == beforeEmptyFinal.filter { $0.source == .them },
                    "A completed empty microphone decode cannot retire meeting audio")
        try require(remainingEmptyFinal.filter { $0.source == .you }.map(\.id)
                    == beforeEmptyFinal.filter { $0.source == .you && !($0.start >= 0.6 && $0.end <= 2.2) }.map(\.id),
                    "Only estimates fully inside the completed empty interval disappear")
        try require(remainingEmptyFinal.contains { $0.source == .you && abs($0.end - 0.6) < 0.000_001 }
                    && remainingEmptyFinal.contains { $0.source == .you && abs($0.start - 2.2) < 0.000_001 },
                    "Boundary estimates retain their unprocessed edges")
        let emptyFinalRevision = emptyFinal.snapshot.revision
        emptyFinal.acknowledgeEmptyRecognition(source: .you, start: .nan, end: 4)
        emptyFinal.acknowledgeEmptyRecognition(source: .you, start: -1, end: 4)
        emptyFinal.acknowledgeEmptyRecognition(source: .you, start: 4, end: 3)
        try require(emptyFinal.snapshot.revision == emptyFinalRevision, "Invalid empty completion cannot change waiting audio")
        emptyFinal.acknowledgeEmptyRecognition(source: .you, start: 0, end: 4)
        try require(emptyFinal.snapshot.tokens.allSatisfy { $0.source == .them },
                    "Successful empty completion clears its waves without requiring invented transcript words")
        print("PASS empty final interval retirement, boundary preservation, source isolation and invalid coverage")
        func timedProjection(spacing: Double) -> (MeetingPendingSpeechProjection, MeetingLiveTranscriptSnapshot) {
            var projection = MeetingPendingSpeechProjection()
            confirmedSpeech(&projection, from: 0, seconds: 8)
            var visible = MeetingLiveTranscriptSnapshot.empty
            visible.revision = 1
            visible.utterances = (0..<8).map { index in
                .init(id: UUID(), speaker: .you, text: "слово", start: Double(index) * spacing,
                      end: Double(index) * spacing + 0.15)
            }
            projection.reconcile(visible: visible)
            return (projection, visible)
        }
        var (fast, timed) = timedProjection(spacing: 0.256)
        var (slow, _) = timedProjection(spacing: 0.75)
        var repeated = fast
        timed.revision = 2
        repeated.reconcile(visible: timed)
        let fastCount = fast.snapshot.tokens.count, slowCount = slow.snapshot.tokens.count
        confirmedSpeech(&fast, from: 8, seconds: 4)
        confirmedSpeech(&slow, from: 8, seconds: 4)
        confirmedSpeech(&repeated, from: 8, seconds: 4)
        try require(fast.snapshot.tokens.count - fastCount > slow.snapshot.tokens.count - slowCount,
                    "New native word spacing adapts visual cadence to faster and slower speech")
        try require(fast.snapshot.tokens == repeated.snapshot.tokens,
                    "A higher metadata revision cannot train twice from the same native words")
        let beforeCadencePause = fast.snapshot.tokens
        fast.observeSpeechActivity(source: .you, start: 12, end: 12.256, activity: .nonSpeech)
        try require(fast.snapshot.tokens == beforeCadencePause && fast.snapshot.animatedTokenIDs.isEmpty,
                    "A learned fast cadence still cannot mint or animate speech in a pause")
        print("PASS native timing adapts cadence once without creating speech during pauses")
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
        try testActivityEvidence()
        try testDelayedReplacementDiagnostics()
        try testCaptureTee()
    }

    static func testReadableParticipantContinuity() throws {
        let name = MeetingSpeakerPresentation.Name(displayName: "Участник 1", isLocalUser: false)
        let first = MeetingSpeakerPresentation(identity: "first", label: .identified(name), participantID: UUID())
        let second = MeetingSpeakerPresentation(identity: "second", label: .identified(name), participantID: UUID())
        let unknown = MeetingSpeakerPresentation(identity: "unresolved", label: .unknown)
        let candidates = MeetingSpeakerPresentation(identity: "candidates", label: .candidates([name, nil], relation: .conflict))
        func snapshot(_ participants: [MeetingSpeakerPresentation?]) -> MeetingLiveTranscriptSnapshot {
            var value = MeetingLiveTranscriptSnapshot.empty
            value.utterances = participants.enumerated().map { index, participant in
                .init(id: UUID(), speaker: .you, text: index == 1 ? "А" : "слово\(index)",
                      start: Double(index), end: Double(index) + 0.1, participant: participant)
            }
            return value
        }
        let initial = snapshot([nil, unknown, candidates])
        let initialRows = MeetingLiveBubbleComposer.rows(for: initial)
        try require(initialRows.allSatisfy { $0.showsLabel && !$0.hasReadableParticipant }
                    && initialRows.map { $0.participant?.identity } == [nil, unknown.identity, candidates.identity],
                    "Initial unresolved text retains internal metadata without a fake participant header")
        for participants in [[first, unknown, first], [first, nil, first], [first, candidates, first]] {
            let value = snapshot(participants)
            let original = value
            let rows = MeetingLiveBubbleComposer.rows(for: value)
            try require(rows.map(\.showsLabel) == [true, true, true]
                        && rows.map { $0.participant?.identity } == participants.map { $0?.identity },
                        "The composer cannot infer a participant solely from the capture source")
            try require(!rows[1].hasReadableParticipant,
                        "Unresolved source metadata cannot become independent ownership evidence")
            try require(value == original && rows.map(\.id) == value.utterances.map(\.id)
                        && rows.map(\.text) == value.utterances.map(\.text)
                        && rows.map(\.start) == value.utterances.map(\.start),
                        "Composition preserves raw uncertainty, row IDs, text order and native start times")
        }
        let contextual = MeetingLiveBubbleComposer.rows(for: snapshot([first, first.markingEstimated(), first]))
        try require(contextual.map(\.showsLabel) == [true, false, false]
                    && contextual.allSatisfy { $0.participant?.identity == first.identity }
                    && contextual[0].participant?.isEstimated == true,
                    "A participant supplied by the protected context policy continues the actual reading turn as an internal estimate")
        var value = snapshot([first, unknown, second])
        let partialID = UUID()
        value.partials[.you] = .init(id: partialID, text: "продолжение", start: 3, end: 3.5)
        let original = value
        let rows = MeetingLiveBubbleComposer.rows(for: value)
        try require(rows.map(\.showsLabel) == [true, true, true, true]
                    && rows.map { $0.participant?.identity } == [first.identity, unknown.identity, second.identity, nil],
                    "Known participant switches remain distinct and source-only partials do not claim ownership")
        try require(rows.last?.id == partialID && rows.last?.isPartial == true && value == original,
                    "A source-only growing partial retains its ID and original evidence")
        print("PASS live unresolved letters, nil/candidate ownership, initial anonymity and known participant switches")
    }

    static func testReadableParticipantCorrectionsAndSources() throws {
        let owner = UUID(), other = UUID()
        let first = MeetingSpeakerPresentation(identity: "participant-a", label: .identified(.init(displayName: "Same alias", isLocalUser: false)), participantID: owner)
        let second = MeetingSpeakerPresentation(identity: "participant-b", label: .identified(.init(displayName: "Same alias", isLocalUser: false)), participantID: other)
        let unknown = MeetingSpeakerPresentation(identity: "unknown", label: .unknown)
        var value = MeetingLiveTranscriptSnapshot.empty
        value.revision = 1
        value.utterances = [
            .init(id: UUID(), speaker: .you, text: "первое", start: 7, end: 7.4, participant: first),
            .init(id: UUID(), speaker: .them, text: "другая дорожка", start: 8, end: 8.4, participant: unknown),
            .init(id: UUID(), speaker: .you, text: "продолжение", start: 9, end: 9.4, participant: nil),
            .init(id: UUID(), speaker: .them, text: "ответ", start: 10, end: 10.4, participant: second),
        ]
        let before = MeetingLiveBubbleComposer.rows(for: value)
        try require(before.map { $0.participant?.identity } == [first.identity, unknown.identity, nil, second.identity]
                    && before.map(\.showsLabel) == [true, true, true, true],
                    "Unresolved ownership never leaks across capture sources or collapses distinct equal-name identities")
        try require(before[2].readingTurnStart == 9 && before[3].readingTurnStart == 10,
                    "Unassigned source text retains its own time; a known participant uses its actual first word")
        value.revision = 2
        value.utterances[2].participant = second
        let corrected = MeetingLiveBubbleComposer.rows(for: value)
        try require(corrected[2].participant == second && corrected[2].readingTurnStart == 9
                    && corrected.map(\.id) == before.map(\.id) && corrected.map(\.text) == before.map(\.text),
                    "A higher revision with unchanged row IDs replaces provisional reading ownership with actual corrected identity")
        value.revision = 3
        value.utterances[2].participant = .init(identity: second.identity,
            label: .identified(.init(displayName: "Ручное имя", isLocalUser: false)), participantID: other)
        try require(MeetingLiveBubbleComposer.rows(for: value)[2].participant == value.utterances[2].participant,
                    "Manual participant names are refreshed without translated-name comparisons or stale identity caches")
        print("PASS independent source ownership, equal aliases, same-ID speaker corrections and manual names")
    }

    static func testElapsedParticipantTurnTimes() throws {
        for (seconds, expected) in [(0.0, "00:00"), (7.9, "00:07"), (59, "00:59"), (60, "01:00"),
                                    (755, "12:35"), (3599, "59:59"), (3600, "1:00:00"), (3755, "1:02:35")] {
            try require(MeetingTranscriptExporter.timestampText(seconds) == expected,
                        "Elapsed timestamp format is stable at minute/hour boundaries and uses the first word's whole second")
        }
        for seconds in [-1.0, -Double.infinity, Double.infinity, Double.nan, Double.greatestFiniteMagnitude] {
            try require(MeetingTranscriptExporter.timestampText(seconds) == "00:00",
                        "Invalid, negative and unrepresentable elapsed values are handled before integer conversion")
        }
        let participant = MeetingSpeakerPresentation(identity: "speaker", label: .identified(.init(displayName: "Участник", isLocalUser: false)))
        var value = MeetingLiveTranscriptSnapshot.empty
        value.utterances = [
            .init(id: UUID(), speaker: .you, text: "Начало\n", start: 7.8, end: 8, participant: participant),
            .init(id: UUID(), speaker: .you, text: String(repeating: "слово ", count: 200), start: 20, end: 40, participant: participant),
        ]
        value.partials[.you] = .init(id: UUID(), text: "ожидаю", start: 50)
        let before = MeetingLiveBubbleComposer.rows(for: value)
        value.revision += 1
        value.partials[.you]?.text += " новые слова"
        value.partials[.you]?.end = 55
        let after = MeetingLiveBubbleComposer.rows(for: value)
        try require(before.map(\.readingTurnStart) == [7.8, 7.8, 50]
                    && after.map(\.readingTurnStart) == [7.8, 7.8, 50]
                    && after.map(\.showsLabel) == [true, false, true],
                    "Layout and pending growth preserve actual participant turn time without attaching source-only partials")
        print("PASS finite elapsed timestamp boundaries and stable first-word turn anchors")
    }

    static func testActivityEvidence() throws {
        func feedEvidence(_ projection: inout MeetingPendingSpeechProjection, source: MeetingLiveSpeaker = .you,
                          start: Double, duration: Double, activity: MeetingSpeechActivity) {
            for frame in 0..<Int((duration / 0.02).rounded()) {
                let time = start + Double(frame) * 0.02
                projection.observeSpeechActivity(source: source, start: time, end: time + 0.02,
                    activity: activity)
            }
        }
        var projection = MeetingPendingSpeechProjection()
        feedEvidence(&projection, start: 0, duration: 2, activity: .speech)
        let first = projection.snapshot
        try require(first.tokens.count == 5 && first.activityBySource[.you] == .speech,
                    "Confirmed speech bypasses energy and modulation heuristics")
        try require(first.animatedTokenIDs == Set(first.tokens.suffix(3).map(\.id)),
                    "Only the last three waves of an active source animate")
        feedEvidence(&projection, start: 2, duration: 8, activity: .nonSpeech)
        let quiet = projection.snapshot
        try require(quiet.tokens == first.tokens && quiet.animatedTokenIDs.isEmpty,
                    "Confirmed pause immediately freezes all retained speech without losing its IDs")
        try require(quiet.revision == first.revision + 1,
                    "Hundreds of non-speech decisions publish only one activity transition")
        feedEvidence(&projection, start: 10, duration: 8, activity: .unknown)
        let unknown = projection.snapshot
        try require(unknown.activityBySource[.you] == .unknown && unknown.tokens == quiet.tokens
                    && unknown.animatedTokenIDs.isEmpty && unknown.revision == quiet.revision + 1,
                    "Missing VAD evidence stays unknown and cannot claim silence, erase audio or churn revisions")
        var held = MeetingLiveTranscriptSnapshot.empty
        held.revision = 1
        held.utterances = [.init(id: UUID(), speaker: .you, text: "Approved prefix only", start: 0, end: 2,
            hasIncompleteTextCoverage: true)]
        projection.reconcile(visible: held)
        try require(projection.snapshot == unknown,
                    "PII-held finalized suffix keeps every uncovered pending interval and remains frozen")
        feedEvidence(&projection, start: 18, duration: 1, activity: .speech)
        let resumed = projection.snapshot
        try require(resumed.tokens.starts(with: first.tokens) && !resumed.animatedTokenIDs.isEmpty,
                    "Confirmed resumed speech preserves history and restarts only bounded recent waves")
        feedEvidence(&projection, source: .them, start: 0, duration: 2, activity: .speech)
        let both = projection.snapshot
        try require(both.animatedTokenIDs.count == 6,
                    "Independent simultaneous sources each animate at most their own last three waves")
        feedEvidence(&projection, start: 19, duration: 1, activity: .nonSpeech)
        let otherOnly = projection.snapshot
        let otherIDs = Set(otherOnly.tokens.filter { $0.source == .them }.suffix(3).map(\.id))
        try require(otherOnly.animatedTokenIDs == otherIDs,
                    "A microphone pause cannot freeze the independently active other source")
        projection.observeSpeechActivity(source: .you, start: 18, end: 18.02, activity: .speech)
        projection.observeSpeechActivity(source: .them, start: 0, end: 0.02, activity: .nonSpeech)
        projection.observeSpeechActivity(source: .you, start: .nan, end: 21, activity: .speech)
        try require(projection.snapshot == otherOnly,
                    "Stale, cross-source reordered and invalid detector decisions cannot revive or freeze waves")
        feed(&projection, start: 20, duration: 2, rms: Self.speech)
        try require(projection.snapshot.activityBySource[.you] == .speech,
                    "The heuristic fallback remains usable after unknown decisions without model residency")
        let retained = projection.snapshot.tokens
        feed(&projection, start: 22, duration: 5, rms: { _ in 0 })
        try require(projection.snapshot.tokens == retained && projection.snapshot.activityBySource[.you] == .nonSpeech
                    && projection.snapshot.animatedTokenIDs == otherIDs,
                    "Heuristic pauses also freeze their own source after bounded hangover")
        let settledRevision = projection.snapshot.revision
        feed(&projection, start: 27, duration: 5, rms: { _ in 0 })
        try require(projection.snapshot.revision == settledRevision,
                    "Settled heuristic silence cannot invalidate UI at PCM cadence")
        projection.stop()
        let stopped = projection.snapshot
        projection.stop()
        feedEvidence(&projection, start: 32, duration: 2, activity: .speech)
        try require(stopped == projection.snapshot && stopped.tokens.isEmpty && stopped.animatedTokenIDs.isEmpty,
                    "Stop clears animation and capture once; repeated stop and late evidence are inert")
        print("PASS speech/pause/resume, unknown evidence, PII hold, per-source animation and transition-only revisions")
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
        let quietSnapshot = projection.snapshot
        try require(quietSnapshot.tokens == original.tokens && quietSnapshot.animatedTokenIDs.isEmpty,
                    "Even an 18-second ASR delay preserves earlier speech while freezing quiet waves")
        let quiet = receipt.values()
        try require(quiet.filter { $0.kind == .quietWaiting }.count == 1, "One quiet transition produces one diagnostic, not a PCM-frame log flood")
        try require(!quiet.contains { $0.kind == .replaced }, "Quiet is never logged as replacement")
        var held = MeetingLiveTranscriptSnapshot.empty
        held.revision = 1
        projection.reconcile(visible: held)
        try require(projection.snapshot == quietSnapshot, "An empty/privacy-held update cannot remove pending audio or restart animation")
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
