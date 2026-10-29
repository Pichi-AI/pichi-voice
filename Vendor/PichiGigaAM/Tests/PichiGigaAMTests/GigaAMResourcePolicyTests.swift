import XCTest
@testable import PichiGigaAM

final class GigaAMResourcePolicyTests: XCTestCase {
    func testCapableGPUSelectsOnlyTheUniversalQuantizedArtifact() {
        let policy = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 16_000_000_000)
        XCTAssertEqual(policy.preferredDownload, GigaAMModelCatalog.downloadableModel)
        XCTAssertEqual(policy.preferredDownload.artifacts.count, 1)
        XCTAssertNil(policy.defaultCPUReason)
        XCTAssertNil(policy.gpuAdmissionReason)
        XCTAssertNotEqual(policy.preferredDownload, GigaAMModelCatalog.coreMLModel)
    }

    func testNominalFourGBTabletPreservesTheExistingCPUProfileBeforeDownload() {
        let policy = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 4_166_696_960,
                                          availableProcessMemory: 2_000_000_000)
        XCTAssertEqual(policy.preferredDownload, GigaAMModelCatalog.compactONNXModel)
        XCTAssertEqual(policy.defaultCPUReason, .memoryBudget)
        XCTAssertEqual(policy.gpuAdmissionReason, .memoryBudget)
        XCTAssertEqual(policy.preferredDownload.artifacts.compactMap(\.byteCount).reduce(0, +), 224_895_354)
    }

    func testMissingGPUSelectsCompactCPUWithoutDownloadingGPUWeights() {
        let policy = GigaAMResourcePolicy(hasGPU: false, physicalMemory: 16_000_000_000)
        XCTAssertEqual(policy.preferredDownload, GigaAMModelCatalog.compactONNXModel)
        XCTAssertEqual(policy.defaultCPUReason, .gpuUnavailable)
    }

    func testTransientHeadroomAffectsPreparationButDoesNotOscillateArtifactIdentity() {
        let normal = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 16_000_000_000)
        let pressured = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 16_000_000_000,
                                             availableProcessMemory: 128 * 1_024 * 1_024)
        let exhausted = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 16_000_000_000,
                                             availableProcessMemory: 0)
        XCTAssertEqual(pressured.preferredDownload.fingerprint, normal.preferredDownload.fingerprint)
        XCTAssertNil(normal.gpuAdmissionReason)
        XCTAssertEqual(pressured.gpuAdmissionReason, .memoryBudget)
        XCTAssertEqual(exhausted.gpuAdmissionReason, .memoryBudget)
    }
}
