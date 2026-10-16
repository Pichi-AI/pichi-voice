import Darwin
import Foundation

// Standalone compile context: the app supplies this protocol and localization service.
nonisolated protocol MeetingPCMReplaySource: Sendable {
    var totalSampleCount: Int { get }
    func readSamples(in range: Range<Int>) async throws -> [Float]
}
nonisolated enum PichiLocalization { static func text(_ key: String) -> String { key } }

private func require(_ condition: @autoclosure () -> Bool, _ reason: String) throws {
    if !condition() { throw NSError(domain: "MeetingMemoryAudioArchiveTests", code: 1, userInfo: [NSLocalizedDescriptionKey: reason]) }
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

@main
private struct ArchiveTests {
    static func main() async throws {
        try await roundTripAndTimeline()
        try await terminalOwnershipAndBounds()
        try await cancellation()
        if CommandLine.arguments.contains("--repeat-eight-hours") {
            let firstPeak = try await eightHours()
            let secondPeak = try await eightHours()
            try require(secondPeak <= firstPeak + 32 * 1024 * 1024, "A second eight-hour session accumulated retained native memory")
        } else if CommandLine.arguments.contains("--eight-hours") { _ = try await eightHours() }
        print("MeetingMemoryAudioArchiveTests passed")
    }

    private static func append(_ samples: [Float], to archive: MeetingMemoryAudioArchive) throws {
        for start in stride(from: 0, to: samples.count, by: 8_000) {
            try samples.withUnsafeBufferPointer { buffer in
                try archive.append(UnsafeBufferPointer(rebasing: buffer[start..<min(start + 8_000, samples.count)]))
            }
        }
    }

    private static func roundTripAndTimeline() async throws {
        // Non-packet-aligned length and boundaries exercise AAC leading/padded-tail trimming.
        for count in [1, 1_023, 1_024, 16_001, 39_731] {
            let archive = try MeetingMemoryAudioArchive(segmentSeconds: 1)
            let samples = (0..<count).map { frame -> Float in
                let envelope: Float = frame % 8_000 < 4_000 ? 0.4 : 0.1
                return envelope * sin(Float(frame) * 0.12)
            }
            try append(samples, to: archive)
            do {
                _ = try await archive.readSamples(in: 0..<min(count, 1))
                throw NSError(domain: "Tests", code: 1)
            } catch MeetingMemoryAudioArchiveError.notSealed { }
            try archive.seal()
            try archive.seal()
            try require(archive.totalSampleCount == count, "Capture frame count changed while sealing")
            let actual = try await archive.readSamples(in: 0..<count)
            try require(actual.count == count, "AAC priming/tail altered the original timeline length")
            if count > 2_000 {
                let start = 600, end = count - 600
                let mse = (start..<end).reduce(Float(0)) { $0 + pow(actual[$1] - samples[$1], 2) } / Float(end - start)
                try require(mse < 0.002, "AAC roundtrip drift or unexpected distortion: mse=\(mse)")
                // A priming error shifts this tone by 2112 frames and fails the MSE assertion.
            }
            let lower = min(15_900, count), upper = min(16_200, count)
            let excerpt = try await archive.readSamples(in: lower..<upper)
            try require(excerpt == Array(actual[lower..<upper]), "Random reads changed sample offsets across a segment boundary")
            try require(archive.bufferedPCMSampleCount <= 16_000, "Decoder retained more than one segment")
            try require([32_000, 48_000].contains(archive.encodingBitRate ?? 0), "Encoder did not select a supported bounded bit rate")
            archive.clear()
            try require(archive.totalSampleCount == 0 && archive.retainedEncodedBytes == 0 && archive.bufferedPCMSampleCount == 0, "Clear retained audio")
        }
    }

    private static func terminalOwnershipAndBounds() async throws {
        let archive = try MeetingMemoryAudioArchive(maximumRetainedBytes: 1, segmentSeconds: 1)
        do {
            try append([Float](repeating: 0.1, count: 16_000), to: archive)
            throw NSError(domain: "Tests", code: 1)
        } catch MeetingMemoryAudioArchiveError.capacityExceeded { }
        try require(archive.totalSampleCount == 0 && archive.retainedEncodedBytes == 0, "Capacity failure kept partial audio")
        do { try archive.seal(); throw NSError(domain: "Tests", code: 1) }
        catch MeetingMemoryAudioArchiveError.unavailable { }
        let invalid = try MeetingMemoryAudioArchive()
        do { try append([0, .nan], to: invalid); throw NSError(domain: "Tests", code: 1) }
        catch MeetingMemoryAudioArchiveError.invalidPCM { }
        let sealed = try MeetingMemoryAudioArchive()
        try append([0.1], to: sealed)
        try sealed.seal()
        do { _ = try await sealed.readSamples(in: -1..<0); throw NSError(domain: "Tests", code: 1) }
        catch MeetingMemoryAudioArchiveError.invalidRange { }
        do { _ = try await sealed.readSamples(in: 0..<2); throw NSError(domain: "Tests", code: 1) }
        catch MeetingMemoryAudioArchiveError.invalidRange { }
        sealed.clear()
        do { _ = try await sealed.readSamples(in: 0..<0); throw NSError(domain: "Tests", code: 1) }
        catch MeetingMemoryAudioArchiveError.unavailable { }
        let empty = try MeetingMemoryAudioArchive()
        try empty.seal()
        let emptySamples = try await empty.readSamples(in: 0..<0)
        try require(emptySamples.isEmpty, "Empty archive produced samples")
    }

    private static func cancellation() async throws {
        let archive = try MeetingMemoryAudioArchive()
        try append([Float](repeating: 0.2, count: 16_000), to: archive)
        try archive.seal()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try await archive.readSamples(in: 0..<16_000); return false }
            catch is CancellationError { return true }
            catch { return false }
        }
        let cancelled = await task.value
        try require(cancelled, "Cancelled replay did not stop")
        archive.clear()
        try require(archive.retainedEncodedBytes == 0, "Cancelled replay prevented release")
    }

    private static func eightHours() async throws -> UInt64 {
        let archive = try MeetingMemoryAudioArchive()
        // Synthetic, repeatedly generated input. This actually encodes every frame through the
        // native codec; no fixture/reference duplication substitutes for eight-hour ownership.
        let chunk = (0..<32_000).map { 0.35 * sin(Float($0) * 0.11) + 0.1 * sin(Float($0) * 0.043) }
        let baseline = footprint()
        var peak = baseline
        for index in 0..<14_400 {
            try chunk.withUnsafeBufferPointer { try archive.append($0) }
            if index % 15 == 0 { peak = max(peak, footprint()) }
            try require(archive.retainedEncodedBytes <= 256 * 1024 * 1024, "Archive exceeded encoded budget")
            try require(archive.bufferedPCMSampleCount <= 480_000, "Capture PCM grew with duration")
        }
        try archive.seal()
        try require(archive.totalSampleCount == 8 * 60 * 60 * 16_000, "Eight-hour sample count drifted")
        try require(archive.retainedSegmentCount == 960, "Eight-hour archive segment ownership drifted")
        let count = archive.totalSampleCount
        let first = try await archive.readSamples(in: 0..<16_000)
        let last = try await archive.readSamples(in: (count - 16_000)..<count)
        try require(first.count == 16_000 && last.count == 16_000, "Eight-hour endpoints were not recoverable")
        let retained = archive.retainedEncodedBytes
        peak = max(peak, footprint())
        archive.clear()
        try require(archive.retainedEncodedBytes == 0 && archive.bufferedPCMSampleCount == 0, "Eight-hour archive did not release owned audio")
        print("eight-hour synthetic native AAC: frames=\(count) segments=960 retainedBytes=\(retained) physicalFootprintBaseline=\(baseline) physicalFootprintPeak=\(peak) afterClear=\(footprint())")
        if baseline > 0 { try require(peak < baseline + UInt64(retained) + 96 * 1024 * 1024, "Physical memory exceeded retained audio plus bounded codec working headroom") }
        return peak
    }
}
