@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The artifact check decides which model the app loads, so a folder holding another model must be refused.
final class ExternalCoreMLArtifactValidationXCTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        self.directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("external-coreml-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.directory)
    }

    private func spec() throws -> ExternalCoreMLASRModelSpec {
        try XCTUnwrap(ExternalCoreMLModelRegistry.spec(for: .cohereTranscribeSixBit))
    }

    private func writeArtifacts(of spec: ExternalCoreMLASRModelSpec, modelID: String) throws {
        for entry in spec.requiredEntries where entry != spec.manifestFileName {
            let package = spec.url(for: entry, in: self.directory)
            let contents = package.appendingPathComponent("Data", isDirectory: true)
            try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)
            try Data("synthetic weights".utf8).write(to: contents.appendingPathComponent("weights.bin"))
            let packageManifest = ["itemInfoEntries": ["weights": ["path": "weights.bin"]]]
            try JSONSerialization.data(withJSONObject: packageManifest)
                .write(to: package.appendingPathComponent("Manifest.json"))
        }
        let manifest: [String: Any] = ["model_id": modelID, "sample_rate": spec.expectedSampleRate,
                                       "max_audio_samples": spec.expectedSampleRate * 30, "max_audio_seconds": 30.0]
        try JSONSerialization.data(withJSONObject: manifest)
            .write(to: spec.url(for: spec.manifestFileName, in: self.directory))
    }

    func testTheExpectedModelPasses() throws {
        let spec = try self.spec()
        try self.writeArtifacts(of: spec, modelID: spec.expectedModelID)
        XCTAssertNoThrow(try spec.validateArtifactsOrThrow(at: self.directory))
    }

    func testAManifestOfAnotherModelIsRefused() throws {
        let spec = try self.spec()
        try self.writeArtifacts(of: spec, modelID: "Synthetic/other-model")
        XCTAssertThrowsError(try spec.validateArtifactsOrThrow(at: self.directory)) { error in
            guard case let ExternalCoreMLArtifactsValidationError.unexpectedModelID(expected, actual) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
            XCTAssertEqual(expected, spec.expectedModelID)
            XCTAssertEqual(actual, "Synthetic/other-model")
        }
    }
}
