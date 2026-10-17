import Foundation
#if canImport(CoreML)
import CoreML
#endif

/// Opt-in inspection at the already validated model boundary. A compute plan is
/// Core ML's anticipated placement, not a measurement of GPU use or elapsed op time.
/// It never changes the inference configuration or retains a plan through inference.
nonisolated enum MeetingCoreMLComputeDiagnostics {
    nonisolated enum Role: String, Sendable { case diarizer, voiceEncoder }
    nonisolated enum Device: String, Codable, CaseIterable, Hashable, Sendable {
        case cpu, gpu, neuralEngine, unknown
    }

    /// Fixed bounds also cover malformed or unexpectedly large model structures.
    static let maximumOperations = 100_000
    static let maximumGroups = 128
    static let maximumDepth = 32
    static let maximumChildren = 32

    nonisolated struct Group: Encodable, Sendable, Equatable {
        var operationType: String
        var operations = 0
        var preferred: [String: Int] = [:]
        var supported: [String: Int] = [:]
        var estimatedRelativeWeightByPreferred: [String: Double] = [:]
        var estimatedWeights = 0
        var unavailableWeights = 0
    }

    /// Model-free aggregation is independently testable without audio or weights.
    nonisolated struct Summary: Encodable, Sendable, Equatable {
        let schema = "meetingComputePlanV1"
        let placementEvidence = "anticipatedNotMeasured"
        let costMeaning = "relativeEstimateNotSecondsOrUtilization"
        let operationScope = "staticStructureIncludesVisitedFunctionsAndControlFlowBranches"
        let costAggregation = "sumMayIncludeMutuallyExclusiveBranches"
        var role: String
        var requestedComputeUnits: String
        var availableDevices: [String]
        var structure = "unsupported"
        var operations = 0
        var structuralNodes = 0
        var truncated = false
        var unsupportedStructures = 0
        var groups: [String: Group] = [:]
        var elapsedMs: Int64 = 0
        var planLoadMs: Int64 = 0
        var planInspectMs: Int64 = 0

        mutating func enterNode(depth: Int) -> Bool {
            guard depth <= MeetingCoreMLComputeDiagnostics.maximumDepth,
                  structuralNodes < MeetingCoreMLComputeDiagnostics.maximumOperations,
                  operations < MeetingCoreMLComputeDiagnostics.maximumOperations else {
                truncated = true
                return false
            }
            structuralNodes += 1
            return true
        }

        mutating func append(operationType: String, preferred: Device?, supported: [Device], weight: Double?) {
            guard operations < MeetingCoreMLComputeDiagnostics.maximumOperations else {
                truncated = true
                return
            }
            operations += 1
            var type = Self.safeOperationType(operationType)
            // Reserve the last group for all additional structural operator types.
            if groups[type] == nil, groups.count >= MeetingCoreMLComputeDiagnostics.maximumGroups - 1 { type = "other" }
            var group = groups[type] ?? Group(operationType: type)
            group.operations += 1
            let device = (preferred ?? .unknown).rawValue
            group.preferred[device, default: 0] += 1
            for supportedDevice in Set(supported) { group.supported[supportedDevice.rawValue, default: 0] += 1 }
            if let weight, weight.isFinite, (0...1).contains(weight) {
                group.estimatedWeights += 1
                group.estimatedRelativeWeightByPreferred[device, default: 0] += weight
            } else {
                group.unavailableWeights += 1
            }
            groups[type] = group
        }

        private static func safeOperationType(_ value: String) -> String {
            guard !value.isEmpty, value.utf8.count <= 64,
                  value.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || $0 == 95 }) else {
                return "other"
            }
            return value
        }
    }

    /// Compute-plan loading may specialize a large model and consume substantial
    /// time/memory. Routine detailed timing never opts into that separate probe.
    static func requested(environment: [String: String]) -> Bool {
        environment["PICHI_MEETING_DETAILED_PROFILE"] == "1"
            && environment["PICHI_MEETING_COMPUTE_PLAN"] == "1"
    }

    static var enabled: Bool {
        Self.requested(environment: ProcessInfo.processInfo.environment)
    }

    #if canImport(CoreML)
    /// The caller supplies the compiled URL validated for this attempt and the exact
    /// immutable model configuration. No model reload, download or artifact selection.
    static func logPlan(for compiledURL: URL, configuration: MLModelConfiguration, role: Role) async {
        guard enabled else { return }
        guard !Task.isCancelled else {
            Self.logUnavailable(role: role, reason: "cancelled")
            return
        }
        guard #available(iOS 17.4, macOS 14.4, tvOS 17.4, watchOS 10.4, *) else {
            Self.logUnavailable(role: role, reason: "apiUnavailable")
            return
        }
        // Copy preserves every configuration field while preventing a caller's
        // mutation across the suspension from changing the inspected selection.
        guard let snapshot = configuration.copy() as? MLModelConfiguration else {
            Self.logUnavailable(role: role, reason: "configurationUnavailable")
            return
        }
        let began = ContinuousClock.now
        DebugLogger.shared.log("[meeting/compute-plan] event=begin role=\(role.rawValue) requestedComputeUnits=\(Self.computeName(snapshot.computeUnits)) placementEvidence=anticipatedNotMeasured", source: "MeetingPCMRuntime")
        do {
            // The scoped method releases the plan before returning the small summary.
            var summary = try await Self.loadSummary(for: compiledURL, configuration: snapshot, role: role)
            summary.elapsedMs = Self.milliseconds(since: began)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            guard let payload = try? encoder.encode(summary), payload.count <= 192 * 1024,
                  let line = String(data: payload, encoding: .utf8) else {
                Self.logUnavailable(role: role, reason: "summaryUnavailable")
                return
            }
            DebugLogger.shared.log("[meeting/compute-plan] event=end summary=\(line)", source: "MeetingPCMRuntime")
        } catch {
            // Never log errors that may contain file paths, tensor/model contents or
            // inputs. Optional diagnostics must not fail the real inference phase.
            Self.logUnavailable(role: role, reason: Task.isCancelled ? "cancelled" : "planUnavailable")
        }
    }

    private static func computeName(_ units: MLComputeUnits) -> String {
        switch units {
        case .cpuOnly: return "cpuOnly"
        case .cpuAndGPU: return "cpuAndGPU"
        case .cpuAndNeuralEngine: return "cpuAndNeuralEngine"
        case .all: return "all"
        @unknown default: return "unknown"
        }
    }

    @available(iOS 17.4, macOS 14.4, tvOS 17.4, watchOS 10.4, *)
    private static func device(_ device: MLComputeDevice) -> Device {
        switch device {
        case .cpu: return .cpu
        case .gpu: return .gpu
        case .neuralEngine: return .neuralEngine
        @unknown default: return .unknown
        }
    }

    @available(iOS 17.4, macOS 14.4, tvOS 17.4, watchOS 10.4, *)
    private static func loadSummary(for url: URL, configuration: MLModelConfiguration, role: Role) async throws -> Summary {
        let loadBegan = ContinuousClock.now
        let plan = try await MLComputePlan.load(contentsOf: url, configuration: configuration)
        let loadMs = Self.milliseconds(since: loadBegan)
        let inspectBegan = ContinuousClock.now
        try Task.checkCancellation()
        var summary = Summary(role: role.rawValue, requestedComputeUnits: Self.computeName(configuration.computeUnits),
                              availableDevices: Set(MLComputeDevice.allComputeDevices.map { Self.device($0).rawValue }).sorted())
        summary.planLoadMs = loadMs
        switch plan.modelStructure {
        case .program: summary.structure = "program"
        case .neuralNetwork: summary.structure = "neuralNetwork"
        case .pipeline: summary.structure = "pipeline"
        case .unsupported: break
        @unknown default: break
        }
        try Self.append(structure: plan.modelStructure, plan: plan, depth: 0, summary: &summary)
        summary.planInspectMs = Self.milliseconds(since: inspectBegan)
        return summary
    }

    @available(iOS 17.4, macOS 14.4, tvOS 17.4, watchOS 10.4, *)
    private static func append(structure: MLModelStructure, plan: MLComputePlan, depth: Int, summary: inout Summary) throws {
        try Task.checkCancellation()
        guard summary.enterNode(depth: depth) else { return }
        switch structure {
        case let .program(program):
            if program.functions.count > maximumChildren { summary.truncated = true }
            for key in program.functions.keys.prefix(maximumChildren).sorted() {
                guard let function = program.functions[key] else { continue }
                try Self.append(block: function.block, plan: plan, depth: depth, summary: &summary)
            }
        case let .neuralNetwork(network):
            for layer in network.layers {
                guard summary.operations < maximumOperations else { summary.truncated = true; break }
                try Task.checkCancellation()
                let usage = plan.deviceUsage(for: layer)
                summary.append(operationType: layer.type, preferred: usage.map { Self.device($0.preferred) },
                               supported: usage?.supported.map(Self.device) ?? [], weight: nil)
            }
        case let .pipeline(pipeline):
            if pipeline.subModels.count > maximumChildren { summary.truncated = true }
            for submodel in pipeline.subModels.prefix(maximumChildren) {
                try Self.append(structure: submodel, plan: plan, depth: depth + 1, summary: &summary)
            }
        case .unsupported: summary.unsupportedStructures += 1
        @unknown default: summary.unsupportedStructures += 1
        }
    }

    @available(iOS 17.4, macOS 14.4, tvOS 17.4, watchOS 10.4, *)
    private static func append(block: MLModelStructure.Program.Block, plan: MLComputePlan, depth: Int, summary: inout Summary) throws {
        try Task.checkCancellation()
        guard summary.enterNode(depth: depth) else { return }
        for operation in block.operations {
            guard summary.operations < maximumOperations else { summary.truncated = true; break }
            try Task.checkCancellation()
            let usage = plan.deviceUsage(for: operation)
            summary.append(operationType: operation.operatorName, preferred: usage.map { Self.device($0.preferred) },
                           supported: usage?.supported.map(Self.device) ?? [], weight: plan.estimatedCost(of: operation)?.weight)
            if operation.blocks.count > maximumChildren { summary.truncated = true }
            for nested in operation.blocks.prefix(maximumChildren) {
                try Self.append(block: nested, plan: plan, depth: depth + 1, summary: &summary)
            }
        }
    }
    #endif

    private static func milliseconds(since began: ContinuousClock.Instant) -> Int64 {
        let duration = began.duration(to: .now).components
        return duration.seconds * 1_000 + duration.attoseconds / 1_000_000_000_000_000
    }

    private static func logUnavailable(role: Role, reason: String) {
        DebugLogger.shared.log("[meeting/compute-plan] event=unavailable role=\(role.rawValue) reason=\(reason) placementEvidence=anticipatedNotMeasured", source: "MeetingPCMRuntime")
    }
}
