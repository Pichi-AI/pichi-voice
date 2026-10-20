import Foundation

/// Model-free regression for renewing an existing contextual identity, never admitting one.
@main
struct MeetingKnownSpeakerRegistryTests {
    typealias Tail = MeetingStreamingProtectedWordTail
    static let attempt = UUID(uuidString: "00000000-0000-0000-0000-000000000141")!
    static let epoch = MeetingAnalysisEpochID(
        trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000142")!, ordinal: 0)
    static var checks = 0

    struct Fixture {
        var words: [MeetingTranscriptSegment]
        var speakers: [MeetingSessionSpeaker]
        let activity: [MeetingBackendSpeakerActivity]
        let target: Int
        let duration: Double
    }

    static func check(_ condition: Bool, _ message: String = #function, line: Int = #line) {
        checks += 1
        guard condition else { fatalError("Line \(line): \(message)") }
    }

    static func token(_ label: String, epoch: MeetingAnalysisEpochID = Self.epoch) -> MeetingBackendSpeakerToken {
        .init(analysisEpochID: epoch, label: label)
    }

    static func word(_ id: Int, _ start: Double, _ end: Double,
                     _ assignment: MeetingBackendSpeakerAssignment) -> MeetingTranscriptSegment {
        .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012lld", Int64(id)))!,
            start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
            end: .init(value: Int64((end * 1_000).rounded()), timescale: 1_000), sourceTrackID: epoch.trackID,
            speakerID: nil, text: "Synthetic-\(id)", revision: 0, status: .final, overlap: .none,
            completeness: .complete, attributionState: .unassigned,
            nativePrecision: .word, nativeUnitID: "synthetic-\(id)", nativeSpeakerAssignment: assignment,
            nativeTiming: .init(start: start, end: end))
    }

    static func established(attempt: UUID = Self.attempt) throws -> [MeetingSessionSpeaker] {
        let transcript = MeetingPCMTranscriptBatch(segments: [word(1, 0, 6, .unassigned), word(2, 7, 13, .unassigned)])
        var speakers = try MeetingPCMRecordingAttribution.assemble(transcript: transcript,
            activity: [.init(token: token("a"), start: 0, end: 6), .init(token: token("b"), start: 7, end: 13)],
            epoch: epoch, attemptID: attempt, duration: 13, speakerNameFormat: "Speaker %lld").speakers
        let index = speakers.firstIndex { $0.diarizationClusterID?.hasSuffix(":b") == true }!
        speakers[index].displayName = "Синтетический Ёж"
        speakers[index].diarizationEmbedding = [0.1, 0.2]
        speakers[index].isLocalUser = true
        return speakers
    }

    static func fixture(_ mode: Int = 0) throws -> Fixture {
        let a = token("a"), b = token("b"), c = token("c"), d = token("d")
        var words: [MeetingTranscriptSegment]
        var activity: [MeetingBackendSpeakerActivity]
        let target: Int, duration: Double
        if mode == 1 {
            words = [word(10, 20, 26, .assigned(a)), word(11, 26, 26.2, .unassigned),
                     word(12, 26.2, 26.6, .assigned(b))]
            activity = [.init(token: a, start: 20, end: 26), .init(token: b, start: 26.2, end: 26.6)]
            target = 1; duration = 26.6
        } else {
            let assignment: MeetingBackendSpeakerAssignment = mode == 2 ? .ambiguous([c, d]) : .unassigned
            words = [word(10, 20, 26, .assigned(a)), word(11, 26.1, 26.3, .assigned(b)),
                     word(12, 26.3, 26.4, assignment), word(13, 26.4, 26.6, .assigned(b))]
            activity = [.init(token: a, start: 20, end: 26), .init(token: b, start: 26.1, end: 26.3),
                        .init(token: b, start: 26.4, end: 26.6)]
            if mode == 2 {
                activity += [.init(token: c, start: 26.3, end: 26.4), .init(token: d, start: 26.3, end: 26.4)]
            }
            target = 2; duration = 26.6
        }
        let speakers = try established()
        let ids = Dictionary(uniqueKeysWithValues: speakers.map { speaker in
            (speaker.diarizationClusterID!.hasSuffix(":a") ? a : b, speaker.id)
        })
        let units = words.map { source in
            MeetingFinalTextUnit(id: source.nativeUnitID!, trackID: epoch.trackID, analysisEpochID: epoch,
                precision: .word, text: source.text, analysisStart: source.nativeTiming!.start,
                analysisEnd: source.nativeTiming!.end, speaker: source.nativeSpeakerAssignment!, analysisSpanIDs: [])
        }
        let decision = try MeetingSpeakerAttribution.resolve(units: units, activity: activity)
            .first { $0.unitID == words[target].nativeUnitID }!
        check(decision.selectedToken == b)
        words[target].speakerID = ids[b]
        words[target].attributionState = .assigned
        words[target].speakerAttribution = .init(decision: decision, speakerIDs: ids)
        return Fixture(words: words, speakers: speakers, activity: activity, target: target, duration: duration)
    }

    static func run(_ fixture: Fixture) throws -> Tail.Update {
        var tail = try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld",
                            priorSpeakers: fixture.speakers)
        return try tail.update(safeWords: .init(segments: fixture.words), activity: fixture.activity,
            watermarks: .init(asrStableThrough: fixture.duration, diarizationProcessedThrough: fixture.duration,
                              privacySafeThrough: fixture.duration), attemptID: attempt, epoch: epoch)
    }

    static func changingSummary(_ source: MeetingTranscriptSpeakerAttribution,
                                _ key: String, _ value: Any) throws -> MeetingTranscriptSpeakerAttribution {
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(source)) as! [String: Any]
        object[key] = value
        return try JSONDecoder().decode(MeetingTranscriptSpeakerAttribution.self,
            from: JSONSerialization.data(withJSONObject: object))
    }

    static func main() throws {
        try matchingAutomaticContext()
        try manualAndMalformedMetadata()
        try safetyAndSourceScopes()
        try registryScopes()
        try noNewIdentityAndNativeEvidence()
        print("Known contextual speaker registry: \(checks) checks passed")
    }

    static func matchingAutomaticContext() throws {
        for mode in 0..<3 {
            let input = try fixture(mode), original = input.words[input.target]
            let result = try run(input), output = result.inserted[input.target]
            check(output.speakerID == original.speakerID, "The same automatic contextual identity disappeared")
            check(output.speakerAttribution?.selectedSpeakerID == original.speakerID)
            check(output.speakerAttribution?.selectedToken == original.speakerAttribution?.selectedToken)
            check(output.attributionState == .assigned)
            check(output.nativeUnitID == original.nativeUnitID && output.nativeSpeakerAssignment == original.nativeSpeakerAssignment)
            check(output.nativeTiming == original.nativeTiming && output.start == original.start && output.end == original.end)
            check(output.text == original.text && output.originalText == original.originalText)
            check(output.status == original.status && output.completeness == original.completeness)
            let identity = result.speakers.first { $0.id == original.speakerID }!
            check(identity.displayName == "Синтетический Ёж" && identity.isLocalUser)
            check(identity.diarizationEmbedding == nil, "The tail retained a voice tensor")
            let merged = MeetingPCMTranscriptBatch(segments: [], speakers: result.speakers).mergingSpeakers(into: input.speakers)
            check(merged.first { $0.id == original.speakerID }?.diarizationEmbedding == [0.1, 0.2])
            if mode == 2 { check(output.overlap == .ambiguous && output.speakerAttribution?.candidates.count == 2) }
        }
    }

    static func manualAndMalformedMetadata() throws {
        for change in 0..<15 {
            var input = try fixture()
            var source = input.words[input.target]
            switch change {
            case 0: source.speakerAttribution = nil
            case 1: source.isUserTextEdited = true
            case 2: source.originalText = "Legacy manual correction"
            case 3: source.speakerID = UUID()
            case 4: source.nativeUnitID = "mismatching-native-id"
            case 5: source.nativeSpeakerAssignment = .assigned(token("a"))
            case 6: source.speakerAttribution = try changingSummary(source.speakerAttribution!, "policyFingerprint", "different")
            case 7: source.speakerAttribution = try changingSummary(source.speakerAttribution!, "selectedSpeakerID", UUID().uuidString)
            case 8: source.speakerAttribution = try changingSummary(source.speakerAttribution!, "unitID", "different")
            case 9: source.nativePrecision = .utterance
            case 10, 11, 12:
                let foreignEpoch = change == 10
                    ? MeetingAnalysisEpochID(trackID: epoch.trackID, ordinal: 1)
                    : change == 11 ? MeetingAnalysisEpochID(trackID: epoch.trackID, ordinal: 0, generation: 1)
                    : MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
                let foreign = try JSONSerialization.jsonObject(with: JSONEncoder().encode(token("b", epoch: foreignEpoch)))
                source.speakerAttribution = try changingSummary(source.speakerAttribution!, "selectedToken", foreign)
            case 13:
                source.speakerAttribution = try changingSummary(source.speakerAttribution!, "policyVersion", 99)
            default:
                source.speakerAttributionInference = .init(rule: .surroundingSpeaker, originalState: .unassigned,
                    originalOverlap: .none, precedingSegmentID: UUID(), followingSegmentID: UUID())
            }
            input.words[input.target] = source
            check(try run(input).inserted[input.target].speakerID == nil, "Manual or mismatching provenance regained a contextual ID")
        }
    }

    static func safetyAndSourceScopes() throws {
        for change in 0..<6 {
            var input = try fixture()
            switch change {
            case 0: input.words[input.target].completeness = .incompleteTrack
            case 1: input.words[input.target].status = .provisional
            case 2: input.words[input.target].isLikelyEcho = true
            case 3: input.words[input.target].attributionState = .timingUncertain
            case 4: input.words[input.target].nativeTiming = .init(start: 26.31, end: 26.4)
            default: input.words[input.target].attributionState = .unassigned
            }
            check(try run(input).inserted[input.target].speakerID == nil, "An unsafe source regained a contextual ID")
        }
        var foreign = try fixture()
        foreign.words[foreign.target].sourceTrackID = UUID()
        do { _ = try run(foreign); check(false, "Foreign source was accepted") }
        catch let error as Tail.Failure { check(error == .invalidWord) }
    }

    static func registryScopes() throws {
        for change in 0..<7 {
            var input = try fixture()
            let index = input.speakers.firstIndex { $0.id == input.words[input.target].speakerID }!
            var known = input.speakers[index]
            switch change {
            case 0:
                known.id = MeetingTranscriptAssembler.speakerID(attemptID: UUID(), token: token("b"))
                input.words[input.target].speakerID = known.id
                input.words[input.target].speakerAttribution = try changingSummary(
                    input.words[input.target].speakerAttribution!, "selectedSpeakerID", known.id.uuidString)
            case 1: known.diarizationClusterID = "\(MeetingAnalysisEpochID(trackID: epoch.trackID, ordinal: 1)):b"
            case 2: known.diarizationClusterID = "\(MeetingAnalysisEpochID(trackID: epoch.trackID, ordinal: 0, generation: 1)):b"
            case 3: known.diarizationClusterID = "\(MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)):b"
            case 4: known.mergedIntoSpeakerID = input.speakers.first { $0.id != known.id }!.id
            case 5: known.trackKind = .applicationAudio
            default:
                var duplicate = known; duplicate.id = UUID()
                input.speakers.append(duplicate)
            }
            input.speakers[index] = known
            check(try run(input).inserted[input.target].speakerID == nil, "Foreign, inactive or conflicting identity was reused")
        }
        var duplicatedID = try fixture()
        duplicatedID.speakers.append(duplicatedID.speakers[0])
        do { _ = try run(duplicatedID); check(false, "Duplicate registry UUID was accepted") }
        catch let error as Tail.Failure { check(error == .invalidConfiguration) }
    }

    static func noNewIdentityAndNativeEvidence() throws {
        var input = try fixture(), original = input.words[input.target]
        input.speakers.removeAll { $0.id == original.speakerID }
        check(try run(input).inserted[input.target].speakerID == nil, "Context admitted a new short voice")
        input = try fixture()
        original = input.words[input.target]
        input.words[input.target].nativeSpeakerAssignment = .assigned(token("a"))
        check(try run(input).inserted[input.target].speakerID == nil, "Clean native assignment was treated as an automatic gap")
        check(input.words[input.target].speakerID == original.speakerID,
              "A failed contextual restoration mutated the source value")
    }
}
