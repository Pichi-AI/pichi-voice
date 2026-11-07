import Foundation
import XCTest
@testable import PichiGigaAM

final class GigaAMWindowOwnershipTests: XCTestCase {
    func testEmptyFirstCoreAndDroppedContextKeepNativeIndicesOfSecondWindow() throws {
        // The production 22-second call first infers 0...21s, then 19...22s.
        // Word zero in the second inference belongs to overlap already owned by core one.
        let first = try GigaAMRuntime.ownedWords([], windowSampleRange: 0..<336_000,
                                                 coreSampleRange: 0..<320_000)
        let native = [GigaAMWordTiming(text: "context", start: 0.04, end: 0.08, confidence: 0.7),
                      GigaAMWordTiming(text: "first-retained", start: 1.08, end: 1.12, confidence: 0.8),
                      GigaAMWordTiming(text: "next", start: 1.44, end: 1.80, confidence: 0.9)]
        let second = try GigaAMRuntime.ownedWords(native, windowSampleRange: 304_000..<352_000,
                                                  coreSampleRange: 320_000..<352_000)
        let result = first + second
        XCTAssertEqual(result.map(\.text), ["first-retained", "next"])
        XCTAssertEqual(result.map { $0.sourceContext?.wordIndex }, [1, 2])
        XCTAssertTrue(result.allSatisfy { $0.sourceContext?.sampleRange == (304_000..<352_000) })
        XCTAssertEqual(result[0].start, 20.08, accuracy: 1e-6)
        XCTAssertEqual(result[0].end, 20.12, accuracy: 1e-6)
        XCTAssertEqual(result[1].start, 20.44, accuracy: 1e-6)
        XCTAssertEqual(result[1].end, 20.80, accuracy: 1e-6)
        XCTAssertEqual(result.map(\.confidence), Array(native.dropFirst()).map(\.confidence))
        XCTAssertTrue(native.allSatisfy { $0.sourceContext == nil }, "Raw inference data is unchanged")
    }

    func testSeparateInferenceWindowsKeepSeparateNativeWordZero() throws {
        let first = try GigaAMRuntime.ownedWords(
            [.init(text: "first", start: 0.08, end: 0.12, confidence: 1)],
            windowSampleRange: 0..<336_000, coreSampleRange: 0..<320_000)
        let second = try GigaAMRuntime.ownedWords(
            [.init(text: "second", start: 1.08, end: 1.12, confidence: 1)],
            windowSampleRange: 304_000..<640_000, coreSampleRange: 320_000..<640_000)
        XCTAssertEqual(first[0].sourceContext?.wordIndex, 0)
        XCTAssertEqual(second[0].sourceContext?.wordIndex, 0)
        XCTAssertNotEqual(first[0].sourceContext?.sampleRange, second[0].sourceContext?.sampleRange)
        XCTAssertTrue(first[0].sourceContext?.isValid == true)
        XCTAssertTrue(second[0].sourceContext?.isValid == true)
    }

    func testInvalidWindowOwnershipIsRejectedBeforeSourceContextIsCreated() throws {
        let word = GigaAMWordTiming(text: "word", start: 0.04, end: 0.08, confidence: 1)
        XCTAssertThrowsError(try GigaAMRuntime.ownedWords([word],
            windowSampleRange: -1..<16_000, coreSampleRange: 0..<16_000))
        XCTAssertThrowsError(try GigaAMRuntime.ownedWords([word],
            windowSampleRange: 0..<16_000, coreSampleRange: 0..<32_000))
        XCTAssertFalse(GigaAMWordSourceContext(sampleRange: 0..<16_000, wordIndex: -1).isValid)
        XCTAssertFalse(GigaAMWordSourceContext(sampleRange: 0..<16_000, wordIndex: 8_192).isValid)
    }
}
