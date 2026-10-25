import Foundation

nonisolated enum MeetingSummaryKind: String, CaseIterable, Identifiable, Codable {
    case executive, detailed, actions, decisions, participants, topics, custom
    var id: String {
        self.rawValue
    }

    var title: String {
        switch self {
        case .executive: "Executive summary"
        case .detailed: "Detailed summary"
        case .actions: "Action items"
        case .decisions: "Key decisions"
        case .participants: "Participants"
        case .topics: "Topics discussed"
        case .custom: "Custom prompt"
        }
    }
}

/// Persisted template summary data shared by the coordinator and platform UI.
/// Storage migration must not require the macOS model/UI controller on iOS.
nonisolated struct MeetingSavedSummary: Codable {
    static let currentTranscriptHashVersion = 2

    var transcriptHash: String
    let modelID: String
    let text: String
    var providerID: String?
    var providerName: String?
    var configurationHash: String?
    var promptVersion: Int?
    var generatedAt: Date?
    /// Set for custom-prompt summaries, so an edited prompt does not show an older result.
    var promptHash: String?
    /// Display name of an on-device model, whose ID is not meant to be read.
    var modelName: String?
    /// Version 2 excludes the meeting title. A missing version uses the original full input.
    var transcriptHashVersion: Int?

    /// Summaries saved before providers were recorded came from the earlier on-device
    /// model, which was withdrawn for accuracy; they stay hidden. Older input/prompt
    /// contracts also require regeneration; their stored text is not deleted.
    func isCurrent(transcriptHash: String, promptHash: String?) -> Bool {
        self.providerID != nil && self.promptVersion == MeetingSummaryInput.currentPromptVersion
            && self.transcriptHash == transcriptHash && self.promptHash == promptHash
    }

    func isCurrent(session: MeetingSession, promptHash: String?) -> Bool {
        let hash: String
        switch self.transcriptHashVersion {
        case nil:
            hash = MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
        case Self.currentTranscriptHashVersion:
            hash = MeetingSummaryInput.contentFingerprint(for: session)
        default:
            return false
        }
        return self.isCurrent(transcriptHash: hash, promptHash: promptHash)
    }

    /// Upgrade before saving a rename, while the original title can still verify old files.
    /// Each upgrade remains valid even if a later write (including the rename) fails.
    static func migrateLegacySummaries(in directory: URL, for session: MeetingSession) throws {
        let legacyHash = MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: session))
        let contentHash = MeetingSummaryInput.contentFingerprint(for: session)
        for kind in MeetingSummaryKind.allCases {
            let url = directory.appendingPathComponent("manual-summary-\(kind.rawValue).json")
            guard var saved = try? JSONDecoder().decode(Self.self, from: Data(contentsOf: url)),
                  saved.transcriptHashVersion == nil,
                  saved.providerID != nil,
                  saved.promptVersion == MeetingSummaryInput.currentPromptVersion,
                  saved.transcriptHash == legacyHash
            else { continue }
            saved.transcriptHash = contentHash
            saved.transcriptHashVersion = Self.currentTranscriptHashVersion
            try JSONEncoder().encode(saved).write(to: url, options: .atomic)
        }
    }
}

