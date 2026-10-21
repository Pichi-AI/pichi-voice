import Foundation
import PichiTextPrivacy

private struct StructuredPrivacyRedactor: TranscriptTextRedacting {
    nonisolated var supportsSpeechBoundaryAdmission: Bool { true }
    func redactSpeechBoundaryWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redactSpeechBoundary(text, ner: [])
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) })
    }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redact(text, ner: [])
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) },
                     provisionalSafeUTF16: try PIIRedactor.provisionalSafePrefix(in: text, ner: [], redactedSpans: output.spans))
    }
}

private struct KnownNonPersonNERPrivacyRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let range = (text as NSString).range(of: "Здравствуйте")
        let ner: [PIINERSpan] = range.location == NSNotFound ? [] : [.init(range: range, label: "PER", score: 0.61)]
        let output = try PIIRedactor.redact(text, ner: ner)
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) },
            provisionalSafeUTF16: try PIIRedactor.provisionalSafePrefix(in: text, ner: ner, redactedSpans: output.spans))
    }
}

private struct ClinicalNERFixtureRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let source = text as NSString
        let ner = ["Амоксициллин", "Ксалендорин", "Xalendorin", "Иван", "Алиса"].compactMap { word -> PIINERSpan? in
            let range = source.range(of: word)
            return range.location == NSNotFound ? nil : .init(range: range, label: "PER", score: 0.99)
        }
        let output = try PIIRedactor.redact(text, ner: ner)
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) },
            provisionalSafeUTF16: try PIIRedactor.provisionalSafePrefix(in: text, ner: ner, redactedSpans: output.spans))
    }
}

#if !PII_POLICY_STANDALONE
private actor NativePrivacyRedactor: TranscriptTextRedacting {
    let runtime = PIINERRuntime()
    nonisolated var supportsSpeechBoundaryAdmission: Bool { true }
    func prepare(_ directory: URL, descriptor: PIIModelDescriptor = .russianTiny) async throws {
        try await runtime.load(descriptor: descriptor, directory: directory)
    }
    func redactSpeechBoundaryWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let output = try PIIRedactor.redactSpeechBoundary(text, ner: await runtime.tag(text))
        return .init(text: output.text, spans: output.spans.map { .init(range: $0.range, replacement: $0.replacement) })
    }
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

private actor RecordingPrivacyRedactor: TranscriptTextRedacting {
    private(set) var inputs: [String] = []
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        inputs.append(text)
        return try await StructuredPrivacyRedactor().redactWithSpans(text)
    }
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
    let useCueMask: Bool
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(started: AsyncStream<String>.Continuation, cancelled: AsyncStream<Void>.Continuation, useCueMask: Bool = false) {
        self.started = started; self.cancelled = cancelled; self.useCueMask = useCueMask
    }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        started.yield(text)
        await withTaskCancellationHandler {
            await withCheckedContinuation { waiters.append($0) }
        } onCancel: { self.cancelled.yield(()) }
        try Task.checkCancellation()
        if useCueMask { return try await CueMaskPrivacyRedactor().redactWithSpans(text) }
        return try await StructuredPrivacyRedactor().redactWithSpans(text)
    }
    func release() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
}

private struct SelectiveMaskPrivacyRedactor: TranscriptTextRedacting {
    let words: [String]
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let input = text as NSString
        var spans: [TranscriptRedactedSpan] = []
        for word in words {
            let range = input.range(of: word)
            if range.location != NSNotFound { spans.append(.init(range: range, replacement: "[REDACTED]")) }
        }
        let output = NSMutableString(string: text)
        for span in spans.sorted(by: { $0.range.location > $1.range.location }) {
            output.replaceCharacters(in: span.range, with: span.replacement)
        }
        return .init(text: output as String, spans: spans, provisionalSafeUTF16: input.length)
    }
}

private struct CueMaskPrivacyRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try await SelectiveMaskPrivacyRedactor(words: text.contains("пароль") ? ["qwerty"] : []).redactWithSpans(text)
    }
}

private struct AtomicFieldPrivacyRedactor: TranscriptTextRedacting {
    let initialSecret: String
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try await SelectiveMaskPrivacyRedactor(words: text.hasPrefix("пароль ") ? [initialSecret] : []).redactWithSpans(text)
    }
}

private actor ColdPagedPrivacyRedactor: TranscriptTextRedacting {
    enum Failure: Error { case notPrepared }
    nonisolated let checkpointIdentity: String? = "synthetic-cold-paging-v1"
    private(set) var preparations = 0
    private(set) var largestInputRows = 0
    private var ready = false
    func prepareForMeeting() async throws { preparations += 1; ready = true }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        guard ready else { throw Failure.notPrepared }
        largestInputRows = max(largestInputRows, text.components(separatedBy: "документ").count - 1)
        return try await StructuredPrivacyRedactor().redactWithSpans(text)
    }
}

private actor FailingPreparePrivacyRedactor: TranscriptTextRedacting {
    enum Failure: Error { case unavailable }
    private(set) var inferenceCalls = 0
    func prepareForMeeting() async throws { throw Failure.unavailable }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        inferenceCalls += 1
        return .init(text: text, spans: [], provisionalSafeUTF16: text.utf16.count)
    }
}

private actor DeferredPreparePrivacyRedactor: TranscriptTextRedacting {
    let started: AsyncStream<Void>.Continuation
    private var waiter: CheckedContinuation<Void, Never>?
    init(started: AsyncStream<Void>.Continuation) { self.started = started }
    func prepareForMeeting() async throws {
        started.yield(())
        await withCheckedContinuation { self.waiter = $0 }
    }
    func release() { waiter?.resume(); waiter = nil }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try Task.checkCancellation()
        return try await StructuredPrivacyRedactor().redactWithSpans(text)
    }
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
    static func speechBoundaryAdmissionSuite() async throws {
        let track = UUID()
        let value = MeetingTranscriptPrivacyContext(redactor: StructuredPrivacyRedactor())
        let ordinary = [segment("обсудили", track: track, start: 0), segment("планы.", track: track, start: 1)]
        let first = try await value.redact(.init(segments: ordinary))
        try check(first.segments.isEmpty, "The normal lexical tail must still be held")
        let settled = try await value.admitSpeechBoundary()!
        try check(settled.segments.map(\.id) == ordinary.map(\.id), "Speech admission changed IDs")
        try check(settled.segments.map(\.text) == ordinary.map(\.text), "Ordinary final words were masked or dropped")
        try check(settled.segments.map(\.start) == ordinary.map(\.start), "Speech admission changed timing")
        try check(settled.segments.allSatisfy { $0.originalText == nil }, "Raw sidecar escaped admission")
        try check(await value.earliestHeldWordStart == nil, "A settled tail remained held")
        try check(try await value.admitSpeechBoundary() == nil, "Repeated boundary duplicated text")
        let unsupported = MeetingTranscriptPrivacyContext(redactor: UnsupportedPreviewRedactor())
        _ = try await unsupported.redact(.init(segments: ordinary))
        try check(try await unsupported.admitSpeechBoundary() == nil, "Unsupported adapter admitted a boundary")
        try check(await unsupported.earliestHeldWordStart == 0, "Unsupported adapter dropped its tail")

        let phone = MeetingTranscriptPrivacyContext(redactor: StructuredPrivacyRedactor())
        // The canonical rule recognizes this seven-digit local phone value. Its
        // retained prefix must still qualify the following full-number continuation.
        let a = [segment("телефон", track: track, start: 0), segment("8", track: track, start: 1),
                 segment("999123", track: track, start: 2)]
        _ = try await phone.redact(.init(segments: a))
        let closedA = try await phone.admitSpeechBoundary()!
        try check(closedA.segments.map(\.id) == a.map(\.id), "Incomplete phone lost source words")
        try check(!closedA.segments.map(\.text).joined().contains("999123"), "Detected phone leaked at silence")
        let b = [segment("45", track: track, start: 20), segment("67", track: track, start: 21)]
        _ = try await phone.redact(.init(segments: b))
        let closedB = try await phone.admitSpeechBoundary()!
        try check(closedB.segments.map(\.id) == b.map(\.id), "Resumed phone lost source words")
        try check(closedB.segments.allSatisfy { $0.text == "[ТЕЛЕФОН]" }, "Retained prefix failed to protect continued phone")
        try check(try await phone.finish() == nil, "Stop duplicated an admitted phone")
        print("Speech boundary privacy: ordinary words, contextual phone continuation and idempotence passed")
    }

    static func completedSpeechBoundaryPrecisionSuite() throws {
        let ordinary = [
            "обсудили планы",
            "обсудили планы.",
            "обсудили номер задачи и телефон в справочнике затем продолжили обсуждение графика",
            "коллега рядом продолжает обсуждение",
            "Это вот они буквально недавно в апреле запустили там новую версию приложения и теперь мы обсуждаем работу интерфейса пока устройство распознаёт речь и показывает текст затем делаем паузу и ждём завершения обработки"
        ]
        for text in ordinary {
            let output = try PIIRedactor.redactSpeechBoundary(text, ner: [])
            try check(output.text == text && output.spans.isEmpty,
                "A completed ordinary fragment was masked, including its unpunctuated last word")
        }
        // An unfinished-preview hold is not canonical PII evidence. Even a rejected
        // NER candidate must not turn the rest of this completed fragment into a mask.
        let candidateText = "коллега рядом продолжает обсуждение"
        let candidate = try PIIRedactor.redactSpeechBoundary(candidateText,
            ner: [.init(range: (candidateText as NSString).range(of: "рядом"), label: "PER", score: 0.3)])
        try check(candidate.text == candidateText && candidate.spans.isEmpty,
            "A rejected provisional candidate masked ordinary completed words")

        let text = "Проверили 🙂 Ратмир, телефон 89991234567 и продолжили обсуждение"
        let source = text as NSString
        let nameRange = source.range(of: "Ратмир")
        let phoneRange = source.range(of: "89991234567")
        let output = try PIIRedactor.redactSpeechBoundary(text,
            ner: [.init(range: nameRange, label: "PER", score: 0.99)])
        try check(output.text == "Проверили 🙂 [ИМЯ], телефон [ТЕЛЕФОН] и продолжили обсуждение",
            "A detected entity changed surrounding ordinary completed text")
        try check(output.spans.map(\.range) == [nameRange, phoneRange]
            && output.spans.map(\.replacement) == ["[ИМЯ]", "[ТЕЛЕФОН]"],
            "Canonical entity masks lost their exact source UTF-16 ranges")
        var reconstructed = text
        for span in output.spans.reversed() {
            try check(Range(span.range, in: text) != nil, "A mask bisected a source character")
            reconstructed = (reconstructed as NSString).replacingCharacters(in: span.range, with: span.replacement)
        }
        try check(reconstructed == output.text, "Speech boundary span reconstruction failed")
        print("Completed speech privacy: punctuation, cue-only prose, rejected NER and precise entity offsets passed")
    }

    static func completedSpeechBoundaryContextSuite(using redactor: any TranscriptTextRedacting) async throws {
        let track = UUID()
        let phrases = [
            "обсудили номер задачи и телефон в справочнике затем продолжили обсуждение графика",
            "проверили работу интерфейса затем делаем паузу и ждём завершения обработки."
        ]
        let context = MeetingTranscriptPrivacyContext(redactor: redactor)
        for (phraseIndex, phrase) in phrases.enumerated() {
            let words = phrase.split(separator: " ").enumerated().map { index, word in
                segment(String(word), track: track, start: phraseIndex * 40 + index)
            }
            let initial = try await context.redact(.init(segments: words))
            try check(initial.segments.isEmpty, "The existing normal lexical hold changed")
            let safe = try await context.admitSpeechBoundary()!
            try check(safe.segments.map(\.text) == words.map(\.text),
                "Ordinary completed words remained hidden or were replaced after a quiet boundary")
            try check(safe.segments.map(\.id) == words.map(\.id)
                && safe.segments.map(\.start) == words.map(\.start)
                && safe.segments.map(\.end) == words.map(\.end),
                "Completed source word identity or timing changed")
            try check(safe.segments.allSatisfy { $0.originalText == nil }, "Raw sidecar escaped completed publication")
            try check(await context.earliestHeldWordStart == nil, "Completed ordinary source remained held during silence")
            try check(try await context.admitSpeechBoundary() == nil, "Repeated quiet progress republished source words")
        }
        try check(try await context.finish() == nil, "Stop republished already admitted speech")
        print("Completed context admission: ordinary source words drain during silence and resumed speech retains timing")
    }

    static func main() async throws {
        do {
            let context = MeetingTranscriptPrivacyContext(redactor: StructuredPrivacyRedactor())
            let track = UUID()
            var batch = MeetingPCMTranscriptBatch(segments: [segment("Обычная синтетическая реплика.", track: track, start: 0)])
            batch.speakerNameFormat = "Frozen %lld"
            let held = try await context.redact(batch)
            try check(held.speakerNameFormat == "Frozen %lld", "Privacy hold lost the attempt's speaker template")
            let sealed = try await context.admitSpeechBoundary()
            try check(sealed?.speakerNameFormat == "Frozen %lld", "Speech boundary lost the frozen speaker template")
            _ = try await context.redact(.init(segments: [segment("Продолжение обычной реплики.", track: track, start: 2)]))
            let final = try await context.finish()
            try check(final?.speakerNameFormat == "Frozen %lld", "Final privacy tail replaced the frozen speaker template")
        }
        try await speechBoundaryAdmissionSuite()
        try completedSpeechBoundaryPrecisionSuite()
        try await completedSpeechBoundaryContextSuite(using: StructuredPrivacyRedactor())
        try await participantAliasSuite()
        let coverageTrack = UUID()
        let coverageBatch = MeetingPCMTranscriptBatch(segments: [segment("слово", track: coverageTrack, start: 0),
            segment("продолжение", track: coverageTrack, start: 1)])
        let boundedPreview = try await MeetingTranscriptPrivacyPolicy.redactedBatch(coverageBatch,
            using: InvalidPreviewRedactor(limit: 8), provisionalPreviewID: UUID(),
            provisionalSegmentIDs: Set(coverageBatch.segments.map(\.id)))
        try check(boundedPreview.livePreview?.end == 1, "A partially approved fragment cannot extend pending audio replacement")
        let unknownPreview = try await MeetingTranscriptPrivacyPolicy.redactedBatch(coverageBatch,
            using: InvalidPreviewRedactor(limit: 2), provisionalPreviewID: UUID(),
            provisionalSegmentIDs: Set(coverageBatch.segments.map(\.id)))
        try check(unknownPreview.livePreview != nil && unknownPreview.livePreview?.end == nil,
                  "A partial first segment has no safely known audio endpoint")
        try await suite(using: StructuredPrivacyRedactor())
        try await liveSuite(using: StructuredPrivacyRedactor())
        try await provisionalSuite(using: StructuredPrivacyRedactor())
        #if !PII_POLICY_STANDALONE
        if let path = ProcessInfo.processInfo.environment["PICHI_PII_TEST_MODEL_DIRECTORY"] {
            let native = NativePrivacyRedactor()
            try await native.prepare(URL(fileURLWithPath: path, isDirectory: true))
            try await completedSpeechBoundaryContextSuite(using: native)
            try await suite(using: native)
            try await liveSuite(using: native)
            try await provisionalSuite(using: native)
            try await knownNonPersonPCMContextSuite(using: native)
            try await clinicalMedicationContextSuite(using: native)
        }
        if let path = ProcessInfo.processInfo.environment["PICHI_PII_A1_TEST_MODEL_DIRECTORY"] {
            let native = NativePrivacyRedactor()
            try await native.prepare(URL(fileURLWithPath: path, isDirectory: true), descriptor: .russianA1)
            try await completedSpeechBoundaryContextSuite(using: native)
        }
        #endif
        try await liveDeliverySuite()
        try await pagedLiveDeliverySuite()
        try await deferredPagedRevisionSuite()
        try await monotonePrivacyProjectionSuite()
        try await privacyPageEdgeMatrixSuite()
        try await partialMaskPrefixProofSuite()
        try await atomicRetainedFieldSuite()
        try await inFlightMaskPrefixProofSuite()
        try await emptyAvailabilityDoesNotPrepareSuite()
        try await joinedColdPreparationSuite()
        try await stableLiveHypothesisSuite()
        try await stablePCMHypothesisSuite()
        try await coarsePCMPreviewCoverageSuite()
        try await stablePCMObservationIdentitySuite()
        try await emptyPCMObservationIdentitySuite()
        try await knownNonPersonPCMContextSuite(using: KnownNonPersonNERPrivacyRedactor())
        try await partialUtteranceCoverageSuite()
        try await clinicalMedicationContextSuite(using: ClinicalNERFixtureRedactor())
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

    static func participantAliasSuite() async throws {
        let track = UUID()
        let alias = "Иван Тестов"
        var source = MeetingSession(configuration: .init(mode: .inRoom, title: alias,
            microphone: .init(captureDeviceID: "fixture", displayName: alias), piiRedactionEnabled: true),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        source.speakers = [.init(id: UUID(), displayName: "Speaker 1", diarizationClusterID: "synthetic",
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        source.transcriptSegments = [segment("Пациент Иван Тестов просит копию.", track: track, start: 0)]
        source.transcriptSegments[0].isUserTextEdited = true
        try source.renameSpeaker(id: source.speakers[0].id, to: "  \(alias)  ")
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: source, using: ClinicalNERFixtureRedactor())
        try check(safe.title == alias && safe.selectedMicrophone.displayName == alias,
                  "Explicit meeting and device display metadata must remain intact")
        try check(safe.speakers[0].displayName == alias, "An explicit participant name is outside transcript redaction")
        try check(!safe.transcriptSegments[0].text.contains("Иван"), "The same name spoken in a transcript must still be redacted")
        try check(safe.transcriptSegments[0].originalText == nil, "Alias exemption cannot restore original voice text")
        try check(safe.transcriptSegments[0].isUserTextEdited == true,
                  "Privacy removes original wording without erasing durable manual text provenance")
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(safe))
        let repeated = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: restored, using: ClinicalNERFixtureRedactor())
        try check(repeated.speakers[0].displayName == alias, "Repeated publication after reload must preserve the explicit alias")
        try check(repeated.transcriptSegments[0].isUserTextEdited == true,
                  "Manual text provenance survives privacy, archive codec and repeated publication")
        let batch = try await MeetingTranscriptPrivacyPolicy.redactedBatch(
            .init(segments: source.transcriptSegments, speakers: source.speakers), using: ClinicalNERFixtureRedactor())
        try check(batch.speakers[0].displayName == alias, "PCM publication must preserve a resumed participant alias")
        try check(!batch.segments[0].text.contains("Иван"), "PCM alias exemption must not exempt speech from redaction")
        try check(batch.segments[0].isUserTextEdited == true, "PCM privacy publication preserves manual text provenance")
        try check(source.transcriptSegments[0].text.contains("Иван"), "Publication cannot mutate source speech")
    }

    static func knownNonPersonPCMContextSuite(using redactor: any TranscriptTextRedacting) async throws {
        let punctuationText = "! Сегодня обсуждаем документы и условия хранения препарата."
        let punctuationNER = [PIINERSpan(range: NSRange(location: 0, length: 1), label: "PER", score: 0.49)]
        try check((try PIIRedactor.provisionalSafePrefix(in: punctuationText, ner: punctuationNER, redactedSpans: []) ?? 0) > 1,
                  "a punctuation-only PER result froze later ordinary speech")
        for candidate in ["ан", "ан сер", "Ан Сер обсуждает инструкцию и условия хранения препарата.",
                          "доктор ан на обсуждает инструкцию и условия хранения препарата."] {
            let output = try PIIRedactor.redact(candidate, ner: [])
            try check(try PIIRedactor.provisionalSafePrefix(in: candidate, ner: [], redactedSpans: output.spans) == 0,
                      "a positional name-prefix guard admitted an unresolved name fragment")
        }
        let context = MeetingTranscriptPrivacyContext(redactor: redactor)
        let track = UUID()
        let texts = [
            "Здравствуйте! Сегодня мы обсудим инструкции и посмотрим раздел с документами. После встречи запишем вопросы, которые нужно уточнить. Сайте, у вас есть.",
            "Запишем вопросы, которые нужно уточнить. Здравствуйте!",
            "Сегодня мы обсудим инструкции и посмотрим раздел с документами. После встречи запишем вопросы, которые нужно уточнить.",
        ]
        var previousText = ""
        for (index, text) in texts.enumerated() {
            let row = segment(text, track: track, start: index * 12)
            var observation = MeetingPCMTranscriptBatch(segments: [row], isComplete: false)
            _ = try await context.previewSpeech(observation)
            let stable = try await context.previewSpeech(observation)
            try check(stable != nil, "a known non-person PER froze a repeated stable hypothesis")
            observation.speechObservationIsFinal = true
            let sealed = try await context.previewSpeech(observation)
            try check(sealed != nil, "sealing erased protected speech after a known non-person PER")
            let checkpoint = try await context.redact(.init(segments: [row]))
            let visible = checkpoint.segments.map(\.text).joined(separator: " ") + " " + (checkpoint.livePreview?.text ?? "")
            try check(visible.utf16.count > previousText.utf16.count, "bounded raw context stopped advancing after a window rollover")
            try check(!visible.contains("[ИМЯ]"), "a known ordinary greeting became a false person mask")
            previousText = visible
        }
        for (index, text) in ["доктор иван", "петрович сидоров, обсуждает переносимость препарата и схему дальнейшего лечения."].enumerated() {
            let row = segment(text, track: track, start: 36 + index * 12)
            var observation = MeetingPCMTranscriptBatch(segments: [row], isComplete: false)
            _ = try await context.previewSpeech(observation)
            let stable = try await context.previewSpeech(observation)
            observation.speechObservationIsFinal = true
            let sealed = try await context.previewSpeech(observation)
            let checkpoint = try await context.redact(.init(segments: [row]))
            let visible = [stable?.text ?? "", sealed?.text ?? "", checkpoint.segments.map(\.text).joined(separator: " "), checkpoint.livePreview?.text ?? ""].joined(separator: " ")
            for name in ["иван", "петрович", "сидоров"] {
                try check(!visible.lowercased().contains(name), "ordinary greeting exclusion admitted a later cross-window name")
            }
        }
        let tail = try await context.finish()
        try check(tail != nil, "the display-only fix discarded the durable context tail")
    }

    static func partialUtteranceCoverageSuite() async throws {
        let first = "Сегодня мы обсудим подробную инструкцию и посмотрим раздел с документами."
        let prefix = "После встречи запишем вопросы которые нужно уточнить "
        let track = UUID()
        var firstRow = segment(first, track: track, start: 0)
        firstRow.end = .init(value: 4, timescale: 1)
        var secondRow = segment(prefix + "Анна", track: track, start: 4)
        secondRow.end = .init(value: 9, timescale: 1)
        let context = MeetingTranscriptPrivacyContext(redactor: StructuredPrivacyRedactor())
        _ = try await context.previewSpeech(.init(segments: [firstRow, secondRow], isComplete: false))
        secondRow.text = prefix + "детали"
        let preview = try await context.previewSpeech(.init(segments: [firstRow, secondRow], isComplete: false))
        try check(preview?.text.contains("После встречи") == true, "native utterance coverage probe did not admit a partial later fragment")
        try check(preview?.end == 4, "a clipped last utterance discarded an earlier source fragment's real endpoint")

        let coarseContext = MeetingTranscriptPrivacyContext(redactor: StructuredPrivacyRedactor())
        var coarse = firstRow
        coarse.end = secondRow.end
        coarse.text = first + " " + prefix + "Анна"
        _ = try await coarseContext.previewSpeech(.init(segments: [coarse], isComplete: false))
        coarse.text = first + " " + prefix + "детали"
        let coarsePreview = try await coarseContext.previewSpeech(.init(segments: [coarse], isComplete: false))
        try check(coarsePreview != nil && coarsePreview?.end == nil, "a coarse source utterance acquired a fabricated partial audio endpoint")
    }

    static func clinicalMedicationContextSuite(using redactor: any TranscriptTextRedacting) async throws {
        for drug in ["Амоксициллин", "Ксалендорин", "Xalendorin"] {
            let text = "Лекарство \(drug) 500 мг обсуждаем переносимость терапии и схему применения."
            let output = try await redactor.redactWithSpans(text)
            try check(output.text == text, "an explicit medication and actual dose remained a person mask")
            try check((output.provisionalSafeUTF16 ?? 0) > (text as NSString).range(of: drug).upperBound,
                      "canonical and provisional medication evidence disagreed")
        }
        let track = UUID()
        let context = MeetingTranscriptPrivacyContext(redactor: redactor)
        let rows = [segment("Лекарство Амоксициллин", track: track, start: 0),
                    segment("500 мг обсуждаем переносимость терапии и схему применения.", track: track, start: 12)]
        let initial = try await context.redact(.init(segments: [rows[0]]))
        try check(initial.segments.isEmpty && initial.livePreview == nil, "an unresolved medication edge bypassed lexical admission")
        let later = try await context.redact(.init(segments: [rows[1]]))
        try check(later.livePreview?.text.contains("Амоксициллин 500 мг") == true,
                  "a dose across the next window did not resolve an explicit medication context")
        let tail = try await context.finish()
        try check(tail?.segments.map(\.id) == rows.map(\.id), "medication context changed source segment identity")
        try check(tail?.segments.map(\.text) == rows.map(\.text), "medication context mutated the drug or dose")
        for (first, last, name) in [
            ("пациент Иван", "500 мг обсуждает переносимость терапии и схему применения.", "Иван"),
            ("лекарство Алиса", "500 мг обсуждаем переносимость терапии и схему применения.", "Алиса"),
        ] {
            let context = MeetingTranscriptPrivacyContext(redactor: redactor)
            let initial = try await context.redact(.init(segments: [segment(first, track: track, start: 0)]))
            let continued = try await context.redact(.init(segments: [segment(last, track: track, start: 12)]))
            let tail = try await context.finish()
            for batch in [initial, continued] + (tail.map { [$0] } ?? []) {
                let visible = batch.segments.map(\.text).joined(separator: " ") + (batch.livePreview?.text ?? "")
                try check(!visible.contains(name), "an actual person acquired a dose-only medication exemption")
            }
        }
    }

    static func liveSuite(using redactor: any TranscriptTextRedacting) async throws {
        let cases: [(String, [String], [String], String)] = [
            ("документ передали сидорову", ["ивану", "ивану петровичу метформин 500 мг"], ["сидорову", "ивану", "петровичу"], "метформин 500 мг"),
            ("телефон 273", ["55", "55 11 метотрексат 15 мг"], ["273", "55 11"], "метотрексат 15 мг"),
            ("дата рождения 12", ["мая", "мая 1980 инсулин 10 единиц"], ["12", "мая 1980"], "инсулин 10 единиц"),
            ("домашний адрес улица Примерная", ["дом", "дом 12 квартира 7 лизиноприл 10 мг"], ["Примерная", "квартира 7"], "лизиноприл 10 мг"),
            ("карта 4111", ["1111", "1111 1111", "1111 1111 1111 508 рублей оземпик"], ["4111", "1111", "508"], "рублей оземпик"),
        ]
        for (initial, partials, privatePieces, medication) in cases {
            let first = MeetingLiveUtterance(id: UUID(), speaker: .you, text: initial, start: 0, end: 1)
            let partialID = UUID()
            var raw = MeetingLiveTranscriptSnapshot.empty
            raw.utterances = [first]
            raw.availability = .available
            raw.revision = 1
            for (index, text) in partials.enumerated() {
                raw = raw.settingPartial(.init(id: partialID, text: text, start: 1, stableUTF16Count: text.utf16.count), for: .you)
                raw.revision += 1
                let safe = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: redactor)
                if let retained = safe.utterances.first {
                    try check(retained.id == first.id && retained.start == 0 && retained.end == 1, "live completed row identity/timing changed")
                }
                if let retained = safe.partials[.you] {
                    try check(retained.id == partialID && retained.start == 1, "live partial identity changed")
                }
                try check(raw.utterances[0].text == initial && raw.partials[.you]?.text == text, "filtered strings replaced canonical raw input")
                if index == partials.count - 1 {
                    let joined = safe.utterances.map(\.text).joined(separator: " ") + " " + (safe.partials[.you]?.text ?? "")
                    for value in privatePieces { try check(!joined.contains(value), "earlier completed live row was not corrected: \(value)") }
                }
            }
            raw = raw.settingPartial(nil, for: .you).inserting(.init(id: partialID, speaker: .you, text: partials.last!, start: 1, end: 4))
            raw.revision += 1
            let completed = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: redactor)
            try check(completed.utterances.allSatisfy { $0.id == first.id || $0.id == partialID }, "EOU changed continuous row identities")
            if let retained = completed.utterances.first(where: { $0.id == partialID }) {
                try check(retained.start == 1 && retained.end == 4, "EOU timing changed")
            }
            try check(completed.partials.isEmpty, "EOU retained an open hypothesis")
            let joined = completed.utterances.map(\.text).joined(separator: " ")
            for value in privatePieces { try check(!joined.contains(value), "completed rows restored recognized PII") }
            // Final export uses canonical projection; live EOU keeps the same lexical hold.
            let canonical = try await redactor.redact((raw.utterances.map(\.text)).joined(separator: " "))
            try check(canonical.contains(medication), "canonical privacy changed a medication/dose")
        }
        // Separate source tags remain source tags, not diarization identities.
        var sources = MeetingLiveTranscriptSnapshot.empty
        sources.utterances = [.init(id: UUID(), speaker: .you, text: "дата рождения", start: 0, end: 1),
                              .init(id: UUID(), speaker: .them, text: "12 мая 1980", start: 1, end: 2)]
        let recorder = RecordingPrivacyRedactor()
        _ = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(sources, using: recorder)
        let sourceInputs = await recorder.inputs
        try check(sourceInputs == ["дата рождения", "12 мая 1980"], "microphone context contaminated another audio source")
    }

    static func stableLiveHypothesisSuite() async throws {
        let recorder = RecordingPrivacyRedactor()
        let partialID = UUID()
        var raw = MeetingLiveTranscriptSnapshot.empty
        raw.revision = 1
        // A temporary name hypothesis must not be classified, displayed or retained as a mask.
        raw.partials[.you] = .init(id: partialID, text: "Анна", start: 1, end: 2)
        let unstable = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: recorder)
        try check(unstable.partials.isEmpty && unstable.utterances.isEmpty, "volatile raw hypothesis escaped privacy admission")
        let unstableInputs = await recorder.inputs
        try check(unstableInputs.isEmpty, "NER evaluated a volatile name hypothesis")

        let stable = "Сегодня обсуждаем планы дальнейшего тестирования распознавания."
        raw.partials[.you] = .init(id: partialID, text: stable + " Анна", start: 1, end: 5,
                                 stableUTF16Count: stable.utf16.count)
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: recorder)
        let inputs = await recorder.inputs
        try check(inputs == [stable], "NER input included the unstable tail or omitted stable context")
        try check(safe.partials[.you]?.text.contains("Сегодня обсуждаем планы") == true,
                  "admitted stable words did not reach display")
        try check(safe.partials[.you]?.text.contains("Анна") == false && safe.partials[.you]?.text.contains("[ИМЯ]") == false,
                  "temporary name hypothesis changed stable display")
        try check(safe.partials[.you]?.end == nil && safe.partials[.you]?.stableUTF16Count == nil,
                  "trimmed privacy text claimed full raw audio or retained raw offsets")
        try check(raw.partials[.you]?.text == stable + " Анна", "privacy replaced its raw source with display text")

        raw.partials = [:]
        raw.utterances = [.init(id: partialID, speaker: .you, text: stable, start: 1, end: 5)]
        let final = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: recorder)
        let finalDisplayed = final.utterances.map(\.text).joined(separator: " ")
        try check(finalDisplayed == safe.partials[.you]?.text && final.partials.isEmpty,
                  "EOU changed lexical admission before the final pipeline flush")
        try check(final.utterances.first?.hasIncompleteTextCoverage == true,
                  "a privacy-held finalized tail claimed full audio coverage")
        raw.partials[.you] = .init(id: UUID(), text: "Новая неподтверждённая гипотеза", start: 5)
        let nextTurn = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: recorder)
        try check(nextTurn.utterances.map(\.text).joined(separator: " ") == finalDisplayed,
                  "a new volatile turn removed previously approved text")

        // A possible entity ending one finalized turn waits for adjacent stable context.
        raw.utterances = [.init(id: UUID(), speaker: .you, text: "Передали документ сидорову", start: 0, end: 1)]
        raw.partials[.you] = .init(id: partialID, text: "ивану петровичу сегодня обсуждаем планы лечения.", start: 1,
                                 stableUTF16Count: "ивану петровичу сегодня обсуждаем планы лечения.".utf16.count)
        let joined = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: recorder)
        let displayed = joined.utterances.map(\.text).joined(separator: " ") + " " + (joined.partials[.you]?.text ?? "")
        for privatePiece in ["сидорову", "ивану", "петровичу"] {
            try check(!displayed.contains(privatePiece), "adjacent stable name context exposed a source fragment")
        }

        for invalid in [-1, 1, 3, 10_000] {
            raw.utterances = []
            raw.partials[.you] = .init(id: partialID, text: "🙂слово продолжение", start: 0, stableUTF16Count: invalid)
            do {
                _ = try await MeetingTranscriptPrivacyPolicy.redactedLiveSnapshot(raw, using: recorder)
                throw Failure.assertion("invalid stability offset reached NER")
            } catch is MeetingPrivacyPublicationError { }
        }
    }

    static func stablePCMHypothesisSuite() async throws {
        let recorder = RecordingPrivacyRedactor()
        let context = MeetingTranscriptPrivacyContext(redactor: recorder)
        let track = UUID()
        let id = UUID()
        func observation(_ text: String, final: Bool = false, rowID: UUID? = nil) -> MeetingPCMTranscriptBatch {
            var row = segment(text, track: track, start: 0)
            row.id = rowID ?? id
            row.status = .provisional
            var batch = MeetingPCMTranscriptBatch(segments: [row], isComplete: false)
            batch.speechObservationIsFinal = final
            return batch
        }
        let initial = try await context.previewSpeech(observation("Анна"))
        try check(initial == nil, "first PCM hypothesis was displayed before stability")
        let initialInputs = await recorder.inputs
        try check(initialInputs.isEmpty, "NER classified an unconfirmed PCM name hypothesis")
        let stable = "Сегодня обсуждаем планы дальнейшего тестирования распознавания речи"
        _ = try await context.previewSpeech(observation(stable + " Анна"))
        let preview = try await context.previewSpeech(observation(stable + " после исправления"))
        let inputs = await recorder.inputs
        try check(inputs == [stable], "PCM NER input included a changed lexical edge: \(inputs)")
        try check(preview?.text.hasPrefix("Сегодня обсуждаем планы") == true && preview?.end == nil,
                  "stable clipped PCM text did not display with conservative audio coverage")
        try check(preview?.text.contains("Анна") == false && preview?.text.contains("[ИМЯ]") == false,
                  "temporary PCM name classification reached display")
        let beforeNewWindow = inputs.count
        _ = try await context.previewSpeech(observation(stable, rowID: UUID()))
        let afterNewWindow = await recorder.inputs
        try check(afterNewWindow.count == beforeNewWindow, "another PCM window inherited hypothesis stability")
        let sealed = try await context.previewSpeech(observation(stable + ".", final: true))
        let sealedInputs = await recorder.inputs
        try check(sealedInputs.last == stable + "." && sealed != nil, "sealed PCM text waited for another inference")
        let durable = try await context.finish()
        try check(durable == nil, "speech observations entered the canonical tail")
        _ = try await context.previewSpeech(observation(stable + "."))
        let afterFinish = await recorder.inputs
        try check(afterFinish.count == sealedInputs.count, "finished context retained raw hypothesis stability")

        let wordRecorder = RecordingPrivacyRedactor()
        let words = MeetingTranscriptPrivacyContext(redactor: wordRecorder)
        var wordRows = ["Сегодня", "обсуждаем", "планы", "дальнейшего", "тестирования", "распознавания", "Анна"]
            .enumerated().map { segment($0.element, track: track, start: $0.offset) }
        _ = try await words.previewSpeech(.init(segments: wordRows, isComplete: false))
        wordRows[wordRows.count - 1].text = "после"
        let wordPreview = try await words.previewSpeech(.init(segments: wordRows, isComplete: false))
        let wordInputs = await wordRecorder.inputs
        try check(wordInputs == ["Сегодня обсуждаем планы дальнейшего тестирования распознавания"],
                  "word-level stability included an unconfirmed fragment")
        try check(wordPreview?.text == "Сегодня обсуждаем" && wordPreview?.end == 2,
                  "fully admitted word fragments lost their exact approved audio coverage")
        _ = try await words.finish()
    }

    static func coarsePCMPreviewCoverageSuite() async throws {
        struct FullyAdmittedPreview: TranscriptTextRedacting {
            func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
                .init(text: text, spans: [], provisionalSafeUTF16: text.utf16.count)
            }
        }
        let track = UUID(), attempt = UUID(), rowID = UUID(), previewID = UUID()
        let text = "Сегодня обсуждаем подробную инструкцию и проверяем запись разговора."
        let identity = MeetingPCMTranscriptBatch.SpeechObservationIdentity(attemptID: attempt,
            epochID: .init(trackID: track, ordinal: 0))
        func observation(end: Int, native: Bool?, final: Bool = false) -> MeetingPCMTranscriptBatch {
            var row = segment(text, track: track, start: 10)
            row.id = rowID
            row.end = .init(value: Int64(end), timescale: 1)
            var batch = MeetingPCMTranscriptBatch(segments: [row], isComplete: false)
            batch.speechObservationIdentity = identity
            batch.speechObservationHasNativeTiming = native
            batch.speechObservationIsFinal = final
            return batch
        }
        for native in [false, true] {
            let context = MeetingTranscriptPrivacyContext(redactor: FullyAdmittedPreview())
            let first = observation(end: 13, native: native)
            let next = observation(end: 16, native: native)
            let firstProtected = try await context.previewSpeech(first)
            try check(firstProtected == nil, "coverage evidence bypassed hypothesis agreement")
            let protected = try await context.previewSpeech(next)
            try check(protected?.text == text, "coarse timing suppressed the approved words themselves")
            try check(first.speechPreview(id: previewID)?.end == (native ? 13 : nil),
                      "no-privacy preview treated a sampled window as native speech coverage")
            try check(protected?.end == (native ? 16 : nil),
                      "unchanged coarse hypotheses retired newly captured audio")
            let sealed = observation(end: 16, native: native, final: true)
            let finalProtected = try await context.previewSpeech(sealed)
            try check(finalProtected?.end == 16 && sealed.speechPreview(id: previewID)?.end == 16,
                      "sealed accepted audio lost its known physical endpoint")
        }
        let legacy = observation(end: 13, native: nil)
        try check(legacy.speechPreview(id: previewID)?.end == 13,
                  "metadata-free callers lost their existing coverage contract")
        let legacyContext = MeetingTranscriptPrivacyContext(redactor: FullyAdmittedPreview())
        _ = try await legacyContext.previewSpeech(legacy)
        let legacyProtected = try await legacyContext.previewSpeech(legacy)
        try check(legacyProtected?.end == 13, "legacy contextual publication changed its timing contract")

        let held = MeetingTranscriptPrivacyContext(redactor: InvalidPreviewRedactor(limit: 8))
        var nativeRows = MeetingPCMTranscriptBatch(segments: [segment("Сегодня", track: track, start: 0),
            segment("обсуждаем подробную инструкцию.", track: track, start: 1)], isComplete: false)
        nativeRows.speechObservationHasNativeTiming = true
        nativeRows.speechObservationIsFinal = true
        let heldPreview = try await held.previewSpeech(nativeRows)
        try check(heldPreview?.end == 1, "native timing bypassed the privacy-approved prefix endpoint")
        print("PASS coarse/native PCM preview coverage, sealed bounds, legacy callers and privacy holdback")
    }

    static func stablePCMObservationIdentitySuite() async throws {
        let recorder = RecordingPrivacyRedactor()
        let context = MeetingTranscriptPrivacyContext(redactor: recorder)
        let track = UUID()
        let attempt = UUID()
        let identity = MeetingPCMTranscriptBatch.SpeechObservationIdentity(attemptID: attempt,
            epochID: .init(trackID: track, ordinal: 0))
        let coarseID = UUID()
        func observation(_ pieces: [String], identity: MeetingPCMTranscriptBatch.SpeechObservationIdentity,
                         firstID: UUID = UUID(), drift: Int64 = 0) -> MeetingPCMTranscriptBatch {
            let base = Int64(identity.epochID.ordinal / 16)
            let rows = pieces.enumerated().map { index, text -> MeetingTranscriptSegment in
                var row = segment(text, track: identity.epochID.trackID, start: 0)
                row.id = index == 0 ? firstID : UUID()
                row.start = .init(value: base + Int64(index * 2_000) + drift, timescale: 1_000)
                row.end = .init(value: base + Int64(index * 2_000 + 1_500) + drift, timescale: 1_000)
                return row
            }
            var batch = MeetingPCMTranscriptBatch(segments: rows, isComplete: false)
            batch.speechObservationIdentity = identity
            return batch
        }
        let first = "Сегодня обсуждаем планы дальнейшего тестирования распознавания речи."
        _ = try await context.previewSpeech(observation([first], identity: identity, firstID: coarseID))
        let native = try await context.previewSpeech(observation(["Сегодня обсуждаем планы", "дальнейшего тестирования",
            "распознавания речи. Проверим работу микрофона."], identity: identity, drift: 60))
        try check(native != nil, "native segment partition/start drift reset one physical hypothesis")
        let coarse = try await context.previewSpeech(observation([first + " Проверим работу микрофона. Потом сохраним результат."],
            identity: identity, firstID: coarseID))
        try check(coarse != nil, "coarse fallback reset the same physical hypothesis")
        let admittedInputs = await recorder.inputs
        try check(admittedInputs.count == 2 && admittedInputs[0] == first,
                  "partition changes bypassed or discarded whole-word agreement")

        for other in [
            MeetingPCMTranscriptBatch.SpeechObservationIdentity(attemptID: UUID(), epochID: identity.epochID),
            .init(attemptID: attempt, epochID: .init(trackID: track, ordinal: 192_000)),
            .init(attemptID: attempt, epochID: .init(trackID: track, ordinal: 0, generation: 1)),
            .init(attemptID: attempt, epochID: .init(trackID: UUID(), ordinal: 0)),
        ] {
            _ = try await context.previewSpeech(observation([first], identity: identity, firstID: coarseID))
            let before = await recorder.inputs.count
            let value = try await context.previewSpeech(observation([first], identity: other, firstID: coarseID))
            let after = await recorder.inputs.count
            try check(value == nil && after == before, "a different attempt/track/window/replay inherited stability")
        }
        _ = try await context.previewSpeech(observation([first], identity: identity, firstID: coarseID))
        var legacy = observation([first], identity: identity, firstID: coarseID)
        legacy.speechObservationIdentity = nil
        let beforeLegacy = await recorder.inputs.count
        _ = try await context.previewSpeech(legacy)
        let afterLegacy = await recorder.inputs.count
        try check(beforeLegacy == afterLegacy, "legacy fallback matched a previous typed observation")
        let repeatedLegacy = try await context.previewSpeech(legacy)
        try check(repeatedLegacy != nil, "legacy first-segment agreement stopped working")

        var wrongTrack = observation([first], identity: identity)
        wrongTrack.segments[0].sourceTrackID = UUID()
        do {
            _ = try await context.previewSpeech(wrongTrack)
            throw Failure.assertion("observation provenance accepted another source track")
        } catch is MeetingPrivacyPublicationError { }

        let corrections = RecordingPrivacyRedactor()
        let correcting = MeetingTranscriptPrivacyContext(redactor: corrections)
        _ = try await correcting.previewSpeech(observation(["Иван"], identity: identity))
        _ = try await correcting.previewSpeech(observation(["и вам завтра нужно проверить инструкцию."], identity: identity))
        let correctedInputs = await corrections.inputs
        try check(correctedInputs.isEmpty, "typed identity allowed an unstable word correction into NER")
        let stable = try await correcting.previewSpeech(observation(["и вам завтра нужно проверить инструкцию. Потом обсудим результат."], identity: identity))
        try check(stable?.text.contains("Иван") == false && stable?.text.contains("[ИМЯ]") == false,
                  "corrected transient name reached protected display")
    }

    static func emptyPCMObservationIdentitySuite() async throws {
        let recorder = RecordingPrivacyRedactor()
        let context = MeetingTranscriptPrivacyContext(redactor: recorder)
        let track = UUID(), attempt = UUID()
        let identity = MeetingPCMTranscriptBatch.SpeechObservationIdentity(attemptID: attempt,
            epochID: .init(trackID: track, ordinal: 0))
        func empty(_ identity: MeetingPCMTranscriptBatch.SpeechObservationIdentity, sealed: Bool = false) -> MeetingPCMTranscriptBatch {
            var batch = MeetingPCMTranscriptBatch(segments: [], isComplete: false)
            batch.speechObservationIdentity = identity; batch.speechObservationIsFinal = sealed
            return batch
        }
        let firstEmpty = empty(identity)
        let first = try await context.previewSpeech(firstEmpty)
        let beforeSpeech = await recorder.inputs
        try check(first == nil && beforeSpeech.isEmpty && firstEmpty.sourceTrack == nil,
                  "a genuine first empty observation failed or invented source/word evidence")
        let old = segment("Сегодня обсуждаем подробную инструкцию и условия хранения препарата.", track: track, start: 0)
        _ = try await context.redact(.init(segments: [old]))
        let next = MeetingPCMTranscriptBatch.SpeechObservationIdentity(attemptID: attempt,
            epochID: .init(trackID: track, ordinal: 192_000))
        let pendingEmpty = try await context.previewSpeech(empty(next))
        try check(pendingEmpty == nil, "an empty next window inherited an earlier pending preview")
        var speech = MeetingPCMTranscriptBatch(segments: [segment(
            "Затем проверим результат распознавания и обсудим планы следующей встречи.", track: track, start: 12)], isComplete: false)
        speech.speechObservationIdentity = next
        let beforeFirstWords = await recorder.inputs.count
        _ = try await context.previewSpeech(speech)
        let afterFirstWords = await recorder.inputs.count
        try check(beforeFirstWords == afterFirstWords, "an empty observation confirmed the first text hypothesis")
        let stillUnconfirmed = try await context.previewSpeech(empty(next))
        try check(stillUnconfirmed == nil, "empty current speech retagged a safe prefix from an earlier window")
        let approved = try await context.previewSpeech(speech)
        try check(approved != nil, "a later repeated hypothesis failed after a valid empty observation")
        let beforeSeal = await recorder.inputs.count
        let sealed = try await context.previewSpeech(empty(next, sealed: true))
        let afterSeal = await recorder.inputs.count
        try check(sealed == approved && beforeSeal == afterSeal, "an empty seal confirmed words or erased its own approved preview")
        let otherAttempt = MeetingPCMTranscriptBatch.SpeechObservationIdentity(attemptID: UUID(), epochID: next.epochID)
        let different = try await context.previewSpeech(empty(otherAttempt, sealed: true))
        try check(different == nil, "an empty observation inherited another attempt's approved preview")
        let tail = try await context.finish()
        try check(tail?.segments.map(\.id) == [old.id], "empty/provisional speech entered the durable tail")

        let explicitOtherSource = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic microphone", format: nil,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [])
        for var mismatched in [empty(identity), speech] {
            mismatched.sourceTrack = explicitOtherSource
            let rejecting = MeetingTranscriptPrivacyContext(redactor: recorder)
            do {
                _ = try await rejecting.previewSpeech(mismatched)
                throw Failure.assertion("typed metadata overrode an explicitly contradictory track")
            } catch is MeetingPrivacyPublicationError { }
        }
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
        large.utterances = (0..<200).map { index in .init(id: UUID(), speaker: .you,
            text: "документ инструкция терапия схема применение переносимость", start: Double(index), end: Double(index + 1)) }
        submit(large, UUID())
        let boundedInput = await starts.next()
        try check(boundedInput?.components(separatedBy: "документ").count == 101,
                  "pending raw snapshot retained rows outside the display bound")
        await redactor.release()
        let boundedOutput = await updates.next()
        try check(boundedOutput?.0.utterances.count == 100 && boundedOutput?.0.utterances.first?.id == large.utterances[100].id, "bounded live rows changed identity")
        await publisher.stop()
    }

    @MainActor
    static func pagedLiveDeliverySuite() async throws {
        let delivery = AsyncStream<MeetingLiveTranscriptSnapshot>.makeStream()
        let timeout = Task { try? await Task.sleep(for: .seconds(60)); delivery.continuation.finish() }
        defer { timeout.cancel() }
        let publisher = MeetingLivePrivacyPublication()
        let detector = ColdPagedPrivacyRedactor()
        let generation = UUID()
        var failures = 0
        var source = MeetingLiveTranscriptSnapshot.empty
        source.revision = 1
        source.utterances = (0..<1_200).map { index -> MeetingLiveUtterance in
            let speaker: MeetingLiveSpeaker = index % 2 == 0 ? .you : .them
            return MeetingLiveUtterance(id: UUID(), speaker: speaker,
                  text: "документ инструкция терапия схема применение.", start: Double(index), end: Double(index + 1))
        }
        // One source's person name crosses the 100-row page edge. Page overlap must
        // provide raw context while every delivered version remains protected.
        for (index, text) in [(98, "доктор Иван"), (100, "Петрович Сидоров, обсуждает препарат.")] {
            source.utterances[index].speaker = .you; source.utterances[index].text = text
        }
        func submit() {
            publisher.submit(source, generation: generation, using: detector, latestSnapshot: { source },
                publish: { value, _ in delivery.continuation.yield(value) },
                failed: { _ in failures += 1; delivery.continuation.finish() })
        }
        var updates = delivery.stream.makeAsyncIterator()
        func complete(_ count: Int) async throws -> MeetingLiveTranscriptSnapshot {
            while let value = await updates.next() {
                let text = value.utterances.map(\.text).joined(separator: " ")
                for name in ["Иван", "Петрович", "Сидоров"] {
                    try check(!text.contains(name), "a person name escaped while crossing a bounded privacy page")
                }
                if value.utterances.count == count { return value }
            }
            throw Failure.assertion("bounded privacy paging did not produce the complete protected history")
        }
        submit()
        let first = try await complete(1_200)
        try check(first.utterances.map(\.id) == source.utterances.map(\.id),
                  "an initial 1200-row snapshot lost unseen rows outside the 100-row detector page")
        try check(await detector.preparations == 1, "cold live privacy did not prepare its frozen redactor exactly once")
        try check(await detector.largestInputRows <= 100, "privacy paging exceeded its raw row budget")

        source.utterances += (1_200..<1_400).map { index -> MeetingLiveUtterance in
            MeetingLiveUtterance(id: UUID(), speaker: .you, text: "документ инструкция терапия схема применение.",
                  start: Double(index), end: Double(index + 1))
        }
        source.revision += 1
        submit()
        let extended = try await complete(1_400)
        try check(extended.utterances.prefix(1_200).map(\.id) == first.utterances.map(\.id),
                  "coalesced growth beyond the page budget lost earlier participants")
        let withdrawn = source.utterances.remove(at: 20).id
        let changed = source.utterances[50].id
        source.utterances[50].text = "документ инструкция терапия схема применение. документ."
        source.revision += 1
        submit()
        let revised = try await complete(1_399)
        try check(!revised.utterances.contains { $0.id == withdrawn }, "a withdrawn raw row remained in protected history")
        try check(revised.utterances.first(where: { $0.id == changed })?.text == "документ инструкция терапия схема применение. документ.",
                  "a previously visited raw row was not revalidated after correction")
        try check(await detector.preparations == 1 && failures == 0, "paging restarted preparation or failed a valid history")
        await publisher.stop()
        print("PASS cold privacy preparation, 1200-row initial/backfill, 1400-row growth, source retraction/revision and cross-page person masking")
    }

    @MainActor
    static func deferredPagedRevisionSuite() async throws {
        let began = AsyncStream<String>.makeStream()
        let cancelled = AsyncStream<Void>.makeStream()
        let delivery = AsyncStream<MeetingLiveTranscriptSnapshot>.makeStream()
        let timeout = Task { try? await Task.sleep(for: .seconds(60)); delivery.continuation.finish(); began.continuation.finish() }
        defer { timeout.cancel() }
        let detector = DeferredLiveRedactor(started: began.continuation, cancelled: cancelled.continuation)
        let publisher = MeetingLivePrivacyPublication()
        let generation = UUID()
        var source = MeetingLiveTranscriptSnapshot.empty
        source.revision = 1
        source.utterances = (0..<60).map { index -> MeetingLiveUtterance in
            .init(id: UUID(), speaker: .you, text: "документ инструкция терапия.", start: Double(index), end: Double(index + 1))
        }
        var failures = 0
        func submit() {
            publisher.submit(source, generation: generation, using: detector, latestSnapshot: { source },
                publish: { value, _ in delivery.continuation.yield(value) },
                failed: { _ in failures += 1; delivery.continuation.finish() })
        }
        submit()
        var starts = began.stream.makeAsyncIterator()
        _ = await starts.next()
        // The first page is still inside a noncooperative detector. Withdraw and
        // revise its source, then coalesce a history jump much larger than one page.
        let withdrawn = source.utterances.remove(at: 10).id
        let changed = source.utterances[15].id
        source.utterances[15].text = "документ инструкция."
        source.utterances += (60..<1_260).map { index -> MeetingLiveUtterance in
            .init(id: UUID(), speaker: .you, text: "документ инструкция терапия.", start: Double(index), end: Double(index + 1))
        }
        source.revision = 2; submit()
        source.revision = 3; submit()
        let releaser = Task {
            while await starts.next() != nil { await detector.release() }
        }
        await detector.release()
        var updates = delivery.stream.makeAsyncIterator()
        var complete = false
        while let value = await updates.next() {
            try check(!value.utterances.contains { $0.id == withdrawn },
                      "a page withdrawn during inference was published")
            if let revised = value.utterances.first(where: { $0.id == changed }) {
                try check(revised.text == "документ инструкция.", "a stale in-flight raw text version was published")
            }
            if value.utterances.count == source.utterances.count {
                try check(value.utterances.map(\.id) == source.utterances.map(\.id),
                          "coalesced history backfill omitted an unseen word")
                complete = true; break
            }
        }
        await publisher.stop()
        began.continuation.finish(); releaser.cancel(); await releaser.value
        try check(complete && failures == 0, "source revisions during native inference did not recover complete history")
        print("PASS 60-to-1259 coalescing and stale-page rejection/retry while inference is deferred")
    }

    static func monotonePrivacyProjectionSuite() async throws {
        var source = MeetingLiveTranscriptSnapshot.empty
        let id = UUID()
        let raw = " leftSECRET rightSECRET"
        source.utterances = [.init(id: id, speaker: .you, text: raw, start: 0, end: 1)]
        let first = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: ["leftSECRET"]))
        let second = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: ["rightSECRET"]), preserving: first.redactions)
        let third = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: []), preserving: second.redactions)
        for projection in [second, third] {
            let text = projection.snapshot.utterances.map(\.text).joined()
            try check(!text.contains("leftSECRET") && !text.contains("rightSECRET"),
                      "a later context removed an earlier raw-offset mask or discarded a new mask")
        }
        source.utterances = []
        let partial = MeetingLivePartial(id: id, text: raw, start: 0, stableUTF16Count: raw.utf16.count)
        source.partials[.you] = partial
        let protected = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: []), preserving: second.redactions)
        try check(protected.snapshot.partials[.you]?.text == "[REDACTED] [REDACTED]",
                  "an unchanged partial lost its masks when preceding context left the page")
        source.partials = [:]
        source.utterances = [.init(id: id, speaker: .you, text: raw, start: 0, end: 1)]
        let final = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: []), preserving: protected.redactions)
        try check(final.snapshot.utterances.first?.text == " [REDACTED] [REDACTED]",
                  "partial-to-final masks lost their original UTF16 coordinates after trimming")

        source.utterances = [.init(id: id, speaker: .you, text: "alpha beta gamma", start: 0, end: 1)]
        let overlapping = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: ["alpha beta"]))
        let strengthened = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: ["beta gamma"]), preserving: overlapping.redactions)
        try check(strengthened.snapshot.utterances.first?.text == "[REDACTED]",
                  "overlapping detector disagreements exposed part of either previously masked range")

        let shrinkingRaw = " alpha beta gamma."
        source.utterances = []
        source.partials[.you] = .init(id: id, text: shrinkingRaw, start: 0, stableUTF16Count: shrinkingRaw.utf16.count)
        let complete = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: ["beta gamma"]))
        source.partials[.you]?.stableUTF16Count = " alpha beta ".utf16.count
        let shortened = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: []), preserving: complete.redactions)
        try check(shortened.snapshot.partials[.you]?.text == "alpha", "a shorter stable prefix bisected a retained mask")
        source.partials[.you]?.stableUTF16Count = shrinkingRaw.utf16.count
        let regrown = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(source,
            using: SelectiveMaskPrivacyRedactor(words: []), preserving: shortened.redactions)
        try check(regrown.snapshot.partials[.you]?.text == "alpha [REDACTED]",
                  "stable-prefix shrink and growth discarded a previously known mask")
    }

    @MainActor
    static func privacyPageEdgeMatrixSuite() async throws {
        let edges = [36, 68, 72, 100, 104, 108, 136, 140, 144, 172, 176, 180, 208, 212, 216, 244, 248, 252, 280, 284, 288]
        let scenarios: [(String, String, [String])] = [
            ("пароль", "qwerty", ["qwerty"]),
            ("дата рождения", "12.03.1985", ["1985"]),
            ("телефон", "+7 903 112-34-56", ["903", "112-34-56"]),
            ("доктор", "Иван Петрович Сидоров", ["Иван", "Петрович", "Сидоров"])
        ]
        for (cue, secret, forbidden) in scenarios {
            for offset in [-1, 0, 1] {
                let delivery = AsyncStream<MeetingLiveTranscriptSnapshot>.makeStream()
                let timeout = Task { try? await Task.sleep(for: .seconds(60)); delivery.continuation.finish() }
                let publisher = MeetingLivePrivacyPublication()
                var source = MeetingLiveTranscriptSnapshot.empty
                source.revision = 1
                source.utterances = (0..<320).map { index -> MeetingLiveUtterance in
                    .init(id: UUID(), speaker: .you, text: "документ инструкция терапия.", start: Double(index), end: Double(index + 1))
                }
                for edge in edges {
                    let position = edge + offset
                    source.utterances[position - 1].text = cue
                    source.utterances[position].text = secret
                }
                let redactor = RecordingPrivacyRedactor()
                source.utterances[319].text = "конечный документ."
                publisher.submit(source, generation: UUID(), using: redactor, latestSnapshot: { source },
                    publish: { value, _ in delivery.continuation.yield(value) },
                    failed: { _ in delivery.continuation.finish() })
                await publisher.waitForCurrentWork()
                delivery.continuation.finish()
                var updates = delivery.stream.makeAsyncIterator()
                var publications = 0
                while let value = await updates.next() {
                    publications += 1
                    let text = value.utterances.map(\.text).joined(separator: " ")
                    for token in forbidden {
                        try check(!text.contains(token), "a secret was unmasked by left/right page context or mask disagreement")
                    }
                }
                let inputs = await redactor.inputs
                await publisher.stop(); timeout.cancel()
                try check(publications > 1 && inputs.contains { $0.contains("конечный документ.") },
                          "edge-matrix inference did not visit the final source page")
            }
        }
        print("PASS password/DOB/phone/name at 21 page edges with -1/0/+1 offsets and monotone raw-offset mask union")
    }

    @MainActor
    static func partialMaskPrefixProofSuite() async throws {
        let delivery = AsyncStream<MeetingLiveTranscriptSnapshot>.makeStream()
        let publisher = MeetingLivePrivacyPublication()
        let generation = UUID(), id = UUID()
        var source = MeetingLiveTranscriptSnapshot.empty
        source.revision = 1
        source.utterances = [.init(id: UUID(), speaker: .you, text: "пароль", start: 0, end: 1)]
        var raw = " qwerty initial words."
        source.partials[.you] = .init(id: id, text: raw, start: 1, stableUTF16Count: raw.utf16.count)
        func submit() {
            publisher.submit(source, generation: generation, using: CueMaskPrivacyRedactor(), latestSnapshot: { source },
                publish: { value, _ in delivery.continuation.yield(value) }, failed: { _ in delivery.continuation.finish() })
        }
        var updates = delivery.stream.makeAsyncIterator()
        submit()
        let first = await updates.next()
        try check(first?.partials[.you]?.text.contains("[REDACTED]") == true,
                  "the first partial did not mask its context-dependent secret")
        source.utterances = []
        for suffix in [" initial words. Appended words.", " corrected tail."] {
            raw = " qwerty" + suffix
            source.revision += 1
            source.partials[.you] = .init(id: id, text: raw, start: 1, stableUTF16Count: raw.utf16.count)
            submit()
            let update = await updates.next()
            try check(update?.partials[.you]?.text.contains("qwerty") == false
                && update?.partials[.you]?.text.contains("[REDACTED]") == true,
                      "an unchanged masked prefix was exposed after partial growth or an unrelated tail correction")
        }
        source.revision += 1; source.partials = [:]
        source.utterances = [.init(id: id, speaker: .you, text: raw, start: 1, end: 2)]
        submit()
        let final = await updates.next()
        try check(final?.utterances.first?.text.contains("qwerty") == false
            && final?.utterances.first?.text.contains("[REDACTED]") == true,
                  "the partial-to-final handoff lost a verified original-prefix mask")
        await publisher.stop()
    }

    @MainActor
    static func atomicRetainedFieldSuite() async throws {
        var fresh = MeetingLiveTranscriptSnapshot.empty
        let firstToken = " qwertyZ! initial words."
        fresh.partials[.you] = .init(id: UUID(), text: firstToken, start: 0, stableUTF16Count: firstToken.utf16.count)
        let firstProjection = try await MeetingTranscriptPrivacyPolicy.redactedLiveProjection(fresh,
            using: SelectiveMaskPrivacyRedactor(words: ["qwerty"]))
        try check(firstProjection.snapshot.partials[.you]?.text == "[REDACTED] initial words.",
                  "the first publication exposed a suffix before fresh mask normalization")
        let cases: [(secret: String, initial: String, revisions: [String], expected: [String])] = [
            ("qwerty", " qwerty initial words.",
             [" qwertyz initial words.", " qwertyz!B2 initial words.", " qwertyz!B2жЁ👩🏽‍⚕️?/% initial words."],
             Array(repeating: "[REDACTED] initial words.", count: 3)),
            ("A!b", " A!b", [" A!bc", " A!bcЖЁ👩🏽‍⚕️!/?"], Array(repeating: "[REDACTED]", count: 2)),
            ("qwerty", " qwerty initial words.", [" qwertyinitial words."], ["[REDACTED] words."]),
            ("qwerty", " qwerty initial words.", [" xqwerty initial words."], ["[REDACTED]"]),
            ("qwerty", " qwerty initial words.", [" qwErty initial words."], ["[REDACTED]"]),
            ("qwerty", " qwerty initial words.", [" prefix qwerty initial words."], ["[REDACTED]"]),
            ("qwerty", " qwerty initial words.", ["\tqwerty initial words."], ["[REDACTED]"]),
            ("qwerty", " qwerty\tinitial words.", [" qwertyZ!?\tinitial words."], ["[REDACTED]\tinitial words."]),
            ("qwerty", " qwerty initial words.", [" qwertyZ!? initial words."], ["[REDACTED] initial words."]),
            ("one two", " «one two» initial words.", [" «one two more» initial words."], ["[REDACTED]"]),
            ("one two", " \"one two\" initial words.", [" \"one two more\" initial words."], ["[REDACTED]"])
        ]
        for scenario in cases {
            let delivery = AsyncStream<MeetingLiveTranscriptSnapshot>.makeStream()
            let publisher = MeetingLivePrivacyPublication()
            let generation = UUID(), id = UUID()
            var source = MeetingLiveTranscriptSnapshot.empty
            source.revision = 1
            source.utterances = [.init(id: UUID(), speaker: .you, text: "пароль", start: 0, end: 1)]
            var raw = scenario.initial
            source.partials[.you] = .init(id: id, text: raw, start: 1, stableUTF16Count: raw.utf16.count)
            func submit() {
                publisher.submit(source, generation: generation, using: AtomicFieldPrivacyRedactor(initialSecret: scenario.secret),
                    latestSnapshot: { source }, publish: { value, _ in delivery.continuation.yield(value) },
                    failed: { _ in delivery.continuation.finish() })
            }
            var updates = delivery.stream.makeAsyncIterator()
            submit()
            let initial = await updates.next()
            try check(initial?.partials[.you]?.text.contains(scenario.secret) == false,
                      "an atomic-field fixture did not initially protect its secret")
            source.utterances = []
            for (index, revised) in scenario.revisions.enumerated() {
                raw = revised
                source.partials[.you] = .init(id: id, text: raw, start: 1, stableUTF16Count: raw.utf16.count)
                source.revision += 1; submit()
                let update = await updates.next()
                try check(update?.partials[.you]?.text == scenario.expected[index],
                          "a retained sensitive field revealed a changed token, suffix, punctuation or ambiguous rewrite")
                source.revision += 1; submit()
                let repeated = await updates.next()
                try check(repeated?.partials[.you]?.text == scenario.expected[index],
                          "repeated stability removed retained atomic-field protection")
            }
            source.revision += 1; source.partials = [:]
            source.utterances = [.init(id: id, speaker: .you, text: raw, start: 1, end: 2)]
            submit()
            let final = await updates.next()
            try check(final?.utterances.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) == scenario.expected.last,
                      "finalization revealed a retained sensitive-field token after recognition revisions")
            await publisher.stop()
        }
        print("PASS retained atomic fields: suffixes, prepend/case/insertion, Unicode, punctuation, quotes, EOF and repeated/finalized hypotheses")
    }

    @MainActor
    static func inFlightMaskPrefixProofSuite() async throws {
        let scenarios: [(raw: String, expected: String)] = [
            (" qwerty initial words. More words.", "[REDACTED] initial words. More words."),
            (" qwertyz! initial words.", "[REDACTED] initial words."),
            (" xqwerty initial words.", "[REDACTED]"),
            (" qwErty initial words.", "[REDACTED]"),
            (" prefix qwerty initial words.", "[REDACTED]")
        ]
        for scenario in scenarios {
            let began = AsyncStream<String>.makeStream(), cancelled = AsyncStream<Void>.makeStream()
            let delivery = AsyncStream<MeetingLiveTranscriptSnapshot>.makeStream()
            let detector = DeferredLiveRedactor(started: began.continuation, cancelled: cancelled.continuation, useCueMask: true)
            let publisher = MeetingLivePrivacyPublication()
            let generation = UUID(), id = UUID()
            var source = MeetingLiveTranscriptSnapshot.empty
            source.revision = 1
            source.utterances = [.init(id: UUID(), speaker: .you, text: "пароль", start: 0, end: 1)]
            var raw = " qwerty initial words."
            source.partials[.you] = .init(id: id, text: raw, start: 1, stableUTF16Count: raw.utf16.count)
            func submit() {
                publisher.submit(source, generation: generation, using: detector, latestSnapshot: { source },
                    publish: { value, _ in delivery.continuation.yield(value) }, failed: { _ in delivery.continuation.finish() })
            }
            submit()
            var starts = began.stream.makeAsyncIterator()
            _ = await starts.next()
            // The first secret has been detected only by the still-running old input.
            // Its cue vanishes and the partial grows before that native call returns.
            source.revision = 2; source.utterances = []
            raw = scenario.raw
            source.partials[.you] = .init(id: id, text: raw, start: 1, stableUTF16Count: raw.utf16.count)
            submit()
            let releaser = Task { while await starts.next() != nil { await detector.release() } }
            await detector.release()
            var updates = delivery.stream.makeAsyncIterator()
            let revised = await updates.next()
            try check(revised?.partials[.you]?.text == scenario.expected,
                      "rejecting stale publication discarded learned atomic-field protection")
            source.revision = 3; submit()
            let repeated = await updates.next()
            try check(repeated?.partials[.you]?.text == scenario.expected,
                      "repeated stability removed in-flight sensitive-field protection")
            source.revision = 4; source.partials = [:]
            source.utterances = [.init(id: id, speaker: .you, text: raw, start: 1, end: 2)]
            submit()
            let final = await updates.next()
            try check(final?.utterances.first?.text.trimmingCharacters(in: .whitespacesAndNewlines) == scenario.expected,
                      "an in-flight learned atomic mask was lost on finalization")
            await publisher.stop()
            began.continuation.finish(); releaser.cancel(); await releaser.value
        }
        print("PASS learned atomic masks survive deferred inference, withdrawn cue, suffix/prepend/case/insertion and finalization")
    }

    @MainActor
    static func emptyAvailabilityDoesNotPrepareSuite() async throws {
        let delivery = AsyncStream<MeetingLiveTranscriptSnapshot>.makeStream()
        let detector = ColdPagedPrivacyRedactor()
        let publisher = MeetingLivePrivacyPublication()
        let generation = UUID()
        var source = MeetingLiveTranscriptSnapshot.empty
        source.revision = 1
        source.availability = .unavailable(reason: "Synthetic models loading")
        var failures = 0
        func submit() {
            publisher.submit(source, generation: generation, using: detector, latestSnapshot: { source },
                publish: { value, _ in delivery.continuation.yield(value) },
                failed: { _ in failures += 1; delivery.continuation.finish() })
        }
        var updates = delivery.stream.makeAsyncIterator()
        submit()
        let empty = await updates.next()
        try check(empty?.availability == source.availability && empty?.utterances.isEmpty == true,
                  "the initial availability update did not publish without text")
        try check(await detector.preparations == 0, "an empty startup snapshot warmed privacy before capture")
        source.revision = 2
        source.partials[.you] = .init(id: UUID(), text: " UNAPPROVED_SYNTHETIC_PERSON", start: 0,
                                      stableUTF16Count: 1)
        submit()
        let unstable = await updates.next()
        let unstablePreparations = await detector.preparations
        try check(unstable?.partials.isEmpty == true && unstablePreparations == 0,
                  "an unstable partial prepared privacy or entered publication")
        source.revision = 3; source.partials = [:]
        source.utterances = [.init(id: UUID(), speaker: .you, text: "документ инструкция терапия.", start: 0, end: 1)]
        submit()
        let speech = await updates.next()
        let speechPreparations = await detector.preparations
        try check(speech?.utterances.count == 1 && speechPreparations == 1,
                  "the first recognized text did not lazily prepare privacy exactly once")
        await publisher.stop()

        var publishedText = false
        source = .empty; source.revision = 1
        publisher.submit(source, generation: UUID(), using: detector, latestSnapshot: { source },
            publish: { value, _ in publishedText = !value.utterances.isEmpty || !value.partials.isEmpty },
            failed: { _ in failures += 1 })
        await publisher.stop()
        let cancelledPreparations = await detector.preparations
        try check(!publishedText && failures == 0 && cancelledPreparations == 1,
                  "cancelling initial empty availability warmed privacy or leaked text")
        print("PASS initial empty/unstable availability does not prepare privacy, first speech prepares once, empty cancellation stays clean")
    }

    @MainActor
    static func joinedColdPreparationSuite() async throws {
        let began = AsyncStream<Void>.makeStream()
        let detector = DeferredPreparePrivacyRedactor(started: began.continuation)
        let publisher = MeetingLivePrivacyPublication()
        var source = MeetingLiveTranscriptSnapshot.empty
        source.revision = 1
        source.utterances = [.init(id: UUID(), speaker: .you, text: "документ инструкция.", start: 0, end: 1)]
        var publications = 0, failures = 0
        publisher.submit(source, generation: UUID(), using: detector, latestSnapshot: { source },
            publish: { _, _ in publications += 1 }, failed: { _ in failures += 1 })
        var starts = began.stream.makeAsyncIterator()
        _ = await starts.next()
        var stopped = false
        let stopBegan = AsyncStream<Void>.makeStream()
        let stop = Task { stopBegan.continuation.yield(()); await publisher.stop(); stopped = true }
        var stopping = stopBegan.stream.makeAsyncIterator()
        _ = await stopping.next()
        try check(!stopped, "stop abandoned noncooperative cold model preparation")
        await detector.release()
        await stop.value
        try check(stopped && publications == 0 && failures == 0,
                  "cancelled cold preparation published raw text or reported a spurious failure")

        let failure = AsyncStream<Void>.makeStream()
        let unavailable = FailingPreparePrivacyRedactor()
        publisher.submit(source, generation: UUID(), using: unavailable, latestSnapshot: { source },
            publish: { _, _ in publications += 1 }, failed: { _ in failures += 1; failure.continuation.yield(()) })
        var errors = failure.stream.makeAsyncIterator()
        _ = await errors.next()
        let inferenceCalls = await unavailable.inferenceCalls
        try check(publications == 0 && failures == 1 && inferenceCalls == 0,
                  "failed cold preparation must prevent inference and publication")
        await publisher.stop()
    }

    static func provisionalSuite(using redactor: any TranscriptTextRedacting) async throws {
        let track = UUID()
        let benign = "Сегодня обсуждаем применение амоксициллина и переносимость назначенной терапии."
        let original = segment(benign, track: track, start: 0)
        var originalObservation = MeetingPCMTranscriptBatch(segments: [original])
        originalObservation.speechObservationIsFinal = true
        let speechOnly = MeetingTranscriptPrivacyContext(redactor: redactor)
        let immediate = try await speechOnly.previewSpeech(originalObservation)
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
        let early = try await staged.previewSpeech(originalObservation)
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
        // An explicit medication slot is positive evidence. An uncued unknown
        // word plus a quantity remains ambiguous and is not an exemption.
        let doseText = "Лекарство Амоксициллин 500 мг обсуждаем переносимость терапии и схему применения."
        let doseContext = MeetingTranscriptPrivacyContext(redactor: redactor)
        let doseSegment = segment(doseText, track: track, start: 0)
        let doseUpdate = try await doseContext.redact(.init(segments: [doseSegment]))
        let evaluatedDose = try await redactor.redactWithSpans(doseText)
        try check(doseUpdate.segments.isEmpty, "dose preview released the durable hold")
        if (evaluatedDose.provisionalSafeUTF16 ?? 0) > 0 {
            try check(doseUpdate.livePreview?.text.hasPrefix("Лекарство Амоксициллин 500 мг") == true,
                      "approved numeric dose prefix did not reach provisional display")
        } else {
            try check(doseUpdate.livePreview == nil, "withheld native person candidate reached provisional display")
        }
        let doseTail = try await doseContext.finish()
        let doseReference = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: [doseSegment]), using: redactor)
        try check(doseTail?.segments == doseReference.segments && doseTail?.livePreview == nil, "dose preview altered canonical text")
        let ambiguousDoseText = "Амоксициллин 500 мг обсуждаем переносимость терапии и схему применения."
        let doseRange = (ambiguousDoseText as NSString).range(of: "Амоксициллин")
        let candidateDose = try PIIRedactor.provisionalSafePrefix(in: ambiguousDoseText,
            ner: [.init(range: doseRange, label: "PER", score: 0.2)], redactedSpans: [])
        try check(candidateDose == 0, "numeric dose evidence overrode an actual native person candidate")
        let decimalDose = "Амоксициллин 0.5 мг обсуждаем переносимость терапии и схему применения."
        let decimalLimit = try PIIRedactor.provisionalSafePrefix(in: decimalDose, ner: [], redactedSpans: [])
        try check((decimalLimit ?? 0) > (decimalDose as NSString).range(of: "мг").location,
                  "decimal dose punctuation was mistaken for a private email fragment")
        for amount in ["508 рублей", "508 USD", "0.50 руб", "1008 мг"] {
            let text = "карта 4111 1111 1111 1111 \(amount) оземпик. Подготовим материалы к следующей встрече и проверим условия хранения."
            let redacted = try PIIRedactor.redact(text, ner: [])
            let limit = try PIIRedactor.provisionalSafePrefix(in: text, ner: [], redactedSpans: redacted.spans)
            try check((limit ?? 0) > (text as NSString).range(of: amount).upperBound,
                      "a confirmed quantity after a masked PAN withheld the whole live transcript: \(amount), limit=\(String(describing: limit))")
            try check(redacted.text.contains("[КАРТА]") && !redacted.text.contains("4111"),
                      "quantity admission weakened canonical card masking")
        }
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
