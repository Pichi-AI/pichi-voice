import Foundation
import XCTest
@testable import PichiTextPrivacy

final class PIIIndependentBIOTests: XCTestCase {
    private func tokenizer() throws -> PIIWordPieceTokenizer {
        let json: [String: Any] = [
            "model": ["type": "WordPiece", "unk_token": "[UNK]", "continuing_subword_prefix": "##",
                      "max_input_chars_per_word": 100,
                      "vocab": ["[PAD]": 0, "[UNK]": 1, "[CLS]": 2, "[SEP]": 3, "[MASK]": 4,
                                "Ив": 5, "##ан": 6, "Ёлкин": 7, "@": 8, "слово": 9, "🙂": 10]],
            "normalizer": ["type": "BertNormalizer", "clean_text": true, "handle_chinese_chars": true,
                           "lowercase": false],
            "pre_tokenizer": ["type": "BertPreTokenizer"],
        ]
        return try PIIWordPieceTokenizer(tokenizerJSON: JSONSerialization.data(withJSONObject: json))
    }

    func testTokenOffsetsRetainSurrogatesYoAndEachWordPiece() throws {
        let text = "🙂 Иван Ёлкин@Иван"
        let windows = try tokenizer().independentWindows(text)
        XCTAssertEqual(windows.count, 1)
        XCTAssertEqual(windows[0].ids, [2,10,5,6,7,8,5,6,3])
        XCTAssertEqual(windows[0].offsets, [
            NSRange(location: 0, length: 0), NSRange(location: 0, length: 2),
            NSRange(location: 3, length: 2), NSRange(location: 5, length: 2),
            NSRange(location: 8, length: 5), NSRange(location: 13, length: 1),
            NSRange(location: 14, length: 2), NSRange(location: 16, length: 2),
            NSRange(location: 0, length: 0),
        ])
        // BERT does not split arbitrary Unicode symbols from adjacent letters.
        XCTAssertEqual(try tokenizer().independentWindows("🙂Иван")[0].ids, [2,1,3])
        XCTAssertEqual(try tokenizer().independentWindows("И\u{0000}ван")[0].offsets[1], NSRange(location: 0, length: 3))
        XCTAssertEqual(try tokenizer().independentWindows("Иван[CLS]Ёлкин")[0].ids, [2,5,6,2,7,3])
        XCTAssertEqual(try tokenizer().independentWindows("Е\u{0308}лкин")[0].ids, [2,1,3])
    }

    func testTokenSlidingWindowsHaveExact64TokenOverlapIncludingPartialWords() throws {
        let windows = try tokenizer().independentWindows(Array(repeating: "Иван", count: 300).joined(separator: " "))
        XCTAssertEqual(windows.map { $0.ids.count }, [256,256,222])
        for index in 1..<windows.count {
            XCTAssertEqual(Array(windows[index - 1].offsets.dropLast().suffix(64)), Array(windows[index].offsets.dropFirst().prefix(64)))
        }
        XCTAssertEqual(windows.last?.offsets.dropLast().last, NSRange(location: 1497, length: 2))
        XCTAssertThrowsError(try tokenizer().independentWindows(String(repeating: "а", count: 65_537)))
    }

    func testIndependentHeadsPreserveOverlapsOrphanIAndDiscardSpecialOffsets() throws {
        let window = PIITokenWindow(ids: [2,5,6,7,3], offsets: [
            .init(location: 0, length: 0), .init(location: 3, length: 2), .init(location: 5, length: 2),
            .init(location: 8, length: 5), .init(location: 0, length: 0),
        ])
        // Three independent heads, each with O/B/I. FULL_NAME spans all real
        // tokens; PHONE starts from an orphan I and overlaps the first name.
        let tags = [[1,1,1], [1,2,0], [2,2,0], [2,0,1], [1,1,1]]
        var logits: [Float] = []
        for token in tags { for tag in token { logits += (0..<3).map { $0 == tag ? 9 : 0 } } }
        let spans = try PIINERRuntime.decodeIndependent(logits: logits, labels: ["FULL_NAME","PHONE","ADDRESS"], window: window)
        XCTAssertEqual(spans, [
            .init(range: .init(location: 3, length: 10), label: "PER", score: 1),
            .init(range: .init(location: 3, length: 4), label: "PHONE", score: 1),
            .init(range: .init(location: 8, length: 5), label: "ADDRESS", score: 1),
        ])
        XCTAssertThrowsError(try PIINERRuntime.decodeIndependent(logits: [.nan], labels: ["FULL_NAME"], window: window))
        XCTAssertThrowsError(try PIINERRuntime.decodeIndependent(logits: Array(repeating: 0, count: 14), labels: ["FULL_NAME"], window: window))
        XCTAssertTrue(try PIINERRuntime.decodeIndependent(logits: Array(repeating: 0, count: 15), labels: ["FULL_NAME"], window: window).isEmpty)
    }

    func testInferenceHeadsMapToExistingPrivacyPolicyLabels() throws {
        let heads = ["FULL_NAME", "CARDHOLDER_NAME", "DATE_OF_BIRTH", "CARD_NUMBER", "CVV", "PIN", "DRIVER_LICENSE", "CITY"]
        let window = PIITokenWindow(ids: [5], offsets: [.init(location: 0, length: 2)])
        let logits: [Float] = heads.flatMap { _ -> [Float] in [0, 9, 0] }
        XCTAssertEqual(try PIINERRuntime.decodeIndependent(logits: logits, labels: heads, window: window).map(\.label),
                       ["PER", "PER", "DOB", "CARD", "SECRET", "SECRET", "NUMBER", "CITY"])
    }

    func testWindowMergingUnifiesOnlyOverlappingSameTypeSpans() {
        let spans: [PIINERSpan] = [
            .init(range: .init(location: 3, length: 5), label: "PER", score: 1),
            .init(range: .init(location: 6, length: 7), label: "PER", score: 1),
            .init(range: .init(location: 3, length: 5), label: "PER", score: 1),
            .init(range: .init(location: 13, length: 2), label: "PER", score: 1),
            .init(range: .init(location: 6, length: 7), label: "ADDRESS", score: 1),
        ]
        XCTAssertEqual(PIINERRuntime.mergeIndependent(spans), [
            .init(range: .init(location: 6, length: 7), label: "ADDRESS", score: 1),
            .init(range: .init(location: 3, length: 10), label: "PER", score: 1),
            .init(range: .init(location: 13, length: 2), label: "PER", score: 1),
        ])
    }

    func testA1PinnedNativeInferenceAndCancellation() async throws {
        guard let path = ProcessInfo.processInfo.environment["PICHI_PII_A1_TEST_MODEL_DIRECTORY"] else {
            throw XCTSkip("Set isolated A1 artifact directory for native inference")
        }
        let runtime = PIINERRuntime()
        try await runtime.load(descriptor: .russianA1, directory: URL(fileURLWithPath: path, isDirectory: true))
        let text = "🙂 Иван Ёлкин. Почта audit.person@example.invalid. Телефон +7 916 123-45-67."
        let spans = try await runtime.tag(text)
        XCTAssertTrue(spans.contains { $0.label == "PER" && NSIntersectionRange($0.range, (text as NSString).range(of: "Ёлкин")).length > 0 })
        XCTAssertTrue(spans.contains { $0.label == "EMAIL" })
        for span in spans { XCTAssertNotNil(Range(span.range, in: text)) }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await runtime.tag(text)
        }
        do { _ = try await cancelled.value; XCTFail("cancelled inference must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
        let continued = try await runtime.tag(text)
        XCTAssertFalse(continued.isEmpty)
        await runtime.unload()
        let ready = await runtime.isReady
        XCTAssertFalse(ready)
    }
}
