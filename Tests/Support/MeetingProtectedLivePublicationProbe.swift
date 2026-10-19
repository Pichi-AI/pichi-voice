import Foundation

// Only application composition is inert. The runner inserts the actual live value types,
// generation/session guards and publication callback from MeetingSessionCoordinator.
nonisolated struct MeetingSpeakerPresentation: Sendable, Equatable {}
// PRODUCTION_LIVE_VALUE_TYPES

@MainActor final class MeetingProtectedLivePublicationProbe {
    struct Session { let id: UUID }
    var memoryCheckpointGeneration: UUID?
    var activeSession: Session?
    var liveTranscript = MeetingLiveTranscriptSnapshot.empty
    var reconciliationCount = 0
    var trace: MeetingTimelineTrace?

    func reconcilePendingSpeech() { reconciliationCount += 1 }

    func preview(session: Session, generation: UUID) -> (MeetingLivePartial?) throws -> Void {
        // PRODUCTION_PROTECTED_PREVIEW_CALLBACK
    }
}
