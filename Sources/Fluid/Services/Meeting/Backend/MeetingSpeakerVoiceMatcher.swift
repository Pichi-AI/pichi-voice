import Foundation

/// Attempt-local audio only. Never persisted or sent to a service.
nonisolated struct MeetingSpeakerVoiceSamples: Sendable {
    let token: MeetingBackendSpeakerToken
    let clips: [[Float]]

    static let maximumProfiles = 128
    static let sampleRate = 16_000

    /// Two disjoint, single-speaker excerpts. Overlap and turn edges are excluded; short or
    /// silent observations cannot establish identity. At most 10 seconds is retained per slot.
    static func collect(
        epoch: MeetingAnalysisEpochID,
        samples: [Float],
        segments: [MeetingNemotronSpeakerSegment]
    ) -> [Self] {
        let duration = Double(samples.count) / Double(self.sampleRate)
        let valid = segments.filter {
            (0..<8).contains($0.slotIndex) && $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 1e-6
        }
        return Set(valid.map(\.slotIndex)).sorted().compactMap { slot in
            var ranges: [Range<Int>] = []
            var singleSpeakerPieces: [Range<Int>] = []
            let candidates = valid.filter { $0.slotIndex == slot }
                .sorted { $0.end - $0.start > $1.end - $1.start }.prefix(16)
            for segment in candidates {
                var pieces = [MeetingAnalysisInterval(start: segment.start, end: segment.end)]
                for other in valid where other.slotIndex != slot {
                    pieces = pieces.flatMap { piece -> [MeetingAnalysisInterval] in
                        guard other.start < piece.end, other.end > piece.start else { return [piece] }
                        var remaining: [MeetingAnalysisInterval] = []
                        if other.start > piece.start {
                            remaining.append(.init(start: piece.start, end: other.start))
                        }
                        if other.end < piece.end {
                            remaining.append(.init(start: other.end, end: piece.end))
                        }
                        return remaining
                    }
                }
                for piece in pieces {
                    let start = max(0, Int(((piece.start + 0.16) * Double(self.sampleRate)).rounded(.up)))
                    let end = min(samples.count, Int(((piece.end - 0.16) * Double(self.sampleRate)).rounded(.down)))
                    if end - start >= self.sampleRate / 2 {
                        let energy = samples[start..<end].reduce(Double.zero) { $0 + Double($1) * Double($1) }
                        if energy.isFinite, energy / Double(end - start) > 1e-8 { singleSpeakerPieces.append(start..<end) }
                    }
                    if end - start >= 3 * self.sampleRate { ranges.append(start..<end) }
                }
            }
            ranges.sort { $0.count == $1.count ? $0.lowerBound < $1.lowerBound : $0.count > $1.count }
            var selected: [Range<Int>] = []
            for range in ranges {
                var start = range.lowerBound
                while selected.count < 2, range.upperBound - start >= 3 * self.sampleRate {
                    // Split a long turn so both excerpts contain independent audio.
                    let length = min(
                        5 * self.sampleRate,
                        (range.upperBound - start >= 6 * self.sampleRate)
                            ? (range.upperBound - start) / 2 : range.upperBound - start
                    )
                    let candidate = start..<(start + length)
                    start += length
                    guard !selected.contains(where: { $0.overlaps(candidate) }) else { continue }
                    let energy = samples[candidate].reduce(Double.zero) { $0 + Double($1) * Double($1) }
                    guard energy.isFinite, energy / Double(length) > 1e-8 else { continue }
                    selected.append(candidate)
                }
                if selected.count == 2 { break }
            }
            let clips: [[Float]]
            if selected.count == 2 {
                clips = selected.map { Array(samples[$0]) }
            } else {
                // Natural pauses can split ample clean voice evidence into pieces
                // shorter than three seconds. Build two disjoint three-second excerpts
                // from only this slot's admitted speech, keeping overlap/edges excluded.
                // Identity distance/margin and minimum excerpt duration stay unchanged.
                var excerpts: [[Float]] = []
                var pending: [Float] = []
                var consumedEnd = 0
                for range in singleSpeakerPieces.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                    var start = max(consumedEnd, range.lowerBound)
                    while start < range.upperBound, excerpts.count < 2 {
                        let end = min(range.upperBound, start + 3 * self.sampleRate - pending.count)
                        pending.append(contentsOf: samples[start..<end])
                        start = end
                        if pending.count == 3 * self.sampleRate { excerpts.append(pending); pending.removeAll(keepingCapacity: true) }
                    }
                    consumedEnd = max(consumedEnd, range.upperBound)
                    if excerpts.count == 2 { break }
                }
                guard excerpts.count == 2 else { return nil }
                clips = excerpts
            }
            return Self(
                token: MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-\(slot)"),
                clips: clips
            )
        }
    }
}

nonisolated struct MeetingSpeakerVoiceProfile: Codable, Equatable, Sendable {
    let token: MeetingBackendSpeakerToken
    let embeddings: [[Float]]
}

/// Explicit identity evidence across resets. Backend tokens remain epoch-scoped.
nonisolated struct MeetingSpeakerIdentityLink: Codable, Equatable, Sendable {
    let token: MeetingBackendSpeakerToken
    let canonicalToken: MeetingBackendSpeakerToken
}

/// One bounded admission snapshot for the strict PCM path. A profile that cannot establish
/// consistent identity must not become a newly named person merely because it has no link.
nonisolated struct MeetingPCMSpeakerAdmission: Sendable {
    let retainedProfiles: [MeetingSpeakerVoiceProfile]
    let links: [MeetingSpeakerIdentityLink]
    let identityTokens: Set<MeetingBackendSpeakerToken>
    let currentProfileCount: Int
    let rejectedCurrentProfileCount: Int
    let selfInconsistentCurrentProfileCount: Int
    let capacityExcludedCurrentProfileCount: Int
    let matchingDiagnostics: String

    /// Safe aggregate support data. No speaker identifiers, embeddings, distances or text.
    var diagnosticFields: String {
        "profiles=\(self.currentProfileCount) rejectedProfiles=\(self.rejectedCurrentProfileCount)"
            + " selfInconsistentProfiles=\(self.selfInconsistentCurrentProfileCount)"
            + " retainedProfiles=\(self.retainedProfiles.count) linkedProfiles=\(self.links.count)"
            + " newIdentities=\(self.identityTokens.subtracting(self.links.map(\.token)).count)"
            + " capacityExcludedProfiles=\(self.capacityExcludedCurrentProfileCount)"
            + " \(self.matchingDiagnostics)"
    }
}

nonisolated enum MeetingSpeakerVoiceMatcher {
    static let maximumDistance: Float = 0.25
    static let ambiguityMargin: Float = 0.10

    static func validLinks(_ links: [MeetingSpeakerIdentityLink], allowedTokens: Set<MeetingBackendSpeakerToken>) -> Bool {
        guard links.count <= MeetingSpeakerVoiceSamples.maximumProfiles else { return false }
        var canonicalByToken: [MeetingBackendSpeakerToken: MeetingBackendSpeakerToken] = [:]
        for link in links {
            guard allowedTokens.contains(link.token), allowedTokens.contains(link.canonicalToken),
                  link.token.analysisEpochID.trackID == link.canonicalToken.analysisEpochID.trackID,
                  link.token.analysisEpochID.ordinal > link.canonicalToken.analysisEpochID.ordinal,
                  canonicalByToken.updateValue(link.canonicalToken, forKey: link.token) == nil
            else { return false }
        }
        var epochsByIdentity: [MeetingBackendSpeakerToken: Set<MeetingAnalysisEpochID>] = [:]
        for token in allowedTokens {
            let root = canonicalByToken[token] ?? token
            guard canonicalByToken[root] == nil,
                  epochsByIdentity[root, default: []].insert(token.analysisEpochID).inserted
            else { return false }
        }
        return true
    }

    /// Links for a diarizer that kept one state per track: each slot label in a track resolves to
    /// its earliest visible epoch. Tracks never link to each other.
    static func continuityLinks(allowedTokens: Set<MeetingBackendSpeakerToken>) -> [MeetingSpeakerIdentityLink] {
        let groups = Dictionary(grouping: allowedTokens) {
            "\($0.analysisEpochID.trackID.uuidString)\u{0}\($0.label)"
        }
        return groups.values.flatMap { tokens -> [MeetingSpeakerIdentityLink] in
            let ordered = tokens.sorted {
                ($0.analysisEpochID.ordinal, $0.analysisEpochID.generation)
                    < ($1.analysisEpochID.ordinal, $1.analysisEpochID.generation)
            }
            guard let root = ordered.first else { return [] }
            return ordered.dropFirst().map { MeetingSpeakerIdentityLink(token: $0, canonicalToken: root) }
        }
    }

    static func distance(_ left: MeetingSpeakerVoiceProfile, _ right: MeetingSpeakerVoiceProfile) -> Float? {
        guard left.embeddings.count == 2, right.embeddings.count == 2 else { return nil }
        var worst: Float = 0
        for lhs in left.embeddings {
            for rhs in right.embeddings {
                guard lhs.count == 256, rhs.count == 256,
                      let value = MeetingSpeakerEmbeddingIndex.cosineDistance(lhs, rhs), value.isFinite
                else { return nil }
                worst = max(worst, value)
            }
        }
        return worst
    }

    private static func admittedProfiles(
        _ profiles: [MeetingSpeakerVoiceProfile], allowedTokens: Set<MeetingBackendSpeakerToken>
    ) -> [MeetingSpeakerVoiceProfile] {
        let counts = Dictionary(grouping: profiles, by: \.token)
        return profiles.filter {
            allowedTokens.contains($0.token) && counts[$0.token]?.count == 1
                && (self.distance($0, $0).map { $0 <= self.maximumDistance } ?? false)
        }
    }

    /// Shares the matcher's exact validity and distance rules with product identity admission.
    /// Matching may use a current observation beyond the reference budget if it links to an
    /// already retained identity, but an unretained new identity always stays unassigned.
    static func pcmAdmission(
        priorProfiles: [MeetingSpeakerVoiceProfile], currentProfiles: [MeetingSpeakerVoiceProfile],
        epoch: MeetingAnalysisEpochID
    ) -> MeetingPCMSpeakerAdmission {
        let allProfiles = priorProfiles + currentProfiles
        let allowedTokens = Set(allProfiles.map(\.token))
        let valid = self.admittedProfiles(allProfiles, allowedTokens: allowedTokens)
        let matching = self.match(validProfiles: valid, measuredEpoch: epoch)
        let links = matching.links
            .filter { $0.token.analysisEpochID == epoch }
        let retained = Array(valid.prefix(MeetingSpeakerVoiceSamples.maximumProfiles))
        let identityTokens = Set(retained.filter { $0.token.analysisEpochID == epoch }.map(\.token))
            .union(links.map(\.token))
        let validCurrent = valid.filter { $0.token.analysisEpochID == epoch }
        return MeetingPCMSpeakerAdmission(
            retainedProfiles: retained, links: links, identityTokens: identityTokens,
            currentProfileCount: currentProfiles.count,
            rejectedCurrentProfileCount: currentProfiles.count - validCurrent.count,
            selfInconsistentCurrentProfileCount: currentProfiles.filter {
                self.distance($0, $0).map { $0 > self.maximumDistance } ?? false
            }.count,
            capacityExcludedCurrentProfileCount: validCurrent.filter { !identityTokens.contains($0.token) }.count,
            matchingDiagnostics: matching.diagnosticFields
        )
    }

    private nonisolated struct MatchingResult {
        var links: [MeetingSpeakerIdentityLink] = []
        var eligibleReferenceComparisons = 0
        var thresholdFailedCandidates = 0
        var ambiguityRejectedObservations = 0
        var sameEpochCollisions = 0
        var nearestDistanceBins = [Int](repeating: 0, count: 4)

        var diagnosticFields: String {
            "referenceComparisons=\(self.eligibleReferenceComparisons) thresholdFailedCandidates=\(self.thresholdFailedCandidates)"
                + " ambiguityRejectedObservations=\(self.ambiguityRejectedObservations) sameEpochCollisions=\(self.sameEpochCollisions)"
                + " nearestDistanceBins=\(self.nearestDistanceBins.map(String.init).joined(separator: ","))"
        }
    }

    /// Complete-link comparison prevents gradual drift from joining different people. Distinct
    /// slots in the same epoch can never merge, including when both propose the same identity.
    static func links(
        profiles: [MeetingSpeakerVoiceProfile],
        allowedTokens: Set<MeetingBackendSpeakerToken>
    ) -> [MeetingSpeakerIdentityLink] {
        let valid = self.admittedProfiles(profiles, allowedTokens: allowedTokens)
        return self.match(validProfiles: valid).links
    }

    /// The optional measured epoch limits diagnostics to the current PCM observation. Bins
    /// are aggregate candidate distances <=0.10, <=0.25, <=0.50, >0.50, not voice signatures.
    private static func match(
        validProfiles valid: [MeetingSpeakerVoiceProfile], measuredEpoch: MeetingAnalysisEpochID? = nil
    ) -> MatchingResult {
        let epochs = Dictionary(grouping: valid, by: { $0.token.analysisEpochID })
        var clusters: [[MeetingSpeakerVoiceProfile]] = []
        var result = MatchingResult()
        for epoch in epochs.keys.sorted(by: {
            ($0.trackID.uuidString, $0.ordinal, $0.generation) < ($1.trackID.uuidString, $1.ordinal, $1.generation)
        }) {
            let observations = (epochs[epoch] ?? []).sorted { $0.token.label < $1.token.label }
            var proposals: [MeetingBackendSpeakerToken: Int] = [:]
            for observation in observations {
                let measuresObservation = epoch == measuredEpoch
                let candidates = clusters.indices.compactMap { index -> (Int, Float)? in
                    let cluster = clusters[index]
                    guard let root = cluster.first, root.token.analysisEpochID.trackID == epoch.trackID,
                          !cluster.contains(where: { $0.token.analysisEpochID == epoch })
                    else { return nil }
                    let distances = cluster.compactMap { self.distance(observation, $0) }
                    guard distances.count == cluster.count, let worst = distances.max() else { return nil }
                    if measuresObservation {
                        result.eligibleReferenceComparisons += distances.count
                        if worst > self.maximumDistance { result.thresholdFailedCandidates += 1 }
                    }
                    return (index, worst)
                }.sorted { $0.1 == $1.1 ? $0.0 < $1.0 : $0.1 < $1.1 }
                guard let best = candidates.first else { continue }
                if measuresObservation {
                    let bin = best.1 <= 0.10 ? 0 : (best.1 <= 0.25 ? 1 : (best.1 <= 0.50 ? 2 : 3))
                    result.nearestDistanceBins[bin] += 1
                }
                guard best.1 <= self.maximumDistance else { continue }
                guard candidates.count == 1 || candidates[1].1 - best.1 >= self.ambiguityMargin else {
                    if measuresObservation { result.ambiguityRejectedObservations += 1 }
                    continue
                }
                proposals[observation.token] = best.0
            }
            let collisions = Dictionary(grouping: proposals.values, by: { $0 })
            for observation in observations {
                if let index = proposals[observation.token], collisions[index]?.count == 1,
                   let root = clusters[index].first
                {
                    result.links.append(.init(token: observation.token, canonicalToken: root.token))
                    clusters[index].append(observation)
                } else {
                    if epoch == measuredEpoch, let index = proposals[observation.token],
                       (collisions[index]?.count ?? 0) > 1 {
                        result.sameEpochCollisions += 1
                    }
                    clusters.append([observation])
                }
            }
        }
        return result
    }
}

extension MeetingSpeakerVoiceSamples {
    /// The stopped archive is replayable, so owner verification needs only two bounded,
    /// disjoint three-second excerpts per global slot after the diarizer releases its weights.
    /// No Float buffer or voice evidence grows with meeting duration.
    nonisolated static func collect(
        epoch: MeetingAnalysisEpochID, source: any MeetingPCMReplaySource,
        segments: [MeetingNemotronSpeakerSegment]
    ) async throws -> [Self] {
        let duration = Double(source.totalSampleCount) / Double(self.sampleRate)
        let valid = segments.filter {
            (0..<8).contains($0.slotIndex) && $0.start.isFinite && $0.end.isFinite
                && $0.start >= 0 && $0.end > $0.start && $0.end <= duration + 1e-6
        }
        var result: [Self] = []
        for slot in Set(valid.map(\.slotIndex)).sorted() {
            try Task.checkCancellation()
            let candidates = valid.filter { $0.slotIndex == slot }
                .sorted { $0.end - $0.start > $1.end - $1.start }.prefix(16)
            var ranges: [Range<Int>] = []
            for segment in candidates {
                var pieces = [MeetingAnalysisInterval(start: segment.start, end: segment.end)]
                for other in valid where other.slotIndex != slot {
                    pieces = pieces.flatMap { piece -> [MeetingAnalysisInterval] in
                        guard other.start < piece.end, other.end > piece.start else { return [piece] }
                        var remaining: [MeetingAnalysisInterval] = []
                        if other.start > piece.start { remaining.append(.init(start: piece.start, end: other.start)) }
                        if other.end < piece.end { remaining.append(.init(start: other.end, end: piece.end)) }
                        return remaining
                    }
                }
                for piece in pieces {
                    let start = max(0, Int(((piece.start + 0.16) * Double(self.sampleRate)).rounded(.up)))
                    let end = min(source.totalSampleCount, Int(((piece.end - 0.16) * Double(self.sampleRate)).rounded(.down)))
                    if end - start >= self.sampleRate / 2 { ranges.append(start..<end) }
                }
            }
            var clips: [[Float]] = []
            var pending: [Float] = []
            var consumedEnd = 0
            for range in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
                var start = max(consumedEnd, range.lowerBound)
                while start < range.upperBound, clips.count < 2 {
                    try Task.checkCancellation()
                    let end = min(range.upperBound, start + 3 * self.sampleRate - pending.count)
                    let samples = try await source.readSamples(in: start..<end)
                    guard samples.count == end - start, samples.allSatisfy(\.isFinite) else {
                        throw MeetingParakeetNemotronRuntimeError.invalidPCMWindow
                    }
                    let energy = samples.reduce(Double.zero) { $0 + Double($1) * Double($1) }
                    if energy / Double(samples.count) > 1e-8 { pending.append(contentsOf: samples) }
                    start = end
                    if pending.count == 3 * self.sampleRate {
                        clips.append(pending)
                        pending.removeAll(keepingCapacity: true)
                    }
                }
                consumedEnd = max(consumedEnd, range.upperBound)
                if clips.count == 2 { break }
            }
            if clips.count == 2 {
                result.append(Self(token: .init(analysisEpochID: epoch, label: "slot-\(slot)"), clips: clips))
            }
        }
        return result
    }
}
