import CoreML
import Foundation
@testable import PichiGigaAM
import XCTest

final class GigaAMMaskedAttentionTests: XCTestCase {
    /// A fixed graph should give the same CTC distribution for the same real frames
    /// even when extra padded positions change the width of its attention matrices.
    func testShortAndLongGraphsIgnorePaddingWhenPublicPackageIsAvailable() throws {
        #if os(macOS) && arch(arm64)
        guard let path = ProcessInfo.processInfo.environment["PICHI_GIGAAM_MASK_TEST_MODEL_DIR"] else {
            throw XCTSkip("Set PICHI_GIGAAM_MASK_TEST_MODEL_DIR to the verified Core ML package directory")
        }
        let directory = URL(fileURLWithPath: path)
        let descriptor = GigaAMModelCatalog.coreMLModel
        try descriptor.verify(in: directory)
        let package = directory.appendingPathComponent(descriptor.modelFile)
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: temp) }
        let shortURL = temp.appendingPathComponent("short.mlpackage")
        let longURL = temp.appendingPathComponent("long.mlpackage")
        try GigaAMShortGraph.materialize(from: package, into: shortURL)
        try GigaAMEncoderGraph.materialize(from: package, into: longURL)

        let frames = 371
        var features = [Float]()
        for mel in 0..<64 {
            for time in 0..<frames {
                let first = 2 * cos(Double(mel) * 0.21 + Double(time) * 0.047)
                let second = 4 * sin(Double(mel) * 0.17 - Double(time) * 0.09)
                features.append(Float(-4 + first + second))
            }
        }
        func scores(_ url: URL, capacity: Int) throws -> [Float] {
            let backend = try GigaAMCoreMLInference(packageURL: url, featureFrameCount: capacity)
            try backend.load(computeUnits: .cpuAndNeuralEngine)
            defer { backend.unloadModel() }
            return try backend.predict(features: features, frameCount: frames).values
        }
        let short = try scores(shortURL, capacity: GigaAMShortGraph.frameCount)
        let long = try scores(longURL, capacity: 2_499)
        XCTAssertEqual(short.count, 93 * 257)
        XCTAssertEqual(long.count, short.count)
        var difference = 0.0
        for (a, b) in zip(short, long) { difference += abs(exp(Double(a)) - exp(Double(b))) }
        // Mean total variation across real frames. Allows FP16/ANE numerical variation.
        XCTAssertLessThan(difference / (2 * 93), 0.025)
        #else
        throw XCTSkip("This regression compares the Apple Silicon macOS Neural Engine graphs")
        #endif
    }
}
