import Foundation
import XCTest

final nonisolated class MeetingCoreMLComputeDiagnosticsTests: XCTestCase {
    func testStructuralCountsDistinguishAnticipatedAndUnavailablePlacement() throws {
        var summary = MeetingCoreMLComputeDiagnostics.Summary(role: "diarizer", requestedComputeUnits: "cpuAndGPU", availableDevices: ["cpu", "gpu"])
        summary.append(operationType: "matmul", preferred: .gpu, supported: [.cpu, .gpu, .gpu], weight: 0.7)
        summary.append(operationType: "matmul", preferred: .cpu, supported: [.cpu], weight: 0.2)
        summary.append(operationType: "reshape", preferred: nil, supported: [], weight: nil)
        XCTAssertEqual(summary.operations, 3)
        XCTAssertEqual(summary.groups["matmul"]?.preferred, ["cpu": 1, "gpu": 1])
        XCTAssertEqual(summary.groups["matmul"]?.supported, ["cpu": 2, "gpu": 1])
        XCTAssertEqual(summary.groups["matmul"]?.estimatedRelativeWeightByPreferred, ["cpu": 0.2, "gpu": 0.7])
        XCTAssertEqual(summary.groups["reshape"]?.preferred, ["unknown": 1])
        XCTAssertEqual(summary.groups["reshape"]?.unavailableWeights, 1)
        let data = try JSONEncoder().encode(summary)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("anticipatedNotMeasured"))
        XCTAssertTrue(text.contains("relativeEstimateNotSecondsOrUtilization"))
        XCTAssertFalse(summary.truncated)
    }

    func testUntrustedTypeAndNonfiniteCostsCannotEnterMetadata() throws {
        var summary = MeetingCoreMLComputeDiagnostics.Summary(role: "diarizer", requestedComputeUnits: "cpuAndGPU", availableDevices: [])
        for (name, cost) in [("/private/model/secret", Double.nan), ("text\ncontents", Double.infinity), ("", -1.0), (String(repeating: "a", count: 65), 2.0)] {
            summary.append(operationType: name, preferred: .cpu, supported: [.cpu], weight: cost)
        }
        XCTAssertEqual(summary.groups.count, 1)
        XCTAssertEqual(summary.groups["other"]?.unavailableWeights, 4)
        XCTAssertEqual(summary.groups["other"]?.estimatedWeights, 0)
        let data = try JSONEncoder().encode(summary)
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret"))
    }

    func testAggregationAndOutputStayBoundedForLargeStructures() throws {
        var summary = MeetingCoreMLComputeDiagnostics.Summary(role: "diarizer", requestedComputeUnits: "cpuOnly", availableDevices: ["cpu"])
        for index in 0...MeetingCoreMLComputeDiagnostics.maximumOperations {
            summary.append(operationType: "operator_\(index)", preferred: .cpu, supported: [.cpu], weight: 1)
        }
        XCTAssertEqual(summary.operations, MeetingCoreMLComputeDiagnostics.maximumOperations)
        XCTAssertEqual(summary.groups.count, MeetingCoreMLComputeDiagnostics.maximumGroups)
        XCTAssertEqual(summary.groups.values.map(\.operations).reduce(0, +), summary.operations)
        XCTAssertTrue(summary.truncated)
        XCTAssertLessThan(try JSONEncoder().encode(summary).count, 192 * 1024)
    }

    func testEmptyNestedStructuresHaveIndependentTraversalAndDepthBounds() {
        var summary = MeetingCoreMLComputeDiagnostics.Summary(role: "diarizer", requestedComputeUnits: "cpuOnly", availableDevices: [])
        XCTAssertFalse(summary.enterNode(depth: MeetingCoreMLComputeDiagnostics.maximumDepth + 1))
        XCTAssertEqual(summary.structuralNodes, 0)
        var admitted = 0
        for _ in 0..<MeetingCoreMLComputeDiagnostics.maximumOperations { if summary.enterNode(depth: 0) { admitted += 1 } }
        XCTAssertEqual(admitted, MeetingCoreMLComputeDiagnostics.maximumOperations)
        XCTAssertFalse(summary.enterNode(depth: 0))
        XCTAssertEqual(summary.operations, 0)
        XCTAssertTrue(summary.truncated)
    }
}
