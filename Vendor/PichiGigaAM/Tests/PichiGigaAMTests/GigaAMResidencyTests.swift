import Darwin
import Foundation
import XCTest
@testable import PichiGigaAM

/// Opt-in native stress without personal audio. Matches the meeting's sequential
/// prepare, bounded PCM inference and joined release instead of a warm session only.
final class GigaAMResidencyTests: XCTestCase {
    func testRepeatedSyntheticBoundedWindowsReleaseNativeResidency() async throws {
        guard ProcessInfo.processInfo.environment["PICHI_GIGAAM_RESIDENCY_PROBE"] == "1",
              let modelPath = ProcessInfo.processInfo.environment["PICHI_GIGAAM_TEST_MODEL_DIR"] else {
            throw XCTSkip("Enable the local native residency probe with an installed public model.")
        }
        let directory = URL(fileURLWithPath: modelPath, isDirectory: true)
        let installed = try XCTUnwrap(GigaAMModelCatalog.discover(in: directory))
        let repetitions = min(256, max(8, Int(ProcessInfo.processInfo.environment["PICHI_GIGAAM_RESIDENCY_REPETITIONS"] ?? "16") ?? 16))
        let samples = [Float](repeating: 0, count: 12 * 16_000)
        let verificationStart = ContinuousClock.now
        try installed.descriptor.verify(in: installed.directory)
        print("GigaAM synthetic residency fullChecksumMS=\(milliseconds(since: verificationStart))")
        var warmedUnloaded: UInt64?
        var maximumLoaded: UInt64 = 0
        var recentUnloaded: [UInt64] = []
        for index in 0..<repetitions {
            let runtime = try GigaAMRuntime()
            let loadStart = ContinuousClock.now
            try await runtime.load(descriptor: installed.descriptor, directory: installed.directory)
            let loadMS = milliseconds(since: loadStart)
            let inferStart = ContinuousClock.now
            let result = try await runtime.transcribe(samples)
            let inferMS = milliseconds(since: inferStart)
            XCTAssertTrue(result.text.isEmpty, "Synthetic silence must preserve the rejection behavior")
            maximumLoaded = max(maximumLoaded, footprint())
            await runtime.unload()
            let ready = await runtime.isReady
            XCTAssertFalse(ready)
            let unloaded = footprint()
            if index == 3 { warmedUnloaded = unloaded }
            recentUnloaded.append(unloaded)
            if recentUnloaded.count > 4 { recentUnloaded.removeFirst() }
            print("GigaAM synthetic residency window=\(index + 1) loadMS=\(loadMS) inferMS=\(inferMS) unloadedFootprintBytes=\(unloaded)")
        }
        // macOS can defer releasing malloc arenas across several model calls. Check
        // the recent unloaded floor rather than treating one allocator high-water sample
        // as a leak. The probe logs every sample so transient peaks remain reviewable.
        XCTAssertLessThanOrEqual(try XCTUnwrap(recentUnloaded.min()),
                                 try XCTUnwrap(warmedUnloaded) + 96 * 1_024 * 1_024,
                                 "Joined release must not accumulate native residency")
        print("GigaAM synthetic residency windows=\(repetitions) maximumLoadedFootprintBytes=\(maximumLoaded)")
    }

    private func milliseconds(since start: ContinuousClock.Instant) -> Int64 {
        let elapsed = start.duration(to: .now).components
        return elapsed.seconds * 1_000 + elapsed.attoseconds / 1_000_000_000_000_000
    }

    private func footprint() -> UInt64 {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return status == KERN_SUCCESS ? info.phys_footprint : 0
    }
}
