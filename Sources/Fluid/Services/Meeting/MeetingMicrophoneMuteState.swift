import Foundation

/// Ephemeral capture status. It does not change stored transcripts or a meeting's source selection.
nonisolated enum MeetingMicrophoneMuteState: String, Equatable, Sendable {
    case notApplicable
    case checking
    case unmuted
    case muted
    case unknown

    var admitsMicrophone: Bool { self == .notApplicable || self == .unmuted }
}
