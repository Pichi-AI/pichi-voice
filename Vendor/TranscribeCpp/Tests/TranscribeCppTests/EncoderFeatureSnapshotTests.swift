import CTranscribe
import Foundation
import XCTest
@testable import TranscribeCpp

final class EncoderFeatureSnapshotTests: XCTestCase {
    private let session = OpaquePointer(bitPattern: 1)!

    private func api(
        clear: @escaping (OpaquePointer) -> Int32 = { _ in 0 },
        get: @escaping NativeEncoderFeatureAPI.Getter
    ) -> NativeEncoderFeatureAPI {
        .init(supports: { _ in true }, clear: clear, get: get)
    }

    private func metadata(_ frames: UInt32 = 2, generation: UInt64 = 1) -> EncoderFeatureMetadata {
        .init(frameCount: frames, dimension: 3, sampleRate: 16_000, hopSamples: 640, generation: generation)
    }

    func testLegacySDKMissingSymbolsFailsClosed() {
        XCTAssertNil(NativeEncoderFeatureAPI.resolve { _ in nil })
    }

    func testLoadedImageOptionalLookupWithoutModel() {
        // Exercise dladdr/dlopen/dlsym against the actual linked image. An
        // explicit expectation lets a patched-native test runner verify ABI
        // availability without opening model weights.
        let available = NativeEncoderFeatureAPI.resolved != nil
        XCTAssertEqual(Session.nativeEncoderFeatureAPIAvailable, available)
        if let expected = ProcessInfo.processInfo.environment["TRANSCRIBE_TEST_ENCODER_API_AVAILABLE"] {
            XCTAssertEqual(available, expected == "1")
        }
    }

    private func transcript() -> Transcript {
        var timing = transcribe_timings()
        transcribe_timings_init(&timing)
        return Transcript(text: "Kept ASR text.", language: "en", timestampKind: .none,
            segments: [], words: [], tokens: [], timings: Timings(timing))
    }

    func testOptionalCaptureFailurePreservesTranscriptWithExactlyOneASRCall() throws {
        var runs = 0, queries = 0, discarded = 0
        let expected = self.transcript()
        let badMetadata = self.api { _, _, _, _, _, _, _, _ in queries += 1; return 0 }
        let result = try performEncoderFeatureRun(required: false, run: { runs += 1; return expected },
            copy: { try badMetadata.copy(session: self.session, maximumBytes: 4, cancelled: { false }) },
            cancelled: { false }, discard: { discarded += 1 })
        XCTAssertEqual(result.transcript, expected)
        XCTAssertNil(result.encoderFeatures)
        XCTAssertEqual(runs, 1)
        XCTAssertEqual(queries, 1)
        XCTAssertGreaterThan(discarded, 0)
    }

    func testStrictCaptureFailureStillThrowsAfterOneASRCall() {
        var runs = 0
        XCTAssertThrowsError(try performEncoderFeatureRun(required: true,
            run: { runs += 1; return self.transcript() },
            copy: { throw TranscribeError.backend("copy failed") },
            cancelled: { false }, discard: {}))
        XCTAssertEqual(runs, 1)
    }

    func testLegacyOptionalFallbackRunsOnceAndStrictRejectsBeforeASR() throws {
        var runs = 0
        let expected = self.transcript()
        let result = try performEncoderFeatureRun(required: false, run: { runs += 1; return expected },
            copy: nil, cancelled: { false }, discard: {})
        XCTAssertEqual(result.transcript, expected)
        XCTAssertNil(result.encoderFeatures)
        XCTAssertEqual(runs, 1)
        XCTAssertThrowsError(try performEncoderFeatureRun(required: true,
            run: { runs += 1; return expected }, copy: nil, cancelled: { false }, discard: {}))
        XCTAssertEqual(runs, 1)
    }

    func testOptionalCaptureNeverMasksASRFailureOrReadsFeaturesAfterIt() {
        var copies = 0
        XCTAssertThrowsError(try performEncoderFeatureRun(required: false,
            run: { throw TranscribeError.backend("ASR failed") },
            copy: { copies += 1; throw TranscribeError.backend("copy") },
            cancelled: { false }, discard: {})) { error in
            guard case TranscribeError.backend(let message) = error else { return XCTFail("Wrong error: \(error)") }
            XCTAssertEqual(message, "ASR failed")
        }
        XCTAssertEqual(copies, 0)
    }

    func testOptionalCapturePropagatesBothCancellationErrorForms() {
        for failure: Error in [CancellationError(), TranscribeError.aborted(message: "cancelled", partial: nil)] {
            XCTAssertThrowsError(try performEncoderFeatureRun(required: false, run: { self.transcript() },
                copy: { throw failure }, cancelled: { false }, discard: {}))
        }
        var cancelled = false
        XCTAssertThrowsError(try performEncoderFeatureRun(required: false, run: { self.transcript() },
            copy: { cancelled = true; throw TranscribeError.backend("copy failed during cancellation") },
            cancelled: { cancelled }, discard: {})) { error in
            guard case TranscribeError.aborted = error else { return XCTFail("Cancellation was hidden: \(error)") }
        }
    }

    func testBoundedOwnedCopyKeepsClockAndGeneration() throws {
        var source: [Float] = [1, 2, 3, 4, 5, 6]
        var copies = 0
        let api = self.api { _, frames, dimension, rate, hop, generation, destination, capacity in
            frames?.pointee = 2; dimension?.pointee = 3; rate?.pointee = 16_000
            hop?.pointee = 640; generation?.pointee = 7
            if let destination {
                XCTAssertEqual(capacity, 6)
                for index in source.indices { destination[index] = source[index] }
                copies += 1
            }
            return 0
        }
        let snapshot = try api.copy(session: self.session, maximumBytes: 24, cancelled: { false })
        source[0] = 99
        XCTAssertEqual(snapshot.values, [1, 2, 3, 4, 5, 6])
        XCTAssertEqual(snapshot.frameDuration, 0.04)
        XCTAssertEqual(snapshot.nativeGeneration, 7)
        XCTAssertEqual(snapshot.recipeVersion, 1)
        XCTAssertEqual(copies, 1)
    }

    func testShapeAndCallerCapacityRejectBeforeCopy() throws {
        XCTAssertEqual(try self.metadata().elementCount(maximumBytes: 24), 6)
        XCTAssertThrowsError(try self.metadata().elementCount(maximumBytes: 23))
        XCTAssertThrowsError(try self.metadata(601).elementCount(maximumBytes: 2 * 1_024 * 1_024))
        XCTAssertThrowsError(try self.metadata(generation: 0).elementCount(maximumBytes: 24))
        XCTAssertThrowsError(try self.metadata().elementCount(maximumBytes: 2 * 1_024 * 1_024 + 1))
        var metadata = self.metadata()
        metadata.dimension = UInt32.max
        XCTAssertThrowsError(try metadata.elementCount(maximumBytes: 2 * 1_024 * 1_024))
    }

    func testChangedGenerationIsRejectedAndCleared() {
        var cleared = 0
        let api = self.api(clear: { _ in cleared += 1; return 0 }) {
            _, frames, dimension, rate, hop, generation, destination, _ in
            frames?.pointee = 1; dimension?.pointee = 1; rate?.pointee = 16_000
            hop?.pointee = 640; generation?.pointee = destination == nil ? 1 : 2
            destination?.pointee = 1
            return 0
        }
        XCTAssertThrowsError(try api.copy(session: self.session, maximumBytes: 4, cancelled: { false }))
        XCTAssertEqual(cleared, 1)
    }

    func testCancellationBeforeQueryClearsWithoutReadingOldFeatures() {
        var queried = false, cleared = false
        let api = self.api(clear: { _ in cleared = true; return 0 }) { _, _, _, _, _, _, _, _ in
            queried = true; return 0
        }
        XCTAssertThrowsError(try api.copy(session: self.session, maximumBytes: 4, cancelled: { true }))
        XCTAssertTrue(cleared)
        XCTAssertFalse(queried)
    }

    func testCancellationDuringCopyDoesNotPublishFeatures() {
        var cancelled = false, cleared = false
        let api = self.api(clear: { _ in cleared = true; return 0 }) {
            _, frames, dimension, rate, hop, generation, destination, _ in
            frames?.pointee = 1; dimension?.pointee = 1; rate?.pointee = 16_000
            hop?.pointee = 640; generation?.pointee = 1
            if let destination { destination.pointee = 1; cancelled = true }
            return 0
        }
        XCTAssertThrowsError(try api.copy(session: self.session, maximumBytes: 4, cancelled: { cancelled }))
        XCTAssertTrue(cleared)
    }

    func testNativeFailureAndNonfiniteValuesNeverReturnSnapshot() {
        let failure = self.api { _, _, _, _, _, _, _, _ in
            Int32(bitPattern: TRANSCRIBE_ERR_INVALID_ARG.rawValue)
        }
        XCTAssertThrowsError(try failure.copy(session: self.session, maximumBytes: 4, cancelled: { false }))
        let nonfinite = self.api { _, frames, dimension, rate, hop, generation, destination, _ in
            frames?.pointee = 1; dimension?.pointee = 1; rate?.pointee = 16_000
            hop?.pointee = 640; generation?.pointee = 1; destination?.pointee = .nan
            return 0
        }
        XCTAssertThrowsError(try nonfinite.copy(session: self.session, maximumBytes: 4, cancelled: { false }))
    }
}
