import Foundation

@main
struct MeetingSpeakerContinuityTests {
    static let track = UUID(), firstSpeaker = UUID(), nextSpeaker = UUID()

    static func segment(_ start: Double, _ end: Double, _ speaker: UUID?, text: String = "word") -> MeetingTranscriptSegment {
        .init(id: UUID(), start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
            end: .init(value: Int64((end * 1_000).rounded()), timescale: 1_000), sourceTrackID: track,
            speakerID: speaker, text: text, revision: 0, status: .final, overlap: .none,
            completeness: .complete, attributionState: speaker == nil ? .unassigned : .assigned)
    }

    static func resolve(_ input: [MeetingTranscriptSegment],
                        epochs: [UUID: MeetingAnalysisEpochID]? = nil,
                        barriers: [MeetingAssemblyCoverageGap] = []) throws -> [MeetingTranscriptSegment] {
        try MeetingTranscriptSpeakerContinuity.resolve(input,
            epochs: epochs ?? Dictionary(uniqueKeysWithValues: input.map { ($0.id, .init(trackID: $0.sourceTrackID, ordinal: 0)) }),
            barriers: barriers)
    }

    static func main() async throws {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        let same = [segment(0, 0.4, firstSpeaker), segment(0.45, 0.6, nil), segment(0.65, 1, firstSpeaker)]
        let filled = try resolve(same)
        check(filled[1].speakerID == firstSpeaker, "Same-speaker bookends fill the unknown")
        check(filled[1].speakerAttributionInference?.rule == .surroundingSpeaker, "Inference is explicit")
        check(filled[1].speakerAttributionInference?.precedingSegmentID == same[0].id, "Left anchor is persisted")
        check(filled[1].speakerAttributionInference?.followingSegmentID == same[2].id, "Right anchor is persisted")
        let boundary = [segment(0, 0.4, firstSpeaker), segment(0.4, 0.6, nil), segment(0.6, 0.8, nil), segment(0.8, 1, nextSpeaker)]
        let handoff = try resolve(boundary)
        check(handoff[1].speakerID == nextSpeaker && handoff[2].speakerID == nextSpeaker,
              "The complete multiword gap belongs to the incoming speaker")
        check(handoff[1].speakerAttributionInference?.rule == .incomingSpeaker, "Handoff rule is recorded")
        var overlap = same
        overlap[1].attributionState = .overlappingSpeakers
        overlap[1].overlap = .ambiguous
        let shortOverlap = try resolve(overlap)
        check(shortOverlap[1].speakerID == firstSpeaker && shortOverlap[1].overlap == .none,
              "A bounded ambiguous boundary follows the authorized readability rule")
        check(shortOverlap[1].speakerAttributionInference?.originalOverlap == .ambiguous
                && shortOverlap[1].speakerAttributionInference?.originalState == .overlappingSpeakers,
              "Original ambiguity survives the contextual assignment")
        check(try resolve(filled) == filled, "Applying the policy twice cannot cascade")
        check(try resolve([segment(0, 0.2, nil), segment(0.2, 0.4, firstSpeaker), segment(0.4, 0.6, nil)]).filter { $0.speakerID == nil }.count == 2,
              "Leading and trailing unknowns require both anchors")
        let pause = [segment(0, 0.2, firstSpeaker), segment(1.1, 1.3, nil), segment(1.3, 1.5, firstSpeaker)]
        check(try resolve(pause) == pause, "A pause is a continuity boundary")
        let long = [segment(0, 0.2, firstSpeaker), segment(0.2, 3.21, nil), segment(3.21, 3.5, firstSpeaker)]
        check(try resolve(long) == long, "Long overlap or uncertainty is not relabelled")
        var many = same
        many[1].text = "one two three four five six"
        check(try resolve(many) == many, "Word limit is independent of segment count")
        var uncertain = same
        uncertain[1].attributionState = .timingUncertain
        check(try resolve(uncertain) == uncertain, "Uncertain timing cannot infer an identity")
        var provisional = same
        provisional[1].status = .provisional
        check(try resolve(provisional) == provisional, "Live provisional text cannot trigger the final rule")
        var incomplete = same
        incomplete[1].completeness = .incompleteTrack
        check(try resolve(incomplete) == incomplete, "Incomplete coverage remains explicit")
        var echo = same
        echo[1].isLikelyEcho = true
        check(try resolve(echo) == echo, "Echo words cannot be borrowed into a speaker turn")
        var crossedTrack = same
        crossedTrack[1].sourceTrackID = UUID()
        check(try resolve(crossedTrack) == crossedTrack, "Tracks never share speaker guesses")
        var epochs = Dictionary(uniqueKeysWithValues: same.map { ($0.id, MeetingAnalysisEpochID(trackID: track, ordinal: 0)) })
        epochs[same[2].id] = .init(trackID: track, ordinal: 1)
        check(try resolve(same, epochs: epochs) == same, "Capture epochs never share guesses")
        check(try resolve(same, barriers: [.init(trackID: track, start: 0.61, end: 0.64, reason: .inadmissibleCaptureEra)]) == same,
              "Excluded coverage is a barrier even when the neighboring timestamps are close")
        var genuineOverlap = same
        genuineOverlap[1].start = .init(value: 0, timescale: 1)
        check(try resolve(genuineOverlap) == genuineOverlap, "Meaningful simultaneous text is not an adjacent gap")
        var inferredAnchor = filled
        inferredAnchor.append(segment(1, 1.2, nil))
        inferredAnchor.append(segment(1.2, 1.4, nextSpeaker))
        inferredAnchor[2].speakerAttributionInference = filled[1].speakerAttributionInference
        check(try resolve(inferredAnchor)[3].speakerID == nil, "An inferred anchor cannot support another guess")
        for index in same.indices {
            check(filled[index].id == same[index].id && filled[index].text == same[index].text
                    && filled[index].start == same[index].start && filled[index].end == same[index].end
                    && filled[index].revision == same[index].revision,
                  "Text, IDs, redaction, timing and revision stay unchanged")
        }
        let encoded = try JSONEncoder().encode(filled)
        check(try JSONDecoder().decode([MeetingTranscriptSegment].self, from: encoded) == filled,
              "Inference metadata round-trips with the real persisted codec")
        let legacy = try JSONEncoder().encode(same)
        check(!String(decoding: legacy, as: UTF8.self).contains("speakerAttributionInference"), "Old schema stays additive")
        let cancellation = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try resolve(same)
        }
        do { _ = try await cancellation.value; preconditionFailure("Cancelled inference must not publish") }
        catch is CancellationError { checks += 1 }
        print("Speaker continuity checks passed: \(checks)")

        // Explicit offline audit only. The source session is never overwritten.
        if CommandLine.arguments.count == 3 {
            let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
            var session = try decoder.decode(MeetingSession.self,
                from: Data(contentsOf: URL(fileURLWithPath: CommandLine.arguments[1])))
            precondition(session.audioTracks.count == 1 && session.transcriptTimeDomain == .meetingRelative,
                         "Audit input must be an explicit single-track whole-recording result")
            let before = session.transcriptSegments
            session.transcriptSegments = try resolve(before)
            let encoder = JSONEncoder(); encoder.dateEncodingStrategy = .iso8601
            try encoder.encode(session).write(to: URL(fileURLWithPath: CommandLine.arguments[2]), options: .atomic)
            let remaining = session.transcriptSegments.filter { $0.speakerID == nil }.count
            let inferred = session.transcriptSegments.filter { $0.speakerAttributionInference != nil }.count
            print("Offline audit segments=\(before.count) inferred=\(inferred) remainingUnknown=\(remaining)")
        }
    }
}
