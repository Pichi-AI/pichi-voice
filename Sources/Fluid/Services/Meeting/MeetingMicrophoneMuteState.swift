import Foundation

/// Last observed meeting transition. Online capture starts enabled and retains that state
/// until an explicit mute/unmute signal changes it; missing UI does not introduce a new state.
nonisolated enum MeetingMicrophoneMuteState: String, Equatable, Sendable {
    case notApplicable
    case unmuted
    case muted

    var admitsMicrophone: Bool { self == .notApplicable || self == .unmuted }
}
