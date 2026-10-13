import Foundation
import PichiTextPrivacy

private struct StructuredPrivacyRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redact(text, ner: [])
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) })
    }
}

private actor NativePrivacyRedactor: TranscriptTextRedacting {
    let runtime = PIINERRuntime()
    func prepare(_ directory: URL) async throws { try await runtime.load(directory: directory) }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redact(text, ner: await runtime.tag(text))
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) })
    }
}

private struct InvalidOffsetRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: "[ИМЯ]", spans: [.init(range: NSRange(location: 1, length: 1), replacement: "[ИМЯ]")])
    }
}

private struct MissingOffsetsRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction { .init(text: "[ИМЯ]", spans: []) }
}

private actor CancellablePrivacyRedactor: TranscriptTextRedacting {
    let started: AsyncStream<Void>.Continuation
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        started.yield(())
        try await Task.sleep(nanoseconds: 5_000_000_000)
        try Task.checkCancellation()
        return try await StructuredPrivacyRedactor().redactWithSpans(text)
    }
}

private actor DeferredLiveRedactor: TranscriptTextRedacting {
    let started: AsyncStream<String>.Continuation
    let cancelled: AsyncStream<Void>.Continuation
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(started: AsyncStream<String>.Continuation, cancelled: AsyncStream<Void>.Continuation) {
        self.started = started; self.cancelled = cancelled
    }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        started.yield(text)
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: { self.cancelled.yield(()) }
        try Task.checkCancellation()
        return try await StructuredPrivacyRedactor().redactWithSpans(text)
    }
    func release() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
}

@main
struct MeetingPrivacyContextTests {
    enum Failure: Error { case assertion(String) }
    static func check(_ condition: Bool, _ message: String) throws {
        if !condition { throw Failure.assertion(message) }
    }
    static func segment(_ text: String, track: UUID, start: Int) -> MeetingTranscriptSegment {
        .init(id: UUID(), start: .init(value: Int64(start), timescale: 1), end: .init(value: Int64(start + 1), timescale: 1),
              sourceTrackID: track, speakerID: nil, text: text, originalText: "Synthetic original", revision: 1,
              status: .final, overlap: .none, completeness: .complete)
    }
    static func main() async throws {
        try await suite(using: StructuredPrivacyRedactor())
        try await liveSuite(using: StructuredPrivacyRedactor())
        if let path = ProcessInfo.processInfo.environment["PICHI_PII_TEST_MODEL_DIRECTORY"] {
            let native = NativePrivacyRedactor()
            try await native.prepare(URL(fileURLWithPath: path, isDirectory: true))
            try await suite(using: native)
            try await liveSuite(using: native)
        }
        try await liveDeliverySuite()
        let track = UUID()
        let invalid = MeetingPCMTranscriptBatch(segments: [segment("🙂 Иван", track: track, start: 0)])
        do {
            _ = try await MeetingTranscriptPrivacyPolicy.redactedBatch(invalid, using: InvalidOffsetRedactor())
            throw Failure.assertion("invalid surrogate offsets must not publish")
        } catch is MeetingPrivacyPublicationError { }
        do {
            _ = try await MeetingTranscriptPrivacyPolicy.redactedBatch(invalid, using: MissingOffsetsRedactor())
            throw Failure.assertion("redacted text without offsets must not publish raw segments")
        } catch is MeetingPrivacyPublicationError { }
        let context = MeetingTranscriptPrivacyContext(redactor: StructuredPrivacyRedactor())
        let oversized = MeetingPCMTranscriptBatch(segments: [segment(String(repeating: "x", count: 16_385), track: track, start: 0)])
        do {
            _ = try await context.redact(oversized)
            throw Failure.assertion("pending tail must stay bounded")
        } catch is MeetingPrivacyPublicationError { }
        let started = AsyncStream<Void>.makeStream()
        let cancelled = MeetingTranscriptPrivacyContext(redactor: CancellablePrivacyRedactor(started: started.continuation))
        let task = Task { try await cancelled.redact(.init(segments: [segment("телефон 8 999", track: track, start: 0)])) }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        task.cancel()
        do { _ = try await task.value; throw Failure.assertion("cancelled privacy work must join and throw") }
        catch is CancellationError { }
        let cancelledTail = try await cancelled.finish()
        try check(cancelledTail == nil, "cancelled transform committed a raw pending tail")
        print("Meeting privacy context tests passed: actual segments/evidence, structured rules, opt-in native NER, delayed tail and final flush")
    }

    static func liveSuite(using redactor: any TranscriptTextRedacting) async throws {
        let cases: [(String, [String], [String], String)] = [
            ("документ передали сидорову", ["ивану", "ивану петровичу метформин 500 мг"], ["сидорову", "ивану", "петровичу"], "метформин 500 мг"),
            ("телефон 273", ["55", "55 11 метотрексат 15 мг"], ["273", "55 11"], "метотрексат 15 мг"),
            ("дата рождения 12", ["мая", "мая 1980 инсулин 10 единиц"], ["12", "мая 1980"], "инсулин 10 единиц"),
            ("домашний адрес улица Примерная", ["дом", "дом 12 квартира 7 лизиноприл 10 мг"], ["Примерная", "квартира 7"], "лизиноприл 10 мг"),
            ("карта 4111", ["1111", "1111 1111", "1111 1111 1111 508 рублей оземпик"], ["4111", "1111"], "508 рублей оземпик"),
        ]
        for (initial, partials, privatePieces, medication) in cases {
            let first = MeetingLiveUtterance(id: UUID(), speaker: .you, text: initial, start: 0, end: 1)
            let partialID = UUID()
            var raw = MeetingLiveTranscriptSnapshot.empty
            raw.utterances = [first]
            raw.availability = .available
            raw.revision = 1
            for (index, text) in partials.enumerated() {
                raw = raw.settingPartial(.init(id: partialID, text: text, start: 1), for: .you)
                raw.revision += 1
                let safe = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: redactor)
                try check(safe.utterances[0].id == first.id && safe.utterances[0].start == 0 && safe.utterances[0].end == 1, "live completed row identity/timing changed")
                try check(safe.partials[.you]?.id == partialID && safe.partials[.you]?.start == 1, "live partial identity changed")
                try check(raw.utterances[0].text == initial && raw.partials[.you]?.text == text, "filtered strings replaced canonical raw input")
                if index == partials.count - 1 {
                    let joined = safe.utterances.map(\.text).joined(separator: " ") + " " + (safe.partials[.you]?.text ?? "")
                    for value in privatePieces { try check(!joined.contains(value), "earlier completed live row was not corrected: \(value)") }
                    try check(joined.contains(medication), "live privacy changed a neighboring medication/dose")
                }
            }
            raw = raw.settingPartial(nil, for: .you).inserting(.init(id: partialID, speaker: .you, text: partials.last!, start: 1, end: 4))
            raw.revision += 1
            let completed = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: redactor)
            try check(completed.utterances.map(\.id) == [first.id, partialID], "EOU changed continuous row identities")
            try check(completed.utterances[1].start == 1 && completed.utterances[1].end == 4 && completed.partials.isEmpty, "EOU timing/state changed")
            let joined = completed.utterances.map(\.text).joined(separator: " ")
            for value in privatePieces { try check(!joined.contains(value), "completed rows restored recognized PII") }
            try check(joined.contains(medication), "EOU privacy changed a medication/dose")
        }
        // Separate source tags remain source tags, not diarization identities.
        var sources = MeetingLiveTranscriptSnapshot.empty
        sources.utterances = [.init(id: UUID(), speaker: .you, text: "дата рождения", start: 0, end: 1),
                              .init(id: UUID(), speaker: .them, text: "12 мая 1980", start: 1, end: 2)]
        let separate = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(sources, using: redactor)
        try check(separate.utterances[1].text == "12 мая 1980", "microphone context contaminated another audio source")
    }

    static func liveDeliverySuite() async throws {
        let started = AsyncStream<String>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let delivered = AsyncStream<(MeetingLiveTranscriptSnapshot, UUID)>.makeStream()
        let redactor = DeferredLiveRedactor(started: started.continuation, cancelled: cancelled.continuation)
        let publisher = MeetingLivePrivacyPublication()
        let generation = UUID()
        var failures = 0
        func snapshot(_ revision: UInt64, _ text: String) -> MeetingLiveTranscriptSnapshot {
            var value = MeetingLiveTranscriptSnapshot.empty
            value.revision = revision
            value.utterances = [.init(id: UUID(), speaker: .you, text: text, start: 0, end: 1)]
            return value
        }
        func submit(_ value: MeetingLiveTranscriptSnapshot, _ token: UUID) {
            publisher.submit(value, generation: token, using: redactor,
                publish: { value, generation in delivered.continuation.yield((value, generation)) }, failed: { _ in failures += 1 })
        }
        var starts = started.stream.makeAsyncIterator()
        var updates = delivered.stream.makeAsyncIterator()
        submit(snapshot(1, "метформин 500 мг"), generation)
        _ = await starts.next()
        submit(snapshot(2, "инсулин 10 единиц"), generation)
        submit(snapshot(3, "метотрексат 15 мг"), generation)
        submit(snapshot(2, "out-of-order old update"), generation)
        await redactor.release()
        let first = await updates.next()
        try check(first?.0.revision == 1, "new partial cancelled/starved the running safe revision")
        let latestInput = await starts.next()
        try check(latestInput == "метотрексат 15 мг", "pending privacy input was not coalesced to latest raw revision")
        await redactor.release()
        let latest = await updates.next()
        try check(latest?.0.revision == 3 && latest?.1 == generation, "latest live privacy revision did not publish")

        submit(snapshot(4, "телефон 273 55 11"), generation)
        _ = await starts.next()
        var stopped = false
        let stop = Task { await publisher.stop(); stopped = true }
        var cancellations = cancelled.stream.makeAsyncIterator()
        _ = await cancellations.next()
        try check(!stopped, "teardown abandoned an unfinished native privacy operation")
        await redactor.release()
        await stop.value
        try check(stopped && failures == 0, "joined cancellation produced a failure/publication")
        let freshGeneration = UUID()
        submit(snapshot(1, "оземпик"), freshGeneration)
        _ = await starts.next()
        await redactor.release()
        let fresh = await updates.next()
        try check(fresh?.0.revision == 1 && fresh?.1 == freshGeneration, "a stopped generation published into a new meeting")
        await publisher.stop()
        var large = MeetingLiveTranscriptSnapshot.empty
        large.revision = 1
        large.utterances = (0..<200).map { index in .init(id: UUID(), speaker: .you, text: "строка \(index)", start: Double(index), end: Double(index + 1)) }
        submit(large, UUID())
        let boundedInput = await starts.next()
        try check(boundedInput?.contains("строка 99 ") == false && boundedInput?.hasPrefix("строка 100 ") == true, "pending raw snapshot retained rows outside the display bound")
        await redactor.release()
        let boundedOutput = await updates.next()
        try check(boundedOutput?.0.utterances.count == 100 && boundedOutput?.0.utterances.first?.id == large.utterances[100].id, "bounded live rows changed identity")
        await publisher.stop()
    }

    static func suite(using redactor: any TranscriptTextRedacting) async throws {
        let track = UUID()
        for (texts, masked) in [
            (["телефон", "273 55 11", "метформин 500 мг"], "273 55 11"),
            (["дата рождения", "12 мая 1980", "инсулин 10 единиц"], "12 мая 1980"),
            (["домашний адрес", "улица Примерная дом 12", "метотрексат 15 мг"], "улица Примерная дом 12"),
            (["врач иван", "петрович сидоров", "обсудил лизиноприл 10 мг"], "петрович сидоров"),
        ] {
            let input = MeetingPCMTranscriptBatch(segments: texts.enumerated().map { segment($0.element, track: track, start: $0.offset) })
            let output = try await MeetingTranscriptPrivacyPolicy.redactedBatch(input, using: redactor)
            try check(!output.segments.map(\.text).joined(separator: " ").contains(masked), "cross-segment PII escaped")
            try check(output.segments.last?.text == texts.last, "unrelated drug/dose text changed")
            try check(output.segments.map(\.id) == input.segments.map(\.id), "IDs changed")
            try check(output.segments.map(\.start) == input.segments.map(\.start), "timestamps changed")
            try check(output.segments.allSatisfy { $0.originalText == nil }, "originalText retained")
        }

        // A word/utterance canonical sidecar uses the same validated projection.
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let units = ["дата рождения", "12 мая 1980", "метформин 500 мг"].enumerated().map { index, text in
            MeetingFinalTextUnit(id: "unit-\(index)", trackID: track, analysisEpochID: epoch, precision: .utterance,
                text: text, analysisStart: Double(index), analysisEnd: Double(index + 1), speaker: .unassigned, analysisSpanIDs: ["span"])
        }
        let evidence = MeetingFinalTranscriptEvidence(backendID: .parakeetNemotron, attemptID: UUID(), units: units)
        let safeEvidence = try await MeetingTranscriptPrivacyPolicy.redactedEvidence(evidence, using: redactor)
        try check(!safeEvidence.units[1].text.contains("1980"), "canonical DOB leaked")
        try check(safeEvidence.units[2].text == units[2].text, "canonical unrelated text changed")

        let large = MeetingPCMTranscriptBatch(segments: [
            segment(String(repeating: "word ", count: 7_998), track: track, start: 0),
            segment("дата рождения", track: track, start: 1),
            segment("12 мая 1980", track: track, start: 2),
            segment(String(repeating: "note ", count: 7_998), track: track, start: 3),
        ])
        let largeOutput = try await MeetingTranscriptPrivacyPolicy.redactedBatch(large, using: redactor)
        try check(largeOutput.segments[2].text == "[ДАТА_РОЖДЕНИЯ]", "overlap duplicated a replacement or leaked DOB")
        try check(largeOutput.segments[0].text == large.segments[0].text && largeOutput.segments[3].text == large.segments[3].text, "window projection changed unrelated large text")

        // Strict successive windows hold the possible first half until context
        // arrives. No checkpoint from either call may contain the phone fragments.
        let context = MeetingTranscriptPrivacyContext(redactor: redactor)
        let first = MeetingPCMTranscriptBatch(segments: [segment("телефон 8 999", track: track, start: 0)])
        let second = MeetingPCMTranscriptBatch(segments: [segment("123 45 67", track: track, start: 8)])
        let firstOutput = try await context.redact(first)
        try check(firstOutput.segments.isEmpty, "possible raw entity tail published early")
        let secondOutput = try await context.redact(second)
        try check(secondOutput.segments.isEmpty, "raw lexical tail published before its holdback closed")
        let finalOutput = try await context.finish()
        try check(finalOutput?.segments.count == 2 && finalOutput?.segments.map(\.text).joined(separator: " ").contains("123 45 67") == false, "final phone tail leaked")
        let repeatFinish = try await context.finish()
        try check(repeatFinish == nil, "finish duplicated a checkpoint")

        for (cue, value, privateValue) in [
            ("дата рождения", "12 мая 1980", "1980"),
            ("домашний адрес", "улица Примерная дом 12", "Примерная"),
        ] {
            let contextual = MeetingTranscriptPrivacyContext(redactor: redactor)
            let a = try await contextual.redact(.init(segments: [segment(cue, track: track, start: 0)]))
            let b = try await contextual.redact(.init(segments: [segment(value, track: track, start: 8)]))
            let c = try await contextual.finish()
            let text = (a.segments + b.segments + (c?.segments ?? [])).map(\.text).joined(separator: " ")
            try check(!text.contains(privateValue), "context-only identifier escaped across strict windows")
        }
        let fresh = MeetingTranscriptPrivacyContext(redactor: redactor)
        _ = try await fresh.redact(MeetingPCMTranscriptBatch(segments: [segment("12 мая 1980", track: track, start: 0)]))
        let freshOutput = try await fresh.finish()
        try check(freshOutput?.segments[0].text == "12 мая 1980", "context leaked across attempts")

        // ASR may emit a separate segment per word. The whole sensitive lexical
        // suffix must wait, not only the final word of the first PCM window.
        let cards = MeetingTranscriptPrivacyContext(redactor: redactor)
        let firstWords = ["карта", "4111", "1111"].enumerated().map { segment($0.element, track: track, start: $0.offset) }
        let secondWords = ["1111", "1111", "500", "мг", "метформин500мг"].enumerated().map { segment($0.element, track: track, start: 8 + $0.offset) }
        let cardA = try await cards.redact(.init(segments: firstWords))
        let cardB = try await cards.redact(.init(segments: secondWords))
        let cardC = try await cards.finish()
        let checkpoints = [cardA, cardB] + (cardC.map { [$0] } ?? [])
        for checkpoint in checkpoints {
            let text = checkpoint.segments.map(\.text).joined(separator: " ")
            try check(!text.contains("4111") && !text.contains("1111"), "a PAN fragment reached an earlier checkpoint")
            let json = String(decoding: try JSONEncoder().encode(checkpoint.segments), as: UTF8.self)
            try check(!json.contains("4111") && !json.contains("1111"), "a PAN fragment reached an export payload")
        }
        let all = checkpoints.flatMap(\.segments)
        try check(all.map(\.id) == (firstWords + secondWords).map(\.id), "held words changed IDs or vanished")
        try check(all.map(\.start) == (firstWords + secondWords).map(\.start), "held words changed timestamps")
        try check(all.allSatisfy { $0.originalText == nil }, "held words retained original text")
        try check(all.suffix(3).map(\.text) == ["500", "мг", "метформин500мг"], "PAN detection absorbed an adjacent dose")

        let names = MeetingTranscriptPrivacyContext(redactor: redactor)
        let nameA = ["доктор", "анна"].enumerated().map { segment($0.element, track: track, start: $0.offset) }
        let nameB = ["сергеевна", "кузнецова", "метотрексат", "15", "мг"].enumerated().map { segment($0.element, track: track, start: 8 + $0.offset) }
        let nameCheckpoints = [try await names.redact(.init(segments: nameA)), try await names.redact(.init(segments: nameB))]
        let nameTail = try await names.finish()
        for checkpoint in nameCheckpoints + (nameTail.map { [$0] } ?? []) {
            let text = checkpoint.segments.map(\.text).joined(separator: " ")
            try check(!text.contains("анна") && !text.contains("сергеевна") && !text.contains("кузнецова"), "recognized name fragment reached a checkpoint")
        }
        try check(nameTail?.segments.suffix(3).map(\.text) == ["метотрексат", "15", "мг"], "name tail changed adjacent medication")

        // A long complete utterance still holds one segment; token-based policy
        // must not delay 32 complete eight-second utterances.
        let complete = MeetingTranscriptPrivacyContext(redactor: redactor)
        let utterance = Array(repeating: "документ", count: 40).joined(separator: " ")
        let utteranceA = segment(utterance, track: track, start: 0)
        let utteranceB = segment(utterance, track: track, start: 8)
        _ = try await complete.redact(.init(segments: [utteranceA]))
        let released = try await complete.redact(.init(segments: [utteranceB]))
        try check(released.segments.map(\.id) == [utteranceA.id], "complete utterance granularity over-buffered")
        let completeTail = try await complete.finish()
        try check(completeTail?.segments.map(\.id) == [utteranceB.id], "complete utterance tail did not flush")

        // Enforce the budget over the entire held array, not each individual word.
        let bounded = MeetingTranscriptPrivacyContext(redactor: redactor)
        let part = String(repeating: "x", count: 8_000)
        _ = try await bounded.redact(.init(segments: [segment(part, track: track, start: 0)]))
        _ = try await bounded.redact(.init(segments: [segment(part, track: track, start: 8)]))
        do {
            _ = try await bounded.redact(.init(segments: [segment(part, track: track, start: 16)]))
            throw Failure.assertion("whole pending array exceeded its UTF-16 budget")
        } catch is MeetingPrivacyPublicationError { }
    }
}
