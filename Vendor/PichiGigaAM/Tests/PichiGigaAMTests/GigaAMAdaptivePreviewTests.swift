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

    func testDeltasAgreeWithFullPrefixesAndClosingRetiresTheLease() async throws {
        let decoder: GigaAMAdaptivePreview.Decoder = { samples, _ in
            [.init(text: "слово", start: 0, end: min(0.25, Double(samples.count) / 16_000), confidence: 1)]
        }
        let direct = GigaAMAdaptivePreview(decode: decoder)
        let delta = GigaAMAdaptivePreview(decode: decoder)
        let audio = self.audio(25)
        var previous = 0
        for end in stride(from: 8_000, through: audio.count, by: 8_000) {
            let full = try await direct.preview(growingSamples: Array(audio[..<end]))
            let appended = try await delta.preview(appendingSamples: Array(audio[previous..<end]), totalSampleCount: end)
            XCTAssertEqual(full.words, appended.words)
            previous = end
        }
        do {
            _ = try await delta.preview(appendingSamples: [1], totalSampleCount: previous + 2)
            XCTFail("An input gap must switch to the canonical engine")
        } catch GigaAMError.invalidAudio {}
        await delta.close()
        do {
            _ = try await delta.preview(growingSamples: [])
            XCTFail("Retired lease returned text")
        } catch {}
    }

    func testPhraseCheckpointIsVerifiedOnceAfterItSettlesAndTheMicrophoneCanContinue() async throws {
        let word = GigaAMWordTiming(text: "голос", start: 0, end: 0.2, confidence: 1)
        let stream = GigaAMAdaptivePreview { _,_ in [word] }
        let loud = [Float](repeating: 0.1, count: 8_000), quiet = [Float](repeating: 0, count: 8_000)
        _ = try await stream.preview(growingSamples: loud)
        for n in [16_000, 24_000] {
            let atPause = try await stream.preview(appendingSamples: quiet, totalSampleCount: n)
            XCTAssertTrue(atPause.needsCanonicalCheckpoint)
            try await stream.acceptCanonicalCheckpoint([word], sampleCount: n)
        }
        let settled = try await stream.preview(appendingSamples: quiet, totalSampleCount: 32_000)
        XCTAssertFalse(settled.needsCanonicalCheckpoint)
        let resumed = try await stream.preview(appendingSamples: loud, totalSampleCount: 40_000)
        XCTAssertEqual(resumed.stats.shortCalls, 1)
        XCTAssertFalse(resumed.needsCanonicalCheckpoint)
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
