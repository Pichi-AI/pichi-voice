import Foundation

/// Single source of truth for rendering a `MeetingSession` transcript as plain text, Markdown or JSON.
nonisolated enum MeetingTranscriptExporter {
    struct CoverageDetail: Equatable, Sendable {
        let trackID: MeetingAudioTrackID
        let kind: MeetingAudioTrackKind?
        let omittedSeconds: TimeInterval
        let intervalCount: Int
    }

    /// Recorded intervals excluded from transcription, without counting overlapping
    /// reasons twice. Missing capture time remains separate evidence.
    static func coverageDetails(in session: MeetingSession) -> [CoverageDetail] {
        let grouped = Dictionary(grouping: (session.transcriptCoverageGaps ?? []).filter {
            $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end > $0.start
        }, by: \.trackID)
        let trackOrder = Dictionary(uniqueKeysWithValues: session.audioTracks.enumerated().map { ($0.element.id, $0.offset) })
        return grouped.keys.sorted {
            (trackOrder[$0] ?? Int.max, $0.uuidString) < (trackOrder[$1] ?? Int.max, $1.uuidString)
        }.compactMap { id in
            let ordered = (grouped[id] ?? []).sorted { ($0.start, $0.end) < ($1.start, $1.end) }
            var intervals: [(start: TimeInterval, end: TimeInterval)] = []
            for gap in ordered {
                if let last = intervals.last, gap.start <= last.end {
                    intervals[intervals.count - 1].end = max(last.end, gap.end)
                } else { intervals.append((gap.start, gap.end)) }
            }
            let seconds = intervals.reduce(0) { $0 + $1.end - $1.start }
            guard seconds.isFinite, seconds > 0 else { return nil }
            return CoverageDetail(trackID: id, kind: session.audioTracks.first(where: { $0.id == id })?.kind,
                                  omittedSeconds: seconds, intervalCount: intervals.count)
        }
    }

    static func coverageDescription(in session: MeetingSession,
                                    language: PichiInterfaceLanguage = .english,
                                    bundle: Bundle = .main) -> String? {
        let descriptions = self.coverageDetails(in: session).map { value in
            let key: String
            switch value.kind {
            case .microphone: key = "Microphone"
            case .applicationAudio: key = "Meeting audio"
            case nil: key = "Audio"
            }
            return PichiLocalization.format("%@: %.1f s. Audio intervals: %lld.", language: language,
                bundle: bundle, arguments: [PichiLocalization.text(key, language: language, bundle: bundle),
                                             value.omittedSeconds, Int64(value.intervalCount)])
        }
        return descriptions.isEmpty ? nil : descriptions.joined(separator: "\n")
    }
    /// The persisted alias stays user data. UI and text export resolve the owner marker
    /// with their chosen interface locale without rewriting a saved participant name.
    static func speakerDisplayName(_ speaker: MeetingSessionSpeaker,
                                   language: PichiInterfaceLanguage = .english,
                                   bundle: Bundle = .main) -> String {
        speaker.isLocalUser && speaker.usesCustomDisplayName != true
            ? PichiLocalization.text("You", language: language, bundle: bundle) : speaker.displayName
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
            var headingParagraph = paragraph
            // A selected excerpt stands on its own even when its full-session paragraph
            // would suppress a repeated participant heading.
            if segmentIDs != nil { headingParagraph.showsSpeakerLabel = true }
            let speaker = Self.captionLabel(for: headingParagraph, in: session, speakerNames: speakerNames)
            let heading = speaker.map { "\($0): " } ?? ""
            return "[\(Self.timestampText(segment.start.seconds))] \(heading)\(DisplayParagraph(segments: selected).text)"
        }.joined(separator: "\n\n")
    }

    static func markdown(for session: MeetingSession, includeEchoes: Bool = false) -> String {
        let speakerNames = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let title = Self.markdownHeading(session.title)
        let segments = session.transcriptSegments
            .filter { includeEchoes || !$0.isEcho }
            .enumerated().sorted {
                ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
            }.map(\.element)
        var blocks = ["# \(title)", "## Transcript"]
        for paragraph in self.displayParagraphs(for: segments, in: session) {
            let speaker = Self.captionLabel(for: paragraph, in: session, speakerNames: speakerNames)
                .map(Self.markdownHeading)
            let heading = speaker.map { " \($0)" } ?? ""
            blocks.append("### [\(Self.timestampText(paragraph.firstSegment.start.seconds))]\(heading)")
            blocks.append(Self.escapeMarkdown(paragraph.text))
        }
        return blocks.joined(separator: "\n\n") + "\n"
    }

    private static func markdownHeading(_ text: String) -> String {
        self.escapeMarkdown(text.components(separatedBy: .newlines).joined(separator: " "))
    }

    private static func escapeMarkdown(_ text: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(text.utf8.count)
        for character in text {
            if "\\`*_{}[]<>()#+-.!|>".contains(character) {
                escaped.append("\\")
            }
            escaped.append(character)
        }
        return escaped
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
        let participantID = self.readingParticipantID(segment.speakerID, label: label, in: session)
        return MeetingSpeakerPresentation(
            identity: self.paragraphIdentity(for: segment, legacySpeakerID: nil, in: session, speakerNames: names),
            label: label, participantID: participantID,
            participantIndex: participantID.flatMap { id in session.speakers.firstIndex { $0.id == id } })
    }

    /// A displayed paragraph can begin with an unresolved fragment or a merged alias.
    /// Its styling and actions use the same resolved reading owner as the full-session map.
    static func speakerPresentation(
        for paragraph: DisplayParagraph, in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String]
    ) -> MeetingSpeakerPresentation {
        let first = paragraph.captionSegment
        let projected = paragraph.projectedSpeakerID
        if let speaker = paragraph.projectedSpeakerRecord {
            return MeetingSpeakerPresentation(identity: "\(speaker.id.uuidString)|assigned",
                label: .estimated(.init(displayName: speaker.displayName, isLocalUser: speaker.isLocalUser,
                    usesCustomDisplayName: speaker.usesCustomDisplayName,
                    isProvisional: speaker.identityIsProvisional == true)),
                participantID: speaker.id, participantIndex: paragraph.projectedSpeakerIndex)
        }
        let label = projected.flatMap { self.speakerName($0, in: session, speakerNames: speakerNames) }
            .map(MeetingSpeakerPresentation.Label.estimated)
            ?? self.speakerLabelValue(for: first, in: session, speakerNames: speakerNames)
        let participantID = self.readingParticipantID(projected ?? first.speakerID, label: label, in: session)
        return MeetingSpeakerPresentation(
            identity: self.paragraphIdentity(for: first, legacySpeakerID: projected, in: session, speakerNames: speakerNames),
            label: label, participantID: participantID,
            participantIndex: participantID.flatMap { id in session.speakers.firstIndex { $0.id == id } })
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
            let presentation = self.speakerPresentation(for: paragraph, in: context, speakerNames: names)
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

    /// Product captions require an actual readable participant. The detailed label resolver
    /// remains available to evidence/correction tools without leaking its uncertainty labels
    /// into live/history UI or plain transcript export.
    static func captionLabel(
        for presentation: MeetingSpeakerPresentation,
        language: PichiInterfaceLanguage = .english, bundle: Bundle = .main
    ) -> String? {
        guard presentation.hasReadableParticipant else { return nil }
        return self.speakerLabel(for: presentation, language: language, bundle: bundle)
    }

    private static func speakerLabel(
        for label: MeetingSpeakerPresentation.Label,
        language: PichiInterfaceLanguage, bundle: Bundle
    ) -> String {
        func name(_ value: MeetingSpeakerPresentation.Name) -> String {
            value.isLocalUser && value.usesCustomDisplayName != true
                ? PichiLocalization.text("You", language: language, bundle: bundle) : value.displayName
        }
        switch label {
        case .unknown:
            return PichiLocalization.text("Unknown speaker", language: language, bundle: bundle)
        case let .identified(value), let .estimated(value):
            // Legacy uncertainty remains in the presentation/evidence value. Product
            // captions and readable exports use the participant's unqualified name.
            return name(value)
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
        if segment.isUserSpeakerAssigned != true, let speakerID = segment.speakerID,
           let speaker = session.activeSpeakers.first(where: {
               $0.id == self.resolvedAliasID(speakerID, in: session)
           }), speaker.identityIsProvisional != nil,
           let value = name(speakerID) {
            if speaker.identityIsProvisional == true {
                return .estimated(.init(displayName: value.displayName, isLocalUser: false,
                    usesCustomDisplayName: value.usesCustomDisplayName, isProvisional: true))
            }
            if segment.speakerIdentityIsProvisional == true {
                return segment.speakerAttribution?.rule.isHeuristic == true ? .estimated(value) : .identified(value)
            }
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
            return .init(displayName: owner.displayName, isLocalUser: true,
                usesCustomDisplayName: owner.usesCustomDisplayName)
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

    /// A reading projection of timed fragments, not a replacement for canonical evidence.
    /// Every member retains its ID, text, revision and attribution for corrections and playback.
    struct DisplayParagraph: Identifiable, Equatable, Sendable {
        let segments: [MeetingTranscriptSegment]
        /// A legacy reading bridge is deliberately not persisted as a native assignment.
        var containsLegacySpeakerBridge = false
        /// A legacy incoming turn can begin with an unresolved source member. Keep its
        /// reading identity separate from that member's immutable stored evidence.
        var projectedSpeakerID: SessionSpeakerID? = nil
        /// Archive reading can supply one stable participant when no identity was ever saved.
        /// Original members remain unchanged, so correction and playback retain their revisions.
        var projectedSpeakerRecord: MeetingSessionSpeaker? = nil
        var projectedSpeakerIndex: Int? = nil
        /// Each displayed paragraph repeats its known participant beside its timestamp.
        /// An unresolved paragraph does not invent a participant header.
        var showsSpeakerLabel = true
        var id: MeetingTranscriptSegmentID { segments[0].id }
        var firstSegment: MeetingTranscriptSegment { segments[0] }
        var captionSegment: MeetingTranscriptSegment { segments.first(where: \.hasReadableContent) ?? segments[0] }
        let text: String

        init(segments: [MeetingTranscriptSegment], containsLegacySpeakerBridge: Bool = false,
             projectedSpeakerID: SessionSpeakerID? = nil) {
            self.segments = segments
            self.containsLegacySpeakerBridge = containsLegacySpeakerBridge
            self.projectedSpeakerID = projectedSpeakerID
            self.text = segments.enumerated().map { index, segment in
                Self.separator(after: index > 0 ? segments[index - 1].text : nil, before: segment.text) + segment.text
            }.joined()
        }

        static let closingPunctuation = ".,;:!?…)]}»"

        static func separator(after previous: String?, before next: String) -> String {
            guard let last = previous?.last, let first = next.first,
                  !last.isWhitespace, !first.isWhitespace else { return "" }
            if Self.closingPunctuation.contains(first) || "([{«".contains(last) { return "" }
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
        if let speaker = paragraph.projectedSpeakerRecord {
            return self.speakerLabel(for: .estimated(.init(displayName: speaker.displayName,
                isLocalUser: speaker.isLocalUser, usesCustomDisplayName: speaker.usesCustomDisplayName,
                isProvisional: speaker.identityIsProvisional == true)), language: language, bundle: bundle)
        }
        if let projected = paragraph.projectedSpeakerID {
            let resolved = self.resolvedAliasID(projected, in: session)
            if session.activeSpeakers.contains(where: { $0.id == resolved }),
               let name = self.speakerName(resolved, in: session, speakerNames: speakerNames) {
                return self.speakerLabel(for: .estimated(name),
                    language: language, bundle: bundle)
            }
        }
        return self.speakerLabel(for: paragraph.captionSegment, in: session, speakerNames: speakerNames,
                                language: language, bundle: bundle)
    }

    static func captionLabel(
        for paragraph: DisplayParagraph, in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String], language: PichiInterfaceLanguage = .english,
        bundle: Bundle = .main
    ) -> String? {
        guard paragraph.showsSpeakerLabel else { return nil }
        if paragraph.projectedSpeakerRecord != nil {
            return self.speakerLabel(for: paragraph, in: session, speakerNames: speakerNames,
                language: language, bundle: bundle)
        }
        if let projected = paragraph.projectedSpeakerID {
            guard let name = self.speakerName(projected, in: session, speakerNames: speakerNames) else { return nil }
            return self.speakerLabel(for: .estimated(name), language: language, bundle: bundle)
        }
        let label = self.speakerLabelValue(for: paragraph.captionSegment, in: session, speakerNames: speakerNames)
        let presentation = self.speakerPresentation(for: paragraph.captionSegment, in: session, speakerNames: speakerNames)
        guard presentation.hasReadableParticipant else { return nil }
        return self.speakerLabel(for: label, language: language, bundle: bundle)
    }

    /// Detailed evidence identities still drive correction rows and JSON. A readable turn is
    /// instead defined by the foreground speaker and meaningful uncertainty/background changes,
    /// not which individual word needed a neighbor rule or retained a suppressed candidate.
    private static func paragraphIdentity(
        for segment: MeetingTranscriptSegment, legacySpeakerID: SessionSpeakerID?,
        in session: MeetingSession, speakerNames: [SessionSpeakerID: String]
    ) -> String {
        if segment.isUserSpeakerAssigned != true, let speakerID = segment.speakerID {
            let resolved = self.resolvedAliasID(speakerID, in: session)
            if let speaker = session.activeSpeakers.first(where: { $0.id == resolved }), speaker.identityIsProvisional != nil {
                if speaker.identityIsProvisional == true {
                    return [resolved.uuidString, "provisional"].joined(separator: "|")
                }
                if segment.speakerIdentityIsProvisional == true {
                    return [resolved.uuidString, "assigned"].joined(separator: "|")
                }
            }
        }
        if let speaker = legacySpeakerID ?? segment.speakerID,
           legacySpeakerID != nil || segment.attributionState == nil || segment.attributionState == .assigned {
            return [self.resolvedAliasID(speaker, in: session).uuidString, "assigned"].joined(separator: "|")
        }
        return self.speakerLabelIdentity(for: segment, in: session, speakerNames: speakerNames)
    }

    /// Reading ownership follows a continuing participant across a bounded mixed bout. This
    /// is the same contextual convention as the canonical resolver, not new voice evidence.
    private static func mainSpeakerReadingOwners(
        for segments: [MeetingTranscriptSegment], in session: MeetingSession,
        recoveredOwners: [MeetingTranscriptSegmentID: SessionSpeakerID] = [:]
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
            let automaticRevision = value.nativePrecision == .word && value.nativeUnitID != nil
                && value.speakerAttribution.map { $0.unitID == value.nativeUnitID
                    && $0.rawAssignment == value.nativeSpeakerAssignment } == true
            return (value.revision == 0 || automaticRevision) && value.originalText == nil
                && value.isUserTextEdited != true && value.isUserSpeakerAssigned != true && value.status == .final
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
            guard safe(value), value.hasReadableContent, value.speakerAttributionInference == nil else { return nil }
            // Older continuation policies could override a clean native reply. Its exact
            // recovered token/UUID mapping is an original acoustic anchor, not the old
            // contextual choice. Do not let a second reading pass swallow it again.
            if let recovered = recoveredOwners[value.id], let summary = value.speakerAttribution,
               summary.rule == .mainSpeakerContinuation, summary.relation == .single,
               summary.background.isEmpty, value.overlap == .none,
               case let .assigned(token) = value.nativeSpeakerAssignment,
               summary.rawAssignment == .assigned(token), summary.selectedToken != token {
                return recovered
            }
            guard value.attributionState == nil || value.attributionState == .assigned else { return nil }
            if let summary = value.speakerAttribution {
                guard summary.rule.isIndependentAcousticSelection, summary.selectedSpeakerID == value.speakerID,
                      summary.unitID == value.nativeUnitID, summary.rawAssignment == value.nativeSpeakerAssignment,
                      let token = summary.selectedToken, token.analysisEpochID.trackID == value.sourceTrackID,
                      summary.rawAssignment == .assigned(token) else { return nil }
            } else {
                guard !interruptions[index], value.revision == 0 else { return nil }
            }
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

    /// Streaming can commit a contextual token before that voice has enough clean support
    /// to admit a participant. Later words admit its identity, but the committed word keeps
    /// its original missing UUID. Complete only that mapping for reading, using independent
    /// native anchors. This does not select a voice, replay neighbor rules across pauses or
    /// change stored evidence. A revision can be an automatic identity patch, not a user edit;
    /// explicit speaker corrections clear the summary, and manual text provenance survives PII.
    private static func unmappedCanonicalReadingOwners(
        for segments: [MeetingTranscriptSegment], in session: MeetingSession
    ) -> [MeetingTranscriptSegmentID: SessionSpeakerID] {
        let active = Set(session.activeSpeakers.map(\.id))
        func safeNative(_ segment: MeetingTranscriptSegment) -> Bool {
            guard segment.status == .final, segment.completeness == .complete, !segment.isEcho,
                  segment.originalText == nil, segment.isUserTextEdited != true, segment.isUserSpeakerAssigned != true,
                  segment.attributionState != .timingUncertain,
                  segment.speakerAttributionInference == nil, segment.revision >= 0,
                  segment.start.seconds.isFinite, segment.end.seconds.isFinite,
                  segment.start.seconds >= 0, segment.end.seconds > segment.start.seconds,
                  let timing = segment.nativeTiming, timing.start.isFinite, timing.end.isFinite,
                  timing.start >= 0, timing.end > timing.start,
                  segment.nativePrecision == .word, segment.nativeUnitID?.isEmpty == false,
                  segment.nativeSpeakerAssignment != nil else { return false }
            return true
        }
        func evidence(_ segment: MeetingTranscriptSegment) -> MeetingTranscriptSpeakerAttribution? {
            guard safeNative(segment), let nativeID = segment.nativeUnitID,
                  let native = segment.nativeSpeakerAssignment, let summary = segment.speakerAttribution,
                  summary.unitID == nativeID, summary.rawAssignment == native,
                  summary.rule != .barrier, summary.rule != .conflict, summary.relation != .conflict,
                  summary.selectedToken.map({ $0.analysisEpochID.trackID == segment.sourceTrackID }) ?? true
            else { return nil }
            return summary
        }
        func anchorToken(_ segment: MeetingTranscriptSegment) -> MeetingBackendSpeakerToken? {
            guard safeNative(segment), segment.hasReadableContent, segment.attributionState == .assigned,
                  let native = segment.nativeSpeakerAssignment, case let .assigned(token) = native,
                  token.analysisEpochID.trackID == segment.sourceTrackID,
                  self.resolvedSpeakerID(segment.speakerID, in: session, activeSpeakerIDs: active) != nil
            else { return nil }
            if let summary = evidence(segment) {
                guard summary.rule.isIndependentAcousticSelection,
                      summary.selectedToken == token, summary.selectedSpeakerID == segment.speakerID else { return nil }
            } else {
                // Revised nil-summary rows can be manual assignments. Only pristine compact
                // native evidence establishes a new acoustic anchor without a summary.
                guard segment.speakerAttribution == nil, segment.revision == 0, segment.overlap == .none else { return nil }
            }
            return token
        }
        var identities: [MeetingBackendSpeakerToken: Set<SessionSpeakerID>] = [:]
        for segment in session.transcriptSegments {
            guard let token = anchorToken(segment),
                  let id = self.resolvedSpeakerID(segment.speakerID, in: session, activeSpeakerIDs: active) else { continue }
            identities[token, default: []].insert(id)
        }
        var owners: [MeetingTranscriptSegmentID: SessionSpeakerID] = [:]
        for segment in segments {
            // Repair only the reading projection of an old demonstrable policy override.
            // Names, stored IDs, native timing and the canonical JSON remain untouched.
            // A clean independent token must map uniquely through original native anchors.
            if let summary = evidence(segment), summary.rule == .mainSpeakerContinuation,
               summary.relation == .single, summary.background.isEmpty, segment.overlap == .none,
               summary.selectedSpeakerID == segment.speakerID,
               case let .assigned(nativeToken) = segment.nativeSpeakerAssignment,
               nativeToken.analysisEpochID.trackID == segment.sourceTrackID,
               summary.selectedToken != nativeToken,
               !(session.transcriptCoverageGaps ?? []).contains(where: {
                   $0.trackID == segment.sourceTrackID
                       && (!$0.start.isFinite || !$0.end.isFinite
                           || ($0.start < segment.end.seconds && $0.end > segment.start.seconds))
               }),
               let mapped = identities[nativeToken], mapped.count == 1 {
                owners[segment.id] = mapped.first
                continue
            }
            guard segment.speakerID == nil, let summary = evidence(segment),
                  summary.selectedSpeakerID == nil, let token = summary.selectedToken,
                  let mapped = identities[token], mapped.count == 1,
                  segment.attributionState == .unassigned || segment.attributionState == .overlappingSpeakers
            else { continue }
            // The voice can already be independently selected while its participant UUID
            // was not admitted yet. Complete only that exact native token's unique mapping.
            if summary.rule.isIndependentAcousticSelection, summary.rawAssignment == .assigned(token) {
                owners[segment.id] = mapped.first
                continue
            }
            switch summary.rule {
            case .neighborAgreement, .incomingSpeaker, .boundaryContinuation, .mainSpeakerContinuation:
                owners[segment.id] = mapped.first
            default: break
            }
        }
        // Reuse canonical bounded neighbor admission for original unresolved evidence. Acoustic
        // selections can anchor this pass; none of its contextual results become new anchors.
        let anchors = segments.map { segment -> MeetingBackendSpeakerToken? in
            guard let token = anchorToken(segment), identities[token]?.count == 1 else { return nil }
            return token
        }
        let eligible = segments.map { segment -> Bool in
            guard safeNative(segment), segment.speakerID == nil,
                  segment.attributionState == .unassigned || segment.attributionState == .overlappingSpeakers else { return false }
            if let summary = segment.speakerAttribution {
                guard evidence(segment) != nil, summary.selectedToken == nil else { return false }
                if summary.rule == .ambiguous, case let .ambiguous(tokens) = summary.rawAssignment {
                    return Set(tokens).count >= 2
                }
                return summary.rawAssignment == .unassigned && summary.relation == .none && summary.candidates.isEmpty
            }
            return segment.revision == 0 && segment.nativeSpeakerAssignment == .unassigned
        }
        let candidateTokens = segments.map { segment in
            Set((segment.nativeSpeakerAssignment?.tokens ?? [])
                + (segment.speakerAttribution?.candidates.map(\.token) ?? [])
                + (segment.speakerAttribution?.background.map(\.token) ?? []))
        }
        let intervals = segments.map { MeetingSpeakerAttributionInterval(start: $0.nativeTiming?.start ?? $0.start.seconds,
                                                                          end: $0.nativeTiming?.end ?? $0.end.seconds) }
        let runs = (try? MeetingSpeakerAttribution.neighborRuns(intervals: intervals, eligible: eligible,
            anchorIdentities: anchors, candidateIdentities: candidateTokens, policy: .standard)) ?? []
        let source = session.transcriptSegments.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        let positions = Dictionary(source.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        guard positions.count == source.count else { return owners }
        let blocked = MeetingSpeakerAttribution.overlappingIntervalIndices(source.map {
            .init(start: $0.nativeTiming?.start ?? $0.start.seconds, end: $0.nativeTiming?.end ?? $0.end.seconds)
        }, tolerance: MeetingSpeakerAttributionPolicy.standard.comparisonTolerance, checkpoint: { _ in })
        // A new turn can begin with unsupported words before its first independent voice.
        // Reuse the incoming-neighbor reading convention both at the start of a session
        // and after a proven pause from an independent prior turn. Nearby outgoing speech
        // still needs the ordinary two-sided rule. This is an estimated reading owner;
        // neither acoustic evidence nor the finite unknown horizon changes.
        let policy = MeetingSpeakerAttributionPolicy.standard
        var incomingPosition = 0
        while incomingPosition < segments.count {
            func unsupported(_ index: Int) -> Bool {
                eligible[index] && candidateTokens[index].isEmpty && segments[index].nativeSpeakerAssignment == .unassigned
                    && segments[index].attributionState == .unassigned && segments[index].overlap == .none
            }
            guard unsupported(incomingPosition) else { incomingPosition += 1; continue }
            let first = incomingPosition
            while incomingPosition < segments.count, unsupported(incomingPosition) { incomingPosition += 1 }
            guard incomingPosition < segments.count, let token = anchors[incomingPosition],
                  let id = identities[token]?.first else { continue }
            let scopeStart: Int
            var isTinySameSpeakerResidual = false
            if first == 0 {
                guard positions[segments[first].id] == 0 else { continue }
                scopeStart = first
            } else {
                guard let previous = anchors[first - 1], previous.analysisEpochID == token.analysisEpochID else { continue }
                // A tiny unsupported word can sit at an ASR window edge far from the
                // surrounding voiced words. Matching independent original voices on both
                // sides keep this residual in the same reading turn across silence. Reuse
                // the existing residual cap, without extending acoustic neighbor inference
                // or changing the unsupported word's native assignment or timestamp.
                let range = (first - 1)...incomingPosition
                isTinySameSpeakerResidual = previous == token
                    && intervals[incomingPosition - 1].end - intervals[first].start
                        <= policy.maximumBoundaryResidualSeconds + policy.comparisonTolerance
                    && (first..<incomingPosition).allSatisfy {
                        segments[$0].hasLexicalContent
                    }
                    && range.allSatisfy { index in
                        let word = segments[index]
                        return word.overlap == .none
                            && (word.speakerAttribution.map { $0.relation == .none || $0.relation == .single } ?? true)
                            && abs(intervals[index].start - word.start.seconds) <= 0.001
                            && abs(intervals[index].end - word.end.seconds) <= 0.001
                    }
                guard isTinySameSpeakerResidual
                    || intervals[first].start - intervals[first - 1].end
                        > policy.maximumNeighborGapSeconds + policy.comparisonTolerance else { continue }
                scopeStart = first - 1
            }
            let head = segments[scopeStart], incoming = segments[incomingPosition]
            let range = scopeStart...incomingPosition
            guard let sourceStart = positions[head.id],
                  isTinySameSpeakerResidual || intervals[incomingPosition].start - intervals[first].start
                    <= policy.maximumUnknownRunSeconds + policy.comparisonTolerance,
                  range.allSatisfy({ positions[segments[$0].id] == sourceStart + $0 - scopeStart
                      && !blocked.contains(sourceStart + $0 - scopeStart) && segments[$0].sourceTrackID == head.sourceTrackID }),
                  !(session.transcriptCoverageGaps ?? []).contains(where: {
                      $0.trackID == head.sourceTrackID && (!$0.start.isFinite || !$0.end.isFinite
                          || ($0.start < incoming.end.seconds && $0.end > head.start.seconds))
                  }) else { continue }
            for index in first..<incomingPosition { owners[segments[index].id] = id }
        }
        for run in runs {
            let range = run.before...run.after, first = segments[run.before], last = segments[run.after]
            guard let token = anchors[run.after], let id = identities[token]?.first,
                  let start = positions[first.id], range.allSatisfy({
                      positions[segments[$0].id] == start + $0 - run.before
                          && !blocked.contains(start + $0 - run.before)
                          && segments[$0].sourceTrackID == first.sourceTrackID
                  }), !(session.transcriptCoverageGaps ?? []).contains(where: {
                      $0.trackID == first.sourceTrackID && (!$0.start.isFinite || !$0.end.isFinite
                          || ($0.start < last.end.seconds && $0.end > first.start.seconds))
                  }) else { continue }
            let epochs = Set(range.flatMap { index in
                (segments[index].nativeSpeakerAssignment?.tokens ?? []) + [anchors[index]].compactMap { $0 }
            }.map(\.analysisEpochID))
            guard epochs.count == 1 else { continue }
            for index in run.first...run.last { owners[segments[index].id] = id }
        }
        return owners
    }

    /// A very short unsupported lexical tail next to an independent outgoing word can
    /// remain outside both voices at an ASR window edge. Keep that residual with its
    /// adjacent outgoing reading turn only when a separated following word proves the
    /// same source epoch. Punctuation alone attaches typographically to the prior turn.
    /// Neither convention creates acoustic evidence or changes any canonical member.
    private static func boundaryReadingOwners(
        for segments: [MeetingTranscriptSegment], in session: MeetingSession,
        existingOwners: [MeetingTranscriptSegmentID: SessionSpeakerID]
    ) -> [MeetingTranscriptSegmentID: SessionSpeakerID] {
        guard segments.count >= 2 else { return [:] }
        let policy = MeetingSpeakerAttributionPolicy.standard
        let source = session.transcriptSegments.enumerated().sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        guard source.allSatisfy({ $0.start.seconds.isFinite && $0.end.seconds.isFinite
            && $0.start.seconds >= 0 && $0.end.seconds > $0.start.seconds }) else { return [:] }
        let positions = Dictionary(source.enumerated().map { ($0.element.id, $0.offset) },
                                   uniquingKeysWith: { first, _ in first })
        guard positions.count == source.count else { return [:] }
        let blocked = MeetingSpeakerAttribution.overlappingIntervalIndices(source.map {
            .init(start: $0.nativeTiming?.start ?? $0.start.seconds, end: $0.nativeTiming?.end ?? $0.end.seconds)
        }, tolerance: policy.comparisonTolerance, checkpoint: { _ in })
        let active = Set(session.activeSpeakers.map(\.id))
        func safe(_ word: MeetingTranscriptSegment, allowsRevisedCompactTiming: Bool = false) -> Bool {
            guard word.revision >= 0, !word.text.isEmpty, word.status == .final, word.completeness == .complete, !word.isEcho,
                  word.originalText == nil, word.isUserTextEdited != true, word.isUserSpeakerAssigned != true,
                  word.attributionState != .timingUncertain, word.overlap == .none,
                  word.nativePrecision == .word, word.nativeUnitID?.isEmpty == false,
                  let timing = word.nativeTiming, timing.start.isFinite, timing.end.isFinite,
                  timing.start >= 0, timing.end > timing.start,
                  abs(timing.start - word.start.seconds) <= 0.001,
                  abs(timing.end - word.end.seconds) <= 0.001,
                  word.speakerAttributionInference == nil else { return false }
            if let summary = word.speakerAttribution {
                return summary.unitID == word.nativeUnitID && summary.rawAssignment == word.nativeSpeakerAssignment
                    && summary.rule != .barrier && summary.rule != .conflict && summary.relation != .conflict
            }
            // An automatically revised compact row can prove following native timing/epoch,
            // but cannot become a new outgoing ownership anchor without its summary.
            return word.revision == 0 || allowsRevisedCompactTiming
        }
        func anchor(_ word: MeetingTranscriptSegment) -> (SessionSpeakerID, MeetingBackendSpeakerToken)? {
            guard safe(word), word.hasReadableContent, word.attributionState == .assigned,
                  let id = self.resolvedSpeakerID(word.speakerID, in: session, activeSpeakerIDs: active),
                  case let .assigned(token) = word.nativeSpeakerAssignment,
                  token.analysisEpochID.trackID == word.sourceTrackID else { return nil }
            if let summary = word.speakerAttribution {
                guard summary.rule.isIndependentAcousticSelection, summary.selectedToken == token,
                      summary.selectedSpeakerID == word.speakerID else { return nil }
            }
            return (id, token)
        }
        func eligible(_ word: MeetingTranscriptSegment) -> Bool {
            guard safe(word), word.speakerID == nil, existingOwners[word.id] == nil,
                  word.attributionState == .unassigned, word.nativeSpeakerAssignment == .unassigned else { return false }
            guard let summary = word.speakerAttribution else { return true }
            return summary.selectedToken == nil && summary.selectedSpeakerID == nil
                && summary.relation == .none && summary.candidates.isEmpty && summary.background.isEmpty
        }
        func punctuation(_ word: MeetingTranscriptSegment) -> Bool {
            let scalars = word.text.trimmingCharacters(in: .whitespacesAndNewlines).unicodeScalars
            return !scalars.isEmpty && scalars.allSatisfy { DisplayParagraph.closingPunctuation.unicodeScalars.contains($0) }
        }
        var owners: [MeetingTranscriptSegmentID: SessionSpeakerID] = [:]
        var position = 0
        while position < segments.count {
            guard eligible(segments[position]) else { position += 1; continue }
            let first = position
            while position < segments.count, eligible(segments[position]) { position += 1 }
            let last = position - 1
            guard first > 0, let (owner, token) = anchor(segments[first - 1]),
                  let sourceStart = positions[segments[first - 1].id] else { continue }
            let range = (first - 1)...last
            let prior = segments[first - 1], head = segments[first], tail = segments[last]
            guard existingOwners[prior.id].map({ $0 == owner }) ?? true,
                  range.allSatisfy({ positions[segments[$0].id] == sourceStart + $0 - first + 1
                      && !blocked.contains(sourceStart + $0 - first + 1)
                      && segments[$0].sourceTrackID == prior.sourceTrackID }),
                  !(session.transcriptCoverageGaps ?? []).contains(where: {
                      $0.trackID == prior.sourceTrackID && (!$0.start.isFinite || !$0.end.isFinite
                          || ($0.start < tail.end.seconds && $0.end > prior.start.seconds))
                  }) else { continue }
            let gap = head.start.seconds - prior.end.seconds
            guard gap >= -policy.comparisonTolerance else { continue }
            let allPunctuation = (first...last).allSatisfy { punctuation(segments[$0]) }
            if allPunctuation {
                // This is typography, not a claim that a voice spoke punctuation in silence.
                guard tail.end.seconds - prior.end.seconds <= policy.maximumUnknownRunSeconds
                    + policy.comparisonTolerance else { continue }
            } else {
                guard (first...last).allSatisfy({ punctuation(segments[$0])
                        || segments[$0].hasLexicalContent }),
                      tail.end.seconds - head.start.seconds <= policy.maximumBoundaryResidualSeconds
                        + policy.comparisonTolerance,
                      gap <= policy.maximumBoundaryResidualSeconds + policy.comparisonTolerance,
                      position < segments.count else { continue }
                let next = segments[position]
                guard safe(next, allowsRevisedCompactTiming: true), next.attributionState == .assigned,
                      self.resolvedSpeakerID(next.speakerID, in: session, activeSpeakerIDs: active) != nil,
                      next.start.seconds - tail.end.seconds > policy.maximumNeighborGapSeconds
                        + policy.comparisonTolerance,
                      next.sourceTrackID == prior.sourceTrackID,
                      positions[next.id] == sourceStart + position - first + 1,
                      !blocked.contains(sourceStart + position - first + 1),
                      case let .assigned(nextToken) = next.nativeSpeakerAssignment,
                      nextToken.analysisEpochID == token.analysisEpochID,
                      !(session.transcriptCoverageGaps ?? []).contains(where: {
                          $0.trackID == prior.sourceTrackID && (!$0.start.isFinite || !$0.end.isFinite
                              || ($0.start < next.end.seconds && $0.end > prior.start.seconds))
                      }) else { continue }
            }
            for index in first...last { owners[segments[index].id] = owner }
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
            segment.revision == 0 && segment.originalText == nil && segment.isUserTextEdited != true
                && segment.isUserSpeakerAssigned != true && segment.status == .final
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
            guard untouched(segment), segment.hasReadableContent, segment.overlap == .none, segment.attributionState == .assigned,
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
    /// Unresolved fragments retain their uncertainty on canonical members. Readable captions
    /// omit an unsupported participant name instead of exposing an unknown/source label.
    /// Identified speaker/state changes and source/evidence changes stay boundaries. Short safe
    /// gaps in untouched pre-canonical archives retain the legacy projection's estimate marker.
    /// Buffer size,
    /// elapsed time, pauses and line breaks are not evidence of a new speaker turn. Explicit line
    /// breaks remain in the text inside a turn without creating a second speaker header.
    static func displayParagraphs(for segments: [MeetingTranscriptSegment], in session: MeetingSession) -> [DisplayParagraph] {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let legacyBridges = self.legacyReadingBridges(for: segments, in: session)
        let canonicalMappings = self.unmappedCanonicalReadingOwners(for: segments, in: session)
        let continuations = self.mainSpeakerReadingOwners(for: segments, in: session, recoveredOwners: canonicalMappings)
        let contextualOwners = legacyBridges.merging(canonicalMappings) { _, canonical in canonical }
            .merging(continuations) { _, continuation in continuation }
        var readingOwners = contextualOwners.merging(self.boundaryReadingOwners(
            for: segments, in: session, existingOwners: contextualOwners)) { contextual, _ in contextual }
        var readingSpeakers = session.speakers
        if session.speakerLabelsEnabled != false {
            let source = session.transcriptSegments.isEmpty ? segments : session.transcriptSegments
            let projected = source.map { original -> MeetingTranscriptSegment in
                guard let id = readingOwners[original.id], original.isUserSpeakerAssigned != true else { return original }
                var value = original
                value.speakerID = id
                value.speakerAttribution = .init(readingParticipant: id, source: original, policy: .standard)
                return value
            }
            var barriers: [MeetingAudioTrackID: [MeetingSpeakerAttributionInterval]] = [:]
            for gap in session.transcriptCoverageGaps ?? [] where gap.start.isFinite && gap.end.isFinite && gap.end > gap.start {
                barriers[gap.trackID, default: []].append(.init(start: gap.start, end: gap.end))
            }
            let format = PichiLocalization.text("Speaker %lld")
            let scopes = MeetingReadingSpeakerResolver.readingScopes(for: source)
            if let reading = try? MeetingReadingSpeakerResolver.resolve(segments: projected, speakers: session.speakers,
                barriersByTrack: barriers, scopeForSegment: { scopes[$0.id] },
                fallbackSpeaker: { scope in
                    MeetingReadingSpeakerResolver.fallbackSpeaker(namespace: session.id, scope: scope,
                        trackKind: session.audioTracks.first { $0.id == scope.trackID }?.kind ?? .microphone,
                        speakerNameFormat: format)
                }) {
                readingSpeakers = MeetingSessionSpeaker.numberingGeneratedParticipants(reading.speakers, speakerNameFormat: format)
                for (original, resolved) in zip(source, reading.segments) {
                    if let id = resolved.speakerID, original.hasReadableContent,
                       original.speakerID != id || original.attributionState != .assigned {
                        readingOwners[original.id] = id
                    }
                }
            }
        }
        let readingSpeakerIndices = Dictionary(readingSpeakers.enumerated().map { ($0.element.id, $0.offset) },
                                               uniquingKeysWith: { first, _ in first })
        // Nonlexical members are typography only when adjacent to actual readable speech.
        // Preserve the original members and timing, but never let their unsupported identity
        // open a paragraph. Standalone artifacts remain available in canonical JSON/evidence.
        var typographyAnchors: [MeetingTranscriptSegmentID: MeetingTranscriptSegment] = [:]
        let maximumGap = MeetingSpeakerAttributionPolicy.standard.maximumNeighborGapSeconds
        var typographyIndex = 0
        while typographyIndex < segments.count {
            guard !segments[typographyIndex].hasReadableContent else { typographyIndex += 1; continue }
            let first = typographyIndex
            while typographyIndex + 1 < segments.count, !segments[typographyIndex + 1].hasReadableContent {
                typographyIndex += 1
            }
            let last = typographyIndex
            typographyIndex += 1
            let neighbors = [first - 1, last + 1].filter { segments.indices.contains($0) }
            for neighbor in neighbors {
                let anchor = segments[neighbor]
                let gap = neighbor < first ? segments[first].start.seconds - anchor.end.seconds
                    : anchor.start.seconds - segments[last].end.seconds
                let start = min(anchor.start.seconds, segments[first].start.seconds)
                let end = max(anchor.end.seconds, segments[last].end.seconds)
                guard anchor.hasReadableContent, gap >= -0.001, gap <= maximumGap,
                      segments[last].end.seconds - segments[first].start.seconds
                        <= MeetingSpeakerAttributionPolicy.standard.maximumUnknownRunSeconds,
                      (first...last).allSatisfy({
                          let value = segments[$0]
                          let priorGap = $0 > first ? value.start.seconds - segments[$0 - 1].end.seconds : 0
                          return anchor.sourceTrackID == value.sourceTrackID && anchor.status == value.status
                              && anchor.completeness == value.completeness && anchor.isEcho == value.isEcho
                              && priorGap >= -0.001 && priorGap <= maximumGap
                      }),
                      !(session.transcriptCoverageGaps ?? []).contains(where: {
                          $0.trackID == anchor.sourceTrackID && $0.start < end && $0.end > start
                      }) else { continue }
                for index in first...last { typographyAnchors[segments[index].id] = anchor }
                break
            }
        }
        func readingIdentity(_ segment: MeetingTranscriptSegment) -> String {
            let anchor = typographyAnchors[segment.id] ?? segment
            return paragraphIdentity(for: anchor, legacySpeakerID: readingOwners[anchor.id], in: session, speakerNames: names)
        }
        var paragraphs: [DisplayParagraph] = []
        var members: [MeetingTranscriptSegment] = []
        var containsLegacyBridge = false
        var projectedSpeakerID: SessionSpeakerID?
        for segment in segments {
            guard segment.hasReadableContent || typographyAnchors[segment.id] != nil || readingOwners[segment.id] != nil else { continue }
            let startsParagraph = members.last.map { previous in
                let bothUnknown = previous.speakerID == nil && segment.speakerID == nil
                    && readingOwners[previous.id] == nil && readingOwners[segment.id] == nil
                return ((!bothUnknown || previous.speakerAttribution != nil || segment.speakerAttribution != nil)
                    && readingIdentity(previous) != readingIdentity(segment))
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
            else if projectedSpeakerID == nil { projectedSpeakerID = readingOwners[segment.id] }
            members.append(segment)
            containsLegacyBridge = containsLegacyBridge || legacyBridges[segment.id] != nil
        }
        if !members.isEmpty {
            paragraphs.append(DisplayParagraph(segments: members, containsLegacySpeakerBridge: containsLegacyBridge,
                                               projectedSpeakerID: projectedSpeakerID))
        }
        paragraphs.removeAll { !$0.segments.contains(where: \.hasReadableContent) }
        for index in paragraphs.indices {
            let paragraph = paragraphs[index], first = paragraph.captionSegment
            if let id = paragraph.projectedSpeakerID, let speakerIndex = readingSpeakerIndices[id],
               !session.speakers.contains(where: { $0.id == id }) {
                paragraphs[index].projectedSpeakerRecord = readingSpeakers[speakerIndex]
                paragraphs[index].projectedSpeakerIndex = speakerIndex
            }
            let presentation = self.speakerPresentation(for: first, in: session, speakerNames: names)
            // Each timestamp starts a displayed paragraph, so repeat its known name even
            // when an unresolved paragraph intervened. Unsupported names remain absent.
            paragraphs[index].showsSpeakerLabel = paragraph.projectedSpeakerID != nil || presentation.hasReadableParticipant
        }
        return paragraphs
    }

    /// Only values that affect reading ownership invalidate a cached projection. Capture
    /// meters, pending audio, timestamps, title and playback state do not participate.
    /// Arrays share the session's immutable value storage until a genuine edit arrives.
    struct ReadingInput: Equatable, Sendable {
        let sessionID: MeetingSessionID
        let ownership: MeetingProfileOwnership?
        let state: MeetingSessionState
        let endedAt: Date?
        let isComplete: Bool?
        let sidecar: MeetingResultSidecarReference?
        let latestAttempt: MeetingProcessingAttempt?
        let speakers: [MeetingSessionSpeaker]
        let segments: [MeetingTranscriptSegment]
        let gaps: [MeetingTranscriptCoverageGap]?

        init(_ session: MeetingSession) {
            sessionID = session.id; ownership = session.profileOwnership
            state = session.state; endedAt = session.endedAt
            isComplete = session.transcriptIsComplete; sidecar = session.resultSidecarReference
            latestAttempt = session.processingAttempts.last; speakers = session.speakers
            segments = session.transcriptSegments; gaps = session.transcriptCoverageGaps
        }
    }

    /// Saved screens must not run the contextual attribution pass inside SwiftUI body.
    /// Keep the pure projection cancellable and join its worker before returning.
    static func readingParagraphs(for session: MeetingSession) async throws -> [DisplayParagraph] {
        let projection = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let segments = session.transcriptSegments.enumerated().filter { !$0.element.isEcho }.sorted {
                ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
            }.map(\.element)
            let paragraphs = self.displayParagraphs(for: segments, in: session)
            try Task.checkCancellation()
            return paragraphs
        }
        return try await withTaskCancellationHandler {
            let result = try await projection.value
            try Task.checkCancellation()
            return result
        } onCancel: { projection.cancel() }
    }

    static func json(for session: MeetingSession) throws -> Data {
        let speakers = session.activeSpeakers.map {
            ExportedSpeaker(id: $0.id, displayName: $0.displayName, isLocalUser: $0.isLocalUser,
                usesCustomDisplayName: $0.usesCustomDisplayName, identityIsProvisional: $0.identityIsProvisional)
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
                    isUserTextEdited: $0.isUserTextEdited,
                    isUserSpeakerAssigned: $0.isUserSpeakerAssigned,
                    speakerIdentityIsProvisional: $0.speakerIdentityIsProvisional,
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
            title: session.displayTitle,
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

    /// Eligibility follows the recording's frozen publication policy, independently of
    /// settings for future recordings. An unprotected archive cannot acquire a privacy
    /// declaration merely because its export omits the original-text field.
    static func canExportProtectedTranscript(_ session: MeetingSession) -> Bool {
        session.state == .completed && session.piiRedactionEnabled == true
            && session.transcriptSegments.allSatisfy { $0.originalText == nil }
    }

    enum PortableExportError: LocalizedError {
        case protectedTranscriptRequired, invalidTranscript, limitExceeded

        var errorDescription: String? {
            switch self {
            case .protectedTranscriptRequired:
                return PichiLocalization.text("A protected transcript export requires a completed meeting captured with sensitive data redaction enabled.")
            case .invalidTranscript:
                return PichiLocalization.text("This meeting cannot be exported in the portable transcript format.")
            case .limitExceeded:
                return PichiLocalization.text("This transcript exceeds the portable export limits.")
            }
        }
    }

    /// Portable handoff uses an explicit allowlist instead of the canonical evidence
    /// export. No audio, paths, original text, identity suggestions or inference evidence
    /// can enter this schema. Its turns are the same reading projection as the saved UI.
    static func protectedTranscriptJSON(for session: MeetingSession) throws -> Data {
        try Task.checkCancellation()
        guard canExportProtectedTranscript(session) else { throw PortableExportError.protectedTranscriptRequired }
        let maximumBytes = 750_000
        let maximumTextUnits = 100_000
        let durationSeconds = session.duration
        let title = session.displayTitle
        guard title.utf16.count <= 200, session.languageCode.utf16.count <= 35,
              session.activeSpeakers.allSatisfy({ $0.displayName.utf16.count <= 200 })
        else { throw PortableExportError.limitExceeded }
        guard session.startedAt.timeIntervalSince1970.isFinite,
              session.endedAt?.timeIntervalSince1970.isFinite != false,
              durationSeconds.isFinite, durationSeconds >= 0,
              Set(session.speakers.map(\.id)).count == session.speakers.count,
              Set(session.transcriptSegments.map(\.id)).count == session.transcriptSegments.count
        else { throw PortableExportError.invalidTranscript }

        var textUnits = 0
        for segment in session.transcriptSegments where !segment.isEcho {
            guard segment.status == .final, segment.start.timescale > 0, segment.end.timescale > 0,
                  segment.start.seconds.isFinite, segment.end.seconds.isFinite,
                  segment.start.seconds >= 0, segment.end.seconds >= segment.start.seconds
            else { throw PortableExportError.invalidTranscript }
            textUnits += segment.text.utf16.count
            guard textUnits <= maximumTextUnits else { throw PortableExportError.limitExceeded }
        }
        let ordered = session.transcriptSegments.enumerated().filter { !$0.element.isEcho }.sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        try Task.checkCancellation()
        let paragraphs = displayParagraphs(for: ordered, in: session)
        try Task.checkCancellation()
        guard paragraphs.count <= 10_000 else { throw PortableExportError.limitExceeded }
        let presentations = speakerPresentations(in: session)
        textUnits = 0
        let segments = try paragraphs.map { paragraph in
            textUnits += paragraph.text.utf16.count
            guard textUnits <= maximumTextUnits else { throw PortableExportError.limitExceeded }
            // Group envelopes use actual member bounds. A paragraph is not a native word
            // or utterance unit, so native precision, timing and unit IDs are all omitted.
            return PortableTranscript.Segment(
                id: paragraph.id,
                startSeconds: paragraph.segments.map { $0.start.seconds }.min()!,
                endSeconds: paragraph.segments.map { $0.end.seconds }.max()!,
                speakerID: presentations[paragraph.id]?.participantID,
                text: paragraph.text)
        }
        let usedParticipantIDs = Set(segments.compactMap(\.speakerID))
        var exportSpeakers = session.readableSpeakers.filter {
            usedParticipantIDs.contains($0.id) || $0.identityIsProvisional != true
                || $0.diarizationClusterID != nil || $0.usesCustomDisplayName == true || $0.isLocalUser
        }
        var exportedIDs = Set(exportSpeakers.map(\.id))
        for paragraph in paragraphs {
            if let speaker = paragraph.projectedSpeakerRecord, exportedIDs.insert(speaker.id).inserted {
                exportSpeakers.append(speaker)
            }
        }
        let document = PortableTranscript(
            sessionID: session.id, title: title, languageCode: session.languageCode,
            startedAt: session.startedAt, endedAt: session.endedAt, durationSeconds: durationSeconds,
            speakers: exportSpeakers.map {
                .init(id: $0.id, displayName: $0.displayName, isLocalUser: $0.isLocalUser,
                    identityIsProvisional: $0.identityIsProvisional)
            }, segments: segments)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(document)
        try Task.checkCancellation()
        guard data.count <= maximumBytes else { throw PortableExportError.limitExceeded }
        return data
    }

    /// Like readingParagraphs, sharing must not run contextual attribution on the UI
    /// actor. Join the worker on cancellation before any share file is staged.
    static func protectedTranscriptJSONForSharing(for session: MeetingSession) async throws -> Data {
        try Task.checkCancellation()
        let export = Task.detached(priority: .userInitiated) {
            try protectedTranscriptJSON(for: session)
        }
        return try await withTaskCancellationHandler {
            let result = try await export.value
            try Task.checkCancellation()
            return result
        } onCancel: { export.cancel() }
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
        guard seconds.isFinite, seconds >= 0, let total = Int(exactly: seconds.rounded(.down)) else { return "00:00" }
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
    var usesCustomDisplayName: Bool?
    var identityIsProvisional: Bool?
}

/// A separate DTO is necessary because the full JSON export intentionally preserves
/// canonical evidence that must never be handed to a transcript-only importer.
nonisolated private struct PortableTranscript: Encodable {
    let format = "pichi-voice-transcript"
    let schemaVersion = 1
    let sessionID: UUID
    let title: String
    let languageCode: String
    let startedAt: Date
    let endedAt: Date?
    let durationSeconds: TimeInterval
    let speakers: [Speaker]
    let segments: [Segment]
    let privacy = Privacy()

    struct Speaker: Encodable {
        let id: UUID
        let displayName: String
        let isLocalUser: Bool
        let identityIsProvisional: Bool?
    }

    struct Segment: Encodable {
        let id: UUID
        let startSeconds: TimeInterval
        let endSeconds: TimeInterval
        let speakerID: UUID?
        let text: String
    }

    struct Privacy: Encodable {
        let transcriptPIIRedacted = true
        let includesAudio = false
        let metadataMayContainPersonalData = true
    }
}

private struct ExportedSegment: Codable {
    var id: MeetingTranscriptSegmentID
    var startSeconds: TimeInterval
    var endSeconds: TimeInterval
    var speakerID: SessionSpeakerID?
    var text: String
    var isUserTextEdited: Bool?
    var isUserSpeakerAssigned: Bool?
    var speakerIdentityIsProvisional: Bool?
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
