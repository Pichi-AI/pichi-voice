import Foundation
import XCTest
@testable import PichiTextPrivacy

final class PichiTextPrivacyTests: XCTestCase {
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
