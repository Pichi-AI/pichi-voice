import Foundation
import XCTest
#if canImport(PichiGigaAM)
@testable import PichiGigaAM
#endif

final class GigaAMAcousticDictionaryTests: XCTestCase {
    func testGainAndSmallTempoChangesMatchButUnrelatedSoundDoesNot() throws {
        let references = try [0.95, 1, 1.05].map {
            try GigaAMAcousticFeatures.extract(Self.signal(tempo: $0))
        }
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrate(references: references))
        let same = try GigaAMAcousticFeatures.extract(Self.signal(tempo: 1.02, gain: 0.45))
        XCTAssertTrue(try XCTUnwrap(GigaAMAcousticMatcher.match(query: same, references: references, calibration: calibration)).accepted)
        let different = try GigaAMAcousticFeatures.extract(Self.signal(tempo: 1.02, different: true))
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.match(query: different, references: references, calibration: calibration)).accepted)
    }

    func testLeadingAndTrailingQuietFramesPreserveTheirTimeAndDoNotCreateMatches() throws {
        let original = Self.signal()
        let plain = try GigaAMAcousticFeatures.extract(original)
        let padded = try GigaAMAcousticFeatures.extract([Float](repeating: 0, count: 3200) + original + [Float](repeating: 0, count: 3200))
        XCTAssertGreaterThan(padded.frameCount, plain.frameCount)
        XCTAssertEqual(Array(padded.values.prefix(GigaAMAcousticFeatures.dimension)), [Float](repeating: 0, count: GigaAMAcousticFeatures.dimension))
        XCTAssertLessThan(try XCTUnwrap(GigaAMAcousticMatcher.distance(plain, padded)), 0.08)
        XCTAssertThrowsError(try GigaAMAcousticFeatures.extract([Float](repeating: 0, count: 16000)))
    }

    func testCalibrationFailsClosedOnTooFewOrInconsistentReferences() throws {
        let first = try GigaAMAcousticFeatures.extract(Self.signal())
        let other = try GigaAMAcousticFeatures.extract(Self.signal(different: true))
        XCTAssertNil(try GigaAMAcousticMatcher.calibrate(references: [first, first]))
        XCTAssertNil(try GigaAMAcousticMatcher.calibrate(references: [first, first, other]))
        XCTAssertNil(try GigaAMAcousticMatcher.calibrate(references: Array(repeating: first, count: 11)))
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrate(references: [first, first, first]))
        XCTAssertNil(try GigaAMAcousticMatcher.match(query: first, references: [other, first, first], calibration: calibration))
    }

    func testDurationGuardRejectsARepeatedLongerPhrase() throws {
        let short = try GigaAMAcousticFeatures.extract(Self.signal())
        let long = try GigaAMAcousticFeatures.extract(Self.signal() + Self.signal() + Self.signal())
        XCTAssertNil(try GigaAMAcousticMatcher.distance(short, long))
    }

    func testNegativeEvidenceOnlyVetoesAndRemainsBounded() throws {
        let positive = try GigaAMAcousticFeatures.extract(Self.signal())
        let negative = try GigaAMAcousticFeatures.extract(Self.signal(different: true))
        let references = [positive, positive, positive]
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrate(references: references))
        XCTAssertTrue(try XCTUnwrap(GigaAMAcousticMatcher.match(query: positive, references: references, calibration: calibration)).accepted)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.match(query: positive, references: references, calibration: calibration, negativeReferences: [positive])).accepted)
        XCTAssertTrue(try XCTUnwrap(GigaAMAcousticMatcher.match(query: positive, references: references, calibration: calibration, negativeReferences: [negative])).accepted)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.match(query: negative, references: references, calibration: calibration, negativeReferences: [positive])).accepted)
        XCTAssertNil(try GigaAMAcousticMatcher.match(query: positive, references: references, calibration: calibration, negativeReferences: Array(repeating: negative, count: 33)))
    }

    func testStoredFeaturesRoundTripAndRejectMalformedOrUnnormalizedData() throws {
        let value = try GigaAMAcousticFeatures.extract(Self.signal())
        XCTAssertEqual(try GigaAMAcousticFeatures(values: value.values), value)
        XCTAssertEqual(value.meanL2?.count, GigaAMAcousticFeatures.dimension)
        for values: [Float] in [[], [0], Array(repeating: 0, count: 40), Array(repeating: .nan, count: 40), Array(repeating: 1, count: 40), Array(repeating: 0, count: 40 * 376)] {
            XCTAssertThrowsError(try GigaAMAcousticFeatures(values: values))
        }
    }

    func testAudioValidationRejectsNonFiniteOversizedAndQuietInputs() throws {
        for samples: [Float] in [[], [0], Array(repeating: 0.1, count: 240001), Array(repeating: .nan, count: 320), Array(repeating: .infinity, count: 320), Array(repeating: 1.1, count: 320), Array(repeating: 1e-8, count: 16000)] {
            XCTAssertThrowsError(try GigaAMAcousticFeatures.extract(samples))
        }
    }

    func testCancellationIsObservedBeforeExtractionOrMatching() async throws {
        let samples = Self.signal()
        let extraction = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GigaAMAcousticFeatures.extract(samples)
        }
        do { _ = try await extraction.value; XCTFail("Cancelled extraction returned features") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let features = try GigaAMAcousticFeatures.extract(samples)
        let comparison = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GigaAMAcousticMatcher.distance(features, features)
        }
        do { _ = try await comparison.value; XCTFail("Cancelled comparison returned a score") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private static func signal(tempo: Double = 1, gain: Float = 1, different: Bool = false) -> [Float] {
        let count = Int(16000 * 1.2 * tempo)
        let pairs: [(Double, Double)] = different ? [(800, 2400), (1200, 3100), (600, 2800)] : [(300, 900), (500, 1400), (240, 2000)]
        return (0..<count).map { index in
            let progress = Double(index) / Double(count)
            let segment = min(2, Int(progress * 3))
            let local = progress * 3 - Double(segment)
            let envelope = min(1, min(local * 30, (1 - local) * 30))
            let time = Double(index) / 16000
            return gain * Float(envelope * (0.15 * sin(2 * .pi * pairs[segment].0 * time) + 0.08 * sin(2 * .pi * pairs[segment].1 * time)))
        }
    }
}
