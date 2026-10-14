import Foundation
import PichiTextPrivacy

private struct StructuredPrivacyRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redact(text, ner: [])
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) },
                     provisionalSafeUTF16: try PIIRedactor.provisionalSafePrefix(in: text, ner: [], redactedSpans: output.spans))
    }
}

#if !PII_POLICY_STANDALONE
private actor NativePrivacyRedactor: TranscriptTextRedacting {
    let runtime = PIINERRuntime()
    func prepare(_ directory: URL) async throws { try await runtime.load(directory: directory) }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let ner = try await runtime.tag(text)
        let output = try PIIRedactor.redact(text, ner: ner)
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) },
                     provisionalSafeUTF16: try PIIRedactor.provisionalSafePrefix(in: text, ner: ner, redactedSpans: output.spans))
    }
}
#endif

private struct UnsupportedPreviewRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redact(text, ner: [])
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) })
    }
}

private struct InvalidPreviewRedactor: TranscriptTextRedacting {
    let limit: Int
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: text, spans: [], provisionalSafeUTF16: limit)
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
        try await provisionalSuite(using: StructuredPrivacyRedactor())
        #if !PII_POLICY_STANDALONE
        if let path = ProcessInfo.processInfo.environment["PICHI_PII_TEST_MODEL_DIRECTORY"] {
            let native = NativePrivacyRedactor()
            try await native.prepare(URL(fileURLWithPath: path, isDirectory: true))
            try await suite(using: native)
            try await liveSuite(using: native)
            try await provisionalSuite(using: native)
        }
        #endif
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

    static func provisionalSuite(using redactor: any TranscriptTextRedacting) async throws {
        let track = UUID()
        let benign = "Сегодня обсуждаем применение амоксициллина и переносимость назначенной терапии."
        let original = segment(benign, track: track, start: 0)
        let speechOnly = MeetingTranscriptPrivacyContext(redactor: redactor)
        let immediate = try await speechOnly.previewSpeech(.init(segments: [original]))
        try check(immediate?.text.hasPrefix("Сегодня обсуждаем применение") == true,
                  "protected ASR text did not appear before attribution")
        let noCheckpoint = try await speechOnly.finish()
        try check(noCheckpoint == nil, "ASR-only observation entered a durable privacy tail")
        let oversized = MeetingTranscriptPrivacyContext(redactor: redactor)
        do {
            _ = try await oversized.previewSpeech(.init(segments: [segment(String(repeating: "документ ", count: 4_500), track: track, start: 0)]))
            throw Failure.assertion("oversized ASR observation reached provisional display")
        } catch is MeetingPrivacyPublicationError { }
        let oversizedTail = try await oversized.finish()
        try check(oversizedTail == nil, "rejected ASR observation advanced durable state")
        let staged = MeetingTranscriptPrivacyContext(redactor: redactor)
        let early = try await staged.previewSpeech(.init(segments: [original]))
        let canonical = try await staged.redact(.init(segments: [original]))
        try check(canonical.segments.isEmpty && canonical.livePreview?.id == early?.id,
                  "early observation changed durable holdback or preview identity")
        let canonicalTail = try await staged.finish()
        let canonicalReference = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: [original]), using: redactor)
        try check(canonicalTail?.segments == canonicalReference.segments,
                  "early observation duplicated or changed canonical output")
        let context = MeetingTranscriptPrivacyContext(redactor: redactor)
        let first = try await context.redact(.init(segments: [original]))
        try check(first.segments.isEmpty, "preview released the canonical 32-token tail")
        let preview = first.livePreview
        try check(preview?.text.hasPrefix("Сегодня обсуждаем применение") == true, "short benign medical speech remained blank without a word whitelist")
        try check(preview?.start == original.start.seconds, "preview lost its physical start time")
        let silent = try await context.redact(.init(segments: []))
        try check(silent.segments.isEmpty && silent.livePreview == preview, "silence erased an approved preview or released the canonical hold")
        let next = segment("Обсуждаем инструкцию и схему применения препарата.", track: track, start: 8)
        let second = try await context.redact(.init(segments: [next]))
        try check(second.segments.isEmpty, "a preview changed durable admission")
        if let updated = second.livePreview { try check(updated.id == preview?.id, "preview row identity changed between PCM windows") }
        let final = try await context.finish()
        let expected = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: [original, next]), using: redactor)
        try check(final?.segments == expected.segments, "preview altered final wording, originalText, IDs or timestamps")
        try check(final?.livePreview == nil, "canonical flush retained provisional display text")
        let repeatedFinish = try await context.finish()
        try check(repeatedFinish == nil, "preview duplicated final flush")
        let englishContext = MeetingTranscriptPrivacyContext(redactor: redactor)
        let english = try await englishContext.redact(.init(segments: [segment(
            "Today we discuss amoxicillin dosing and the tolerability of prescribed therapy.", track: track, start: 0)]))
        try check(english.segments.isEmpty && english.livePreview?.text.hasPrefix("Today we discuss") == true,
                  "short benign English medical speech remained blank without a word whitelist")
        _ = try await englishContext.finish()

        // A fully masked entity in retained raw linguistic context must not
        // block the next benign held sentence. Only held text enters preview.
        let maskedContext = MeetingTranscriptPrivacyContext(redactor: redactor)
        let longText = Array(repeating: "документ", count: 40).joined(separator: " ")
        let priorPhone = segment("телефон 273 55 11 " + longText + ".", track: track, start: 0)
        _ = try await maskedContext.redact(.init(segments: [priorPhone]))
        let releasedPhone = try await maskedContext.redact(.init(segments: [segment(longText + ".", track: track, start: 8)]))
        try check(releasedPhone.segments.map(\.text).joined(separator: " ").contains("273") == false,
                  "the prior contextual phone was not canonically masked")
        let afterPhone = try await maskedContext.redact(.init(segments: [segment(benign, track: track, start: 16)]))
        try check(afterPhone.livePreview?.text.contains("Сегодня обсуждаем применение") == true,
                  "a fully masked phone in previous source context froze a benign preview")
        try check(afterPhone.livePreview?.text.contains("273") == false && afterPhone.livePreview?.text.contains("55 11") == false,
                  "previous raw phone context reached provisional display")
        _ = try await maskedContext.finish()

        let namedContext = MeetingTranscriptPrivacyContext(redactor: redactor)
        let named = segment("доктор анна сергеевна кузнецова, сегодня обсуждает схему назначения терапии и переносимость препарата.",
                            track: track, start: 0)
        let namedUpdate = try await namedContext.redact(.init(segments: [named]))
        let namedDisplay = namedUpdate.livePreview?.text ?? ""
        try check(namedUpdate.segments.isEmpty && namedDisplay.contains(PIIKind.person.placeholder)
                  && namedDisplay.contains("обсуждает схему назначения"),
                  "a completely masked name and benign continuation remained withheld")
        for value in ["анна", "сергеевна", "кузнецова"] {
            try check(!namedDisplay.contains(value), "canonical name replacement exposed a private source fragment")
        }
        let namedTail = try await namedContext.finish()
        let namedReference = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: [named]), using: redactor)
        try check(namedTail?.segments == namedReference.segments && namedTail?.livePreview == nil,
                  "continued masked preview changed canonical name publication")

        let cases: [([String], [String], String)] = [
            (["телефон", "273", "55", "11", "метформин 500 мг"], ["273", "55", "11"], "метформин 500 мг"),
            (["карта", "4111", "1111", "1111", "1111", "метформин 500 мг"], ["4111", "1111"], "метформин 500 мг"),
            (["дата рождения", "12", "мая", "1980", "инсулин 10 единиц"], ["12", "мая", "1980"], "инсулин 10 единиц"),
            (["домашний адрес", "улица", "Примерная", "дом", "12", "квартира", "7", "метотрексат 15 мг"], ["Примерная", "12", "7"], "метотрексат 15 мг"),
            (["моя почта", "ivan", "dot", "petrov", "at", "example", "dot", "com", "метформин 500 мг"], ["ivan", "petrov", "example", "com"], "метформин 500 мг"),
            (["доктор", "анна", "сергеевна", "кузнецова", "метотрексат 15 мг"], ["анна", "сергеевна", "кузнецова"], "метотрексат 15 мг"),
            (["документ передали", "сидорову", "ивану", "петровичу", "лизиноприл 10 мг"], ["сидорову", "ивану", "петровичу"], "лизиноприл 10 мг"),
            (["документ передали", "сидоро", "ву", "ивану", "петровичу", "метформин 500 мг"], ["сидоро", "ву", "ивану", "петровичу"], "метформин 500 мг"),
            (["доктор", "ан", "на", "сергеев", "на", "кузнецо", "ва", "метотрексат 15 мг"], ["ан", "сергеев", "кузнецо"], "метотрексат 15 мг"),
            (["Darragh", "Murphy", "discussed", "metformin 500 mg", "and", "the", "document"], ["Darragh", "Murphy"], "metformin 500 mg"),
            (["доктор И.", "П.", "Сидоров", "метформин 500 мг"], ["И.", "П.", "Сидоров"], "метформин 500 мг"),
            (["доктор С.", "обсуждает препарат и схему лечения", "метформин 500 мг"], ["С."], "метформин 500 мг"),
            (["доктор john", "smith", "обсудил препарат и схему лечения", "метформин 500 мг"], ["john", "smith"], "метформин 500 мг"),
            (["доктор", "львов", "сегодня обсуждает эффективность терапии", "метформин 500 мг"], ["львов"], "метформин 500 мг"),
            (["мой номер", "девятьсот", "шестнадцать", "двести", "метформин 500 мг"], ["девятьсот", "шестнадцать", "двести"], "метформин 500 мг"),
            (["Передаю контакт alex", "дефис", "work сегодня для проверки надежного подключения", "метформин 500 мг"], ["alex", "work"], "метформин 500 мг"),
            (["Передаю контакт alex", "нижнее подчёркивание", "work сегодня для проверки надежного подключения", "метформин 500 мг"], ["alex", "work"], "метформин 500 мг"),
            (["Передаю контакт ALEX", "ДЕФИС", "WORK сегодня для проверки надежного подключения", "метформин 500 мг"], ["ALEX", "WORK"], "метформин 500 мг"),
            (["Sending contact alex", "underscore", "work today for checking reliable connectivity", "metformin 500 mg"], ["alex", "work"], "metformin 500 mg"),
            (["Sending contact ALEX", "HYPHEN", "WORK today for checking reliable connectivity", "metformin 500 mg"], ["ALEX", "WORK"], "metformin 500 mg"),
            (["Анна 500 мг обсуждает переносимость терапии и схему лечения.", "метформин 500 мг"], ["Анна"], "метформин 500 мг"),
            (["доктор Сидоров 500 мг обсуждает переносимость терапии и схему лечения.", "метформин 500 мг"], ["Сидоров"], "метформин 500 мг"),
            (["сидоров 1980 г. обсуждал применение препарата сегодня.", "метформин 500 мг"], ["сидоров"], "метформин 500 мг"),
            (["паспорт email john", "123456", "обсудили переносимость терапии и схему лечения.", "метформин 500 мг"],
             ["john", "123456"], "метформин 500 мг"),
            (["домашний адрес улица розовая дом 12", "корпус а", "обсуждаем препарат сегодня.", "метформин 500 мг"],
             ["розовая", "корпус а"], "метформин 500 мг"),
            (["домашний адрес улица розовая дом 12", "строение второй", "обсуждаем препарат сегодня.", "метформин 500 мг"],
             ["розовая", "строение второй"], "метформин 500 мг"),
            (["доктор иван", "рид", "обсуждает лекарство сегодня.", "метформин 500 мг"], ["иван", "рид"], "метформин 500 мг"),
            (["доктор иван,", "рид", "обсуждает лекарство сегодня.", "метформин 500 мг"], ["иван", "рид"], "метформин 500 мг"),
            (["родился в мае", "1980 году", "обсуждаем препарат сегодня.", "метформин 500 мг"], ["мае", "1980"], "метформин 500 мг"),
        ]
        for (pieces, sensitive, medication) in cases {
            let streaming = MeetingTranscriptPrivacyContext(redactor: redactor)
            var input: [MeetingTranscriptSegment] = []
            var durable: [MeetingTranscriptSegment] = []
            for (index, piece) in pieces.enumerated() {
                let row = segment(piece, track: track, start: index * 8)
                input.append(row)
                let update = try await streaming.redact(.init(segments: [row]))
                durable += update.segments
                let displayed = update.livePreview?.text ?? ""
                for value in sensitive { try check(!displayed.contains(value), "private candidate escaped an intermediate preview: \(value)") }
                try check(update.segments.isEmpty, "a short provisional stream released durable text")
            }
            let tail = try await streaming.finish()
            durable += tail?.segments ?? []
            let reference = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: input), using: redactor)
            try check(durable == reference.segments, "preview changed canonical projection")
            try check(durable.map(\.text).joined(separator: " ").contains(medication), "preview policy mutated a medication/dose in canonical text")
            try check(tail?.livePreview == nil, "finish failed to clear candidate preview")
        }

        let unsupported = MeetingTranscriptPrivacyContext(redactor: UnsupportedPreviewRedactor())
        let hidden = try await unsupported.redact(.init(segments: [original]))
        try check(hidden.livePreview == nil && hidden.segments.isEmpty, "unsupported redactor exposed raw held text")
        for limit in [-1, 1, 100_000] {
            let invalid = MeetingTranscriptPrivacyContext(redactor: InvalidPreviewRedactor(limit: limit))
            do {
                _ = try await invalid.redact(.init(segments: [segment("🙂 документ инструкция", track: track, start: 0)]))
                throw Failure.assertion("invalid preview prefix was accepted")
            } catch is MeetingPrivacyPublicationError { }
            let invalidTail = try await invalid.finish()
            try check(invalidTail == nil, "failed preview transformation mutated held state")
        }
        let candidateText = "Сегодня к нам приехал qX для обсуждения терапии."
        let candidateRange = (candidateText as NSString).range(of: "qX")
        let lowConfidence = try PIIRedactor.provisionalSafePrefix(in: candidateText,
            ner: [.init(range: candidateRange, label: "PER", score: 0.2)], redactedSpans: [])
        try check((lowConfidence ?? 0) <= candidateRange.location, "short low-confidence/mixed-script NER candidate was treated as safe")
        let coveredPersonText = "Сегодня анна обсуждает переносимость терапии и схему назначения препарата."
        let coveredPersonRange = (coveredPersonText as NSString).range(of: "анна")
        let coveredPersonNER = [PIINERSpan(range: coveredPersonRange, label: "PER", score: 0.9)]
        let coveredPersonRedaction = try PIIRedactor.redact(coveredPersonText, ner: coveredPersonNER)
        let coveredPersonLimit = try PIIRedactor.provisionalSafePrefix(in: coveredPersonText,
            ner: coveredPersonNER, redactedSpans: coveredPersonRedaction.spans)
        try check((coveredPersonLimit ?? 0) > NSMaxRange(coveredPersonRange),
                  "a fully canonical-covered PER candidate still blocked benign continuation")
        let englishPersonText = "Doctor John Smith, discusses amoxicillin prescribing and monitoring tolerability during therapy."
        let englishPersonRange = (englishPersonText as NSString).range(of: "John Smith")
        let englishPersonNER = [PIINERSpan(range: englishPersonRange, label: "PER", score: 0.99)]
        let englishPersonRedaction = try PIIRedactor.redact(englishPersonText, ner: englishPersonNER)
        let englishPersonLimit = try PIIRedactor.provisionalSafePrefix(in: englishPersonText,
            ner: englishPersonNER, redactedSpans: englishPersonRedaction.spans)
        try check((englishPersonLimit ?? 0) > NSMaxRange(englishPersonRange),
                  "a resolved capitalized person title still froze a fully masked English name")
        let edgeText = "Сегодня обсуждаем анна сергеевна кузнецова лекарство схему"
        let edgeRedaction = try PIIRedactor.redact(edgeText, ner: [])
        let edgeLimit = try PIIRedactor.provisionalSafePrefix(in: edgeText, ner: [], redactedSpans: edgeRedaction.spans)
        try check(edgeLimit != nil && edgeRedaction.spans.contains { (edgeLimit ?? Int.max) <= $0.range.location }
                  && !edgeRedaction.spans.contains { $0.range.location < (edgeLimit ?? 0) && (edgeLimit ?? 0) < NSMaxRange($0.range) },
                  "lexical edge bisected a canonical person replacement: limit=\(edgeLimit ?? -1), spans=\(edgeRedaction.spans.map(\.range))")
        let doseText = "Амоксициллин 500 мг обсуждаем переносимость терапии и схему применения."
        let doseContext = MeetingTranscriptPrivacyContext(redactor: redactor)
        let doseSegment = segment(doseText, track: track, start: 0)
        let doseUpdate = try await doseContext.redact(.init(segments: [doseSegment]))
        let evaluatedDose = try await redactor.redactWithSpans(doseText)
        try check(doseUpdate.segments.isEmpty, "dose preview released the durable hold")
        if (evaluatedDose.provisionalSafeUTF16 ?? 0) > 0 {
            try check(doseUpdate.livePreview?.text.hasPrefix("Амоксициллин 500 мг") == true,
                      "approved numeric dose prefix did not reach provisional display")
        } else {
            try check(doseUpdate.livePreview == nil, "withheld native person candidate reached provisional display")
        }
        let doseTail = try await doseContext.finish()
        let doseReference = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: [doseSegment]), using: redactor)
        try check(doseTail?.segments == doseReference.segments && doseTail?.livePreview == nil, "dose preview altered canonical text")
        let doseRange = (doseText as NSString).range(of: "Амоксициллин")
        let candidateDose = try PIIRedactor.provisionalSafePrefix(in: doseText,
            ner: [.init(range: doseRange, label: "PER", score: 0.2)], redactedSpans: [])
        try check(candidateDose == 0, "numeric dose evidence overrode an actual native person candidate")
        let decimalDose = "Амоксициллин 0.5 мг обсуждаем переносимость терапии и схему применения."
        let decimalLimit = try PIIRedactor.provisionalSafePrefix(in: decimalDose, ner: [], redactedSpans: [])
        try check((decimalLimit ?? 0) > (decimalDose as NSString).range(of: "мг").location,
                  "decimal dose punctuation was mistaken for a private email fragment")
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
