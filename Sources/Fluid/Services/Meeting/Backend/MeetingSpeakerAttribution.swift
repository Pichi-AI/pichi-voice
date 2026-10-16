import CryptoKit
import Foundation

/// Presentation policy, frozen with the processing attempt. These are conservative product
/// choices, not calibrated probabilities or assumptions about a particular diarization model.
nonisolated struct MeetingSpeakerAttributionPolicy: Codable, Equatable, Sendable {
    static let currentVersion = 1
    static let standard = Self()

    let schemaVersion: Int
    /// Arithmetic slack only. It never expands intervals or creates positive overlap.
    let comparisonTolerance: Double
    let minimumAcousticSupportSeconds: Double
    let dominanceMinLeaderFraction: Double
    let dominanceMaxRunnerFraction: Double
    let dominanceMinRatio: Double
    let maximumUnknownRunSeconds: Double
    let maximumNeighborGapSeconds: Double
    let maximumBoundaryResidualSeconds: Double
    let maximumBriefInterruptionSeconds: Double
    let maximumInterruptionWordSeconds: Double
    let maximumBriefInterruptionGapSeconds: Double
    let enableDominance: Bool
    let enableNeighborResolution: Bool
    let enableBriefInterruption: Bool

    init(
        schemaVersion: Int = Self.currentVersion,
        comparisonTolerance: Double = 0.000_000_001,
        minimumAcousticSupportSeconds: Double = 0.08,
        dominanceMinLeaderFraction: Double = 0.5,
        dominanceMaxRunnerFraction: Double = 0.2,
        dominanceMinRatio: Double = 2,
        maximumUnknownRunSeconds: Double = 3.5,
        maximumNeighborGapSeconds: Double = 0.8,
        maximumBoundaryResidualSeconds: Double = 0.08,
        maximumBriefInterruptionSeconds: Double = 2,
        maximumInterruptionWordSeconds: Double = 3,
        maximumBriefInterruptionGapSeconds: Double = 0.08,
        enableDominance: Bool = true,
        enableNeighborResolution: Bool = true,
        enableBriefInterruption: Bool = true
    ) {
        self.schemaVersion = schemaVersion
        self.comparisonTolerance = comparisonTolerance
        self.minimumAcousticSupportSeconds = minimumAcousticSupportSeconds
        self.dominanceMinLeaderFraction = dominanceMinLeaderFraction
        self.dominanceMaxRunnerFraction = dominanceMaxRunnerFraction
        self.dominanceMinRatio = dominanceMinRatio
        self.maximumUnknownRunSeconds = maximumUnknownRunSeconds
        self.maximumNeighborGapSeconds = maximumNeighborGapSeconds
        self.maximumBoundaryResidualSeconds = maximumBoundaryResidualSeconds
        self.maximumBriefInterruptionSeconds = maximumBriefInterruptionSeconds
        self.maximumInterruptionWordSeconds = maximumInterruptionWordSeconds
        self.maximumBriefInterruptionGapSeconds = maximumBriefInterruptionGapSeconds
        self.enableDominance = enableDominance
        self.enableNeighborResolution = enableNeighborResolution
        self.enableBriefInterruption = enableBriefInterruption
    }

    /// Exact, length-framed values avoid locale, delimiter and rounding collisions. Zero has one
    /// representation, including decoded negative zero. Its digest keeps per-word metadata bounded;
    /// the complete immutable policy remains stored once with the attempt, not reconstructed from
    /// its digest. No model or personal identity enters it.
    var fingerprint: String {
        func bits(_ value: Double) -> String { String(value == 0 ? 0 : value.bitPattern, radix: 16) }
        let canonical = MeetingConfigFingerprintEncoding.encode([
            ("attributionVersion", String(self.schemaVersion)),
            ("comparisonTolerance", bits(self.comparisonTolerance)),
            ("minimumSupport", bits(self.minimumAcousticSupportSeconds)),
            ("leaderFraction", bits(self.dominanceMinLeaderFraction)),
            ("runnerFraction", bits(self.dominanceMaxRunnerFraction)),
            ("leaderRatio", bits(self.dominanceMinRatio)),
            ("unknownRun", bits(self.maximumUnknownRunSeconds)),
            ("neighborGap", bits(self.maximumNeighborGapSeconds)),
            ("boundaryResidual", bits(self.maximumBoundaryResidualSeconds)),
            ("briefInterruption", bits(self.maximumBriefInterruptionSeconds)),
            ("interruptionWord", bits(self.maximumInterruptionWordSeconds)),
            ("interruptionGap", bits(self.maximumBriefInterruptionGapSeconds)),
            ("dominanceEnabled", String(self.enableDominance)),
            ("neighborsEnabled", String(self.enableNeighborResolution)),
            ("interruptionEnabled", String(self.enableBriefInterruption)),
        ])
        let digest = SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
        return "speaker-attribution-v\(self.schemaVersion):\(digest)"
    }

    func validated() throws -> Self {
        guard self.schemaVersion == Self.currentVersion else {
            throw MeetingSpeakerAttributionError.unsupportedPolicyVersion(self.schemaVersion)
        }
        let nonnegative = [self.minimumAcousticSupportSeconds, self.maximumUnknownRunSeconds,
                           self.maximumNeighborGapSeconds, self.maximumBoundaryResidualSeconds,
                           self.maximumBriefInterruptionSeconds, self.maximumInterruptionWordSeconds,
                           self.maximumBriefInterruptionGapSeconds]
        guard self.comparisonTolerance.isFinite, (0...0.000_001).contains(self.comparisonTolerance),
              nonnegative.allSatisfy({ $0.isFinite && $0 >= 0 }),
              self.dominanceMinLeaderFraction.isFinite,
              (0...1).contains(self.dominanceMinLeaderFraction),
              self.dominanceMaxRunnerFraction.isFinite,
              (0...1).contains(self.dominanceMaxRunnerFraction),
              self.dominanceMinRatio.isFinite, self.dominanceMinRatio >= 1
        else { throw MeetingSpeakerAttributionError.invalidPolicy }
        return self
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion, comparisonTolerance, minimumAcousticSupportSeconds, dominanceMinLeaderFraction
        case dominanceMaxRunnerFraction, dominanceMinRatio, maximumUnknownRunSeconds
        case maximumNeighborGapSeconds, maximumBoundaryResidualSeconds, maximumBriefInterruptionSeconds
        case maximumInterruptionWordSeconds, maximumBriefInterruptionGapSeconds
        case enableDominance, enableNeighborResolution, enableBriefInterruption
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        try self.init(
            schemaVersion: c.decode(Int.self, forKey: .schemaVersion),
            comparisonTolerance: c.decode(Double.self, forKey: .comparisonTolerance),
            minimumAcousticSupportSeconds: c.decode(Double.self, forKey: .minimumAcousticSupportSeconds),
            dominanceMinLeaderFraction: c.decode(Double.self, forKey: .dominanceMinLeaderFraction),
            dominanceMaxRunnerFraction: c.decode(Double.self, forKey: .dominanceMaxRunnerFraction),
            dominanceMinRatio: c.decode(Double.self, forKey: .dominanceMinRatio),
            maximumUnknownRunSeconds: c.decode(Double.self, forKey: .maximumUnknownRunSeconds),
            maximumNeighborGapSeconds: c.decode(Double.self, forKey: .maximumNeighborGapSeconds),
            maximumBoundaryResidualSeconds: c.decode(Double.self, forKey: .maximumBoundaryResidualSeconds),
            maximumBriefInterruptionSeconds: c.decode(Double.self, forKey: .maximumBriefInterruptionSeconds),
            maximumInterruptionWordSeconds: c.decode(Double.self, forKey: .maximumInterruptionWordSeconds),
            maximumBriefInterruptionGapSeconds: c.decode(Double.self, forKey: .maximumBriefInterruptionGapSeconds),
            enableDominance: c.decode(Bool.self, forKey: .enableDominance),
            enableNeighborResolution: c.decode(Bool.self, forKey: .enableNeighborResolution),
            enableBriefInterruption: c.decode(Bool.self, forKey: .enableBriefInterruption)
        )
        _ = try self.validated()
    }
}

nonisolated struct MeetingSpeakerAttributionInterval: Codable, Equatable, Sendable {
    let start: Double
    let end: Double
    var duration: Double { self.end - self.start }
}

nonisolated struct MeetingSpeakerAttributionCandidateSupport: Codable, Equatable, Sendable {
    let token: MeetingBackendSpeakerToken
    /// Positive half-open support, clipped to the original text envelope, unioned per token.
    let intervals: [MeetingSpeakerAttributionInterval]
    let supportSeconds: Double
    /// Suppression affects the presentation choice, never the retained acoustic evidence.
    let isSuppressed: Bool
}

nonisolated struct MeetingSpeakerAttributionIntersection: Codable, Equatable, Sendable {
    let tokens: [MeetingBackendSpeakerToken]
    let interval: MeetingSpeakerAttributionInterval
}

nonisolated enum MeetingSpeakerAttributionRelation: String, Codable, Sendable {
    case none, single, simultaneous, consecutive, conflict
}

nonisolated enum MeetingSpeakerAttributionRule: String, Codable, Sendable {
    case rawOnly, rawAssigned, singleAcousticSupport, acousticDominance, insufficientSupport
    case ambiguous, conflict, barrier, neighborAgreement, incomingSpeaker, boundaryContinuation
    case briefInterruption

    var isHeuristic: Bool {
        switch self {
        case .neighborAgreement, .incomingSpeaker, .boundaryContinuation, .briefInterruption: return true
        default: return false
        }
    }
}

/// A presentation decision is distinct from the immutable native assignment. A chosen foreground
/// speaker owns a mixed ASR word for display only; this does not separate or re-recognize its text.
nonisolated struct MeetingSpeakerAttributionDecision: Codable, Equatable, Sendable {
    let unitID: String
    let rawAssignment: MeetingBackendSpeakerAssignment
    let candidates: [MeetingSpeakerAttributionCandidateSupport]
    let activeSupportSeconds: Double
    let simultaneousIntervals: [MeetingSpeakerAttributionIntersection]
    let relation: MeetingSpeakerAttributionRelation
    let selectedToken: MeetingBackendSpeakerToken?
    let rule: MeetingSpeakerAttributionRule
    let cueUnitIDs: [String]
    let backgroundTokens: [MeetingBackendSpeakerToken]
    let policyVersion: Int
    let policyFingerprint: String

    fileprivate func choosing(
        _ token: MeetingBackendSpeakerToken?, rule: MeetingSpeakerAttributionRule,
        cues: [String] = [], background: [MeetingBackendSpeakerToken] = []
    ) -> Self {
        Self(unitID: self.unitID, rawAssignment: self.rawAssignment, candidates: self.candidates,
             activeSupportSeconds: self.activeSupportSeconds, simultaneousIntervals: self.simultaneousIntervals,
             relation: self.relation, selectedToken: token, rule: rule, cueUnitIDs: cues,
             backgroundTokens: background, policyVersion: self.policyVersion, policyFingerprint: self.policyFingerprint)
    }
}

nonisolated enum MeetingSpeakerAttributionError: Error, Equatable {
    case unsupportedPolicyVersion(Int)
    case invalidPolicy
    case duplicateUnitID(String)
    case invalidUnit(String)
    case invalidTokenScope(String)
    case invalidActivity(Int)
    case unknownBarrierUnit(String)
    case invalidBarrierEpoch
}

nonisolated struct MeetingSpeakerAttributionDiagnostics: Codable, Equatable, Sendable {
    var intervalQueryCount = 0
    var visitedIntervalNodeCount = 0
    var returnedIntervalCount = 0
    var normalizedIntervalCount = 0
}

nonisolated struct MeetingSpeakerAttributionResolution: Codable, Equatable, Sendable {
    let decisions: [MeetingSpeakerAttributionDecision]
    let diagnostics: MeetingSpeakerAttributionDiagnostics
}

/// Model-independent, deterministic postprocessing over admitted canonical evidence. Capture
/// admission, missing-audio barriers and identity links remain with their existing owners.
nonisolated enum MeetingSpeakerAttribution {
    private typealias Interval = MeetingSpeakerAttributionInterval
    private typealias Token = MeetingBackendSpeakerToken
    private typealias Decision = MeetingSpeakerAttributionDecision

    static func resolve(
        units: [MeetingFinalTextUnit], activity: [MeetingBackendSpeakerActivity],
        policy: MeetingSpeakerAttributionPolicy = .standard, barrierUnitIDs: Set<String> = [],
        contextualBarrierEpochIDs: Set<MeetingAnalysisEpochID> = []
    ) throws -> [MeetingSpeakerAttributionDecision] {
        try self.resolveWithDiagnostics(units: units, activity: activity, policy: policy,
                                        barrierUnitIDs: barrierUnitIDs,
                                        contextualBarrierEpochIDs: contextualBarrierEpochIDs).decisions
    }

    static func resolveWithDiagnostics(
        units: [MeetingFinalTextUnit], activity: [MeetingBackendSpeakerActivity],
        policy: MeetingSpeakerAttributionPolicy = .standard, barrierUnitIDs: Set<String> = [],
        contextualBarrierEpochIDs: Set<MeetingAnalysisEpochID> = []
    ) throws -> MeetingSpeakerAttributionResolution {
        _ = try policy.validated()
        try self.validate(units: units, activity: activity, barriers: barrierUnitIDs,
                          epochBarriers: contextualBarrierEpochIDs)
        try Task.checkCancellation()
        var diagnostics = MeetingSpeakerAttributionDiagnostics()
        let indexes = try self.makeIndexes(activity: activity, diagnostics: &diagnostics)
        let fingerprint = policy.fingerprint
        let partitions = Dictionary(grouping: units, by: \.analysisEpochID)
        let orderedEpochs = partitions.keys.sorted(by: self.epochBefore)
        var output: [Decision] = []
        output.reserveCapacity(units.count)
        for epoch in orderedEpochs {
            try Task.checkCancellation()
            let ordered = partitions[epoch]!.sorted(by: self.unitBefore)
            let index = indexes[epoch] ?? ActivityIndex(entries: [])
            var decisions: [Decision] = []
            decisions.reserveCapacity(ordered.count)
            for unit in ordered {
                try Task.checkCancellation()
                let entries = index.query(start: unit.analysisStart, end: unit.analysisEnd, diagnostics: &diagnostics)
                decisions.append(self.acousticDecision(unit: unit, entries: entries, hasActivity: !index.entries.isEmpty,
                                                       policy: policy, fingerprint: fingerprint, barrier: barrierUnitIDs.contains(unit.id)))
            }
            if !contextualBarrierEpochIDs.contains(epoch) {
                let temporalBarriers = self.overlappingUnits(ordered, tolerance: policy.comparisonTolerance)
                let anchors = zip(ordered, decisions).map { unit, decision in
                    self.isOriginalAnchor(unit: unit, decision: decision, tolerance: policy.comparisonTolerance)
                        && !temporalBarriers.contains(unit.id) && !barrierUnitIDs.contains(unit.id)
                }
                if policy.enableNeighborResolution {
                    try self.resolveNeighbors(units: ordered, decisions: &decisions, anchors: anchors,
                                          temporalBarriers: temporalBarriers, policy: policy)
                }
                if policy.enableBriefInterruption {
                    try self.resolveInterruptions(
                        units: ordered, decisions: &decisions, anchors: anchors,
                        temporalBarriers: temporalBarriers, index: index, policy: policy,
                        diagnostics: &diagnostics
                    )
                }
            }
            output.append(contentsOf: decisions)
        }
        return .init(decisions: output, diagnostics: diagnostics)
    }

    /// Validated half-open interval union. This helper also keeps actual voiced duration separate
    /// from a presentation-owned word envelope in downstream speaker admission.
    static func unionedIntervals(_ intervals: [MeetingSpeakerAttributionInterval]) throws
        -> [MeetingSpeakerAttributionInterval]
    {
        guard intervals.allSatisfy({ MeetingEvidenceInterval.isValid(start: $0.start, end: $0.end) }) else {
            throw MeetingSpeakerAttributionError.invalidActivity(-1)
        }
        return self.unionValid(intervals)
    }

    private static func validate(
        units: [MeetingFinalTextUnit], activity: [MeetingBackendSpeakerActivity], barriers: Set<String>,
        epochBarriers: Set<MeetingAnalysisEpochID>
    ) throws {
        var ids = Set<String>()
        for unit in units {
            try Task.checkCancellation()
            guard !unit.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, ids.insert(unit.id).inserted else {
                throw MeetingSpeakerAttributionError.duplicateUnitID(unit.id)
            }
            guard MeetingEvidenceInterval.isValid(start: unit.analysisStart, end: unit.analysisEnd),
                  unit.analysisEpochID.trackID == unit.trackID,
                  self.valid(epoch: unit.analysisEpochID)
            else { throw MeetingSpeakerAttributionError.invalidUnit(unit.id) }
            let tokens = unit.speaker.tokens
            if case .ambiguous = unit.speaker, tokens.count < 2 {
                throw MeetingSpeakerAttributionError.invalidTokenScope(unit.id)
            }
            guard Set(tokens).count == tokens.count,
                  tokens.allSatisfy({ self.valid(token: $0) && $0.analysisEpochID == unit.analysisEpochID })
            else { throw MeetingSpeakerAttributionError.invalidTokenScope(unit.id) }
        }
        for (position, entry) in activity.enumerated() {
            try Task.checkCancellation()
            guard self.valid(token: entry.token), MeetingEvidenceInterval.isValid(start: entry.start, end: entry.end)
            else { throw MeetingSpeakerAttributionError.invalidActivity(position) }
        }
        if let unknown = barriers.subtracting(ids).sorted().first {
            throw MeetingSpeakerAttributionError.unknownBarrierUnit(unknown)
        }
        guard epochBarriers.allSatisfy({ self.valid(epoch: $0) }) else {
            throw MeetingSpeakerAttributionError.invalidBarrierEpoch
        }
    }

    private static func valid(epoch: MeetingAnalysisEpochID) -> Bool { epoch.ordinal >= 0 && epoch.generation >= 0 }
    private static func valid(token: Token) -> Bool { self.valid(epoch: token.analysisEpochID) && !token.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    private static func epochBefore(_ lhs: MeetingAnalysisEpochID, _ rhs: MeetingAnalysisEpochID) -> Bool {
        if lhs.trackID != rhs.trackID { return lhs.trackID.uuidString < rhs.trackID.uuidString }
        if lhs.ordinal != rhs.ordinal { return lhs.ordinal < rhs.ordinal }
        return lhs.generation < rhs.generation
    }

    private static func tokenBefore(_ lhs: Token, _ rhs: Token) -> Bool {
        if lhs.analysisEpochID != rhs.analysisEpochID { return self.epochBefore(lhs.analysisEpochID, rhs.analysisEpochID) }
        return lhs.label < rhs.label
    }

    private static func unitBefore(_ lhs: MeetingFinalTextUnit, _ rhs: MeetingFinalTextUnit) -> Bool {
        if lhs.analysisStart != rhs.analysisStart { return lhs.analysisStart < rhs.analysisStart }
        if lhs.analysisEnd != rhs.analysisEnd { return lhs.analysisEnd < rhs.analysisEnd }
        return lhs.id < rhs.id
    }

    private static func unionValid(_ intervals: [Interval]) -> [Interval] {
        let sorted = intervals.sorted { $0.start == $1.start ? $0.end < $1.end : $0.start < $1.start }
        var output: [Interval] = []
        for value in sorted {
            if let last = output.last, value.start <= last.end {
                output[output.count - 1] = .init(start: last.start, end: max(last.end, value.end))
            } else { output.append(value) }
        }
        return output
    }

    private struct IndexedActivity {
        let token: Token
        let interval: Interval
    }

    /// Static augmented interval tree, shared by all voices in one epoch. A growing number of
    /// sequential voices does not cause one binary search per voice per word.
    private struct ActivityIndex {
        struct Node { let entry: IndexedActivity; let left: Int?; let right: Int?; let maximumEnd: Double }
        let entries: [IndexedActivity]
        let byToken: [Token: [Interval]]
        let nodes: [Node]
        let root: Int?

        init(entries: [IndexedActivity]) {
            self.entries = entries.sorted {
                if $0.interval.start != $1.interval.start { return $0.interval.start < $1.interval.start }
                if $0.interval.end != $1.interval.end { return $0.interval.end < $1.interval.end }
                return MeetingSpeakerAttribution.tokenBefore($0.token, $1.token)
            }
            self.byToken = Dictionary(grouping: self.entries, by: \.token).mapValues { $0.map(\.interval) }
            var nodes: [Node] = []
            let values = self.entries
            func build(_ low: Int, _ high: Int) -> Int? {
                guard low < high else { return nil }
                let middle = low + (high - low) / 2
                let left = build(low, middle)
                let right = build(middle + 1, high)
                let end = max(values[middle].interval.end,
                              max(left.map { nodes[$0].maximumEnd } ?? 0, right.map { nodes[$0].maximumEnd } ?? 0))
                nodes.append(.init(entry: values[middle], left: left, right: right, maximumEnd: end))
                return nodes.count - 1
            }
            self.root = build(0, values.count)
            self.nodes = nodes
        }

        func query(start: Double, end: Double, diagnostics: inout MeetingSpeakerAttributionDiagnostics) -> [IndexedActivity] {
            diagnostics.intervalQueryCount += 1
            var result: [IndexedActivity] = []
            func visit(_ position: Int?) {
                guard let position else { return }
                diagnostics.visitedIntervalNodeCount += 1
                let node = self.nodes[position]
                guard node.maximumEnd > start else { return }
                visit(node.left)
                guard node.entry.interval.start < end else { return }
                if node.entry.interval.end > start { result.append(node.entry) }
                visit(node.right)
            }
            visit(self.root)
            diagnostics.returnedIntervalCount += result.count
            return result
        }

        /// Full connected bout rather than its word-clipped remnant. Expansion stops as soon as
        /// the configured duration fails, so an hours-long fragmented speaker cannot rescan it.
        func briefBout(token: Token, start: Double, end: Double, policy: MeetingSpeakerAttributionPolicy) -> Interval? {
            let values = self.byToken[token] ?? []
            var low = 0, high = values.count
            while low < high {
                let middle = low + (high - low) / 2
                if values[middle].end <= start { low = middle + 1 } else { high = middle }
            }
            guard low < values.count, values[low].start < end else { return nil }
            var first = low, last = low
            var result = values[low]
            guard result.duration <= policy.maximumBriefInterruptionSeconds + policy.comparisonTolerance else { return nil }
            while first > 0, result.start - values[first - 1].end <= policy.maximumBriefInterruptionGapSeconds + policy.comparisonTolerance {
                first -= 1
                result = .init(start: values[first].start, end: result.end)
                guard result.duration <= policy.maximumBriefInterruptionSeconds + policy.comparisonTolerance else { return nil }
            }
            while last + 1 < values.count,
                  values[last + 1].start - result.end <= policy.maximumBriefInterruptionGapSeconds + policy.comparisonTolerance {
                last += 1
                result = .init(start: result.start, end: values[last].end)
                guard result.duration <= policy.maximumBriefInterruptionSeconds + policy.comparisonTolerance else { return nil }
            }
            // Two separate bouts within one word have ambiguous conversational roles.
            guard last + 1 == values.count || values[last + 1].start >= end else { return nil }
            let support = values[first...last].reduce(0) { $0 + $1.duration }
            guard support + policy.comparisonTolerance >= policy.minimumAcousticSupportSeconds else { return nil }
            return result
        }
    }

    private static func makeIndexes(
        activity: [MeetingBackendSpeakerActivity], diagnostics: inout MeetingSpeakerAttributionDiagnostics
    ) throws -> [MeetingAnalysisEpochID: ActivityIndex] {
        let grouped = Dictionary(grouping: activity, by: \.token)
        var entries: [MeetingAnalysisEpochID: [IndexedActivity]] = [:]
        for (token, values) in grouped {
            try Task.checkCancellation()
            let intervals = self.unionValid(values.map { .init(start: $0.start, end: $0.end) })
            diagnostics.normalizedIntervalCount += intervals.count
            entries[token.analysisEpochID, default: []].append(contentsOf: intervals.map { .init(token: token, interval: $0) })
        }
        return entries.mapValues { ActivityIndex(entries: $0) }
    }

    private static func acousticDecision(
        unit: MeetingFinalTextUnit, entries: [IndexedActivity], hasActivity: Bool,
        policy: MeetingSpeakerAttributionPolicy, fingerprint: String, barrier: Bool
    ) -> Decision {
        let grouped = Dictionary(grouping: entries, by: \.token)
        let tokens = Set(grouped.keys).union(unit.speaker.tokens).sorted(by: self.tokenBefore)
        let candidates = tokens.map { token -> MeetingSpeakerAttributionCandidateSupport in
            let intervals = self.unionValid((grouped[token] ?? []).map {
                .init(start: max($0.interval.start, unit.analysisStart), end: min($0.interval.end, unit.analysisEnd))
            })
            let support = intervals.reduce(0) { $0 + $1.duration }
            return .init(token: token, intervals: intervals, supportSeconds: support,
                         isSuppressed: support + policy.comparisonTolerance < policy.minimumAcousticSupportSeconds || support <= policy.comparisonTolerance)
        }
        let rawPositive = candidates.filter { $0.supportSeconds > 0 }
        let positive = rawPositive.filter { $0.supportSeconds > policy.comparisonTolerance }
        let eligible = candidates.filter { !$0.isSuppressed }
        let intersections = self.intersections(candidates: rawPositive)
        let active = self.unionValid(rawPositive.flatMap(\.intervals)).reduce(0) { $0 + $1.duration }
        let conflict = hasActivity && unit.speaker.tokens.contains { token in
            !rawPositive.contains { $0.token == token }
        }
        let relation: MeetingSpeakerAttributionRelation = conflict ? .conflict
            : positive.isEmpty ? .none : positive.count == 1 ? .single
            : intersections.contains { $0.interval.duration > policy.comparisonTolerance } ? .simultaneous : .consecutive
        var selected: Token?
        var rule: MeetingSpeakerAttributionRule
        if barrier { rule = .barrier }
        else if !hasActivity {
            if case let .assigned(token) = unit.speaker { selected = token }
            rule = .rawOnly
        } else if conflict { rule = .conflict }
        else if eligible.count == 1, positive.count <= 2 {
            selected = eligible[0].token
            rule = .singleAcousticSupport
        } else if eligible.isEmpty {
            if case let .assigned(token) = unit.speaker { selected = token; rule = .rawAssigned }
            else { rule = .insufficientSupport }
        } else if positive.count == 2, eligible.count == 2, relation == .simultaneous,
                  unit.precision == .word, policy.enableDominance, active > 0 {
            let ranked = eligible.sorted { $0.supportSeconds > $1.supportSeconds }
            let leader = ranked[0], runner = ranked[1]
            if leader.supportSeconds > runner.supportSeconds + policy.comparisonTolerance,
               leader.supportSeconds / active + policy.comparisonTolerance >= policy.dominanceMinLeaderFraction,
               runner.supportSeconds / active <= policy.dominanceMaxRunnerFraction + policy.comparisonTolerance,
               leader.supportSeconds / runner.supportSeconds + policy.comparisonTolerance >= policy.dominanceMinRatio {
                selected = leader.token; rule = .acousticDominance
            } else { rule = .ambiguous }
        } else { rule = .ambiguous }
        // An utterance can encompass several successive people; its text cannot be subdivided
        // without real word timing, even when one candidate happens to have more support.
        if unit.precision == .utterance, positive.count > 1, !barrier { selected = nil; rule = conflict ? .conflict : .ambiguous }
        return .init(unitID: unit.id, rawAssignment: unit.speaker, candidates: candidates,
                     activeSupportSeconds: active, simultaneousIntervals: intersections, relation: relation,
                     selectedToken: selected, rule: rule, cueUnitIDs: [], backgroundTokens: [],
                     policyVersion: policy.schemaVersion, policyFingerprint: fingerprint)
    }

    private static func intersections(candidates: [MeetingSpeakerAttributionCandidateSupport])
        -> [MeetingSpeakerAttributionIntersection]
    {
        struct Event { let time: Double; let token: Token; let isStart: Bool }
        var events: [Event] = []
        for candidate in candidates {
            for interval in candidate.intervals {
                events.append(.init(time: interval.start, token: candidate.token, isStart: true))
                events.append(.init(time: interval.end, token: candidate.token, isStart: false))
            }
        }
        events.sort {
            if $0.time != $1.time { return $0.time < $1.time }
            if $0.isStart != $1.isStart { return !$0.isStart }
            return self.tokenBefore($0.token, $1.token)
        }
        var active = Set<Token>(), previous: Double?, result: [MeetingSpeakerAttributionIntersection] = []
        for event in events {
            if let previous, event.time > previous, active.count > 1 {
                let tokens = active.sorted(by: self.tokenBefore)
                if let last = result.last, last.tokens == tokens, last.interval.end == previous {
                    result[result.count - 1] = .init(tokens: tokens, interval: .init(start: last.interval.start, end: event.time))
                } else { result.append(.init(tokens: tokens, interval: .init(start: previous, end: event.time))) }
            }
            if event.isStart { active.insert(event.token) } else { active.remove(event.token) }
            previous = event.time
        }
        return result
    }

    private static func isOriginalAnchor(unit: MeetingFinalTextUnit, decision: Decision, tolerance: Double) -> Bool {
        guard unit.precision == .word, case let .assigned(token) = unit.speaker,
              decision.rule == .singleAcousticSupport, decision.selectedToken == token,
              decision.relation == .single,
              decision.candidates.filter({ $0.supportSeconds > tolerance }).count == 1
        else { return false }
        return true
    }

    /// An overlapping cluster is a contextual barrier, regardless of ID sort order. Words are
    /// still individually described, but equal or nested envelopes never establish chronology.
    private static func overlappingUnits(_ units: [MeetingFinalTextUnit], tolerance: Double) -> Set<String> {
        var blocked = Set<String>(), cluster: [String] = [], maximumEnd = -Double.infinity
        var clusterIsBlocked = false
        for unit in units {
            if unit.analysisStart < maximumEnd - tolerance {
                if !clusterIsBlocked { blocked.formUnion(cluster); clusterIsBlocked = true }
                blocked.insert(unit.id)
                maximumEnd = max(maximumEnd, unit.analysisEnd)
            } else { cluster = [unit.id]; maximumEnd = unit.analysisEnd; clusterIsBlocked = false }
        }
        return blocked
    }

    private static func canContextualize(_ unit: MeetingFinalTextUnit, _ decision: Decision, blocked: Set<String>) -> Bool {
        guard unit.precision == .word, !blocked.contains(unit.id), case .unassigned = unit.speaker,
              decision.rule != .barrier, decision.relation != .conflict,
              decision.relation == .none || decision.relation == .single,
              decision.candidates.allSatisfy(\.isSuppressed)
        else { return false }
        return true
    }

    private static func resolveNeighbors(
        units: [MeetingFinalTextUnit], decisions: inout [Decision], anchors: [Bool],
        temporalBarriers: Set<String>, policy: MeetingSpeakerAttributionPolicy
    ) throws {
        var position = 0
        while position < units.count {
            try Task.checkCancellation()
            guard self.canContextualize(units[position], decisions[position], blocked: temporalBarriers) else {
                position += 1; continue
            }
            let first = position
            while position < units.count,
                  self.canContextualize(units[position], decisions[position], blocked: temporalBarriers) { position += 1 }
            let last = position - 1
            guard first > 0, position < units.count, anchors[first - 1], anchors[position],
                  units[last].analysisEnd - units[first].analysisStart <= policy.maximumUnknownRunSeconds + policy.comparisonTolerance,
                  let previous = decisions[first - 1].selectedToken,
                  let next = decisions[position].selectedToken
            else { continue }
            let range = (first...position)
            guard range.allSatisfy({ index in
                let gap = units[index].analysisStart - units[index - 1].analysisEnd
                return gap >= -policy.comparisonTolerance && gap <= policy.maximumNeighborGapSeconds + policy.comparisonTolerance
            }) else { continue }
            let runCandidates = decisions[first...last].flatMap(\.candidates).filter { $0.supportSeconds > policy.comparisonTolerance }
            guard runCandidates.allSatisfy({ $0.token == previous || $0.token == next }) else { continue }
            let cues = [units[first - 1].id, units[position].id]
            for index in first...last {
                var token = next
                var rule: MeetingSpeakerAttributionRule = previous == next ? .neighborAgreement : .incomingSpeaker
                let outgoing = decisions[index].candidates.filter { $0.supportSeconds > policy.comparisonTolerance }
                // Apply an outgoing tail only to the word that actually contains that tail.
                // Later unsupported words in the same run do not inherit its local evidence.
                if previous != next, !outgoing.isEmpty,
                   outgoing.allSatisfy({ $0.token == previous }),
                   let firstSupport = outgoing.flatMap(\.intervals).map(\.start).min(),
                   let lastSupport = outgoing.flatMap(\.intervals).map(\.end).max(),
                   firstSupport - units[index].analysisStart <= policy.maximumBoundaryResidualSeconds + policy.comparisonTolerance,
                   lastSupport - units[index].analysisStart <= policy.maximumBoundaryResidualSeconds + policy.comparisonTolerance {
                    token = previous; rule = .boundaryContinuation
                }
                decisions[index] = decisions[index].choosing(token, rule: rule, cues: cues)
            }
        }
    }

    private static func resolveInterruptions(
        units: [MeetingFinalTextUnit], decisions: inout [Decision], anchors: [Bool],
        temporalBarriers: Set<String>, index: ActivityIndex, policy: MeetingSpeakerAttributionPolicy,
        diagnostics: inout MeetingSpeakerAttributionDiagnostics
    ) throws {
        var position = 0
        while position < units.count {
            try Task.checkCancellation()
            let first = position
            let firstDecision = decisions[first]
            let pair = Set(firstDecision.candidates.filter { $0.supportSeconds > policy.comparisonTolerance }.map(\.token))
            guard first > 0, anchors[first - 1], firstDecision.relation == .simultaneous,
                  firstDecision.rule != .barrier, pair.count == 2,
                  !temporalBarriers.contains(units[first].id),
                  let main = decisions[first - 1].selectedToken, pair.contains(main),
                  let other = pair.first(where: { $0 != main })
            else { position += 1; continue }
            // Consecutive mixed words, and native words wholly spoken by the interrupter, form
            // one bounded conversational bout. Splitting one ASR word does not lose its context.
            var stop = first
            var mixed: [Int] = []
            while stop < units.count {
                let unit = units[stop], decision = decisions[stop]
                let positive = Set(decision.candidates.filter { $0.supportSeconds > policy.comparisonTolerance }.map(\.token))
                guard unit.precision == .word, !temporalBarriers.contains(unit.id),
                      decision.rule != .barrier, decision.relation != .conflict,
                      unit.analysisEnd - units[first].analysisStart <= policy.maximumInterruptionWordSeconds + policy.comparisonTolerance,
                      unit.analysisStart + policy.comparisonTolerance >= units[stop - 1].analysisEnd,
                      unit.analysisStart - units[stop - 1].analysisEnd <= policy.maximumNeighborGapSeconds + policy.comparisonTolerance
                else { break }
                if decision.relation == .simultaneous, positive == pair { mixed.append(stop) }
                else if decision.relation == .single, positive == [other], decision.selectedToken == other { }
                else { break }
                stop += 1
            }
            position = max(first + 1, stop)
            guard !mixed.isEmpty, stop < units.count, anchors[stop],
                  decisions[stop].selectedToken == main,
                  units[stop].analysisStart + policy.comparisonTolerance >= units[stop - 1].analysisEnd,
                  units[stop].analysisStart - units[stop - 1].analysisEnd <= policy.maximumNeighborGapSeconds + policy.comparisonTolerance,
                  let bout = index.briefBout(token: other, start: units[first].analysisStart,
                                            end: units[stop - 1].analysisEnd, policy: policy),
                  bout.start >= units[first - 1].analysisEnd, bout.end <= units[stop].analysisStart,
                  mixed.allSatisfy({ decisions[$0].simultaneousIntervals.contains { Set($0.tokens) == pair } })
            else { continue }
            let context = index.query(start: units[first - 1].analysisStart,
                                      end: units[stop].analysisEnd, diagnostics: &diagnostics)
            let mainIntervals = context.filter { $0.token == main }.map(\.interval)
            guard mainIntervals.contains(where: { $0.start < bout.start && $0.end > units[first - 1].analysisStart }),
                  mainIntervals.contains(where: { $0.end > bout.end && $0.start < units[stop].analysisEnd })
            else { continue }
            for mixedIndex in mixed {
                decisions[mixedIndex] = decisions[mixedIndex].choosing(
                    other, rule: .briefInterruption, cues: [units[first - 1].id, units[stop].id], background: [main]
                )
            }
        }
    }
}
