import CryptoKit
import Foundation

/// Completes product ownership after privacy admission. It never creates acoustic evidence,
/// joins voice clusters, edits text/timing or turns its own choices into later voice anchors.
/// The same operation serves protected live publication, final publication and archive reading.
nonisolated enum MeetingReadingSpeakerResolver {
    struct Result: Sendable {
        var segments: [MeetingTranscriptSegment]
        var speakers: [MeetingSessionSpeaker]
    }

    /// A fixed part of the versioned complete-reading policy, measured in presentation seconds.
    static let contextRadiusSeconds: Double = 15

    /// Shared identity construction for durable publication and non-destructive archive
    /// projection. The namespace is the processing attempt, or the saved session for reading.
    static func fallbackSpeaker(namespace: UUID, scope: MeetingAnalysisEpochID,
                                trackKind: MeetingAudioTrackKind, speakerNameFormat: String) -> MeetingSessionSpeaker {
        var bytes = Array(SHA256.hash(data: Data("reading-participant-v1:\(namespace):\(scope.trackID)".utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x50
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        let id = UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                             bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
        return .init(id: id, displayName: String(format: speakerNameFormat, Int64(1)),
            diarizationClusterID: nil, trackKind: trackKind, isLocalUser: false, identityCandidates: [],
            generatedParticipantNumber: 1, identityIsProvisional: true)
    }

    /// Saved tokenless words inherit a neighboring *scope*, never a model slot or identity.
    /// A reset between neighbors chooses the incoming scope so older voices cannot compete
    /// across it. Actual native evidence and explicit coverage barriers remain unchanged.
    static func readingScopes(for segments: [MeetingTranscriptSegment]) -> [MeetingTranscriptSegmentID: MeetingAnalysisEpochID] {
        var result: [MeetingTranscriptSegmentID: MeetingAnalysisEpochID] = [:]
        func nativeScope(_ segment: MeetingTranscriptSegment) -> MeetingAnalysisEpochID? {
            let tokens = segment.nativeSpeakerAssignment?.tokens ?? segment.speakerAttribution?.rawAssignment.tokens ?? []
            return tokens.first?.analysisEpochID ?? segment.speakerAttribution?.selectedToken?.analysisEpochID
        }
        for (track, rows) in Dictionary(grouping: segments, by: \.sourceTrackID) {
            let ordered = rows.enumerated().sorted { ($0.element.start, $0.element.end, $0.offset)
                < ($1.element.start, $1.element.end, $1.offset) }.map(\.element)
            var next: [MeetingAnalysisEpochID?] = Array(repeating: nil, count: ordered.count)
            var following: MeetingAnalysisEpochID?
            for index in ordered.indices.reversed() {
                if let scope = nativeScope(ordered[index]) { following = scope }
                next[index] = following
            }
            var previous: MeetingAnalysisEpochID?
            for index in ordered.indices {
                let scope = nativeScope(ordered[index]) ?? next[index] ?? previous ?? .init(trackID: track, ordinal: 0)
                result[ordered[index].id] = scope
                if let native = nativeScope(ordered[index]) { previous = native }
            }
        }
        return result
    }

    private struct Anchor {
        let index: Int
        let id: SessionSpeakerID
        let start: Double
        let end: Double
    }

    /// Disjoint union plus prefix sums makes support independent of ASR fragmentation and
    /// duplicate intervals. Each candidate query takes logarithmic time in its native turns.
    private struct Support {
        let intervals: [MeetingSpeakerAttributionInterval]
        let prefix: [Double]

        init(_ values: [MeetingSpeakerAttributionInterval]) throws {
            self.intervals = try MeetingSpeakerAttribution.unionedIntervals(values)
            var sums = [0.0]
            for value in self.intervals { sums.append(sums.last! + value.duration) }
            self.prefix = sums
        }

        private func through(_ time: Double) -> Double {
            var low = 0, high = self.intervals.count
            while low < high {
                let middle = low + (high - low) / 2
                if self.intervals[middle].end <= time { low = middle + 1 } else { high = middle }
            }
            guard low < self.intervals.count else { return self.prefix.last! }
            return self.prefix[low] + max(0, time - self.intervals[low].start)
        }

        func seconds(start: Double, end: Double) -> Double {
            max(0, self.through(end) - self.through(start))
        }
    }

    private struct CandidateIndex {
        struct Entry { let id: SessionSpeakerID; let start: Double; let end: Double }
        struct Node { let entry: Entry; let left: Int?; let right: Int?; let maximumEnd: Double }
        let nodes: [Node]
        let root: Int?

        init(_ supports: [SessionSpeakerID: Support]) throws {
            let entries = supports.flatMap { id, support in
                support.intervals.map { Entry(id: id, start: $0.start, end: $0.end) }
            }.sorted { $0.start < $1.start }
            var nodes: [Node] = []
            func build(_ lower: Int, _ upper: Int) throws -> Int? {
                guard lower < upper else { return nil }
                try Task.checkCancellation()
                let middle = lower + (upper - lower) / 2
                let left = try build(lower, middle), right = try build(middle + 1, upper)
                nodes.append(.init(entry: entries[middle], left: left, right: right,
                    maximumEnd: max(entries[middle].end, max(left.map { nodes[$0].maximumEnd } ?? 0,
                        right.map { nodes[$0].maximumEnd } ?? 0))))
                return nodes.count - 1
            }
            self.root = try build(0, entries.count)
            self.nodes = nodes
        }

        func candidates(start: Double, end: Double) throws -> Set<SessionSpeakerID> {
            var result = Set<SessionSpeakerID>()
            func visit(_ index: Int?) throws {
                guard let index, self.nodes[index].maximumEnd > start else { return }
                try Task.checkCancellation()
                let node = self.nodes[index]
                try visit(node.left)
                if node.entry.start < end, node.entry.end > start { result.insert(node.entry.id) }
                if node.entry.start < end { try visit(node.right) }
            }
            try visit(self.root)
            return result
        }
    }

    static func resolve(
        segments: [MeetingTranscriptSegment], speakers: [MeetingSessionSpeaker],
        policy: MeetingSpeakerAttributionPolicy = .standard,
        barriersByTrack: [MeetingAudioTrackID: [MeetingSpeakerAttributionInterval]] = [:],
        contextualBarrierEpochIDs: Set<MeetingAnalysisEpochID> = [],
        resetBeforeIDs: Set<MeetingTranscriptSegmentID> = [],
        scopeForSegment: (MeetingTranscriptSegment) -> MeetingAnalysisEpochID?,
        fallbackSpeaker: (MeetingAnalysisEpochID) -> MeetingSessionSpeaker
    ) throws -> Result {
        try Task.checkCancellation()
        var result = Result(segments: segments, speakers: speakers)
        var records = Dictionary(speakers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let byCluster = Dictionary(grouping: speakers.filter { $0.diarizationClusterID != nil },
                                   by: { $0.diarizationClusterID! })
        func activeID(_ initial: SessionSpeakerID?) -> SessionSpeakerID? {
            guard var id = initial else { return nil }
            var visited = Set<SessionSpeakerID>()
            while let record = records[id], visited.insert(id).inserted {
                if let next = record.mergedIntoSpeakerID { id = next }
                else { return record.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : id }
            }
            return nil
        }
        func knownTokenID(_ token: MeetingBackendSpeakerToken?) -> SessionSpeakerID? {
            guard let token, let matches = byCluster["\(token.analysisEpochID):\(token.label.precomposedStringWithCanonicalMapping)"],
                  matches.count == 1 else { return nil }
            return activeID(matches[0].id)
        }
        func timing(_ value: MeetingTranscriptSegment) -> MeetingTranscriptNativeTiming {
            value.nativeTiming ?? .init(start: value.start.seconds, end: value.end.seconds)
        }
        func isContextSafe(_ value: MeetingTranscriptSegment) -> Bool {
            let time = timing(value)
            return value.status == .final && value.completeness == .complete && !value.isEcho
                && value.attributionState != .timingUncertain && value.isUserSpeakerAssigned != true
                && value.isUserTextEdited != true && value.originalText == nil
                && time.start.isFinite && time.end.isFinite && time.start >= 0 && time.end > time.start
        }
        func anchorID(_ value: MeetingTranscriptSegment) -> SessionSpeakerID? {
            guard value.hasReadableContent, isContextSafe(value), let id = activeID(value.speakerID),
                  records[id]?.diarizationClusterID != nil || records[id]?.identityIsProvisional != true
            else { return nil }
            if let summary = value.speakerAttribution {
                guard summary.rule.isIndependentAcousticSelection || summary.rule == .rawOnly
                    || summary.rule == .rawAssigned else { return nil }
            } else if value.speakerAttributionInference != nil { return nil }
            return id
        }
        var grouped: [MeetingAnalysisEpochID: [Int]] = [:]
        for index in segments.indices {
            try Task.checkCancellation()
            guard let scope = scopeForSegment(segments[index]), scope.trackID == segments[index].sourceTrackID else { continue }
            grouped[scope, default: []].append(index)
        }
        let scopes = grouped.keys.sorted {
            (grouped[$0]!.first!, $0.trackID.uuidString, $0.ordinal, $0.generation)
                < (grouped[$1]!.first!, $1.trackID.uuidString, $1.ordinal, $1.generation)
        }
        for scope in scopes {
            try Task.checkCancellation()
            let indices = grouped[scope]!.sorted {
                let a = timing(segments[$0]), b = timing(segments[$1])
                return (a.start, a.end, $0) < (b.start, b.end, $1)
            }
            let barriers = try MeetingSpeakerAttribution.unionedIntervals(barriersByTrack[scope.trackID] ?? [])
            func crossesBarrier(_ start: Double, _ end: Double) -> Bool {
                var low = 0, high = barriers.count
                while low < high {
                    let middle = low + (high - low) / 2
                    if barriers[middle].end <= start { low = middle + 1 } else { high = middle }
                }
                return low < barriers.count && barriers[low].start < end
            }
            // Barrier rows have their own region. Hidden rows are supplied by callers too, so
            // filtering an echo or a private interval cannot accidentally reconnect context.
            var regions: [[Int]] = []
            var region: [Int] = []
            var previous: MeetingTranscriptNativeTiming?
            for index in indices {
                let source = segments[index], time = timing(source)
                let safe = isContextSafe(source) && !contextualBarrierEpochIDs.contains(scope)
                if !safe || resetBeforeIDs.contains(source.id) || previous.map({ crossesBarrier($0.start, time.end) }) == true {
                    if !region.isEmpty { regions.append(region); region = [] }
                }
                region.append(index)
                if !safe { regions.append(region); region = []; previous = nil }
                else { previous = time }
            }
            if !region.isEmpty { regions.append(region) }
            let placeholder = fallbackSpeaker(scope)
            let mayResolvePlaceholder = records[placeholder.id].map {
                $0.identityIsProvisional == true && $0.usesCustomDisplayName != true && $0.diarizationClusterID == nil
            } ?? true
            let manualPlaceholder = indices.contains {
                segments[$0].speakerID == placeholder.id && segments[$0].isUserSpeakerAssigned == true
            }
            for region in regions {
                try Task.checkCancellation()
                let anchors = region.compactMap { index -> Anchor? in
                    guard let id = anchorID(segments[index]) else { return nil }
                    let time = timing(segments[index])
                    return .init(index: index, id: id, start: time.start, end: time.end)
                }
                var spans: [SessionSpeakerID: [MeetingSpeakerAttributionInterval]] = [:]
                for anchor in anchors { spans[anchor.id, default: []].append(.init(start: anchor.start, end: anchor.end)) }
                var supports: [SessionSpeakerID: Support] = [:]
                for (id, values) in spans { supports[id] = try Support(values) }
                let candidateIndex = try CandidateIndex(supports)
                var firstPosition: [SessionSpeakerID: Int] = [:]
                for (position, anchor) in anchors.enumerated() where firstPosition[anchor.id] == nil {
                    firstPosition[anchor.id] = position
                }
                var cursor = 0
                for index in region {
                    try Task.checkCancellation()
                    let source = segments[index], time = timing(source)
                    guard source.hasReadableContent, !source.isEcho else { continue }
                    // A confirmed/manual selection is authoritative. Existing context remains
                    // a reading choice and is not added to the immutable anchor index above.
                    if let id = activeID(source.speakerID),
                       source.speakerAttribution?.rule != .readingParticipantContext || source.isUserSpeakerAssigned == true,
                       source.speakerID != placeholder.id || !mayResolvePlaceholder || manualPlaceholder {
                        if source.speakerID != id, source.isUserSpeakerAssigned != true {
                            result.segments[index].speakerID = id
                        }
                        continue
                    }
                    while cursor < anchors.count, anchors[cursor].start <= time.start { cursor += 1 }
                    let left = cursor > 0 ? anchors[cursor - 1] : nil
                    let right = cursor < anchors.count ? anchors[cursor] : nil
                    let windowStart = max(0, time.start - Self.contextRadiusSeconds)
                    let windowEnd = time.end + Self.contextRadiusSeconds
                    var candidateIDs = try candidateIndex.candidates(start: windowStart, end: windowEnd)
                    for option in [left?.id, right?.id].compactMap({ $0 }) { candidateIDs.insert(option) }
                    let candidates = candidateIDs.sorted {
                        let a = ($0 == left?.id ? 0 : $0 == right?.id ? 1 : 2, firstPosition[$0] ?? Int.max)
                        let b = ($1 == left?.id ? 0 : $1 == right?.id ? 1 : 2, firstPosition[$1] ?? Int.max)
                        return a < b
                    }
                    // A previously admitted identity may be absent from the current window's
                    // admission table. Reuse its exact scoped token, including coarse mixtures.
                    var chosen = knownTokenID(source.speakerAttribution?.selectedToken)
                    var best = -Double.infinity
                    if chosen == nil {
                        for id in candidates {
                            let support = supports[id]?.seconds(start: windowStart, end: windowEnd) ?? 0
                            // Ties use temporal order, never model slot names or UUIDs.
                            if support > best + policy.comparisonTolerance { chosen = id; best = support }
                        }
                    }
                    if chosen == nil {
                        if records[placeholder.id] == nil {
                            guard result.speakers.count < MeetingSessionSpeaker.maximumParticipants else {
                                throw MeetingReadingSpeakerResolutionError.participantLimit
                            }
                            result.speakers.append(placeholder)
                            records[placeholder.id] = placeholder
                        }
                        chosen = activeID(placeholder.id) ?? placeholder.id
                    }
                    let id = chosen!
                    result.segments[index].speakerID = id
                    if source.attributionState != .timingUncertain { result.segments[index].attributionState = .assigned }
                    result.segments[index].speakerIdentityIsProvisional = records[id]?.identityIsProvisional == true ? true : nil
                    result.segments[index].speakerAttribution = .init(readingParticipant: id, source: source, policy: policy)
                }
            }
            // Retire a temporary reading identity only after every visible member in this
            // scope has a real owner. Preserve the record for old revisions, correction/undo
            // and committed live prefixes; explicit aliases and assignments are never merged.
            if mayResolvePlaceholder, !manualPlaceholder, records[placeholder.id] != nil,
               !indices.contains(where: { result.segments[$0].speakerID == placeholder.id }),
               let target = indices.compactMap({ anchorID(segments[$0]) }).first,
               target != placeholder.id,
               let position = result.speakers.firstIndex(where: { $0.id == placeholder.id }) {
                result.speakers[position].mergedIntoSpeakerID = target
                records[placeholder.id] = result.speakers[position]
            }
        }
        try Task.checkCancellation()
        return result
    }
}

nonisolated enum MeetingReadingSpeakerResolutionError: Error { case participantLimit }

nonisolated extension MeetingTranscriptSpeakerAttribution {
    init(readingParticipant: SessionSpeakerID, source: MeetingTranscriptSegment,
         policy: MeetingSpeakerAttributionPolicy) {
        self.unitID = source.nativeUnitID ?? source.speakerAttribution?.unitID ?? source.id.uuidString
        self.rawAssignment = source.nativeSpeakerAssignment ?? source.speakerAttribution?.rawAssignment ?? .unassigned
        self.selectedToken = nil
        self.selectedSpeakerID = readingParticipant
        self.candidates = source.speakerAttribution?.candidates ?? []
        self.background = source.speakerAttribution?.background ?? []
        self.relation = source.speakerAttribution?.relation ?? (source.overlap == .ambiguous ? .simultaneous : .none)
        self.rule = .readingParticipantContext
        self.policyVersion = policy.schemaVersion
        self.policyFingerprint = policy.fingerprint
    }
}
