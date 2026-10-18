import Foundation

/// A locale-independent reading label, separate from microphone/application source routing.
/// Contains no text, timing or model state and never changes canonical speaker evidence.
nonisolated struct MeetingSpeakerPresentation: Sendable, Equatable {
    struct Name: Sendable, Equatable {
        let displayName: String
        let isLocalUser: Bool
    }

    enum CandidateRelation: Sendable, Equatable {
        case several, simultaneous, conflict
    }

    enum Label: Sendable, Equatable {
        case unknown
        case identified(Name)
        case estimated(Name)
        case interrupting(Name, background: [Name?])
        case candidates([Name?], relation: CandidateRelation)
    }

    /// Canonical readable-turn identity, independent of translated labels or per-word rules.
    let identity: String
    let label: Label
    /// Reading owner for actions and styling; never substituted into stored acoustic evidence.
    let participantID: SessionSpeakerID?

    init(identity: String, label: Label, participantID: SessionSpeakerID? = nil) {
        self.identity = identity
        self.label = label
        self.participantID = participantID
    }

    /// Preserve the whole turn's internal estimate marker without changing the visible name.
    func markingEstimated() -> Self {
        guard case let .identified(name) = label else { return self }
        return Self(identity: identity, label: .estimated(name), participantID: participantID)
    }

    var isEstimated: Bool {
        if case .estimated = label { return true }
        return false
    }
}
