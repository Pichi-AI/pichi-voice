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

    /// Identity evidence can refine the owner marker after a speaker was first checkpointed.
    /// Reuse this merge in the runtime and durable checkpoint so promotion and revocation agree;
    /// an automatic observation never replaces user aliases, merges or identity corrections.
    func mergingSpeakers(into existing: [MeetingSessionSpeaker]) -> [MeetingSessionSpeaker] {
        var result = existing
        var indices = Dictionary(existing.enumerated().map { ($0.element.id, $0.offset) }, uniquingKeysWith: { first, _ in first })
        for speaker in self.speakers {
            if let index = indices[speaker.id] {
                result[index].isLocalUser = speaker.isLocalUser
            } else if result.count < MeetingSpeakerVoiceSamples.maximumProfiles {
                indices[speaker.id] = result.count
                result.append(speaker)
            }
        }
        return result
    }
}
