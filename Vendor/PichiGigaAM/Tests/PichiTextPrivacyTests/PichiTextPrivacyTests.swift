import Foundation
import XCTest
@testable import PichiTextPrivacy

final class PichiTextPrivacyTests: XCTestCase {
    func testKnownNonPersonPERDoesNotFreezeProvisionalMeetingContext() throws {
        let text = "Здравствуйте! Сегодня мы обсудим инструкции и посмотрим раздел с документами. После встречи запишем вопросы, которые нужно уточнить."
        let span = PIINERSpan(range: (text as NSString).range(of: "Здравствуйте"), label: "PER", score: 0.61)
        let output = try PIIRedactor.redact(text, ner: [span])
        XCTAssertEqual(output.text, text)
        let limit = try PIIRedactor.provisionalSafePrefix(in: text, ner: [span], redactedSpans: output.spans)
        XCTAssertGreaterThan(try XCTUnwrap(limit), NSMaxRange(span.range))
        let punctuation = PIINERSpan(range: (text as NSString).range(of: "!"), label: "PER", score: 0.49)
        XCTAssertEqual(try PIIRedactor.provisionalSafePrefix(in: text, ner: [span, punctuation], redactedSpans: output.spans), limit)

        // Reusing an existing precision exclusion must not admit an unrelated
        // name merely because it shares one NER span with an ordinary word.
        let candidate = "Здравствуйте Зальман обсуждает инструкцию и условия хранения препарата."
        let mixed = PIINERSpan(range: (candidate as NSString).range(of: "Здравствуйте Зальман"), label: "PER", score: 0.61)
        let candidateOutput = try PIIRedactor.redact(candidate, ner: [mixed])
        XCTAssertEqual(try PIIRedactor.provisionalSafePrefix(in: candidate, ner: [mixed], redactedSpans: candidateOutput.spans), 0)
    }

    func testIsolatedCompletedNamePrefixDoesNotBlockEveryLaterSentence() throws {
        let text = "У вас есть инструкция. Сегодня мы обсудим документы и уточним вопросы после встречи."
        let output = try PIIRedactor.redact(text, ner: [])
        let limit = try XCTUnwrap(PIIRedactor.provisionalSafePrefix(in: text, ner: [], redactedSpans: output.spans))
        XCTAssertGreaterThan(limit, (text as NSString).range(of: "вас").upperBound)
        for candidate in ["ан", "ан сер", "Ан", "Ан Сер обсуждает инструкцию и условия хранения препарата.",
                          "доктор ан на обсуждает инструкцию и условия хранения препарата."] {
            let output = try PIIRedactor.redact(candidate, ner: [])
            XCTAssertEqual(try PIIRedactor.provisionalSafePrefix(in: candidate, ner: [], redactedSpans: output.spans), 0)
        }
    }

    func testExplicitMedicationAndDosePreserveAnUnknownDrugWithoutExemptingPeople() throws {
        for word in ["Амоксициллин", "Ксалендорин", "Xalendorin"] {
            let text = "Лекарство \(word) 500 мг обсуждаем переносимость терапии и схему применения."
            let range = (text as NSString).range(of: word)
            let ner = [PIINERSpan(range: range, label: "PER", score: 0.99)]
            let output = try PIIRedactor.redact(text, ner: ner)
            XCTAssertEqual(output.text, text)
            XCTAssertGreaterThan(try XCTUnwrap(PIIRedactor.provisionalSafePrefix(in: text, ner: ner, redactedSpans: output.spans)), range.upperBound)
        }
        for (text, person) in [
            ("Иван 500 мг обсуждает инструкцию и условия хранения препарата.", "Иван"),
            ("Лекарство Алиса 500 мг обсуждаем инструкцию и условия хранения.", "Алиса"),
            ("Пациент Зальман получает 500 мг после обсуждения инструкции.", "Зальман"),
            ("Назначили Зальман 500 мг после обсуждения инструкции.", "Зальман"),
            ("Амоксициллин 500 мг обсуждаем переносимость терапии и схему применения.", "Амоксициллин"),
        ] {
            let range = (text as NSString).range(of: person)
            let output = try PIIRedactor.redact(text, ner: [.init(range: range, label: "PER", score: 0.99)])
            XCTAssertFalse(output.text.contains(person))
        }
        let recipient = "Пациент Иван получает препарат Амоксициллин 500 мг после обсуждения инструкции."
        let source = recipient as NSString
        let result = try PIIRedactor.redact(recipient, ner: [
            .init(range: source.range(of: "Иван"), label: "PER", score: 0.99),
            .init(range: source.range(of: "Амоксициллин"), label: "PER", score: 0.99),
        ])
        XCTAssertEqual(result.text, "Пациент [ИМЯ] получает препарат Амоксициллин 500 мг после обсуждения инструкции.")
    }

    func testUTF16OffsetsIncludeEmojiAndYoWithoutTranslatingUserText() throws {
        let tokenizer = try PIIWordPieceTokenizer(vocabulary: "[PAD]\n[UNK]\n[CLS]\n[SEP]\nЁлкин\nИван\n\n")
        let text = "🙂 Ёлкин Иван"
        let words = try tokenizer.words(text)
        XCTAssertEqual(words.map(\.range), [NSRange(location: 0, length: 2), NSRange(location: 3, length: 5), NSRange(location: 9, length: 4)])
        let result = try PIIRedactor.redact(text, ner: [.init(range: NSRange(location: 3, length: 10), label: "PER", score: 0.99)])
        XCTAssertEqual(result.text, "🙂 [ИМЯ]")
        XCTAssertEqual(result.spans[0].range, NSRange(location: 3, length: 10))
    }

    func testCasedWordPieceAndUnknownUseVocabularySpecialIDs() throws {
        let tokenizer = try PIIWordPieceTokenizer(vocabulary: "[PAD]\n[UNK]\n[CLS]\n[SEP]\nИв\n##анов\n")
        let words = try tokenizer.words("Иванов иванов")
        XCTAssertEqual(words.map(\.ids), [[4, 5], [1]])
        XCTAssertEqual(tokenizer.windows(words)[0].ids, [2, 4, 5, 1, 3])
    }

    func testAllLongTextWordsOwnedExactlyOnceAndNoWindowExceedsLimit() throws {
        let tokenizer = try PIIWordPieceTokenizer(vocabulary: "[UNK]\n[CLS]\n[SEP]\nслово\nИванов")
        let words = try tokenizer.words(Array(repeating: "слово", count: 900).joined(separator: " ") + " Иванов")
        let windows = tokenizer.windows(words)
        XCTAssertGreaterThan(windows.count, 1)
        XCTAssertTrue(windows.allSatisfy { $0.ids.count <= 256 })
        XCTAssertEqual(windows.flatMap { window in window.core.map { window.words[$0].range } }, words.map(\.range))
        XCTAssertEqual(windows.last?.words.last?.text, "Иванов")
    }

    func testDecoderBIOAndOwnershipRemainCorrectAcrossWindows() throws {
        let words = [PIIWord(text: "Иван", range: NSRange(location: 0, length: 4), ids: [4]), PIIWord(text: "Ёлкин", range: NSRange(location: 5, length: 5), ids: [5])]
        let window = PIIEncodedWindow(ids: [2,4,5,3], wordOf: [-1,0,1,-1], words: words, core: 0..<2)
        let predictions = try PIINERRuntime.decode(logits: [9,0,0, 0,9,0, 0,0,9, 9,0,0], labels: ["O", "B-PER", "I-PER"], window: window)
        let spans = PIINERRuntime.spans(predictions)
        XCTAssertEqual(spans.count, 1)
        XCTAssertEqual(spans.first?.range, NSRange(location: 0, length: 10))
        XCTAssertEqual(spans.first?.label, "PER")
        XCTAssertThrowsError(try PIINERRuntime.decode(logits: [.nan], labels: ["O"], window: window))
    }

    func testIdentifiersAndSpokenEmailInRUAndMixedEnglish() throws {
        let text = "Почта ivan.petrov@example.org и иван точка петров собака гмейл точка ком. Call +1 415 555 0199. Телефон +7 916 123-45-67. Паспорт 45 11 123456. СНИЛС 112-233-445 95. ИНН 500100732259. Дата рождения 12.05.1985."
        let result = try PIIRedactor.redact(text, ner: [])
        for value in ["ivan.petrov", "иван точка петров", "+1 415", "+7 916", "123456", "112-233", "500100732259", "12.05.1985"] { XCTAssertFalse(result.text.contains(value), value) }
        XCTAssertEqual(result.counts[.email], 2)
        XCTAssertEqual(result.counts[.passport], 1)
        XCTAssertEqual(result.counts[.snils], 1)
        XCTAssertEqual(result.counts[.birthDate], 1)
    }

    func testAddressContextCredentialsAndPaymentCard() throws {
        let result = try PIIRedactor.redact("Домашний адрес: улица Примерная, дом 12; Карта 4111 1111 1111 1111. Логин test_user. Пароль TestSecret42.", ner: [])
        XCTAssertFalse(result.text.contains("Примерная"))
        XCTAssertFalse(result.text.contains("4111"))
        XCTAssertFalse(result.text.contains("test_user"))
        XCTAssertFalse(result.text.contains("TestSecret42"))
        XCTAssertEqual(result.counts[.address], 1)
        XCTAssertEqual(result.counts[.card], 1)
    }

    func testCardCandidatesStopAtActualGroupsAndPreserveFollowingAmount() throws {
        for pan in ["4111 1111 1111 1111", "4111111111111111", "4111-1111-1111-1111", "3782 822463 10005"] {
            let text = "карта \(pan) 500 мг метформин500мг"
            let result = try PIIRedactor.redact(text, ner: [])
            XCTAssertEqual(result.text, "карта [КАРТА] 500 мг метформин500мг", pan)
            XCTAssertEqual(result.counts[.card], 1)
        }
        for text in ["дозировка 500 мг количество 123456 участников", "число 41111111111111115000", "номер 4111 1111 1111 1112"] {
            XCTAssertEqual(try PIIRedactor.redact(text, ner: []).text, text)
        }
        // At least one extension below passes Luhn too: an explicit amount unit
        // must keep that separate quantity outside the card's replacement span.
        XCTAssertTrue(PIIRedactor.luhnValid("4111111111111111508".compactMap(\.wholeNumberValue)))
        for amount in ["500", "503", "508", "1 500"] {
            for unit in ["рублей", "мг", "USD"] {
                let text = "карта 4111 1111 1111 1111 \(amount) \(unit)"
                XCTAssertEqual(try PIIRedactor.redact(text, ner: []).text, "карта [КАРТА] \(amount) \(unit)")
            }
        }
    }

    func testStructuredRussianAddressesStopBeforeUnpunctuatedDrugAndDose() throws {
        for address in ["улица Примерная дом 12", "г. Москва ул. Примерная д.12А корп.2 кв.17",
                        "улица 8 Марта дом12/1", "улица Примерная д12к2 строение1 офис3", "улица 1905 года дом7"] {
            for medication in ["метформин 500 мг", "метотрексат 15 мг", "инсулин 10 единиц", "оземпик 1 мг"] {
                let input = "домашний адрес " + address + " " + medication
                let result = try PIIRedactor.redact(input, ner: [])
                XCTAssertEqual(result.text, "домашний адрес [АДРЕС] " + medication, input)
                XCTAssertEqual(result.spans.first?.range, (input as NSString).range(of: address), input)
            }
        }
        for text in ["домашний адрес уточним позже метформин 500 мг", "домашний адрес улица Примерная метформин 500 мг",
                     "домашний адрес улица Примерная дом500мг", "home address needs confirmation metformin 500 mg"] {
            XCTAssertEqual(try PIIRedactor.redact(text, ner: []).text, text)
        }
    }

    func testUngroupedAmountsAfterValidCardArePreservedAtAllGroupLengths() throws {
        let card = "3782 822463 10005"
        for separator in [" ", "  "] {
            for amount in ["1008 рублей", "123456 рублей", "1 008 рублей", "10 008 рублей", "0.50 руб", "1008 мг"] {
                let input = "карта " + card + separator + amount
                let result = try PIIRedactor.redact(input, ner: [])
                XCTAssertEqual(result.text, "карта [КАРТА]" + separator + amount, input)
                XCTAssertEqual(result.spans.first?.range, (input as NSString).range(of: card), input)
            }
        }
    }

    func testNoBlindLongNumberDateLocationOrganizationOrMedicationRedaction() throws {
        let text = "Аспирин 500 мг и инсулин 10 единиц. В исследовании 123456 участников, дата 12.05.2026. Example Pharma в Москве."
        let source = text as NSString
        let spans = [
            PIINERSpan(range: source.range(of: "Аспирин"), label: "PER", score: 0.99),
            .init(range: source.range(of: "Москве"), label: "LOC", score: 0.99),
            .init(range: source.range(of: "Example Pharma"), label: "ORG", score: 0.99),
        ]
        XCTAssertEqual(try PIIRedactor.redact(text, ner: spans).text, text)
    }

    func testOverlappingSpansMaskUnionAndDoNotLeakTail() {
        let result = PIIRedactor.merge([
            .init(range: NSRange(location: 0, length: 12), kind: .person, contextual: false),
            .init(range: NSRange(location: 6, length: 14), kind: .email, contextual: false),
        ])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].range, NSRange(location: 0, length: 20))
        XCTAssertEqual(result[0].kind, .email)
    }

    func testBadOffsetsFailClosedAndPlaceholdersIdempotentAcrossSegments() throws {
        XCTAssertThrowsError(try PIIRedactor.redact("🙂 Иван", ner: [.init(range: NSRange(location: 1, length: 2), label: "PER", score: 0.99)]))
        let text = "Напишите first@example.org"
        let one = try PIIRedactor.redact(text, ner: [])
        XCTAssertEqual(try PIIRedactor.redact(one.text, ner: []).text, one.text)
        XCTAssertEqual(try PIIRedactor.redact("Повторно first@example.org", ner: []).text, "Повторно [EMAIL]")
    }

    func testUnpreparedAndCancelledRuntimeNeverPublishOriginalText() async throws {
        let runtime = PIINERRuntime()
        do { _ = try await runtime.tag("Иванов Иван"); XCTFail("must require real model") }
        catch { XCTAssertEqual(error as? TextPrivacyError, .notPrepared) }
        let task = Task { try Task.checkCancellation(); return try await runtime.tag("Иванов Иван") }
        task.cancel()
        do { _ = try await task.value; XCTFail("must cancel") } catch { XCTAssertTrue(error is CancellationError) }
    }

    func testCaselessNameRulesRequirePersonEvidenceAndKeepPharmaNumbers() throws {
        // This deterministic layer must still work when the real tiny-news NER
        // produces no person spans for lower-case CTC output.
        for fixture in PIIRussianASRFixtures.positives {
            let expected = (fixture.text as NSString).range(of: fixture.name)
            let result = try PIIRedactor.redact(fixture.text, ner: [])
            XCTAssertTrue(result.spans.contains { $0.range == expected }, fixture.text)
            XCTAssertFalse(result.text.contains(fixture.name), fixture.text)
        }
        for text in PIIRussianASRFixtures.negatives {
            XCTAssertEqual(try PIIRedactor.redact(text, ner: []).text, text)
        }
        // The name dictionary cannot greedily cross punctuation or conjunctions.
        XCTAssertEqual(try PIIRedactor.redact("иван и анна", ner: []).text, "[ИМЯ] и [ИМЯ]")
        XCTAssertEqual(try PIIRedactor.redact("🙂 иван петрович сидоров", ner: []).text, "🙂 [ИМЯ]")
    }

    func testCaselessRussianASRNativeBenchmark() async throws {
        guard let path = ProcessInfo.processInfo.environment["PICHI_PII_TEST_MODEL_DIRECTORY"] else { throw XCTSkip("Set isolated public artifact directory for native inference") }
        let runtime = PIINERRuntime()
        try await runtime.load(directory: URL(fileURLWithPath: path, isDirectory: true))
        var truePositives = 0
        var falsePositives = 0
        var falseNegatives = 0
        for fixture in PIIRussianASRFixtures.positives {
            let result = try PIIRedactor.redact(fixture.text, ner: await runtime.tag(fixture.text))
            let expected = (fixture.text as NSString).range(of: fixture.name)
            let exact = result.spans.filter { $0.range == expected }.count
            truePositives += exact
            falseNegatives += 1 - exact
            falsePositives += result.spans.count - exact
            XCTAssertEqual(exact, 1, fixture.text)
        }
        for text in PIIRussianASRFixtures.negatives {
            let result = try PIIRedactor.redact(text, ner: await runtime.tag(text))
            falsePositives += result.spans.count
            XCTAssertEqual(result.text, text)
        }
        var englishMasked = 0
        for fixture in PIIRussianASRFixtures.englishDiagnostics {
            let result = try PIIRedactor.redact(fixture.text, ner: await runtime.tag(fixture.text))
            if result.spans.contains(where: { $0.range == (fixture.text as NSString).range(of: fixture.name) }) { englishMasked += 1 }
        }
        // English observations are diagnostic, not an assertion that leaks are
        // correct behavior or that a Russian model protects English names.
        print("PII CTC synthetic benchmark: RU TP=\(truePositives), FP=\(falsePositives), FN=\(falseNegatives); \(PIIRussianASRFixtures.negatives.count) negative texts; English exact names \(englishMasked)/\(PIIRussianASRFixtures.englishDiagnostics.count)")
        await runtime.unload()
    }

    /// Opt-in native ONNX smoke test on approved public weights. Ordinary tests
    /// never download weights. A skipped test is not model verification.
    func testPublicModelNativeInference() async throws {
        guard let path = ProcessInfo.processInfo.environment["PICHI_PII_TEST_MODEL_DIRECTORY"] else { throw XCTSkip("Set isolated public artifact directory for native inference") }
        let runtime = PIINERRuntime()
        let start = ProcessInfo.processInfo.systemUptime
        try await runtime.load(directory: URL(fileURLWithPath: path, isDirectory: true))
        let texts = [
            "Врач Иван Иванов и представитель Анна Петрова обсудили препарат.",
            "Передайте документ Марии Сергеевне Соколовой.",
            "🙂 Пётр Ёлкин отправил письмо на test@example.org.",
            "Аспирин 500 мг и инсулин 10 единиц. В исследовании 123456 участников.",
            "Врач Иван Иванов сказал: let's review the presentation. Call +1 415 555 0199.",
        ]
        var results: [String] = []
        for text in texts {
            let spans = try await runtime.tag(text)
            results.append(try PIIRedactor.redact(text, ner: spans).text)
        }
        XCTAssertFalse(results[0].contains("Иванов")); XCTAssertFalse(results[0].contains("Петрова"))
        XCTAssertFalse(results[1].contains("Соколовой"))
        XCTAssertFalse(results[2].contains("Ёлкин")); XCTAssertFalse(results[2].contains("test@example"))
        XCTAssertEqual(results[3], texts[3])
        XCTAssertFalse(results[4].contains("Иванов")); XCTAssertTrue(results[4].contains("let's review the presentation"))
        XCTAssertFalse(results[4].contains("+1 415"))
        let long = Array(repeating: "Проверяем документ.", count: 350).joined(separator: " ") + " Врач Иван Иванов завершил встречу."
        let longResult = try PIIRedactor.redact(long, ner: await runtime.tag(long))
        XCTAssertFalse(longResult.text.contains("Иванов"), "name beyond first token window must be processed")
        XCTAssertTrue(longResult.text.contains("завершил встречу"))
        print("PII native public model: \(texts.count) synthetic fixtures, wall \(ProcessInfo.processInfo.systemUptime - start) s")
        await runtime.unload()
        let ready = await runtime.isReady
        XCTAssertFalse(ready)
    }
}
