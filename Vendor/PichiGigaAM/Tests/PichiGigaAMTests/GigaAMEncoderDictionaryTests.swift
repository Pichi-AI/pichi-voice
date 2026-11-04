import Foundation
import XCTest
#if canImport(PichiGigaAM)
@testable import PichiGigaAM
#endif

final class GigaAMEncoderDictionaryTests: XCTestCase {
    func testLearnedStatesNormalizeIndependentlyOfGainAndKeepPaddingPositions() throws {
        var row = [Float](repeating: 0, count: 768); row[0] = 3; row[1] = 4
        let normalized = try GigaAMEncoderFeatures(values: [Float](repeating: 0, count: 768) + row)
        XCTAssertEqual(normalized.frameCount, 2)
        XCTAssertEqual(Array(normalized.values.prefix(768)), [Float](repeating: 0, count: 768))
        XCTAssertEqual(normalized.values[768], 0.6, accuracy: 1e-6)
        XCTAssertEqual(normalized.values[769], 0.8, accuracy: 1e-6)
        XCTAssertEqual(normalized.meanL2?[0] ?? -1, 0.6, accuracy: 1e-6)
        XCTAssertEqual(GigaAMEncoderFeatures.frameDuration, 0.04)
    }

    func testReferenceOnlyCalibrationRemainsUsefulWithoutAnUnseenNegativeDistribution() throws {
        let references = try [22, 24, 26].map { try self.word(frames: $0) }
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references))
        XCTAssertNil(calibration.nearestContrastDistance)
        XCTAssertLessThanOrEqual(calibration.acceptanceDistance, 0.30)
        let query = try word(frames: 25, variation: 0.05)
        XCTAssertTrue(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: query, references: references, calibration: calibration)).accepted)
        let unrelated = try word(label: 1, frames: 25)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: unrelated, references: references, calibration: calibration)).accepted)
    }

    func testCalibrationUsesReferenceVariationAndTrainingContrastSeparation() throws {
        let references = try [-Float(0.5), 0, 0.5].map { try self.word(variation: $0) }
        let contrast = try word(label: 1)
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references, contrastReferences: [contrast]))
        XCTAssertGreaterThan(calibration.acceptanceDistance, 0.04)
        XCTAssertGreaterThan(calibration.nearestContrastDistance ?? -1, calibration.maximumLeaveOneOutDistance)
        let query = try word(variation: 0.25)
        XCTAssertTrue(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: query, references: references, calibration: calibration)).accepted)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: contrast, references: references, calibration: calibration)).accepted)
        XCTAssertNil(try GigaAMAcousticMatcher.calibrateEncoder(references: references, contrastReferences: [references[0]]))
    }

    func testUnrelatedEnrollmentsOrInsufficientEvidenceCannotWidenCalibration() throws {
        let first = try word(), other = try word(label: 1)
        XCTAssertNil(try GigaAMAcousticMatcher.calibrateEncoder(references: [first, first]))
        XCTAssertNil(try GigaAMAcousticMatcher.calibrateEncoder(references: [first, first, other]))
        XCTAssertNil(try GigaAMAcousticMatcher.calibrateEncoder(references: Array(repeating: first, count: 11)))
        XCTAssertNil(try GigaAMAcousticMatcher.calibrateEncoder(references: [first, first, first], contrastReferences: Array(repeating: other, count: 129)))
        let short = try word(frames: 3)
        XCTAssertNil(try GigaAMAcousticMatcher.calibrateEncoder(references: [short, short, short]))
    }

    func testNegativeExamplesOnlyVetoAndCalibrationCannotMoveToOtherReferences() throws {
        let first = try word(), other = try word(label: 1), references = [first, first, first]
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references))
        XCTAssertNil(try GigaAMAcousticMatcher.matchEncoder(query: first, references: [other, first, first], calibration: calibration))
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: first, references: references, calibration: calibration, negativeReferences: [first])).accepted)
        XCTAssertTrue(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: first, references: references, calibration: calibration, negativeReferences: [other])).accepted)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: other, references: references, calibration: calibration, negativeReferences: [first])).accepted)
        XCTAssertNil(try GigaAMAcousticMatcher.matchEncoder(query: first, references: references, calibration: calibration, negativeReferences: Array(repeating: other, count: 33)))
    }

    func testCorroboratedOperatingPointUsesTrainingContrastWithoutChangingOrdinaryMatching() throws {
        let reference = try word(), references = [reference, reference, reference]
        let contrast = try word(variation: 1.5), query = try word(variation: 1)
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references, contrastReferences: [contrast]))
        let ordinary = try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: query, references: references, calibration: calibration))
        XCTAssertFalse(ordinary.accepted)
        XCTAssertGreaterThan(ordinary.distance, calibration.acceptanceDistance)
        XCTAssertLessThan(ordinary.distance, try XCTUnwrap(calibration.nearestContrastDistance))
        let corroborated = try XCTUnwrap(GigaAMAcousticMatcher.matchEncoderCorroborated(query: query, references: references, calibration: calibration))
        XCTAssertTrue(corroborated.accepted)
        XCTAssertEqual(corroborated.distance, ordinary.distance)
        XCTAssertLessThan(corroborated.distance, try XCTUnwrap(calibration.corroboratedAcceptanceDistance))
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: query, references: references, calibration: calibration)).accepted)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoderCorroborated(query: contrast, references: references, calibration: calibration)).accepted)
        let beyondContrast = try word(variation: 2)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoderCorroborated(query: beyondContrast, references: references, calibration: calibration)).accepted)
    }

    func testCorroboratedOperatingPointStillHasAnAbsoluteCeiling() throws {
        let reference = try word(), references = [reference, reference, reference]
        let contrast = try word(label: 1), query = try word(variation: 2)
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references, contrastReferences: [contrast]))
        XCTAssertGreaterThan(try XCTUnwrap(calibration.nearestContrastDistance), 0.45)
        let result = try XCTUnwrap(GigaAMAcousticMatcher.matchEncoderCorroborated(query: query, references: references, calibration: calibration))
        XCTAssertGreaterThan(result.distance, 0.45)
        XCTAssertLessThan(result.distance, try XCTUnwrap(calibration.nearestContrastDistance))
        XCTAssertFalse(result.accepted)
    }

    func testCorroboratedOperatingPointRequiresAUsableTrainingContrast() throws {
        let reference = try word(), references = [reference, reference, reference]
        let noContrast = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references))
        XCTAssertNil(noContrast.corroboratedAcceptanceDistance)
        XCTAssertNil(try GigaAMAcousticMatcher.matchEncoderCorroborated(query: reference, references: references, calibration: noContrast))
        let tooLong = try GigaAMEncoderFeatures(values: reference.values + reference.values + reference.values)
        let unusableContrast = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references, contrastReferences: [tooLong]))
        XCTAssertNil(unusableContrast.nearestContrastDistance)
        XCTAssertNil(try GigaAMAcousticMatcher.matchEncoderCorroborated(query: reference, references: references, calibration: unusableContrast))
    }

    func testCorroboratedOperatingPointRetainsReferenceBindingAndChecksEveryNegative() throws {
        let reference = try word(), references = [reference, reference, reference]
        let contrast = try word(variation: 1.5), query = try word(variation: 1), unrelated = try word(label: 1)
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references, contrastReferences: [contrast]))
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoder(query: query, references: references, calibration: calibration)).accepted)
        XCTAssertNil(try GigaAMAcousticMatcher.matchEncoderCorroborated(query: query, references: [unrelated, reference, reference], calibration: calibration))
        XCTAssertTrue(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoderCorroborated(query: query, references: references, calibration: calibration, negativeReferences: [unrelated])).accepted)
        XCTAssertFalse(try XCTUnwrap(GigaAMAcousticMatcher.matchEncoderCorroborated(query: query, references: references, calibration: calibration, negativeReferences: [unrelated, query])).accepted)
        XCTAssertNil(try GigaAMAcousticMatcher.matchEncoderCorroborated(query: query, references: references, calibration: calibration, negativeReferences: Array(repeating: unrelated, count: 33)))
        let tooLong = try GigaAMEncoderFeatures(values: query.values + query.values + query.values)
        XCTAssertNil(try GigaAMAcousticMatcher.matchEncoderCorroborated(query: tooLong, references: references, calibration: calibration))
    }

    func testCancellationStopsCorroboratedMatching() async throws {
        let reference = try word(), contrast = try word(variation: 1.5), references = [reference, reference, reference]
        let calibration = try XCTUnwrap(GigaAMAcousticMatcher.calibrateEncoder(references: references, contrastReferences: [contrast]))
        let comparison = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GigaAMAcousticMatcher.matchEncoderCorroborated(query: reference, references: references, calibration: calibration)
        }
        do { _ = try await comparison.value; XCTFail("Cancelled corroborated matching returned a result") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    func testDurationGuardDoesNotRecognizeAWholeRepeatedPhraseAsOneTerm() throws {
        let first = try word()
        let repeated = try GigaAMEncoderFeatures(values: first.values + first.values + first.values)
        XCTAssertNil(try GigaAMAcousticMatcher.distanceEncoder(first, repeated))
    }

    func testMalformedLearnedMatricesRejectBeforeComparison() throws {
        for values: [Float] in [[], [0], Array(repeating: 0, count: 768), Array(repeating: .nan, count: 768), Array(repeating: .infinity, count: 768), Array(repeating: 1, count: 768 * 376)] {
            XCTAssertThrowsError(try GigaAMEncoderFeatures(values: values))
        }
    }

    func testCancellationStopsNormalizationAndDynamicTimeWarping() async throws {
        let first = try word()
        let normalization = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GigaAMEncoderFeatures(values: first.values)
        }
        do { _ = try await normalization.value; XCTFail("Cancelled normalization returned states") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let comparison = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try GigaAMAcousticMatcher.distanceEncoder(first, first)
        }
        do { _ = try await comparison.value; XCTFail("Cancelled DTW returned a score") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
    }

    private func word(label: Int = 0, frames: Int = 24, variation: Float = 0) throws -> GigaAMEncoderFeatures {
        var values = [Float](repeating: 0, count: frames * 768)
        for frame in 0..<frames {
            let phase = min(2, frame * 3 / frames), base = frame * 768
            values[base + label * 64 + phase] = 1
            values[base + label * 64 + 3 + phase] = 0.4
            values[base + 512 + phase] = variation
        }
        return try GigaAMEncoderFeatures(values: values)
    }
}
