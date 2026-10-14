import CryptoKit
import Foundation

nonisolated enum MeetingSummaryInput {
    /// Shared template input/prompt contract for remote and on-device saved results.
    static let currentPromptVersion = 2

    /// The capture language is source metadata, independent of the app's interface language.
    /// Unknown/automatic codes must not turn Locale's default language into an output request.
    static func transcriptLanguageName(_ languageCode: String) -> String? {
        let code = Locale.LanguageCode(languageCode.trimmingCharacters(in: .whitespacesAndNewlines).lowercased())
        guard Locale.LanguageCode.isoLanguageCodes.contains(code),
              ![Locale.LanguageCode.unidentified, .uncoded, .multiple, .unavailable].contains(code),
              let name = Locale(identifier: "en_US_POSIX").localizedString(forLanguageCode: code.identifier)
        else { return nil }
        return "\(name) (\(code.identifier))"
    }

    static func transcriptLanguageDescription(_ languageCode: String) -> String {
        self.transcriptLanguageName(languageCode) ?? "Infer from the spoken transcript text"
    }

    static func transcript(for session: MeetingSession, timeZone: TimeZone? = nil) -> String {
        let names = Dictionary(uniqueKeysWithValues: session.activeSpeakers.map { ($0.id, $0.displayName) })
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        if let timeZone { formatter.timeZone = timeZone }
        formatter.dateStyle = .long
        formatter.timeStyle = .none
        let date = formatter.string(from: session.startedAt)
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        let time = formatter.string(from: session.startedAt)
        // A saved meeting keeps whole seconds. Count the same way here, so the text (and the fingerprint
        // that decides whether a saved summary is still shown) is the same before and after a restart.
        let startSeconds = session.startedAt.timeIntervalSinceReferenceDate.rounded(.down)
        let endSeconds = (session.endedAt ?? session.startedAt).timeIntervalSinceReferenceDate.rounded(.down)
        let duration = max(0, (endSeconds - startSeconds) / 60)
        let turns = session.transcriptSegments.filter { !$0.isEcho }.sorted { $0.start.seconds < $1.start.seconds }
        return """
        Title: \(session.title)
        Date: \(date)
        Time: \(time)
        Duration: \(Int(duration)) minutes
        Transcript language: \(Self.transcriptLanguageDescription(session.languageCode))
        Participants: \(session.activeSpeakers.map(\.displayName).joined(separator: ", "))
        ----------
        """ + "\n" + turns.map {
            "**\(MeetingTranscriptExporter.speakerLabel(for: $0, in: session, speakerNames: names))**: \($0.text)"
        }.joined(separator: "\n")
    }

    static func fingerprint(_ text: String) -> String {
        SHA256.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}
