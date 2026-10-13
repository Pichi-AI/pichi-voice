import Foundation

nonisolated enum MeetingAudioRetentionPolicy: String, Codable, CaseIterable, Sendable {
    case afterTranscription
    case days7
    case days30
    case never

    var displayName: String {
        switch self {
        case .afterTranscription: return "After transcription"
        case .days7: return "7 days"
        case .days30: return "30 days"
        case .never: return "Forever"
        }
    }

    var retentionDays: Int? {
        switch self {
        case .days7: return 7
        case .days30: return 30
        case .afterTranscription, .never: return nil
        }
    }

    func deadline(endedAt: Date?, startedAt: Date) -> Date? {
        let completedAt = endedAt ?? startedAt
        if self == .afterTranscription { return completedAt }
        guard let retentionDays else { return nil }
        return Calendar.current.date(byAdding: .day, value: retentionDays, to: completedAt)
    }

    /// Informational display value only; sweep deadlines always come from `deadline(endedAt:startedAt:)`.
    func retainUntil(startedAt: Date) -> Date? {
        guard let retentionDays else { return nil }
        return Calendar.current.date(byAdding: .day, value: retentionDays, to: startedAt)
    }
}
