import Foundation

/// A bounded PCM window's durable result. PCM ownership ends before the next checkpoint;
/// only normal meeting transcript/speaker records leave the inference adapter.
nonisolated struct MeetingPCMTranscriptBatch: Sendable {
    var segments: [MeetingTranscriptSegment]
    var speakers: [MeetingSessionSpeaker]
    var sourceTrack: MeetingAudioTrack? = nil
    var isComplete: Bool
    /// Ephemeral, conservatively filtered held text. This is not a canonical
    /// segment and must never enter storage, search, summaries or exports.
    var livePreview: MeetingLivePartial? = nil
    /// Ephemeral ASR observation metadata. True only after this audio window seals.
    var speechObservationIsFinal = false
    init(segments: [MeetingTranscriptSegment], speakers: [MeetingSessionSpeaker] = [], isComplete: Bool = true) {
        self.segments = segments
        self.speakers = speakers
        self.isComplete = isComplete
    }
}
