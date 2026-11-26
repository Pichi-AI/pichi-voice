import Foundation
@testable import PichiGigaAM
import XCTest

final class GigaAMEncoderGraphTests: XCTestCase {
    func testAddsNamedOutputToDescriptionAndInnerBlockPreservingOtherFields() throws {
        // Empty ModelDescription, then a program/function/block with a preexisting output "x".
        let model = Data([8, 7, 18, 0, 178, 31, 11, 18, 9, 18, 7, 26, 5, 18, 3, 18, 1, 120])
        let name = Data("layer_norm_95_cast_fp16".utf8)
        var expected = Data([8, 7, 18, 42, 82, 40, 10, 23])
        expected.append(name)
        // Core ML FLOAT16 multiarray [1,625,768].
        expected.append(contentsOf: [26, 13, 42, 11, 10, 5, 1, 241, 4, 128, 6, 16, 144, 128, 4])
        expected.append(contentsOf: [178, 31, 36, 18, 34, 18, 32, 26, 30, 18, 28, 18, 1, 120, 18, 23])
        expected.append(name)
        XCTAssertEqual(try GigaAMEncoderGraph.exposingEncoder(in: model), expected)
    }

    func testRejectsUnrecognizedStructureOrIncompleteLength() {
        for bytes: [UInt8] in [[18, 0], [18, 9], [13, 1, 0], [128, 128, 128, 128, 128, 1]] {
            XCTAssertThrowsError(try GigaAMEncoderGraph.exposingEncoder(in: Data(bytes)))
        }
    }

    func testWrongSourceCannotStageACompiledModel() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let spec = root.appendingPathComponent("Data/com.apple.CoreML/model.mlmodel")
        try FileManager.default.createDirectory(at: spec.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([18, 0]).write(to: spec)
        let output = root.appendingPathComponent("result.mlpackage")
        XCTAssertThrowsError(try GigaAMEncoderGraph.materialize(from: root, into: output))
        XCTAssertFalse(FileManager.default.fileExists(atPath: output.path))
    }
}
