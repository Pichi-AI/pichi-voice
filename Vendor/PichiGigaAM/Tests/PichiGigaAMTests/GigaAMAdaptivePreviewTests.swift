import XCTest
@testable import PichiGigaAM

final class GigaAMAdaptivePreviewTests: XCTestCase {
    private let rate = 16_000
    private func audio(_ seconds: Double) -> [Float] {
        (0..<Int(seconds * Double(self.rate))).map { Float($0) / Float(self.rate) }
    }

    func testTimeAnchorRemovesAnObservationOfTheSameWordAndKeepsSpokenRepeats() async throws {
        let stream = GigaAMAdaptivePreview { samples, _ in
            let offset = Double(samples[0])
            let end = offset + Double(samples.count) / 16_000
            return [("начала", 2.8), ("линии", offset == 0 ? 3.95 : 4.08), ("да", 4.4), ("да", 4.72)]
                .compactMap { text, absolute in
                    guard absolute >= offset, absolute + 0.04 <= end else { return nil }
                    return .init(text: text, start: absolute - offset, end: absolute + 0.04 - offset, confidence: 1)
                }
        }
        _ = try await stream.preview(growingSamples: self.audio(4.5))
        let sealed = try await stream.preview(growingSamples: self.audio(5))
        XCTAssertEqual(sealed.stats.longCalls, 0)
        let next = try await stream.preview(growingSamples: self.audio(5.5))
        XCTAssertEqual(next.words.map(\.text), ["начала", "линии", "да", "да"])
        XCTAssertEqual(next.stats.shortCalls, 1)
        XCTAssertEqual(next.stats.longCalls, 0)
        let same = try await stream.preview(growingSamples: self.audio(5.5))
        XCTAssertEqual(same.stats.shortCalls + same.stats.longCalls, 0)
        XCTAssertEqual(same.words, next.words)
    }

    func testLongContextRestoresDisputedNegationBeforeSealing() async throws {
        let stream = GigaAMAdaptivePreview { samples, long in
            let losesNegation = samples.count >= 80_000 && !long
            return losesNegation ? [] : [.init(text: "не", start: 3.72, end: 3.8, confidence: 1)]
        }
        _ = try await stream.preview(growingSamples: self.audio(4.5))
        let result = try await stream.preview(growingSamples: self.audio(5))
        XCTAssertEqual(result.stats.shortCalls, 1)
        XCTAssertEqual(result.stats.longCalls, 1)
        XCTAssertEqual(result.words.map(\.text), ["не"])
    }

    func testRejectsRetractionMutationAndUncoveredGap() async throws {
        let stream = GigaAMAdaptivePreview { _, _ in [] }
        var samples = self.audio(0.5)
        _ = try await stream.preview(growingSamples: samples)
        samples[0] = 2
        for invalid in [samples, self.audio(0.25), self.audio(24)] {
            do {
                _ = try await stream.preview(growingSamples: invalid)
                XCTFail("An incompatible audio prefix escaped canonical fallback")
            } catch GigaAMError.invalidAudio {}
        }
        let valid = try await stream.preview(growingSamples: self.audio(1))
        XCTAssertEqual(valid.stats.shortCalls, 1)
    }

    func testCancelledDecoderDoesNotCommitItsResult() async throws {
        actor Decoder {
            var calls = 0
            func run() throws -> [GigaAMWordTiming] {
                self.calls += 1
                if self.calls == 1 { throw CancellationError() }
                return [.init(text: "тест", start: 0, end: 0.2, confidence: 1)]
            }
        }
        let decoder = Decoder()
        let stream = GigaAMAdaptivePreview { _, _ in try await decoder.run() }
        do {
            _ = try await stream.preview(growingSamples: self.audio(0.5))
            XCTFail("Cancellation was swallowed")
        } catch is CancellationError {}
        let retried = try await stream.preview(growingSamples: self.audio(0.5))
        XCTAssertEqual(retried.stats.shortCalls, 1)
        XCTAssertEqual(retried.words.map(\.text), ["тест"])
    }
}
