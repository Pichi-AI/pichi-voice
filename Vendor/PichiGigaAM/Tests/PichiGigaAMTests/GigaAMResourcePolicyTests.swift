import XCTest
@testable import PichiGigaAM

final class GigaAMResourcePolicyTests: XCTestCase {
    func testOnePlatformArtifactAcrossDevicesIncludingCPUFallback() {
        #if os(macOS)
        let expected = GigaAMModelCatalog.coreMLModel
        XCTAssertFalse(expected.artifacts.contains { $0.path.hasSuffix(".gguf") })
        #else
        let expected = GigaAMModelCatalog.downloadableModel
        XCTAssertEqual(expected.format, .gguf)
        #endif
        for hasGPU in [true, false] {
            for memory: UInt64 in [2_000_000_000, 4_166_696_960, 16_000_000_000] {
                for background in [true, false] {
                    let policy = GigaAMResourcePolicy(hasGPU: hasGPU, physicalMemory: memory,
                        requiresBackgroundExecution: background)
                    XCTAssertEqual(policy.preferredDownload, expected)
                    let reason: GigaAMExecutionStatus.FallbackReason? = background ? .backgroundExecution : (hasGPU ? nil : .gpuUnavailable)
                    XCTAssertEqual(policy.defaultCPUReason, reason)
                    XCTAssertEqual(policy.gpuAdmissionReason, reason)
                }
            }
        }
    }

    func testTransientHeadroomAffectsPreparationButDoesNotOscillateArtifactIdentity() {
        let normal = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 16_000_000_000)
        let pressured = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 2_000_000_000,
                                             availableProcessMemory: 128 * 1_024 * 1_024)
        let exhausted = GigaAMResourcePolicy(hasGPU: true, physicalMemory: 16_000_000_000,
                                             availableProcessMemory: 0)
        XCTAssertEqual(pressured.preferredDownload.fingerprint, normal.preferredDownload.fingerprint)
        XCTAssertNil(pressured.defaultCPUReason)
        XCTAssertNil(normal.gpuAdmissionReason)
        XCTAssertEqual(pressured.gpuAdmissionReason, .memoryBudget)
        XCTAssertEqual(exhausted.gpuAdmissionReason, .memoryBudget)
    }
}
