import Foundation

/// Synthetic canonical evidence, not a model-quality test or a replay of user speech.
@main struct MeetingProvisionalSpeakerIdentityTests {
    typealias Tail = MeetingStreamingProtectedWordTail
    static let attempt = UUID(uuidString: "00000000-0000-0000-0000-000000009001")!
    static let trackID = UUID(uuidString: "00000000-0000-0000-0000-000000009002")!
    static let epoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 0)
    static let a = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "a")
    static let b = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "b")
    static var checks = 0
    static func check(_ value: Bool, _ message: String = #function, line: Int = #line) {
        checks += 1
        if !value { fatalError("Line \(line): \(message)") }
    }
    static func word(_ index: Int, _ start: Double, _ end: Double) -> MeetingTranscriptSegment {
        .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0003-%012lld", Int64(index)))!,
            start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
            end: .init(value: Int64((end * 1_000).rounded()), timescale: 1_000), sourceTrackID: trackID,
            speakerID: nil, text: "synthetic-\(index)", revision: 0, status: .final,
            overlap: .none, completeness: .complete, attributionState: .unassigned,
            nativePrecision: .word, nativeUnitID: "synthetic-\(index)", nativeSpeakerAssignment: .unassigned,
            nativeTiming: .init(start: start, end: end))
    }
    static func marks(_ end: Double) -> Tail.Watermarks {
        .init(asrStableThrough: end, diarizationProcessedThrough: end, privacySafeThrough: end)
    }
    static func update(_ tail: inout Tail, _ words: [MeetingTranscriptSegment],
                       _ activity: [MeetingBackendSpeakerActivity], end: Double) throws -> Tail.Update {
        try tail.update(safeWords: .init(segments: words), activity: activity, watermarks: marks(end),
            attemptID: attempt, epoch: epoch, activityAvailableFrom: tail.retainActivityFrom)
    }
    static func session(words: [MeetingTranscriptSegment], speakers: [MeetingSessionSpeaker]) -> MeetingSession {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var value = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")), timebase: timebase)
        value.audioTracks = [.init(id: trackID, kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])]
        value.transcriptSegments = words
        value.speakers = speakers
        return value
    }
    static func main() throws {
        try recoveryAndPartitions()
        try shortTokenQualification()
        try refinementRetiresOnlyUncommittedIdentity()
        try boundariesCapacityAndAtomicity()
        try compatibility()
        print("Provisional speaker identities: \(checks) checks passed")
    }
    static func recoveryAndPartitions() throws {
        // A four-second unscored speech passage includes normal pauses over 0.8 seconds.
        // Its return to the old native slot is an uncertain match, not a confirmed identity.
        let starts = [262.441, 262.961, 263.321, 263.481, 264.841, 264.961, 265.841, 266.161]
        let ends = [262.481, 263.001, 263.361, 263.921, 264.881, 265.001, 265.881, 266.201]
        let unknown = zip(starts, ends).enumerated().map { word(10 + $0.offset, $0.element.0, $0.element.1) }
        let words = [word(0, 250, 262.3)] + unknown
            + [word(30, 266.321, 266.6), word(31, 267.84, 268.2), word(32, 270, 270.4),
               word(33, 270.5, 270.7), word(34, 270.8, 271)]
        let activity = [MeetingBackendSpeakerActivity(token: a, start: 250, end: 262.3),
                        .init(token: a, start: 266.321, end: 268.2), .init(token: b, start: 270, end: 270.4)]
        var expected: [SessionSpeakerID?]?
        for cut in [words.count, 5, 9, 10] {
            var tail = try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld")
            let firstEnd = cut == words.count ? 272 : words[cut - 1].nativeTiming!.end
            let firstActivity = activity.compactMap { item -> MeetingBackendSpeakerActivity? in
                let end = min(firstEnd, item.end)
                return end > item.start ? .init(token: item.token, start: item.start, end: end) : nil
            }
            let first = try update(&tail, Array(words.prefix(cut)), firstActivity, end: firstEnd)
            var published = first.inserted
            var finalSpeakers = first.speakers
            if cut < words.count {
                let second = try update(&tail, Array(words.dropFirst(cut)), activity, end: 272)
                published += second.inserted
                for revision in second.revisions {
                    if let index = published.firstIndex(where: { $0.id == revision.segmentID }) { try revision.apply(to: &published[index]) }
                }
                finalSpeakers = second.speakers
            }
            let final = try tail.finish(activity: activity, watermarks: marks(272), attemptID: attempt,
                epoch: epoch, activityAvailableFrom: tail.retainActivityFrom)
            for revision in final.revisions {
                if let index = published.firstIndex(where: { $0.id == revision.segmentID }) { try revision.apply(to: &published[index]) }
            }
            check(published.allSatisfy { $0.speakerID != nil })
            let provisionalID = published[1].speakerID
            check(provisionalID != published[0].speakerID)
            check(published[1...10].allSatisfy { $0.speakerID == provisionalID && $0.speakerIdentityIsProvisional == true })
            check(published[9].nativeSpeakerAssignment == words[9].nativeSpeakerAssignment
                && published[9].nativeTiming == words[9].nativeTiming, "Recovery invented native evidence")
            check(published[11].speakerID != provisionalID, "A different actual token did not end recovery")
            check(published[12].speakerID == published[13].speakerID && published[12].speakerID != provisionalID,
                "The final unresolved bout lost its own stable identity")
            if let expected { check(published.map(\.speakerID) == expected, "Batch partitions changed provisional identities") }
            else { expected = published.map(\.speakerID) }
            var saved = session(words: published, speakers: finalSpeakers)
            try saved.validateTranscriptStructure()
            let reopened = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(saved))
            try reopened.validateTranscriptStructure()
            check(reopened.transcriptSegments == saved.transcriptSegments && reopened.speakers == saved.speakers)
            let before = saved.transcriptSegments[1]
            try saved.reassignSegment(id: before.id, to: saved.speakers[0].id)
            let corrected = saved.transcriptSegments[1]
            check(corrected.isUserSpeakerAssigned == true)
            check(try !MeetingPCMTranscriptBatch.SpeakerRevision(before).apply(to: &saved.transcriptSegments[1]),
                "A delayed provisional callback undid a manual correction")
            check(saved.transcriptSegments[1] == corrected)
            // Undo restores the original complete value; automatic patches never changed it.
            saved.transcriptSegments[1] = before
            check(saved.transcriptSegments[1] == reopened.transcriptSegments[1])
            try saved.setLocalUserSpeaker(id: provisionalID, speakerNameFormat: "Speaker %lld")
            try saved.validateTranscriptStructure()
            check(saved.speakers.first { $0.id == provisionalID }?.identityIsProvisional == false)
        }
    }
    static func shortTokenQualification() throws {
        var tail = try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld")
        var firstID: SessionSpeakerID?
        for index in 0..<6 {
            let start = Double(index * 20)
            let words = [word(100 + index * 2, start, start + 6), word(101 + index * 2, start + 6.1, start + 6.2)]
            let native = try MeetingPCMRecordingAttribution.assemble(transcript: .init(segments: words),
                activity: [.init(token: a, start: start, end: start + 6), .init(token: b, start: start + 6.1, end: start + 7.1)],
                epoch: epoch, attemptID: attempt, duration: start + 20, speakerNameFormat: "Speaker %lld")
            let result = try update(&tail, native.segments,
                [.init(token: a, start: start, end: start + 6), .init(token: b, start: start + 6.1, end: start + 7.1)], end: start + 20)
            let short = result.inserted.last!
            check(short.speakerID != nil && short.speakerID != result.inserted.first?.speakerID)
            if let firstID { check(short.speakerID == firstID) } else { firstID = short.speakerID }
            let identity = result.speakers.first { $0.id == short.speakerID }!
            check(identity.identityIsProvisional == (index < 4))
            check(short.speakerIdentityIsProvisional == (index < 4 ? true : nil))
            check(!identity.isLocalUser)
            if index == 0 {
                var explicitOwner = session(words: result.inserted, speakers: result.speakers)
                try explicitOwner.setLocalUserSpeaker(id: short.speakerID, speakerNameFormat: "Speaker %lld")
                try explicitOwner.validateTranscriptStructure()
                check(explicitOwner.speakers.first { $0.id == short.speakerID }?.identityIsProvisional == false)
            }
        }
    }
    static func boundariesCapacityAndAtomicity() throws {
        var overlapping = try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld")
        let cluster = try update(&overlapping,
            [word(400, 0, 0.5), word(401, 0.3, 0.8), word(402, 0.6, 1.1)], [], end: 2)
        check(Set(cluster.inserted.compactMap(\.speakerID)).count == 1,
            "Overlapping ASR word envelopes manufactured one identity per word")
        var tail = try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld")
        var identities = Set<SessionSpeakerID>()
        for index in 0..<140 {
            let start = Double(index * 10)
            let result = try update(&tail, [word(500 + index, start, start + 0.2)], [], end: start + 10)
            check(result.inserted[0].speakerIdentityIsProvisional == true)
            identities.insert(result.inserted[0].speakerID!)
            check(tail.retainedAdmissionTokenCount == 0)
        }
        check(identities.count == 140, "Provisional people were capped by the voice-profile budget")
        var bounded = try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld",
            limits: .init(maximumSpeakers: 1))
        _ = try update(&bounded, [word(900, 0, 0.2)], [], end: 10)
        let cursor = bounded.committedThrough
        do {
            _ = try update(&bounded, [word(901, 10, 10.2)], [], end: 20)
            check(false, "Participant overflow silently dropped a label")
        } catch Tail.Failure.speakerLimit { check(bounded.committedThrough == cursor) }
    }
    static func refinementRetiresOnlyUncommittedIdentity() throws {
        let main = word(950, 0, 6), gap = word(951, 6.1, 6.3), reply = word(952, 6.4, 7)
        var tail = try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld")
        let first = try update(&tail, [main, gap], [.init(token: a, start: 0, end: 6)], end: 6.3)
        let preliminary = first.inserted[1].speakerID!
        let second = try update(&tail, [reply], [.init(token: a, start: 0, end: 6),
            .init(token: b, start: 6.4, end: 7)], end: 7)
        let target = second.inserted[0].speakerID!
        check(second.revisions.first { $0.segmentID == gap.id }?.speakerID == target)
        check(second.speakers.first { $0.id == preliminary }?.mergedIntoSpeakerID == target,
            "Fully refined preliminary identity remained a ghost participant")
        check(second.speakers.filter { $0.mergedIntoSpeakerID == nil }.count == 2)
        let merged = MeetingPCMTranscriptBatch(segments: [], speakers: second.speakers).mergingSpeakers(into: first.speakers)
        check(merged.first { $0.id == preliminary }?.mergedIntoSpeakerID == target)
        check(merged.first { $0.id == target }?.generatedParticipantNumber == 2)
    }
    static func compatibility() throws {
        let old = MeetingSpeakerAttributionPolicy()
        var json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as! [String: Any]
        json["enableProvisionalSpeakerIdentities"] = nil
        let decoded = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONSerialization.data(withJSONObject: json))
        check(!decoded.enableProvisionalSpeakerIdentities && decoded.fingerprint == old.fingerprint)
        check(decoded.fingerprint != MeetingSpeakerAttributionPolicy.standard.fingerprint)
    }
}
