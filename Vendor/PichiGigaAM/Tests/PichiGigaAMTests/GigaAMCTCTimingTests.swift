import Foundation
import XCTest
#if canImport(PichiGigaAM)
@testable import PichiGigaAM
#endif

/// Synthetic CTC emissions only. These tests load no model and use no audio or personal text.
final class GigaAMCTCTimingTests: XCTestCase {
    private func decode(_ pieces: [String], _ ids: [Int], subword: Bool = true,
                        duration: TimeInterval? = nil, probabilities: [Float]? = nil) throws -> [GigaAMWordTiming] {
        let blank = pieces.count - 1
        let vocabulary = GigaAMVocabulary(tokens: pieces, blankID: blank, unknownID: nil, subword: subword)
        let logits = ids.enumerated().flatMap { frame, id in
            (0..<pieces.count).map { candidate in
                candidate == id ? log(probabilities?[frame] ?? 1) : -Float(100)
            }
        }
        return try GigaAMCTC.decode(logProbabilities: logits, frameCount: ids.count,
            vocabulary: vocabulary, audioDuration: duration ?? Double(ids.count) * GigaAMCTC.frameDuration)
    }

    func testDelayedHeldPunctuationDoesNotExtendLexicalWordThroughPause() throws {
        let pieces = ["▁Привет", ".", "<blk>"]
        var ids = [Int](repeating: 2, count: 500)
        ids[1] = 0
        for frame in 250..<500 { ids[frame] = 1 }
        let words = try decode(pieces, ids)
        XCTAssertEqual(words.map(\.text), ["Привет."])
        XCTAssertEqual(words[0].start, 0.04, accuracy: 0.000001)
        XCTAssertEqual(words[0].end, 0.08, accuracy: 0.000001)
        XCTAssertEqual(words[0].confidence, 1)
    }

    func testLeadingAndTrailingPunctuationKeepTextWithoutOwningLexicalTiming() throws {
        let pieces = ["▁«", "Привет", "?", "<blk>"]
        var ids = [Int](repeating: 3, count: 250)
        for frame in 0..<50 { ids[frame] = 0 }
        ids[100] = 1; ids[101] = 1
        for frame in 200..<250 { ids[frame] = 2 }
        let words = try decode(pieces, ids)
        XCTAssertEqual(words.map(\.text), ["«Привет?"])
        XCTAssertEqual(words[0].start, 4, accuracy: 0.000001)
        XCTAssertEqual(words[0].end, 4.08, accuracy: 0.000001)
    }

    func testPunctuationOnlyUnitKeepsItsEmissionSpan() throws {
        let words = try decode(["▁", ".", "<blk>"], [2, 2, 2, 1, 1, 1, 1, 1, 1, 2])
        XCTAssertEqual(words.map(\.text), ["."])
        XCTAssertEqual(words[0].start, 0.12, accuracy: 0.000001)
        XCTAssertEqual(words[0].end, 0.36, accuracy: 0.000001)
    }

    func testDecimalHyphenAndMixedTokensKeepLexicalEnvelopeAndExactText() throws {
        let pieces = ["▁12", ".", "5", "-", "кг", "%", "<blk>"]
        let words = try decode(pieces, [6, 0, 1, 2, 3, 4, 5, 5, 5, 6])
        XCTAssertEqual(words.map(\.text), ["12.5-кг%"])
        XCTAssertEqual(words[0].start, 0.04, accuracy: 0.000001)
        XCTAssertEqual(words[0].end, 0.24, accuracy: 0.000001)
        let atomic = try decode(["▁42%", "<blk>"], [1, 0, 0, 1])
        XCTAssertEqual(atomic.map(\.text), ["42%"])
        XCTAssertEqual(atomic[0].end, 0.12, accuracy: 0.000001,
            "A token containing both lexical text and punctuation is indivisible")
    }

    func testRepeatedLettersAndRealShortWordsRemainDistinct() throws {
        let pieces = [" ", "а", "б", ".", "<blk>"]
        let words = try decode(pieces, [4, 1, 1, 4, 1, 0, 2, 2, 3, 3, 4], subword: false)
        XCTAssertEqual(words.map(\.text), ["аа", "б."])
        XCTAssertEqual(words[0].start, 0.04, accuracy: 0.000001)
        XCTAssertEqual(words[0].end, 0.20, accuracy: 0.000001)
        XCTAssertEqual(words[1].start, 0.24, accuracy: 0.000001)
        XCTAssertEqual(words[1].end, 0.32, accuracy: 0.000001)
        let short = try decode(["▁Я", "▁и", "▁a", ".", "<blk>"], [4, 0, 4, 1, 4, 2, 3, 3])
        XCTAssertEqual(short.map(\.text), ["Я", "и", "a."])
        for word in short { XCTAssertEqual(word.end - word.start, 0.04, accuracy: 0.000001) }
    }

    func testUnicodeLettersAndDigitsDefineTimingAcrossLanguages() throws {
        let pieces = ["▁Ёж", "▁über", "▁猫", "▁١٢", "!", "<blk>"]
        let words = try decode(pieces, [5, 0, 4, 5, 1, 4, 5, 2, 4, 5, 3, 4, 4])
        XCTAssertEqual(words.map(\.text), ["Ёж!", "über!", "猫!", "١٢!"])
        for (word, frame) in zip(words, [1, 4, 7, 10]) {
            XCTAssertEqual(word.start, Double(frame) * 0.04, accuracy: 0.000001)
            XCTAssertEqual(word.end, Double(frame + 1) * 0.04, accuracy: 0.000001)
        }
    }

    func testPunctuationStillContributesSameConfidenceAndLexicalRunsAreNotCapped() throws {
        let pieces = ["▁да", ".", "<blk>"]
        let words = try decode(pieces, [2, 0, 0, 2, 1, 1, 2],
            probabilities: [1, 0.6, 0.8, 1, 0.3, 0.6, 1])
        XCTAssertEqual(words.map(\.text), ["да."])
        XCTAssertEqual(words[0].confidence, 0.7, accuracy: 0.000001)
        XCTAssertEqual(words[0].end, 0.12, accuracy: 0.000001)
        let long = try decode(pieces, [Int](repeating: 0, count: 500))
        XCTAssertEqual(long.map(\.text), ["да"])
        XCTAssertEqual(long[0].end, 20, accuracy: 0.000001,
            "No arbitrary duration cap may rewrite genuine lexical token evidence")
    }

    func testAdjacentWordsAndDurationClippingRetainTheirBounds() throws {
        let words = try decode(["▁да", ".", "▁нет", "<blk>"], [3, 0, 1, 1, 2, 2], duration: 0.21)
        XCTAssertEqual(words.map(\.text), ["да.", "нет"])
        XCTAssertEqual(words[0].start, 0.04, accuracy: 0.000001)
        XCTAssertEqual(words[0].end, 0.08, accuracy: 0.000001)
        XCTAssertEqual(words[1].start, 0.16, accuracy: 0.000001)
        XCTAssertEqual(words[1].end, 0.21, accuracy: 0.000001)
    }
}
