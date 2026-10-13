import Foundation

/// A bounded PCM window's durable result. PCM ownership ends before the next checkpoint;
/// only normal meeting transcript/speaker records leave the inference adapter.
nonisolated struct MeetingPCMTranscriptBatch: Sendable {
    var segments: [MeetingTranscriptSegment]
    var speakers: [MeetingSessionSpeaker]
    var sourceTrack: MeetingAudioTrack? = nil
    var isComplete: Bool
    init(segments: [MeetingTranscriptSegment], speakers: [MeetingSessionSpeaker] = [], isComplete: Bool = true) {
        self.segments = segments
        self.speakers = speakers
        self.isComplete = isComplete
    }
}
