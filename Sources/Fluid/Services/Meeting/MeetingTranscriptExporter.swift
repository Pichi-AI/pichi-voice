import Foundation

/// Single source of truth for rendering a `MeetingSession` transcript as plain text or JSON.
nonisolated enum MeetingTranscriptExporter {
    /// The persisted alias stays user data. UI and text export resolve the owner marker
    /// with their chosen interface locale without rewriting a saved participant name.
    static func speakerDisplayName(_ speaker: MeetingSessionSpeaker,
                                   language: PichiInterfaceLanguage = .english,
                                   bundle: Bundle = .main) -> String {
        speaker.isLocalUser ? PichiLocalization.text("You", language: language, bundle: bundle) : speaker.displayName
    }

    static func text(for session: MeetingSession, includeEchoes: Bool = false,
                     segmentIDs: Set<MeetingTranscriptSegmentID>? = nil) -> String {
        let speakerNames = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let segments = session.transcriptSegments
            .filter { includeEchoes || !$0.isEcho }
            .enumerated().sorted {
                ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
            }.map(\.element)
        return self.displayParagraphs(for: segments, in: session).compactMap { paragraph in
            let selected = paragraph.segments.filter { segmentIDs?.contains($0.id) ?? true }
            guard let segment = selected.first else { return nil }
            let speaker = Self.speakerLabel(for: paragraph, in: session, speakerNames: speakerNames)
            return "[\(Self.timestampText(segment.start.seconds))] \(speaker): \(DisplayParagraph(segments: selected).text)"
        }.joined(separator: "\n\n")
    }

    /// Single resolver for the label shown next to a segment, shared by text export and
    /// `MeetingTranscriptionView` so the transcript and the UI never disagree on what a segment
    /// is called. `attributionState` (when present) is authoritative; its absence means the
    /// segment predates the state and falls back to inferring from `speakerID`/`overlap`.
    static func speakerLabel(
        for segment: MeetingTranscriptSegment,
        in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String],
        // Stable fallback for exports and summary fingerprints; UI passes its locale explicitly.
        language: PichiInterfaceLanguage = .english,
        bundle: Bundle = .main
    ) -> String {
        self.speakerLabel(for: self.speakerLabelValue(for: segment, in: session, speakerNames: speakerNames),
                          language: language, bundle: bundle)
    }

    /// A live reading label is created only from already protected product segments.
    /// Reuses the history readable-turn identity and exactly the same attribution label resolver.
    static func speakerPresentation(
        for segment: MeetingTranscriptSegment, in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String]? = nil
    ) -> MeetingSpeakerPresentation {
        let names = speakerNames ?? Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let label = self.speakerLabelValue(for: segment, in: session, speakerNames: names)
        return MeetingSpeakerPresentation(
            identity: self.paragraphIdentity(for: segment, legacySpeakerID: nil, in: session, speakerNames: names),
            label: label, participantID: self.readingParticipantID(segment.speakerID, label: label, in: session))
    }

    /// One contextual reading pass per session or bounded live batch. Original members remain
    /// untouched; every consumer uses the same projected owner without a per-word full scan.
    static func speakerPresentations(in session: MeetingSession,
                                     segments: [MeetingTranscriptSegment]? = nil)
        -> [MeetingTranscriptSegmentID: MeetingSpeakerPresentation] {
        var context = session
        if let segments { context.transcriptSegments = segments }
        let ordered = context.transcriptSegments.enumerated().filter { !$0.element.isEcho }.sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        let names = Dictionary(context.activeSpeakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        var result: [MeetingTranscriptSegmentID: MeetingSpeakerPresentation] = [:]
        for paragraph in self.displayParagraphs(for: ordered, in: context) {
            let first = paragraph.firstSegment
            let projected = paragraph.projectedSpeakerID
            let label = projected.flatMap { self.speakerName($0, in: context, speakerNames: names) }
                .map(MeetingSpeakerPresentation.Label.estimated)
                ?? self.speakerLabelValue(for: first, in: context, speakerNames: names)
            let participant = self.readingParticipantID(projected ?? first.speakerID, label: label, in: context)
            let presentation = MeetingSpeakerPresentation(
                identity: self.paragraphIdentity(for: first, legacySpeakerID: projected, in: context, speakerNames: names),
                label: label, participantID: participant)
            for member in paragraph.segments { result[member.id] = presentation }
        }
        return result
    }

    private static func readingParticipantID(_ id: SessionSpeakerID?, label: MeetingSpeakerPresentation.Label,
                                            in session: MeetingSession) -> SessionSpeakerID? {
        switch label {
        case .identified, .estimated, .interrupting:
            return self.resolvedSpeakerID(id, in: session, activeSpeakerIDs: Set(session.activeSpeakers.map(\.id)))
        case .unknown, .candidates: return nil
        }
    }

    static func speakerLabel(
        for presentation: MeetingSpeakerPresentation,
        language: PichiInterfaceLanguage = .english, bundle: Bundle = .main
    ) -> String {
        self.speakerLabel(for: presentation.label, language: language, bundle: bundle)
    }

    private static func speakerLabel(
        for label: MeetingSpeakerPresentation.Label,
        language: PichiInterfaceLanguage, bundle: Bundle
    ) -> String {
        func name(_ value: MeetingSpeakerPresentation.Name) -> String {
            value.isLocalUser ? PichiLocalization.text("You", language: language, bundle: bundle) : value.displayName
        }
        switch label {
        case .unknown:
            return PichiLocalization.text("Unknown speaker", language: language, bundle: bundle)
        case let .identified(value), let .estimated(value): return name(value)
        case let .interrupting(value, _): return name(value)
        case .candidates: return PichiLocalization.text("Unknown speaker", language: language, bundle: bundle)
        }
    }

    private static func speakerLabelValue(
        for segment: MeetingTranscriptSegment, in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String]
    ) -> MeetingSpeakerPresentation.Label {
        func name(_ speakerID: SessionSpeakerID?) -> MeetingSpeakerPresentation.Name? {
            self.speakerName(speakerID, in: session, speakerNames: speakerNames)
        }
        if segment.attributionState != .timingUncertain, let attribution = segment.speakerAttribution,
           attribution.selectedSpeakerID == segment.speakerID {
            if let selectedName = name(segment.speakerID) {
                if !attribution.background.isEmpty {
                    return .interrupting(selectedName, background: attribution.background.map { name($0.speakerID) })
                }
                return attribution.rule.isHeuristic ? .estimated(selectedName) : .identified(selectedName)
            }
            if attribution.candidates.count > 1 {
                let relation: MeetingSpeakerPresentation.CandidateRelation
                switch attribution.relation {
                case .simultaneous: relation = .simultaneous
                case .conflict: relation = .conflict
                default: relation = .several
                }
                return .candidates(attribution.candidates.map { name($0.speakerID) }, relation: relation)
            }
        }
        if segment.speakerAttribution == nil, segment.speakerAttributionInference != nil,
           segment.attributionState == nil || segment.attributionState == .assigned,
           let value = name(segment.speakerID) {
            return .estimated(value)
        }
        guard let state = segment.attributionState else {
            return name(segment.speakerID).map { .identified($0) } ?? .unknown
        }
        switch state {
        case .assigned: return name(segment.speakerID).map { .identified($0) } ?? .unknown
        case .overlappingSpeakers: return .candidates([], relation: .several)
        case .unassigned, .timingUncertain: return .unknown
        }
    }

    private static func speakerName(_ speakerID: SessionSpeakerID?, in session: MeetingSession,
                                    speakerNames: [SessionSpeakerID: String]) -> MeetingSpeakerPresentation.Name? {
        guard let speakerID else { return nil }
        let resolvedID = self.resolvedAliasID(speakerID, in: session)
        if let owner = session.activeSpeakers.first(where: { $0.id == resolvedID && $0.isLocalUser }) {
            return .init(displayName: owner.displayName, isLocalUser: true)
        }
        return speakerNames[resolvedID].map { .init(displayName: $0, isLocalUser: false) }
    }

    /// Presentation grouping key: labels alone are insufficient because two distinct speakers can
    /// legitimately share a display name. The semantic attribution state keeps adjacent nil-speaker
    /// rows such as overlap and timing uncertainty from collapsing into one visual run.
    static func speakerLabelIdentity(
        for segment: MeetingTranscriptSegment,
        in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String]
    ) -> String {
        let label = self.speakerLabel(for: segment, in: session, speakerNames: speakerNames)
        return [
            segment.speakerID?.uuidString ?? "nil",
            segment.attributionState?.rawValue ?? "legacy",
            segment.overlap.rawValue,
            label,
            segment.speakerAttribution?.policyFingerprint ?? "legacy-policy",
            segment.speakerAttribution?.rule.rawValue ?? "legacy-rule",
            segment.speakerAttribution?.candidates.map { "\($0.token.analysisEpochID):\($0.token.label)" }.joined(separator: ",") ?? "",
        ].joined(separator: "|")
    }

    /// Shared presentation only: preserve every input segment and show its label
    /// at a speaker/attribution change, as the original desktop transcript does.
    static func displayRows(for segments: [MeetingTranscriptSegment], in session: MeetingSession)
        -> [(segment: MeetingTranscriptSegment, showsLabel: Bool)] {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        var previousIdentity: String?
        return segments.map { segment in
            let identity = self.speakerLabelIdentity(for: segment, in: session, speakerNames: names)
            let showsLabel = identity != previousIdentity
            previousIdentity = identity
            return (segment, showsLabel)
        }
    }

    /// A reading projection of timed fragments, not a replacement for canonical evidence.
    /// Every member retains its ID, text, revision and attribution for corrections and playback.
    struct DisplayParagraph: Identifiable, Equatable {
        let segments: [MeetingTranscriptSegment]
        /// A legacy reading bridge is deliberately not persisted as a native assignment.
        var containsLegacySpeakerBridge = false
        /// A legacy incoming turn can begin with an unresolved source member. Keep its
        /// reading identity separate from that member's immutable stored evidence.
        var projectedSpeakerID: SessionSpeakerID? = nil
        var id: MeetingTranscriptSegmentID { segments[0].id }
        var firstSegment: MeetingTranscriptSegment { segments[0] }
        var text: String {
            segments.enumerated().map { index, segment in
                Self.separator(after: index > 0 ? segments[index - 1].text : nil, before: segment.text) + segment.text
            }.joined()
        }

        static func separator(after previous: String?, before next: String) -> String {
            guard let last = previous?.last, let first = next.first,
                  !last.isWhitespace, !first.isWhitespace else { return "" }
            if ".,;:!?…)]}»".contains(first) || "([{«".contains(last) { return "" }
            return " "
        }
    }

    /// A reading turn uses the selected participant's name. Contextual estimates remain on
    /// their canonical members without adding a qualifier to the visible participant label.
    static func speakerLabel(
        for paragraph: DisplayParagraph, in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String], language: PichiInterfaceLanguage = .english,
        bundle: Bundle = .main
    ) -> String {
        if let projected = paragraph.projectedSpeakerID {
            let resolved = self.resolvedAliasID(projected, in: session)
            if let speaker = session.activeSpeakers.first(where: { $0.id == resolved }),
               let displayName = speakerNames[resolved] {
                return self.speakerLabel(for: .estimated(.init(displayName: displayName, isLocalUser: speaker.isLocalUser)),
                    language: language, bundle: bundle)
            }
        }
        return self.speakerLabel(for: paragraph.firstSegment, in: session, speakerNames: speakerNames,
                                language: language, bundle: bundle)
    }

    /// Detailed evidence identities still drive correction rows and JSON. A readable turn is
    /// instead defined by the foreground speaker and meaningful uncertainty/background changes,
    /// not which individual word needed a neighbor rule or retained a suppressed candidate.
    private static func paragraphIdentity(
        for segment: MeetingTranscriptSegment, legacySpeakerID: SessionSpeakerID?,
        in session: MeetingSession, speakerNames: [SessionSpeakerID: String]
    ) -> String {
        if let speaker = legacySpeakerID ?? segment.speakerID,
           legacySpeakerID != nil || segment.attributionState == nil || segment.attributionState == .assigned {
            return [self.resolvedAliasID(speaker, in: session).uuidString, "assigned"].joined(separator: "|")
        }
        return self.speakerLabelIdentity(for: segment, in: session, speakerNames: speakerNames)
    }

    /// Reading ownership follows a continuing participant across a bounded mixed bout. This
    /// is the same contextual convention as the canonical resolver, not new voice evidence.
    private static func mainSpeakerReadingOwners(
        for segments: [MeetingTranscriptSegment], in session: MeetingSession
    ) -> [MeetingTranscriptSegmentID: SessionSpeakerID] {
        guard segments.count >= 3 else { return [:] }
        let source = session.transcriptSegments.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        guard source.allSatisfy({ $0.start.seconds.isFinite && $0.end.seconds.isFinite
            && $0.start.seconds >= 0 && $0.end.seconds > $0.start.seconds }) else { return [:] }
        let positions = Dictionary(source.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        guard positions.count == source.count else { return [:] }
        let blocked = MeetingSpeakerAttribution.overlappingIntervalIndices(source.map {
            .init(start: $0.start.seconds, end: $0.end.seconds)
        }, tolerance: MeetingSpeakerAttributionPolicy.standard.comparisonTolerance, checkpoint: { _ in })
        let active = Set(session.activeSpeakers.map(\.id))
        func safe(_ value: MeetingTranscriptSegment) -> Bool {
            value.revision == 0 && value.originalText == nil && value.status == .final
                && value.completeness == .complete && !value.isEcho && value.attributionState != .timingUncertain
                && value.speakerAttribution?.relation != .conflict && value.speakerAttribution?.rule != .barrier
                && value.speakerAttribution?.rule != .conflict
        }
        func isInterruption(_ value: MeetingTranscriptSegment) -> Bool {
            value.attributionState == .overlappingSpeakers || value.overlap == .ambiguous
                || value.speakerAttribution?.rule == .briefInterruption
                || value.speakerAttribution?.relation == .simultaneous
        }
        let interruptions = segments.map { safe($0) && isInterruption($0) }
        let anchors: [SessionSpeakerID?] = segments.enumerated().map { index, value in
            guard safe(value), !interruptions[index],
                  value.attributionState == nil || value.attributionState == .assigned,
                  value.speakerAttributionInference == nil,
                  value.speakerAttribution?.rule.isHeuristic != true else { return nil }
            return self.resolvedSpeakerID(value.speakerID, in: session, activeSpeakerIDs: active)
        }
        let candidates = segments.map(safe)
        guard let runs = try? MeetingSpeakerAttribution.continuingSpeakerRuns(
            intervals: segments.map { .init(start: $0.start.seconds, end: $0.end.seconds) },
            candidates: candidates, interruptions: interruptions, anchorIdentities: anchors, policy: .standard)
        else { return [:] }
        var owners: [MeetingTranscriptSegmentID: SessionSpeakerID] = [:]
        for run in runs {
            let range = run.before...run.after
            let first = segments[run.before], last = segments[run.after]
            guard let owner = anchors[run.before], let sourceStart = positions[first.id],
                  range.allSatisfy({ positions[segments[$0].id] == sourceStart + $0 - run.before
                      && !blocked.contains(sourceStart + $0 - run.before)
                      && segments[$0].sourceTrackID == first.sourceTrackID }),
                  !(session.transcriptCoverageGaps ?? []).contains(where: {
                      $0.trackID == first.sourceTrackID
                          && (!$0.start.isFinite || !$0.end.isFinite
                              || ($0.start < last.end.seconds && $0.end > first.start.seconds))
                  }) else { continue }
            let epochs = Set(range.flatMap { index in
                (segments[index].nativeSpeakerAssignment?.tokens
                    ?? segments[index].speakerAttribution?.rawAssignment.tokens ?? []).map(\.analysisEpochID)
            })
            guard epochs.count <= 1 else { continue }
            for index in run.first...run.last { owners[segments[index].id] = owner }
        }
        return owners
    }

    /// Pre-canonical archives have no native word precision or activity to replay. A completed,
    /// untouched legacy gap between known speakers uses the shared bounded neighbor admission:
    /// equal neighbors keep that voice, different neighbors select the incoming voice. Unsafe
    /// or manual evidence remains a boundary. No stored word, ID, timing or policy is rewritten.
    private static func legacyReadingBridges(
        for segments: [MeetingTranscriptSegment], in session: MeetingSession
    ) -> [MeetingTranscriptSegmentID: SessionSpeakerID] {
        // Pipeline 14 introduced canonical word-attribution provenance. Missing provenance in
        // a current attempt must never opt it into compatibility inference.
        guard session.state == .completed, session.endedAt != nil,
              session.transcriptIsComplete != false, session.transcriptCoverageGaps?.isEmpty != false,
              session.resultSidecarReference == nil, let attempt = session.processingAttempts.last,
              attempt.stage == .completed, attempt.completedAt != nil, attempt.errorCode == nil,
              attempt.pipelineVersion > 0, attempt.pipelineVersion < 14 else { return [:] }
        guard session.transcriptSegments.allSatisfy({
            $0.start.seconds.isFinite && $0.end.seconds.isFinite && $0.start.seconds >= 0 && $0.end.seconds > $0.start.seconds
        }) else { return [:] }
        let source = session.transcriptSegments.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        let sourcePositions = Dictionary(source.enumerated().map { ($0.element.id, $0.offset) },
                                         uniquingKeysWith: { first, _ in first })
        guard sourcePositions.count == source.count else { return [:] }
        let temporalBarriers = MeetingSpeakerAttribution.overlappingIntervalIndices(source.map {
            .init(start: $0.start.seconds, end: $0.end.seconds)
        }, tolerance: MeetingSpeakerAttributionPolicy.standard.comparisonTolerance, checkpoint: { _ in })
        let active = Set(session.activeSpeakers.map(\.id))
        func untouched(_ segment: MeetingTranscriptSegment) -> Bool {
            segment.revision == 0 && segment.originalText == nil && segment.status == .final
                && segment.completeness == .complete && !segment.isEcho
                && segment.nativePrecision == nil && segment.nativeTiming == nil && segment.nativeUnitID == nil
                && segment.nativeSpeakerAssignment == nil && segment.speakerAttribution == nil
                && segment.speakerAttributionInference == nil
        }
        func unknown(_ segment: MeetingTranscriptSegment) -> Bool {
            untouched(segment) && segment.speakerID == nil
                && (segment.attributionState == .unassigned && segment.overlap == .none
                    || segment.attributionState == .overlappingSpeakers)
        }
        func anchor(_ segment: MeetingTranscriptSegment) -> SessionSpeakerID? {
            guard untouched(segment), segment.overlap == .none, segment.attributionState == .assigned,
                  let speaker = segment.speakerID,
                  self.resolvedSpeakerID(speaker, in: session, activeSpeakerIDs: active) != nil else { return nil }
            return speaker
        }
        var bridges: [MeetingTranscriptSegmentID: SessionSpeakerID] = [:]
        var position = 0
        while position < segments.count {
            guard unknown(segments[position]) else { position += 1; continue }
            let first = position
            while position < segments.count, unknown(segments[position]) { position += 1 }
            guard first > 0, position < segments.count,
                  let preceding = anchor(segments[first - 1]),
                  let incoming = anchor(segments[position]) else { continue }
            let range = (first - 1)...position
            guard let sourceStart = sourcePositions[segments[first - 1].id],
                  range.allSatisfy({ sourcePositions[segments[$0].id] == sourceStart + $0 - (first - 1)
                      && !temporalBarriers.contains(sourceStart + $0 - (first - 1))
                      && segments[$0].sourceTrackID == segments[first - 1].sourceTrackID }),
                  MeetingSpeakerAttribution.admitsNeighborRun(range.map {
                      .init(start: segments[$0].start.seconds, end: segments[$0].end.seconds)
                  }, policy: .standard,
                  sameSpeaker: self.resolvedAliasID(preceding, in: session)
                    == self.resolvedAliasID(incoming, in: session)) else { continue }
            for index in first..<position { bridges[segments[index].id] = incoming }
        }
        return bridges
    }

    /// Input order is retained. Callers supply chronological, non-echo segments.
    /// Adjacent nil-speaker fragments can flow under the honest unknown-speaker label. Their
    /// distinct uncertainty states remain on every canonical member, not an invented identity.
    /// Identified speaker/state changes and source/evidence changes stay boundaries. Short safe
    /// gaps in untouched pre-canonical archives retain the legacy projection's estimate marker.
    /// Buffer size,
    /// elapsed time, pauses and line breaks are not evidence of a new speaker turn. Explicit line
    /// breaks remain in the text inside a turn without creating a second speaker header.
    static func displayParagraphs(for segments: [MeetingTranscriptSegment], in session: MeetingSession) -> [DisplayParagraph] {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let legacyBridges = self.legacyReadingBridges(for: segments, in: session)
        let continuations = self.mainSpeakerReadingOwners(for: segments, in: session)
        let readingOwners = legacyBridges.merging(continuations) { _, continuation in continuation }
        var paragraphs: [DisplayParagraph] = []
        var members: [MeetingTranscriptSegment] = []
        var containsLegacyBridge = false
        var projectedSpeakerID: SessionSpeakerID?
        for segment in segments {
            let startsParagraph = members.last.map { previous in
                let bothUnknown = previous.speakerID == nil && segment.speakerID == nil
                    && readingOwners[previous.id] == nil && readingOwners[segment.id] == nil
                return ((!bothUnknown || previous.speakerAttribution != nil || segment.speakerAttribution != nil)
                    && paragraphIdentity(for: previous, legacySpeakerID: readingOwners[previous.id], in: session, speakerNames: names)
                    != paragraphIdentity(for: segment, legacySpeakerID: readingOwners[segment.id], in: session, speakerNames: names))
                    || previous.sourceTrackID != segment.sourceTrackID
                    || previous.status != segment.status || previous.completeness != segment.completeness
                    || previous.isEcho != segment.isEcho
            } ?? false
            if startsParagraph {
                paragraphs.append(DisplayParagraph(segments: members, containsLegacySpeakerBridge: containsLegacyBridge,
                                                   projectedSpeakerID: projectedSpeakerID))
                members = []
                containsLegacyBridge = false
            }
            if members.isEmpty { projectedSpeakerID = readingOwners[segment.id] }
            members.append(segment)
            containsLegacyBridge = containsLegacyBridge || legacyBridges[segment.id] != nil
        }
        if !members.isEmpty {
            paragraphs.append(DisplayParagraph(segments: members, containsLegacySpeakerBridge: containsLegacyBridge,
                                               projectedSpeakerID: projectedSpeakerID))
        }
        return paragraphs
    }

    static func json(for session: MeetingSession) throws -> Data {
        let speakers = session.activeSpeakers.map {
            ExportedSpeaker(id: $0.id, displayName: $0.displayName, isLocalUser: $0.isLocalUser)
        }
        let activeSpeakerIDs = Set(speakers.map(\.id))
        let segments = session.transcriptSegments
            .sorted { $0.start.seconds < $1.start.seconds }
            .map {
                ExportedSegment(
                    id: $0.id,
                    startSeconds: $0.start.seconds,
                    endSeconds: $0.end.seconds,
                    speakerID: Self.resolvedSpeakerID(
                        $0.speakerID,
                        in: session,
                        activeSpeakerIDs: activeSpeakerIDs
                    ),
                    text: $0.text,
                    revision: $0.revision,
                    status: $0.status.rawValue,
                    overlap: $0.overlap.rawValue,
                    completeness: $0.completeness.rawValue,
                    isLikelyEcho: $0.isEcho,
                    attributionState: $0.attributionState?.rawValue,
                    speakerAttributionInference: $0.speakerAttributionInference,
                    nativePrecision: $0.nativePrecision,
                    nativeUnitID: $0.nativeUnitID,
                    nativeSpeakerAssignment: $0.nativeSpeakerAssignment,
                    nativeTiming: $0.nativeTiming,
                    speakerAttribution: $0.speakerAttribution.map { attribution in
                        ExportedSpeakerAttribution(
                            unitID: attribution.unitID, rawAssignment: attribution.rawAssignment,
                            selectedToken: attribution.selectedToken,
                            selectedSpeakerID: Self.resolvedSpeakerID(attribution.selectedSpeakerID, in: session, activeSpeakerIDs: activeSpeakerIDs),
                            candidates: attribution.candidates.map { .init(token: $0.token,
                                speakerID: Self.resolvedSpeakerID($0.speakerID, in: session, activeSpeakerIDs: activeSpeakerIDs)) },
                            background: attribution.background.map { .init(token: $0.token,
                                speakerID: Self.resolvedSpeakerID($0.speakerID, in: session, activeSpeakerIDs: activeSpeakerIDs)) },
                            relation: attribution.relation, rule: attribution.rule,
                            policyVersion: attribution.policyVersion, policyFingerprint: attribution.policyFingerprint)
                    }
                )
            }
        let document = ExportedTranscript(
            schemaVersion: 2,
            title: session.title,
            languageCode: session.languageCode,
            startedAt: session.startedAt,
            endedAt: session.endedAt,
            durationSeconds: session.duration,
            mode: session.mode.rawValue,
            applicationDisplayName: session.capturedApplication?.displayName,
            applicationAudioScope: session.mode == .onlineCall ? session.effectiveApplicationAudioScope : nil,
            speakers: speakers,
            segments: segments
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(document)
    }

    /// A segment can still reference a merged speaker. Resolve its alias chain so JSON export
    /// never references a speaker absent from the exported `speakers` array.
    private static func resolvedSpeakerID(
        _ speakerID: SessionSpeakerID?,
        in session: MeetingSession,
        activeSpeakerIDs: Set<SessionSpeakerID>
    ) -> SessionSpeakerID? {
        guard let resolvedID = speakerID.map({ Self.resolvedAliasID($0, in: session) }) else { return nil }
        return activeSpeakerIDs.contains(resolvedID) ? resolvedID : nil
    }

    private static func resolvedAliasID(_ speakerID: SessionSpeakerID, in session: MeetingSession) -> SessionSpeakerID {
        var resolvedID = speakerID
        var hops = 0
        while let alias = session.speakers.first(where: { $0.id == resolvedID })?.mergedIntoSpeakerID, hops < session.speakers.count {
            resolvedID = alias
            hops += 1
        }
        return resolvedID
    }

    static func timestampText(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds.rounded(.down)))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 {
            return String(format: "%d:%02d:%02d", hours, minutes, secs)
        }
        return String(format: "%02d:%02d", minutes, secs)
    }
}

private struct ExportedSpeaker: Codable {
    var id: SessionSpeakerID
    var displayName: String
    var isLocalUser: Bool
}

private struct ExportedSegment: Codable {
    var id: MeetingTranscriptSegmentID
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval
    var speakerID: SessionSpeakerID?
    var text: String
    var revision: Int
    var status: String
    var overlap: String
    var completeness: String
    var isLikelyEcho: Bool
    var attributionState: String?
    var speakerAttributionInference: MeetingSpeakerAttributionInference?
    var nativePrecision: MeetingTextUnitPrecision?
    var nativeUnitID: String?
    var nativeSpeakerAssignment: MeetingBackendSpeakerAssignment?
    var nativeTiming: MeetingTranscriptNativeTiming?
    var speakerAttribution: ExportedSpeakerAttribution?
}

private struct ExportedSpeakerAttribution: Codable {
    let unitID: String
    let rawAssignment: MeetingBackendSpeakerAssignment
    let selectedToken: MeetingBackendSpeakerToken?
    let selectedSpeakerID: SessionSpeakerID?
    let candidates: [MeetingTranscriptSpeakerReference]
    let background: [MeetingTranscriptSpeakerReference]
    let relation: MeetingSpeakerAttributionRelation
    let rule: MeetingSpeakerAttributionRule
    let policyVersion: Int
    let policyFingerprint: String
}

private struct ExportedTranscript: Codable {
    var schemaVersion: Int
    var title: String
    var languageCode: String
    var startedAt: Date
    var endedAt: Date?
    var durationSeconds: TimeInterval
    var mode: String
    var applicationDisplayName: String?
    var applicationAudioScope: MeetingApplicationAudioScope?
    var speakers: [ExportedSpeaker]
    var segments: [ExportedSegment]
}
