import Foundation
import XCTest
@testable import PichiTextPrivacy

final class PIIContactRulesTests: XCTestCase {
    func testSpokenContactsMaskExactSourceAndKeepFollowingProse() throws {
        let cases: [(String, String, PIIKind)] = [
            ("Почта ", "test плюс work собака example точка org", .email),
            ("Почта ", "test нижнее подчёркивание work at example dot com", .email),
            ("Почта ", "test дефис work собачка example точка ру", .email),
            ("Почта ", "test точка work@example.org", .email),
            ("Телефон ", "плюс семь девятьсот шестнадцать сто двадцать три сорок пять шестьдесят семь", .phone),
            ("Телефон ", "плюс 7 916 123 45 67", .phone),
            ("Телефон: ", "восемь девять один шесть один два три четыре пять шесть семь", .phone),
            ("Телефон для связи ", "плюс 7 916 сто двадцать три 45 67", .phone),
            ("Телефон ", "девять один шесть один два три четыре пять шесть семь", .phone),
        ]
        for (cue, value, kind) in cases {
            let text = "🙂 " + cue + value + " обсудим инструкцию после встречи"
            let result = try PIIRedactor.redact(text, ner: [])
            XCTAssertEqual(result.text, "🙂 " + cue + kind.placeholder + " обсудим инструкцию после встречи", text)
            XCTAssertEqual(result.spans.map(\.range), [(text as NSString).range(of: value)], text)
        }
    }

    func testCredentialsIncludePunctuationAndQualifiedCueWithoutPartialLeaks() throws {
        for (cue, value, kind) in [
            ("логин для входа ", "sample_user", PIIKind.login),
            ("логин для доступа: ", "sample@example.org", .login),
            ("пароль ", "Synthetic!Secret42", .secret),
            ("пароль: ", "!?#$", .secret),
            ("пароль: ", "[СЕКРЕТ]tail!", .secret),
            ("пароль для входа: ", "x!", .secret),
            ("api key = ", "token/a+b=c?d!", .secret),
            ("пароль ", String(repeating: "abc!", count: 40), .secret),
        ] {
            let text = cue + value + " обсудим инструкцию"
            let result = try PIIRedactor.redact(text, ner: [])
            // Email and login overlap: the higher-priority email label may win.
            XCTAssertFalse(result.text.contains(value), text)
            XCTAssertEqual(result.spans.count, 1, text)
            XCTAssertEqual(result.spans.first?.range, (text as NSString).range(of: value), text)
            if kind == .secret { XCTAssertEqual(result.counts[.secret], 1, text) }
            XCTAssertTrue(result.text.hasSuffix(" обсудим инструкцию"), text)
            XCTAssertEqual(try PIIRedactor.redact(result.text, ner: []).text, result.text)
        }
        let quoted = try PIIRedactor.redact("пароль «synthetic ! phrase» обсудим инструкцию", ner: [])
        XCTAssertEqual(quoted.text, "пароль «[СЕКРЕТ]» обсудим инструкцию")
    }

    func testOrdinaryProsePartNumbersAndIncompleteSpokenValuesStayUnchanged() throws {
        for text in [
            "телефон работает после обновления через 12345 минут",
            "телефон сто двадцать три проверим позже", "телефонная линия 12345",
            "пароль нужно изменить завтра", "логин для входа нужен позже", "парольный менеджер работает",
            "партия семь девятьсот шестнадцать сто двадцать три сорок пять шестьдесят семь",
            "точка на графике и собака на улице", "плюс семь процентов дозировка сто мг",
            "логин [ЛОГИН] пароль [СЕКРЕТ]", "продукт model_12345",
        ] { XCTAssertEqual(try PIIRedactor.redact(text, ner: []).text, text, text) }
    }

    func testTypedNERPolicyPreservesGenericDatesAndPlaces() throws {
        for (label, value, kind) in [("EMAIL", "test@example.org", PIIKind.email),
            ("PHONE", "девятьсот десять", .phone), ("PASSPORT", "тестовый", .passport),
            ("CARD", "тестовый", .card), ("SECRET", "тестовый", .secret),
            ("LOGIN", "тестовый", .login), ("NUMBER", "тестовый", .identifier)] {
            let result = try PIIRedactor.redact(value, ner: [.init(range: NSRange(location: 0, length: value.utf16.count), label: label, score: 1)])
            XCTAssertEqual(result.text, kind.placeholder, label)
        }
        for label in ["COUNTRY", "CITY", "STREET", "HOUSE", "APARTMENT", "REGION", "DISTRICT", "LOC", "ORG", "ADDRESS", "DOB", "CARD_NUMBER", "DATE_OF_BIRTH"] {
            let text = "обсуждаем программу"
            XCTAssertEqual(try PIIRedactor.redact(text, ner: [.init(range: NSRange(location: 0, length: text.utf16.count), label: label, score: 1)]).text, text, label)
        }
        for (cue, label, kind) in [("домашний адрес ", "ADDRESS", PIIKind.address), ("дата рождения ", "DOB", .birthDate)] {
            let text = cue + "тестовое значение"
            let result = try PIIRedactor.redact(text, ner: [.init(range: (text as NSString).range(of: "тестовое значение"), label: label, score: 1)])
            XCTAssertEqual(result.text, cue + kind.placeholder)
        }
    }

    func testPreviewResolvesWholeQualifiedCredentialsAndHoldsPartialTypedSpans() throws {
        let text = "логин для входа sample_user обсудим инструкцию и уточним вопросы после встречи."
        let result = try PIIRedactor.redact(text, ner: [])
        let limit = try XCTUnwrap(PIIRedactor.provisionalSafePrefix(in: text, ner: [], redactedSpans: result.spans))
        XCTAssertGreaterThan(limit, (text as NSString).range(of: "sample_user").upperBound)
        let partial = "обсуждаем synthetic инструкцию и уточняем вопросы после встречи."
        let ner = [PIINERSpan(range: (partial as NSString).range(of: "synthetic"), label: "PHONE", score: 0.2)]
        let output = try PIIRedactor.redact(partial, ner: ner)
        XCTAssertLessThanOrEqual(try XCTUnwrap(PIIRedactor.provisionalSafePrefix(in: partial, ner: ner, redactedSpans: output.spans)), ner[0].range.location)
    }
}
