import Foundation
import XCTest
#if canImport(PichiGigaAM)
@testable import PichiGigaAM
#endif

final class GigaAMNativeEmissionTests: XCTestCase {
    func testNativeTokensAndLogitsKeepTheSameLexicalWordEnvelope() throws {
        let pieces = ["▁Привет", ".", "▁Ёж", "<blk>"]
        let ids = [3, 0, 0, 3, 1, 1, 3, 2, 2, 3]
        let probabilities: [Float] = [1, 0.8, 0.7, 1, 0.4, 0.6, 1, 0.5, 0.9, 1]
        let logits = ids.enumerated().flatMap { frame, id in
            (0..<pieces.count).map { $0 == id ? log(probabilities[frame]) : -Float(100) }
        }
        let original = try GigaAMCTC.decode(logProbabilities: logits, frameCount: ids.count,
            vocabulary: .init(tokens: pieces, blankID: 3, unknownID: nil, subword: true), audioDuration: 0.4)
        let native = try GigaAMCTC.words(emissions: [
            .init(piece: "▁Привет", start: 0.04, end: 0.12, confidence: 0.8),
            .init(piece: ".", start: 0.16, end: 0.24, confidence: 0.6),
            .init(piece: "▁Ёж", start: 0.28, end: 0.36, confidence: 0.9),
        ], subword: true, audioDuration: 0.4)
        XCTAssertEqual(native.map(\.text), original.map(\.text))
        for (actual, expected) in zip(native, original) {
            XCTAssertEqual(actual.start, expected.start, accuracy: 0.000001)
            XCTAssertEqual(actual.end, expected.end, accuracy: 0.000001)
            XCTAssertEqual(actual.confidence, expected.confidence, accuracy: 0.000001)
        }
    }

    func testUnavailableProbabilityDoesNotDropTextOrInventHighConfidence() throws {
        let words = try GigaAMCTC.words(emissions: [
            .init(piece: "▁Ё", start: 0.04, end: 0.08, confidence: .nan),
            .init(piece: "ж", start: 0.08, end: 0.12, confidence: 2),
            .init(piece: ".", start: 1.2, end: 1.4, confidence: .infinity),
            .init(piece: "▁ё", start: 1.6, end: 1.64, confidence: .nan),
            .init(piece: "ж", start: 1.64, end: 1.68, confidence: 0),
        ], subword: true, audioDuration: 2)
        XCTAssertEqual(words.map(\.text), ["Ёж.", "ёж"])
        XCTAssertEqual(words.map(\.confidence), [0, 0])
        XCTAssertEqual(words[0].end, 0.12, accuracy: 0.000001)
        XCTAssertEqual(words[1].start, 1.6, accuracy: 0.000001)
    }

    func testAlreadyCollapsedRepeatedNativeWordsRemainDistinctAndClipDuration() throws {
        let words = try GigaAMCTC.words(emissions: [
            .init(piece: "▁да", start: 0, end: 0.04, confidence: 0),
            .init(piece: "▁да", start: 0.08, end: 0.12, confidence: 0),
        ], subword: true, audioDuration: 0.1)
        XCTAssertEqual(words.map(\.text), ["да", "да"])
        XCTAssertEqual(words[1].end, 0.1, accuracy: 0.000001)
    }

    func testNativeEmissionBoundsRejectMalformedOrReorderedEvidence() throws {
        for emissions: [GigaAMCTCEmission] in [
            [.init(piece: "▁а", start: -0.01, end: 0.04, confidence: 0)],
            [.init(piece: "▁а", start: 0.04, end: 0, confidence: 0)],
            [.init(piece: "▁а", start: .nan, end: 0.04, confidence: 0)],
            [.init(piece: "▁а", start: 0.08, end: 0.12, confidence: 0),
             .init(piece: "▁б", start: 0.04, end: 0.08, confidence: 0)],
        ] {
            XCTAssertThrowsError(try GigaAMCTC.words(emissions: emissions, subword: true, audioDuration: 1))
        }
    }
}
