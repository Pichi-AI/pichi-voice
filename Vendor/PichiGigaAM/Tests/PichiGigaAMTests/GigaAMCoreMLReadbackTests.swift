import CoreML
import XCTest
@testable import PichiGigaAM

final class GigaAMCoreMLReadbackTests: XCTestCase {
    func testPublishedLengthRoundingCannotReadPastAudioOrPhysicalOutput() throws {
        XCTAssertEqual(try GigaAMCoreMLInference.validFrameCount(inputFrames: 2_099, reportedFrames: 526, availableFrames: 625), 525)
        XCTAssertEqual(try GigaAMCoreMLInference.validFrameCount(inputFrames: 2_199, reportedFrames: 551, availableFrames: 625), 550)
        XCTAssertEqual(try GigaAMCoreMLInference.validFrameCount(inputFrames: 2_499, reportedFrames: 626, availableFrames: 625), 625)
        XCTAssertThrowsError(try GigaAMCoreMLInference.validFrameCount(inputFrames: 99, reportedFrames: 0, availableFrames: 625))
        XCTAssertThrowsError(try GigaAMCoreMLInference.validFrameCount(inputFrames: 99, reportedFrames: 10_000, availableFrames: 625))
    }

    func testHalfPrecisionPaddedRowsUseTheActualStrides() throws {
        let storage = UnsafeMutablePointer<Float16>.allocate(capacity: 16)
        storage.initialize(repeating: -99, count: 16)
        for frame in 0..<3 {
            for token in 0..<3 { storage[frame * 5 + token] = Float16(frame * 3 + token) }
        }
        let array = try MLMultiArray(dataPointer: storage, shape: [1, 3, 3], dataType: .float16,
                                    strides: [16, 5, 1], deallocator: { pointer in
            pointer.assumingMemoryBound(to: Float16.self).deallocate()
        })
        let result = try GigaAMCoreMLInference.readLogits(array, validFrames: 2)
        XCTAssertEqual(result.frameCount, 2)
        XCTAssertEqual(result.vocabularySize, 3)
        XCTAssertEqual(result.values, [0, 1, 2, 3, 4, 5])
    }

    func testFloatReadbackAndNonFiniteOutputValidation() throws {
        let array = try MLMultiArray(shape: [1, 2, 3], dataType: .float32)
        for index in 0..<array.count { array[index] = NSNumber(value: index) }
        XCTAssertEqual(try GigaAMCoreMLInference.readLogits(array, validFrames: 2).values, [0, 1, 2, 3, 4, 5])
        array[4] = NSNumber(value: Float.nan)
        XCTAssertThrowsError(try GigaAMCoreMLInference.readLogits(array, validFrames: 2))
        XCTAssertThrowsError(try GigaAMCoreMLInference.readLogits(array, validFrames: 0))
        XCTAssertThrowsError(try GigaAMCoreMLInference.readLogits(array, validFrames: 3))
    }
}
