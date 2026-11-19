import Foundation
@testable import PichiVoiceMobile
import XCTest

final class MeetingVoiceMaskTests: XCTestCase {
    func testStreamingThroughUnevenPacketsPreservesEveryFrameAndFilterState() {
        let input = (0..<8_037).map { Float(sin(Double($0) * 0.09) * cos(Double($0) * 0.002)) }
        let expected = masked(input)
        var streamed = input
        let mask = MeetingVoiceMask(seed: 32)
        streamed.withUnsafeMutableBufferPointer { all in
            // Include an empty packet and packet boundaries unrelated to the carrier or analysis.
            for range in [0..<0, 0..<1, 1..<39, 39..<3_211, 3_211..<all.count] {
                mask.process(UnsafeMutableBufferPointer(rebasing: all[range]))
            }
        }
        XCTAssertEqual(streamed, expected)
    }

    func testFreshOrResetMaskKeepsSilenceAndDropsEarlierSpeech() {
        let mask = MeetingVoiceMask(seed: 32)
        XCTAssertEqual(masked([Float](repeating: 0, count: 400), by: mask), [Float](repeating: 0, count: 400))
        let speech = (0..<2_048).map { 0.6 * sin(Float($0) * 0.31) }
        _ = masked(speech, by: mask)
        mask.reset()
        XCTAssertEqual(masked([Float](repeating: 0, count: 911), by: mask), [Float](repeating: 0, count: 911))
    }

    func testSyntheticExcitationReplacesDifferentSourcePitchesAndPolarities() {
        for hz in [157.0, 237.0] {
            let input = (0..<8_000).map { Float(0.5 * sin(Double($0) * 2 * .pi * hz / 16_000)) }
            let output = masked(input)
            // Reversing input polarity preserves its band levels. Any dry audio mixed into the
            // output would change sign and violate this equality.
            XCTAssertEqual(output, masked(input.map { -$0 }))
            let steady = Array(output.suffix(4_000))
            XCTAssertGreaterThan(steady.reduce(Float.zero) { $0 + $1 * $1 }, 1)
            XCTAssertLessThan(toneAmplitude(steady, hz), 0.1 * toneAmplitude(steady, 125))
        }
    }

    func testRecordingProfilesProduceDifferentCarriersAndSurviveReset() {
        let speech = (0..<2_048).map { 0.6 * sin(Float($0) * 0.31) }
        let first = MeetingVoiceMask(seed: 0)
        let second = MeetingVoiceMask(seed: 0xffff)
        let firstOutput = masked(speech, by: first)
        XCTAssertNotEqual(firstOutput, masked(speech, by: second))
        first.reset()
        XCTAssertEqual(firstOutput, masked(speech, by: first))
    }

    func testHostileInputCannotPersistNonFiniteOrOutOfRangeAudio() {
        let pattern: [Float] = [.nan, .infinity, -.infinity, .greatestFiniteMagnitude,
                                0, -.greatestFiniteMagnitude, 0.5, -0.75]
        let output = masked(Array(repeating: pattern, count: 500).flatMap { $0 })
        XCTAssertTrue(output.allSatisfy { $0.isFinite && abs($0) <= 1 })
        XCTAssertTrue(output.contains { abs($0) > 0.001 })
    }

    private func masked(_ input: [Float], by mask: MeetingVoiceMask = MeetingVoiceMask(seed: 32)) -> [Float] {
        var result = input
        result.withUnsafeMutableBufferPointer { mask.process($0) }
        return result
    }

    private func toneAmplitude(_ samples: [Float], _ hz: Double) -> Double {
        var real = 0.0
        var imaginary = 0.0
        for (frame, sample) in samples.enumerated() {
            let angle = Double(frame) * 2 * .pi * hz / 16_000
            real += Double(sample) * cos(angle)
            imaginary += Double(sample) * sin(angle)
        }
        return hypot(real, imaginary)
    }
}
