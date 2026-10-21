import Foundation

/// A bounded PCM window's durable result. PCM ownership ends before the next checkpoint;
/// only normal meeting transcript/speaker records leave the inference adapter.
nonisolated struct MeetingPCMTranscriptBatch: Sendable {
    enum SpeakerRevisionFailure: Error { case identityMismatch, revisionOverflow }
    /// A patch cannot overwrite a concurrent correction to text, native evidence, status or
    /// completeness. Apply it to the latest product segment through the existing store owner.
    struct SpeakerRevision: Equatable, Sendable {
        let segmentID: MeetingTranscriptSegmentID
        let speakerID: SessionSpeakerID?
        let overlap: MeetingTranscriptOverlap
        let attributionState: MeetingTranscriptAttributionState?
        let speakerAttribution: MeetingTranscriptSpeakerAttribution?

        init(_ segment: MeetingTranscriptSegment) {
            self.segmentID = segment.id
            self.speakerID = segment.speakerID
            self.overlap = segment.overlap
            self.attributionState = segment.attributionState
            self.speakerAttribution = segment.speakerAttribution
        }

        @discardableResult
        func apply(to segment: inout MeetingTranscriptSegment) throws -> Bool {
            guard segment.id == self.segmentID else { throw SpeakerRevisionFailure.identityMismatch }
            guard Self(segment) != self else { return false }
            guard segment.revision < Int.max else { throw SpeakerRevisionFailure.revisionOverflow }
            segment.speakerID = self.speakerID
            segment.overlap = self.overlap
            segment.attributionState = self.attributionState
            segment.speakerAttribution = self.speakerAttribution
            segment.revision += 1
            return true
        }
    }

    /// Speaker-only patches apply against the latest checkpoint, preserving edited text and
    /// immutable source evidence. Ordinary batches leave this additive capability empty.
    var speakerRevisions: [SpeakerRevision] = []

    /// Provenance of one growing physical PCM window. Native timing partitions
    /// can change between observations without starting a different hypothesis.
    nonisolated struct SpeechObservationIdentity: Equatable, Sendable {
        let attemptID: UUID
        let epochID: MeetingAnalysisEpochID
    }

    var segments: [MeetingTranscriptSegment]
    var speakers: [MeetingSessionSpeaker]
    var sourceTrack: MeetingAudioTrack? = nil
    var isComplete: Bool
    /// Ephemeral, conservatively filtered held text. This is not a canonical
    /// segment and must never enter storage, search, summaries or exports.
    var livePreview: MeetingLivePartial? = nil
    /// Ephemeral source-clock acknowledgement. The streaming owner sets this only
    /// through joined ASR, acoustic and privacy admission. Apply after publishing its
    /// protected history; never serialize it as a word or use it for speaker identity.
    var protectedSourceThroughSample: Int? = nil
    /// Ephemeral ASR observation metadata. True only after this audio window seals.
    var speechObservationIsFinal = false
    /// Ephemeral only. Neither this identity nor unfiltered speech enters a session.
    var speechObservationIdentity: SpeechObservationIdentity? = nil
    /// Whether the provider supplied genuine word/segment bounds for this observation.
    /// False distinguishes the coarse whole-window placeholder from speech timing.
    /// Nil preserves the existing contract for callers without typed runtime metadata.
    var speechObservationHasNativeTiming: Bool? = nil

    /// A sealed observation can account for its accepted physical prefix. While
    /// it is growing, a coarse window end does not locate the displayed words.
    var permitsSpeechPreviewCoverage: Bool {
        speechObservationHasNativeTiming != false || speechObservationIsFinal
    }

    /// The no-redaction publication path uses the same coverage admission as
    /// contextual privacy. This preview remains ephemeral and never becomes a segment.
    func speechPreview(id: UUID) -> MeetingLivePartial? {
        let ordered = segments.sorted { $0.start < $1.start }
        return ordered.first.map {
            MeetingLivePartial(id: id, text: ordered.map(\.text).joined(separator: " "),
                start: $0.start.seconds,
                end: permitsSpeechPreviewCoverage ? ordered.map { $0.end.seconds }.max() : nil)
        }
    }

    init(segments: [MeetingTranscriptSegment], speakers: [MeetingSessionSpeaker] = [], isComplete: Bool = true) {
        self.segments = segments
        self.speakers = speakers
        self.isComplete = isComplete
    }

    /// Identity evidence can refine the owner marker after a speaker was first checkpointed.
    /// Reuse this merge in the runtime and durable checkpoint so promotion and revocation agree;
    /// an automatic observation never replaces user aliases, merges or identity corrections.
    func mergingSpeakers(into existing: [MeetingSessionSpeaker],
                         speakerNameFormat: String = PichiLocalization.text("Speaker %lld")) -> [MeetingSessionSpeaker] {
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
        // Apply numbering against the latest canonical aliases and owner flags. Delayed raw
        // observations may contain earlier generated numbers and must never restore them.
        return MeetingSessionSpeaker.numberingGeneratedParticipants(result, speakerNameFormat: speakerNameFormat)
    }
}
