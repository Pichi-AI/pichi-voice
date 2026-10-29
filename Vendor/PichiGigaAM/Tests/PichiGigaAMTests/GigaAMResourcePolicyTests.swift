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

    func testSmallTabletsUseTheSameGGUFAndPreferGPURegardlessOfTotalRAM() {
        for memory: UInt64 in [2_000_000_000, 3_000_000_000, 4_166_696_960] {
            let policy = GigaAMResourcePolicy(hasGPU: true, physicalMemory: memory,
                                              availableProcessMemory: 1_024 * 1_024 * 1_024)
            XCTAssertEqual(policy.preferredDownload, GigaAMModelCatalog.downloadableModel)
            XCTAssertEqual(policy.preferredDownload.format, .gguf)
            XCTAssertNil(policy.defaultCPUReason)
            XCTAssertNil(policy.gpuAdmissionReason)
            XCTAssertEqual(policy.preferredDownload.artifacts.compactMap(\.byteCount).reduce(0, +), 272_151_136)
        }
    }

    func testMissingGPUUsesTheSameGGUFOnCPU() {
        for memory: UInt64 in [2_000_000_000, 16_000_000_000] {
            let policy = GigaAMResourcePolicy(hasGPU: false, physicalMemory: memory)
            XCTAssertEqual(policy.preferredDownload, GigaAMModelCatalog.downloadableModel)
            XCTAssertEqual(policy.defaultCPUReason, .gpuUnavailable)
            XCTAssertEqual(policy.gpuAdmissionReason, .gpuUnavailable)
        }
    }

    func testTransientHeadroomAffectsPreparationButDoesNotOscillateArtifactIdentity() {
        let normal = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 16_000_000_000)
        let pressured = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 2_000_000_000,
                                             availableProcessMemory: 128 * 1_024 * 1_024)
        let exhausted = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 16_000_000_000,
                                             availableProcessMemory: 0)
        XCTAssertEqual(pressured.preferredDownload.fingerprint, normal.preferredDownload.fingerprint)
        XCTAssertNil(pressured.defaultCPUReason, "Transient headroom is checked at preparation, not frozen by the store")
        XCTAssertNil(normal.gpuAdmissionReason)
        XCTAssertEqual(pressured.gpuAdmissionReason, .memoryBudget)
        XCTAssertEqual(exhausted.gpuAdmissionReason, .memoryBudget)
    }
}
