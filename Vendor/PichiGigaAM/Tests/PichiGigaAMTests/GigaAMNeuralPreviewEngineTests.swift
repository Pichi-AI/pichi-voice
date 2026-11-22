import Foundation
import XCTest
@testable import PichiGigaAM

final class GigaAMNeuralPreviewEngineTests: XCTestCase {
    func testAcceptsExactlySixSecondsOnShortGraphAndBoundsLongInference() throws {
        let short = [Float](repeating: 0, count: 96_000)
        try GigaAMNeuralPreviewEngine.validate(short, longContext: false)
        XCTAssertThrowsError(try GigaAMNeuralPreviewEngine.validate(short + [0], longContext: false))
        try GigaAMNeuralPreviewEngine.validate(short + [0], longContext: true)
        XCTAssertThrowsError(try GigaAMNeuralPreviewEngine.validate([.nan], longContext: false))
        XCTAssertThrowsError(try GigaAMNeuralPreviewEngine.validate([], longContext: true))
        XCTAssertThrowsError(try GigaAMNeuralPreviewEngine.validate([Float](repeating: 0, count: 400_001), longContext: true))
    }

    func testMissingArtifactsFailBeforeModelIsReady() async {
        let absent = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        do {
            _ = try await GigaAMNeuralPreviewEngine(directory: absent)
            XCTFail("Missing graph must fail preparation")
        } catch {
            XCTAssertFalse(FileManager.default.fileExists(atPath: absent.path))
        }
    }
}
