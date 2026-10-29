import Foundation
import Metal
import XCTest
@testable import PichiGigaAM

final class GigaAMRetainedCPUResourceTests: XCTestCase {
    private final class Resources: @unchecked Sendable {
        private let lock = NSLock()
        private var value = GigaAMResourcePolicy(hasGPU: false, physicalMemory: 16_000_000_000,
                                                 availableProcessMemory: 2_000_000_000)
        func read() -> GigaAMResourcePolicy { self.lock.withLock { self.value } }
        func set(_ value: GigaAMResourcePolicy) { self.lock.withLock { self.value = value } }
    }

    func testUniversalGGUFUsesGPUOnSmallDeviceProfileAndTheSameFileForCPUFallback() async throws {
        guard let path = ProcessInfo.processInfo.environment["PICHI_GIGAAM_Q8_MODEL_DIR"],
              MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Set a verified local Q8 GGUF path on a Metal host for the universal artifact check.")
        }
        let profiles: [(GigaAMResourcePolicy, GigaAMExecutionStatus.Backend, GigaAMExecutionStatus.FallbackReason?)] = [
            (.init(hasGPU: true, physicalMemory: 2_000_000_000, availableProcessMemory: 2_000_000_000), .gpu, nil),
            (.init(hasGPU: false, physicalMemory: 2_000_000_000, availableProcessMemory: 2_000_000_000), .cpu, .gpuUnavailable),
            (.init(hasGPU: true, physicalMemory: 2_000_000_000, availableProcessMemory: 600 * 1_024 * 1_024), .cpu, .memoryBudget),
        ]
        for (profile, backend, reason) in profiles {
            let resources = Resources()
            resources.set(profile)
            let runtime = try GigaAMRuntime(resources: { resources.read() })
            do {
                try await runtime.load(descriptor: profile.preferredDownload, directory: URL(fileURLWithPath: path))
                let status = await runtime.executionStatus
                XCTAssertEqual(status?.backend, backend)
                XCTAssertEqual(status?.fallbackReason, reason)
                let silence = try await runtime.transcribe([Float](repeating: 0, count: 16_000))
                XCTAssertTrue(silence.text.isEmpty)
                resources.set(.init(hasGPU: true, physicalMemory: 2_000_000_000, availableProcessMemory: 2_000_000_000))
                try await runtime.beginAttempt()
                let recovered = await runtime.executionStatus
                XCTAssertEqual(recovered?.backend, .gpu)
                XCTAssertNil(recovered?.fallbackReason)
                await runtime.unload()
                let ready = await runtime.isReady
                XCTAssertFalse(ready)
            } catch { await runtime.unload(); throw error }
        }
    }

    func testLowHeadroomDefersGPURetryWithoutDiscardingPreparedCPU() async throws {
        guard let path = ProcessInfo.processInfo.environment["PICHI_GIGAAM_COREML_MEMORY_MODEL_DIR"],
              MTLCreateSystemDefaultDevice() != nil else {
            throw XCTSkip("Set a verified local Core ML package path on a Metal host for this resource transition check.")
        }
        let resources = Resources()
        let runtime = try GigaAMRuntime(resources: { resources.read() })
        do {
            try await runtime.load(descriptor: GigaAMModelCatalog.coreMLModel, directory: URL(fileURLWithPath: path))
            let initial = await runtime.executionStatus
            XCTAssertEqual(initial?.fallbackReason, .gpuUnavailable)
            resources.set(.init(hasGPU: true, physicalMemory: 16_000_000_000, availableProcessMemory: 512 * 1_024 * 1_024))
            try await runtime.beginAttempt()
            let deferred = await runtime.executionStatus
            let ready = await runtime.isReady
            XCTAssertTrue(ready)
            XCTAssertEqual(deferred?.backend, .cpu)
            XCTAssertEqual(deferred?.fallbackReason, .memoryBudget)
            _ = try await runtime.transcribe([Float](repeating: 0, count: 16_000))
            resources.set(.init(hasGPU: true, physicalMemory: 16_000_000_000, availableProcessMemory: 2_000_000_000))
            try await runtime.beginAttempt()
            let recovered = await runtime.executionStatus
            XCTAssertEqual(recovered?.backend, .gpu)
            XCTAssertNil(recovered?.fallbackReason)
            await runtime.unload()
        } catch { await runtime.unload(); throw error }
    }
}
