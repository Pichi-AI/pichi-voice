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

    static func text(for session: MeetingSession, includeEchoes: Bool = false) -> String {
        let speakerNames = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let segments = session.transcriptSegments
            .filter { includeEchoes || !$0.isEcho }
            .enumerated().sorted {
                ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
            }.map(\.element)
        return self.displayParagraphs(for: segments, in: session).map { paragraph in
            let segment = paragraph.firstSegment
            let speaker = Self.speakerLabel(for: segment, in: session, speakerNames: speakerNames)
            return "[\(Self.timestampText(segment.start.seconds))] \(speaker): \(paragraph.text)"
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
        if segment.attributionState != .timingUncertain, let attribution = segment.speakerAttribution,
           attribution.selectedSpeakerID == segment.speakerID {
            func names(_ references: [MeetingTranscriptSpeakerReference]) -> String {
                references.map { reference in
                    Self.resolvedSpeakerName(reference.speakerID, in: session, speakerNames: speakerNames,
                        language: language, bundle: bundle)
                        ?? PichiLocalization.text("Unidentified voice", language: language, bundle: bundle)
                }.joined(separator: " + ")
            }
            if let selectedName = Self.resolvedSpeakerName(segment.speakerID, in: session,
                speakerNames: speakerNames, language: language, bundle: bundle) {
                if !attribution.background.isEmpty {
                    return PichiLocalization.format("%@ (interrupting; background: %@)", language: language,
                        bundle: bundle, arguments: [selectedName, names(attribution.background)])
                }
                if attribution.rule.isHeuristic {
                    return PichiLocalization.format("Estimated speaker: %@", language: language, bundle: bundle, arguments: [selectedName])
                }
                return selectedName
            }
            if attribution.candidates.count > 1 {
                let template: String
                switch attribution.relation {
                case .simultaneous: template = "Simultaneous speech: %@"
                case .conflict: template = "Speaker evidence conflicts: %@"
                default: template = "Several speakers: %@"
                }
                return PichiLocalization.format(template, language: language, bundle: bundle, arguments: [names(attribution.candidates)])
            }
        }
        guard let state = segment.attributionState else {
            if let name = resolvedSpeakerName(segment.speakerID, in: session, speakerNames: speakerNames, language: language, bundle: bundle) {
                return name
            }
            return PichiLocalization.text("Unknown speaker", language: language, bundle: bundle)
        }
        switch state {
        case .assigned:
            return Self.resolvedSpeakerName(segment.speakerID, in: session, speakerNames: speakerNames, language: language, bundle: bundle)
                ?? PichiLocalization.text("Unknown speaker", language: language, bundle: bundle)
        case .overlappingSpeakers, .unassigned, .timingUncertain:
            return PichiLocalization.text("Unknown speaker", language: language, bundle: bundle)
        }
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

    /// Input order is retained. Callers supply chronological, non-echo segments.
    /// Adjacent nil-speaker fragments can flow under the honest unknown-speaker label. Their
    /// distinct uncertainty states remain on every canonical member, not an invented identity.
    /// Identified speaker/state changes and source/evidence changes stay boundaries. Buffer size,
    /// elapsed time, pauses and line breaks are not evidence of a new speaker turn. Explicit line
    /// breaks remain in the text inside a turn without creating a second speaker header.
    static func displayParagraphs(for segments: [MeetingTranscriptSegment], in session: MeetingSession) -> [DisplayParagraph] {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        var paragraphs: [DisplayParagraph] = []
        var members: [MeetingTranscriptSegment] = []
        for segment in segments {
            let startsParagraph = members.last.map { previous in
                let bothUnknown = previous.speakerID == nil && segment.speakerID == nil
                return ((!bothUnknown || previous.speakerAttribution != nil || segment.speakerAttribution != nil)
                    && speakerLabelIdentity(for: previous, in: session, speakerNames: names)
                    != speakerLabelIdentity(for: segment, in: session, speakerNames: names))
                    || previous.sourceTrackID != segment.sourceTrackID
                    || previous.status != segment.status || previous.completeness != segment.completeness
                    || previous.isEcho != segment.isEcho
            } ?? false
            if startsParagraph {
                paragraphs.append(DisplayParagraph(segments: members))
                members = []
            }
            members.append(segment)
        }
        if !members.isEmpty { paragraphs.append(DisplayParagraph(segments: members)) }
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
                    nativePrecision: $0.nativePrecision,
                    nativeUnitID: $0.nativeUnitID,
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

    /// A segment may still point at a speaker that was merged away; walk the alias chain
    /// defensively even though post-merge segments are already repointed to the target. `nil`
    /// means no known speaker could be resolved, letting callers apply their own fallback label.
    private static func resolvedSpeakerName(
        _ speakerID: SessionSpeakerID?,
        in session: MeetingSession,
        speakerNames: [SessionSpeakerID: String],
        language: PichiInterfaceLanguage, bundle: Bundle
    ) -> String? {
        guard let resolvedID = speakerID.map({ Self.resolvedAliasID($0, in: session) }) else {
            return nil
        }
        if let owner = session.activeSpeakers.first(where: { $0.id == resolvedID && $0.isLocalUser }) {
            return self.speakerDisplayName(owner, language: language, bundle: bundle)
        }
        return speakerNames[resolvedID]
    }

    /// The same alias-chain walk as `resolvedSpeakerName`, but returning the id itself so JSON
    /// export never references a speaker absent from the exported `speakers` array.
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
    var nativePrecision: MeetingTextUnitPrecision?
    var nativeUnitID: String?
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
