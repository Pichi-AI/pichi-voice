import Foundation

/// Extends the existing persisted meeting lifecycle without another inference pipeline.
/// Only the current recording's admitted reading is an input. Native labels remain estimates.
nonisolated enum MeetingAutomaticNaming {
    static let minimumDuration: TimeInterval = 1_800
    static let minimumTextCharacters = 1_500
    static let maximumTextBytes = 4 * 1_024 * 1_024
    static let maximumSegments = 100_000

    /// Validate supported derived metadata at the existing application reading boundary.
    /// Unknown versions remain untouched and display their persisted title snapshot.
    static func validatingMetadata(in source: MeetingSession) -> MeetingSession {
        guard let artifact = source.automaticTitle,
              artifact.algorithmVersion == MeetingUniversalTitleEngine.algorithmVersion else { return source }
        guard MeetingUniversalTitleEngine.catalog.contains(where: {
            $0.candidateID == artifact.candidateID && $0.localizationKey == artifact.localizationKey && !$0.isFallback
        }) else {
            // Do not localize arbitrary persisted text. This display-only normalization does
            // not overwrite an unknown or damaged artifact in the original manifest.
            var session = source
            session.automaticTitle = nil
            session.defaultTitleBase = nil
            return session
        }
        return source
    }

    static func applying(to source: MeetingSession) -> MeetingSession {
        guard source.automaticTitle == nil,
              source.defaultTitleBase != nil,
              source.state == .completed,
              !source.isLocalContentConcealed,
              let endedAt = source.endedAt,
              endedAt.timeIntervalSince(source.startedAt) >= self.minimumDuration,
              source.transcriptSegments.count <= self.maximumSegments else { return source }

        // Bound additional title work before building a reading projection or joined copy.
        var bytes = 0
        for segment in source.transcriptSegments {
            let count = segment.text.utf8.count
            guard count <= self.maximumTextBytes - bytes else { return source }
            bytes += count
        }
        let ordered = source.transcriptSegments.enumerated().filter {
            !$0.element.isEcho && $0.element.hasReadableContent
        }.sorted {
            ($0.element.start, $0.element.end, $0.offset) < ($1.element.start, $1.element.end, $1.offset)
        }.map(\.element)
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: ordered, in: source)
        let text = paragraphs.map(\.text).joined(separator: "\n\n")
        guard text.count >= self.minimumTextCharacters, text.utf8.count <= self.maximumTextBytes else { return source }
        let names = Dictionary(source.activeSpeakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
        let turns = paragraphs.map { paragraph in
            let presentation = MeetingTranscriptExporter.speakerPresentation(for: paragraph, in: source, speakerNames: names)
            return MeetingUniversalTitleEngine.Turn(speaker: presentation.participantID?.uuidString, text: paragraph.text)
        }
        let selected = MeetingUniversalTitleEngine.select(.init(text: text, turns: turns))
        guard !selected.isFallback else { return source }
        var session = source
        session.automaticTitle = .init(algorithmVersion: MeetingUniversalTitleEngine.algorithmVersion,
            candidateID: selected.candidateID, localizationKey: selected.localizationKey,
            previousTitle: source.title, previousDefaultTitleBase: source.defaultTitleBase)
        // Persist a useful current-language snapshot for existing non-UI readers. UI rendering
        // resolves the stable catalog key without translating any recorded speech.
        session.title = session.displayTitle(language: PichiLocalization.language)
        return session
    }
}
