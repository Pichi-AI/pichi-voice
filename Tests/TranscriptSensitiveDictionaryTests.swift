import Foundation

private struct DictionaryEchoRedactor: TranscriptTextRedacting {
    nonisolated var checkpointIdentity: String? { "synthetic-model-v1" }
    nonisolated var supportsSpeechBoundaryAdmission: Bool { true }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: text, spans: [], provisionalSafeUTF16: text.utf16.count)
    }
    func redactSpeechBoundaryWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: text, spans: [])
    }
}

private struct DictionaryOverlappingRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        let range = (text as NSString).range(of: "beta gamma")
        let output = NSMutableString(string: text)
        output.replaceCharacters(in: range, with: "[MODEL]")
        return .init(text: output as String, spans: [.init(range: range, replacement: "[MODEL]")], provisionalSafeUTF16: text.utf16.count)
    }
}

extension MeetingPrivacyContextTests {
    static func sensitiveDictionarySuite() async throws {
        func dictionary(_ phrases: [String]) throws -> TranscriptSensitiveDictionarySnapshot {
            try .init(entries: phrases.map { .init(phrase: $0, matchMode: .exact) })
        }
        func redactor(_ phrases: [String]) throws -> TranscriptDictionaryRedactor {
            try .init(wrapped: DictionaryEchoRedactor(), dictionary: dictionary(phrases))
        }
        let dictionaryRedactor = try redactor(["Ёлка", "секретный проект", "кот", "C++"])
        let source = "🐈 ЁЛКА, е\u{0308}лка; кот, котик скот _кот кот_ C++ C++17. секретный\t\nпроект! 12:34."
        let result = try await dictionaryRedactor.redactWithSpans(source)
        try check(result.text == "🐈 [СКРЫТО], [СКРЫТО]; [СКРЫТО], котик скот _кот кот_ [СКРЫТО] C++17. [СКРЫТО]! 12:34.",
                  "Dictionary canonical/case folding, whitespace, boundary or punctuation failed")
        try check(result.spans.count == 5 && result.spans.allSatisfy { Range($0.range, in: source) != nil }, "Dictionary source spans split Unicode")
        try check((source as NSString).substring(with: result.spans[1].range) == "е\u{0308}лка", "NFD span lost original grapheme")
        try check(!(try await dictionaryRedactor.redactWithSpans("елка")).text.contains("[СКРЫТО]"), "Dictionary silently removed Russian diacritics")
        let overlapping = TranscriptDictionaryRedactor(wrapped: DictionaryOverlappingRedactor(), dictionary: try dictionary(["alpha beta", "beta"]))
        let overlap = try await overlapping.redactWithSpans("alpha beta gamma!")
        try check(overlap.text == "[СКРЫТО]!" && overlap.spans == [.init(range: NSRange(location: 0, length: 16), replacement: "[СКРЫТО]")],
                  "Overlapping model/dictionary evidence exposed part of an entity")
        let longPhrase = "закрытый проект с длинным названием для синтетической проверки"
        let held = try await redactor([longPhrase]).redactWithSpans("обычный текст закрытый проект с длинным названием для")
        try check(held.provisionalSafeUTF16 == "обычный текст ".utf16.count, "Long dictionary prefix escaped live approval")
        let emojiPrefix = try await redactor(["секретный проект"]).redactWithSpans("🐈секретный")
        try check(emojiPrefix.provisionalSafeUTF16 == 2, "Non-BMP punctuation boundary exposed dictionary prefix")
        let unrelated = try await redactor(["закрытый проект"]).redactWithSpans("закрытый проектор")
        try check(unrelated.text == "закрытый проектор" && unrelated.provisionalSafeUTF16 == unrelated.text.utf16.count,
                  "Dictionary masked or held a different whole word")
        let noApproval = TranscriptDictionaryRedactor(wrapped: UnsupportedPreviewRedactorForDictionary(), dictionary: try dictionary(["секрет"]))
        try check(try await noApproval.redactWithSpans("обычный текст").provisionalSafeUTF16 == nil, "Dictionary invented detector display approval")
        for malformed in [DictionaryMalformedRedactor(provisional: false), DictionaryMalformedRedactor(provisional: true)] {
            let wrapper = TranscriptDictionaryRedactor(wrapped: malformed, dictionary: try dictionary(["другая фраза"]))
            do { _ = try await wrapper.redactWithSpans("синтетика"); throw Failure.assertion("Wrapper repaired invalid model output into raw publication") }
            catch SensitiveDataDictionaryError.invalidRedaction { }
        }
        try check(!dictionaryRedactor.supportsSpeechBoundaryAdmission, "VAD silence admitted an unfinished dictionary phrase")
        let first = try dictionary(["Ёлка", "секретный проект"])
        let reordered = try dictionary([" СЕКРЕТНЫЙ  ПРОЕКТ ", "е\u{0308}лка"])
        try check(first.fingerprint == reordered.fingerprint, "Equivalent rule edits invalidated checkpoints")
        let empty = TranscriptDictionaryRedactor(wrapped: DictionaryEchoRedactor(), dictionary: try dictionary([]))
        try check(empty.checkpointIdentity == "synthetic-model-v1" && empty.supportsSpeechBoundaryAdmission, "Empty dictionary broke checkpoint compatibility")
        try check(dictionaryRedactor.checkpointIdentity?.contains(first.entries[0].phrase) == false, "Fingerprint exposed phrase text")
        try await sensitiveDictionaryWordFormsSuite()
        try await sensitiveDictionaryPersistenceSuite()
        try await sensitiveDictionaryProjectionSuite()
        print("Sensitive dictionary synthetic suites passed")
    }

    private static func sensitiveDictionaryWordFormsSuite() async throws {
        let dictionary = try TranscriptSensitiveDictionarySnapshot(entries: [.init(phrase: "взятка"), .init(phrase: "откат")])
        let redactor = TranscriptDictionaryRedactor(wrapped: DictionaryEchoRedactor(), dictionary: dictionary)
        for word in ["взятка", "взятки", "взятке", "взятку", "взяткой", "взяткою", "взяток", "взяткам", "взятками", "взятках",
                     "откат", "отката", "откату", "откатом", "откате", "откаты", "откатов", "откатам", "откатами", "откатах"] {
            try check(try await redactor.redactWithSpans("О \(word)!").text == "О [СКРЫТО]!", "Word-form mismatch: \(word)")
        }
        try check(try await redactor.redactWithSpans("взяточник откатить подоткат").spans.isEmpty,
                  "Morphology confused derivation/substrings with an inflection")
        let phrase = try TranscriptDictionaryRedactor(wrapped: DictionaryEchoRedactor(), dictionary: .init(entries: [.init(phrase: "коммерческий подкуп")]))
        try check(try await phrase.redactWithSpans("О коммерческом подкупе.").text == "О [СКРЫТО].", "Inflected multiword phrase missed")
        let held = try await phrase.redactWithSpans("О коммерческом")
        try check(held.provisionalSafeUTF16 == 2, "Inflected phrase prefix leaked")
        let exact = try TranscriptDictionaryRedactor(wrapped: DictionaryEchoRedactor(), dictionary: .init(entries: [.init(phrase: "взятка", matchMode: .exact)]))
        try check(try await exact.redactWithSpans("взятке").spans.isEmpty, "Exact mode unexpectedly inflected")
        try check(dictionary.fingerprint != TranscriptSensitiveDictionarySnapshot(entries: [.init(phrase: "взятка", matchMode: .exact), .init(phrase: "откат")]).fingerprint,
                  "Matching mode missing from immutable capability identity")
        let groupID = "illicit-remuneration"
        let custom = try TranscriptSensitiveDictionarySnapshot(entries: [], selectedGroupIDs: [groupID], groupTermOverrides: [groupID: ["взятка"]])
        try check(try custom.spans(in: "взяток").count == 1, "Group override omitted morphology")
        let changed = try TranscriptSensitiveDictionarySnapshot(entries: [], selectedGroupIDs: [groupID], groupTermOverrides: [groupID: ["откат"]])
        try check(custom.fingerprint != changed.fingerprint, "Changed private group terms retained stale checkpoint identity")
        let legacy = Data("[{\"id\":\"00000000-0000-0000-0000-000000000001\",\"phrase\":\"взятка\"}]".utf8)
        let migrated = try JSONDecoder().decode([SensitiveDataDictionaryEntry].self, from: legacy)
        try check(migrated[0].matchMode == .wordForms, "Legacy dictionary did not gain word forms")
    }

    private static func sensitiveDictionaryPersistenceSuite() async throws {
        let suite = "sensitive-dictionary-synthetic-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "SyntheticDictionary"
        let original = try TranscriptSensitiveDictionarySnapshot(entries: [.init(phrase: "синтетическая фраза")])
        try original.persist(in: defaults, key: key)
        let first = try TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: key)
        let frozen = TranscriptDictionaryRedactor(wrapped: DictionaryEchoRedactor(), dictionary: first)
        let changed = try TranscriptSensitiveDictionarySnapshot(entries: [.init(phrase: "другая фраза")])
        try changed.persist(in: defaults, key: key)
        try check(try await frozen.redactWithSpans("синтетическая фраза").text == "[СКРЫТО]", "Settings mutation changed an admitted attempt")
        try check(frozen.checkpointIdentity != TranscriptDictionaryRedactor(wrapped: DictionaryEchoRedactor(), dictionary: changed).checkpointIdentity,
                  "Rule mutation retained stale checkpoint identity")
        let roundtrip = try TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: key)
        try check(roundtrip.entries == changed.entries, "Local dictionary roundtrip changed UUID/text")
        let invalidCases: [[SensitiveDataDictionaryEntry]] = [
            [.init(phrase: " ")], [.init(phrase: "...")], [.init(phrase: "[ИМЯ]")], [.init(phrase: "hello\u{0000}world")],
            [.init(phrase: String(repeating: "а", count: 257))], [.init(phrase: Array(repeating: "а", count: 17).joined(separator: " "))],
            [.init(phrase: "Ёлка"), .init(phrase: "е\u{0308}ЛКА")],
            (0..<129).map { .init(phrase: "синтетика\($0)") }
        ]
        for entries in invalidCases {
            do { _ = try TranscriptSensitiveDictionarySnapshot(entries: entries); throw Failure.assertion("Invalid dictionary accepted") }
            catch is SensitiveDataDictionaryError { }
        }
        defaults.set(Data("invalid".utf8), forKey: key)
        do { _ = try TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: key); throw Failure.assertion("Corrupt dictionary silently disabled protection") }
        catch is SensitiveDataDictionaryError { }
    }

    private static func sensitiveDictionaryProjectionSuite() async throws {
        let dictionary = try TranscriptSensitiveDictionarySnapshot(entries: [.init(phrase: "закрытый проект")])
        let redactor = TranscriptDictionaryRedactor(wrapped: DictionaryEchoRedactor(), dictionary: dictionary)
        let track = UUID()
        let segments = [segment("начало закрытый", track: track, start: 0), segment("проект, конец 12:34", track: track, start: 1)]
        let safe = try await MeetingTranscriptPrivacyPolicy.redactedBatch(.init(segments: segments), using: redactor)
        try check(safe.segments.map(\.text) == ["начало [СКРЫТО]", "[СКРЫТО], конец 12:34"], "Cross-segment phrase failed canonical projection")
        try check(safe.segments.map(\.id) == segments.map(\.id) && safe.segments.map(\.start) == segments.map(\.start)
                  && safe.segments.map(\.end) == segments.map(\.end) && safe.segments.map(\.sourceTrackID) == segments.map(\.sourceTrackID),
                  "Dictionary damaged source/timing binding")
        try check(safe.segments.allSatisfy { $0.originalText == nil }, "Dictionary publication retained raw sidecars")
        let context = MeetingTranscriptPrivacyContext(redactor: redactor)
        let first = try await context.redact(.init(segments: [segments[0]]))
        try check(first.segments.isEmpty && first.livePreview?.text.contains("закрытый") != true, "Incomplete prefix escaped strict batch or live preview")
        try check(try await context.admitSpeechBoundary() == nil, "Silence flushed a phrase prefix")
        _ = try await context.redact(.init(segments: [segments[1]]))
        let final = try await context.finish()!
        try check(final.segments.map(\.text) == safe.segments.map(\.text), "Phrase spanning PCM windows escaped finalization")
        let encoded = String(decoding: try JSONEncoder().encode(final.segments), as: UTF8.self)
        try check(!encoded.contains("закрытый") && !encoded.contains("проект"), "Raw dictionary values reached persistence/export payload")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic",
            microphone: .init(captureDeviceID: "fixture", displayName: "Synthetic"), piiRedactionEnabled: true),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.transcriptSegments = segments
        let exported = try await MeetingTranscriptPrivacyPolicy.redactedCopy(session: session, using: redactor)
        try check(exported.transcriptSegments.map(\.text) == safe.segments.map(\.text), "Export copy missed dictionary pipeline")
    }
}

private struct UnsupportedPreviewRedactorForDictionary: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction { .init(text: text, spans: []) }
}

private struct DictionaryMalformedRedactor: TranscriptTextRedacting {
    let provisional: Bool
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        provisional ? .init(text: text, spans: [], provisionalSafeUTF16: text.utf16.count + 1) : .init(text: "[ИМЯ]", spans: [])
    }
}
