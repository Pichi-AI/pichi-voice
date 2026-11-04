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
        let storage = UnsafeMutablePointer<UInt16>.allocate(capacity: 16)
        storage.initialize(repeating: 0xD630, count: 16) // IEEE binary16 -99 padding.
        let halfBits: [UInt16] = [0, 0x3C00, 0x4000, 0x4200, 0x4400, 0x4500, 0x4600, 0x4700, 0x4800]
        for frame in 0..<3 {
            for token in 0..<3 { storage[frame * 5 + token] = halfBits[frame * 3 + token] }
        }
        let array = try MLMultiArray(dataPointer: storage, shape: [1, 3, 3], dataType: .float16,
                                    strides: [16, 5, 1], deallocator: { pointer in
            pointer.assumingMemoryBound(to: UInt16.self).deallocate()
        })
        let result = try GigaAMCoreMLInference.readLogits(array, validFrames: 2)
        XCTAssertEqual(result.frameCount, 2)
        XCTAssertEqual(result.vocabularySize, 3)
        XCTAssertEqual(result.values, [0, 1, 2, 3, 4, 5])
    }

    func testHalfPrecisionTokenStrideAndSpecialFiniteValues() throws {
        let storage = UnsafeMutablePointer<UInt16>.allocate(capacity: 20)
        storage.initialize(repeating: 0xD630, count: 20)
        let bits: [UInt16] = [0x0000, 0x8000, 0x3C00, 0x3800, 0x0001, 0x7BFF]
        for frame in 0..<2 {
            for token in 0..<3 { storage[frame * 9 + token * 2] = bits[frame * 3 + token] }
        }
        let array = try MLMultiArray(dataPointer: storage, shape: [1, 2, 3], dataType: .float16,
                                    strides: [18, 9, 2], deallocator: { $0.assumingMemoryBound(to: UInt16.self).deallocate() })
        let result = try GigaAMCoreMLInference.readLogits(array, validFrames: 2)
        let expected: [Float] = [0, -0.0, 1, 0.5, 1.0 / 16_777_216.0, 65_504]
        XCTAssertEqual(result.values.map(\.bitPattern), expected.map(\.bitPattern))
        for invalid: UInt16 in [0x7C00, 0xFC00, 0x7E00] { // Positive/negative infinity and NaN.
            storage[9] = invalid
            XCTAssertThrowsError(try GigaAMCoreMLInference.readLogits(array, validFrames: 2))
        }
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
