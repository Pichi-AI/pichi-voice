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
        try contextualRecoveryAndNewFinalBout()
        try shortTokenQualification()
        try refinementRetiresOnlyUncommittedIdentity()
        try finalProtectedPublication()
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
    static func contextualRecoveryAndNewFinalBout() throws {
        let words = [word(8_000, 0, 6), word(8_001, 6.1, 8.1), word(8_002, 8.2, 10.1),
            word(8_003, 10.2, 10.4), word(8_004, 11.2, 11.4), word(8_005, 11.5, 11.6),
            word(8_006, 11.7, 12), word(8_007, 12.1, 12.3), word(8_008, 12.4, 12.6)]
        let activity = [MeetingBackendSpeakerActivity(token: a, start: 0, end: 6),
            .init(token: a, start: 10.2, end: 10.4), .init(token: a, start: 11.2, end: 11.4),
            .init(token: a, start: 11.7, end: 12)]
        let native = try MeetingPCMRecordingAttribution.assemble(transcript: .init(segments: words),
            activity: activity, epoch: epoch, attemptID: attempt, duration: 13, speakerNameFormat: "Speaker %lld")
        check(native.segments[5].nativeSpeakerAssignment == .unassigned)
        check(native.segments[5].speakerAttribution?.rule == .neighborAgreement)
        check(native.segments[5].speakerAttribution?.selectedToken == a)
        let final = try Tail.finalizingProtectedTranscript(native, attemptID: attempt, policy: .standard,
            speakerNameFormat: "Speaker %lld", epochForSegment: { _ in epoch })
        func verify(_ rows: [MeetingTranscriptSegment]) {
            let recovered = rows[1].speakerID
            check(recovered != nil && recovered != rows[0].speakerID)
            check(rows[1...6].allSatisfy { $0.speakerID == recovered && $0.speakerIdentityIsProvisional == true },
                "A same-token contextual gap dropped provisional recovery")
            check(rows[7].speakerID != recovered && rows[7].speakerID == rows[8].speakerID,
                "A new unresolved final turn inherited the recovered participant")
            check(rows.allSatisfy { $0.speakerID != nil })
            check(rows.map(\.nativeSpeakerAssignment) == native.segments.map(\.nativeSpeakerAssignment))
            check(rows.map(\.nativeTiming) == native.segments.map(\.nativeTiming))
            check(rows.map(\.speakerAttribution) == native.segments.map(\.speakerAttribution))
        }
        verify(final.segments)
        for cut in [native.segments.count, 5, 6] {
            var tail = try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld")
            let end = cut == native.segments.count ? 13 : native.segments[cut - 1].nativeTiming!.end
            let prefixActivity = activity.compactMap { entry -> MeetingBackendSpeakerActivity? in
                let clipped = min(entry.end, end)
                return clipped > entry.start ? .init(token: entry.token, start: entry.start, end: clipped) : nil
            }
            let first = try update(&tail, Array(native.segments.prefix(cut)), prefixActivity, end: end)
            var rows = first.inserted
            if cut < native.segments.count {
                let next = try update(&tail, Array(native.segments.dropFirst(cut)), activity, end: 13)
                rows += next.inserted
                for revision in next.revisions {
                    if let index = rows.firstIndex(where: { $0.id == revision.segmentID }) { try revision.apply(to: &rows[index]) }
                }
            }
            let stopped = try tail.finish(activity: activity, watermarks: marks(13), attemptID: attempt,
                epoch: epoch, activityAvailableFrom: tail.retainActivityFrom)
            for revision in stopped.revisions {
                if let index = rows.firstIndex(where: { $0.id == revision.segmentID }) { try revision.apply(to: &rows[index]) }
            }
            verify(rows)
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
        check(first.speakers.first { $0.id == preliminary }?.generatedParticipantNumber == 2)
        let second = try update(&tail, [reply], [.init(token: a, start: 0, end: 6),
            .init(token: b, start: 6.4, end: 7)], end: 7)
        let target = second.inserted[0].speakerID!
        check(second.speakers.first { $0.id == target }?.generatedParticipantNumber == 3,
            "A new identity cannot recycle a preliminary participant's reserved number")
        check(second.revisions.first { $0.segmentID == gap.id }?.speakerID == target)
        check(second.speakers.first { $0.id == preliminary }?.mergedIntoSpeakerID == target,
            "Fully refined preliminary identity remained a ghost participant")
        check(second.speakers.filter { $0.mergedIntoSpeakerID == nil }.count == 2)
        let merged = MeetingPCMTranscriptBatch(segments: [], speakers: second.speakers).mergingSpeakers(into: first.speakers)
        check(merged.first { $0.id == preliminary }?.mergedIntoSpeakerID == target)
        check(merged.first { $0.id == target }?.generatedParticipantNumber == 3,
            "Refinement must preserve the target's issued number rather than renumber it")
        check(merged.first { $0.id == preliminary }?.generatedParticipantNumber == 2,
            "Retired identity provenance keeps its original reserved number")
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

    static func finalProtectedPublication() throws {
        let otherTrack = UUID(uuidString: "00000000-0000-0000-0000-000000009003")!
        let nextEpoch = MeetingAnalysisEpochID(trackID: trackID, ordinal: 1)
        let applicationEpoch = MeetingAnalysisEpochID(trackID: otherTrack, ordinal: 0)
        var rows = [word(1_000, 0, 0.4), word(1_001, 0.6, 1), word(1_002, 1.1, 1.4), word(1_003, 1.5, 1.8)]
        rows[2].nativeSpeakerAssignment = .ambiguous([a, b])
        rows[3].sourceTrackID = otherTrack
        let scopes = [rows[0].id: epoch, rows[1].id: nextEpoch, rows[2].id: nextEpoch, rows[3].id: applicationEpoch]
        let input = MeetingPCMTranscriptBatch(segments: rows)
        let final = try Tail.finalizingProtectedTranscript(input, attemptID: attempt, policy: .standard,
            speakerNameFormat: "Speaker %lld", trackKinds: [otherTrack: .applicationAudio],
            epochForSegment: { scopes[$0.id] })
        check(final.segments.allSatisfy { $0.speakerID != nil && $0.speakerIdentityIsProvisional == true })
        check(final.segments[0].speakerID != final.segments[1].speakerID, "A reset epoch reused an unknown identity")
        check(final.segments[1].speakerID == final.segments[2].speakerID, "Ambiguous words lost their bout identity")
        check(final.segments[2].speakerID != final.segments[3].speakerID, "Different capture sources shared an unknown identity")
        check(final.speakers.first { $0.id == final.segments[3].speakerID }?.trackKind == .applicationAudio)
        for (before, after) in zip(rows, final.segments) {
            check(before.text == after.text && before.nativeSpeakerAssignment == after.nativeSpeakerAssignment
                && before.nativeTiming == after.nativeTiming && before.speakerAttribution == after.speakerAttribution)
        }
        let again = try Tail.finalizingProtectedTranscript(final, attemptID: attempt, policy: .standard,
            speakerNameFormat: "Speaker %lld", epochForSegment: { scopes[$0.id] })
        check(again.segments == final.segments && again.speakers == final.speakers)
        let legacy = try Tail.finalizingProtectedTranscript(input, attemptID: attempt, policy: .init(),
            speakerNameFormat: "Speaker %lld", epochForSegment: { scopes[$0.id] })
        check(legacy.segments == rows && legacy.speakers.isEmpty)
        let withGap = try Tail.finalizingProtectedTranscript(.init(segments: Array(rows.prefix(2))),
            attemptID: attempt, policy: .standard, speakerNameFormat: "Speaker %lld",
            barriersByTrack: [trackID: [.init(start: 0.4, end: 0.5)]], epochForSegment: { _ in epoch })
        check(withGap.segments[0].speakerID != withGap.segments[1].speakerID, "Coverage barrier did not split preliminary identity")
        let nestedRows = [word(1_100, 1, 4), word(1_101, 3, 3.2), word(1_102, 3.1, 3.3)]
        let nestedBarrier = try Tail.finalizingProtectedTranscript(.init(segments: nestedRows),
            attemptID: attempt, policy: .standard, speakerNameFormat: "Speaker %lld",
            barriersByTrack: [trackID: [.init(start: 2, end: 2.5)]], epochForSegment: { _ in epoch })
        check(nestedBarrier.segments[0].speakerID != nestedBarrier.segments[1].speakerID,
            "A prior enclosing word consumed a nested excluded interval")
        check(nestedBarrier.segments[1].speakerID == nestedBarrier.segments[2].speakerID)
        let noNestedBarrier = try Tail.finalizingProtectedTranscript(.init(segments: nestedRows),
            attemptID: attempt, policy: .standard, speakerNameFormat: "Speaker %lld", epochForSegment: { _ in epoch })
        check(Set(noNestedBarrier.segments.compactMap(\.speakerID)).count == 1,
            "Ordinary nested word envelopes split a continuous preliminary bout")
        // Cross both the word-count and text-byte working bounds without splitting a bout.
        var long = (0..<4_200).map { index in word(2_000 + index, Double(index) * 0.1, Double(index) * 0.1 + 0.04) }
        for index in long.indices { long[index].text = String(repeating: "x", count: 300) }
        let bounded = try Tail.finalizingProtectedTranscript(.init(segments: long), attemptID: attempt,
            policy: .standard, speakerNameFormat: "Speaker %lld", epochForSegment: { _ in epoch })
        check(bounded.speakers.count == 1 && Set(bounded.segments.compactMap(\.speakerID)).count == 1)
        let raw = try MeetingTranscriptAssembler(speakerNameFormat: "Speaker %lld").assemblePCMWindow(
            attemptID: attempt, epoch: epoch, offset: 0, duration: 1,
            units: [.init(id: "raw", trackID: trackID, analysisEpochID: epoch, precision: .word,
                text: "raw", analysisStart: 0, analysisEnd: 0.4, speaker: .unassigned, analysisSpanIDs: [])])
        check(raw.segments[0].speakerID == nil && raw.speakers.isEmpty,
            "Raw PCM assembly minted a durable unknown identity before privacy admission")
        let recoveryRows = [word(7_000, 0, 6), word(7_001, 6.1, 8.1), word(7_002, 8.2, 10.1), word(7_003, 10.2, 10.4)]
        let native = try MeetingPCMRecordingAttribution.assemble(transcript: .init(segments: recoveryRows),
            activity: [.init(token: a, start: 0, end: 6), .init(token: a, start: 10.2, end: 10.4)],
            epoch: epoch, attemptID: attempt, duration: 11, speakerNameFormat: "Speaker %lld")
        let unsafeEpoch = try Tail.finalizingProtectedTranscript(native, attemptID: attempt, policy: .standard,
            speakerNameFormat: "Speaker %lld", contextualBarrierEpochIDs: [epoch], epochForSegment: { _ in epoch })
        check(unsafeEpoch.segments[1].speakerID == unsafeEpoch.segments[2].speakerID,
            "Unplaceable quarantine manufactured one identity per admitted unknown word")
        check(unsafeEpoch.segments[1].speakerID != unsafeEpoch.segments[0].speakerID)
        check(unsafeEpoch.segments[3].speakerID == unsafeEpoch.segments[0].speakerID,
            "Unsafe epoch reused contextual preceding-token recovery")
        check(unsafeEpoch.segments.map(\.nativeSpeakerAssignment) == native.segments.map(\.nativeSpeakerAssignment))
    }
}
