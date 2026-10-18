import Foundation

/// Synthetic tests establish reconciliation invariants, not recognition or voice accuracy.
@main
struct MeetingStreamingProtectedWordTailTests {
    typealias Tail = MeetingStreamingProtectedWordTail
    static let attempt = UUID(uuidString: "00000000-0000-0000-0000-000000000091")!
    static let epoch = MeetingAnalysisEpochID(trackID: UUID(uuidString: "00000000-0000-0000-0000-000000000001")!, ordinal: 0)
    static var checks = 0

    static func check(_ value: Bool, _ message: String = #function, line: Int = #line) {
        checks += 1
        guard value else { fatalError("Line \(line): \(message)") }
    }

    static func word(_ index: Int, _ start: Double, _ end: Double, text: String? = nil) -> MeetingTranscriptSegment {
        .init(id: UUID(uuidString: String(format: "00000000-0000-0000-0001-%012lld", Int64(index)))!,
            start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
            end: .init(value: Int64((end * 1_000).rounded()), timescale: 1_000),
            sourceTrackID: epoch.trackID, speakerID: nil, text: text ?? "safe-\(index)",
            originalText: "Edited <PERSON>", revision: 2, status: .final,
            overlap: .none, completeness: .complete, attributionState: .unassigned,
            nativePrecision: .word, nativeUnitID: "native-\(index)", nativeSpeakerAssignment: .unassigned,
            nativeTiming: .init(start: start, end: end))
    }

    static func activity(_ label: String, _ start: Double, _ end: Double) -> MeetingBackendSpeakerActivity {
        .init(token: .init(analysisEpochID: epoch, label: label), start: start, end: end)
    }

    static func marks(_ end: Double) -> Tail.Watermarks {
        .init(asrStableThrough: end, diarizationProcessedThrough: end, privacySafeThrough: end)
    }

    static func update(_ tail: inout Tail, words: [MeetingTranscriptSegment] = [],
        activity: [MeetingBackendSpeakerActivity] = [], end: Double) throws -> Tail.Update {
        try tail.update(safeWords: .init(segments: words), activity: activity,
            watermarks: marks(end), attemptID: attempt, epoch: epoch)
    }

    static func tail(limits: Tail.Limits = .init(), prior: [MeetingSessionSpeaker] = []) throws -> Tail {
        try Tail(attemptID: attempt, epoch: epoch, speakerNameFormat: "Speaker %lld", limits: limits, priorSpeakers: prior)
    }

    static func expect(_ expected: Tail.Failure, _ operation: () throws -> Void) {
        do { try operation(); check(false, "Expected \(expected)") }
        catch let error as Tail.Failure { check(error == expected, "Unexpected \(error), expected \(expected)") }
        catch { check(false, "Unexpected error: \(error)") }
    }

    static func main() async throws {
        try futureAnchorAndPatches()
        try interruptionsAndSafety()
        try exactWordBoundary()
        try scopesCursorsAndLimits()
        try independentWatermarksAndTextBound()
        try finalization()
        try knownIdentity()
        try knownNeighborIdentity()
        try knownNeighborSafety()
        try knownContinuationIdentityAndPartitions()
        try alternatingContinuationPartitions()
        try longStream(mode: 0)
        try longStream(mode: 1)
        try longStream(mode: 2)
        try await cancellation()
        print("Protected streaming word tail: \(checks) checks passed")
    }

    static func futureAnchorAndPatches() throws {
        var value = try tail()
        let original = [word(0, 0, 0.8, text: "<PERSON>"), word(1, 0.8, 1, text: "по")]
        let a = activity("a", 0, 0.8)
        let first = try update(&value, words: original, activity: [a], end: 1)
        check(first.inserted.map(\.id) == original.map(\.id))
        check(first.inserted[1].speakerID == nil)
        check(first.provisionalSpeakerIDs == original.map(\.id))
        check(first.committedIDs.isEmpty)
        let repeatUpdate = try update(&value, words: original, activity: [a], end: 1)
        check(repeatUpdate.inserted.isEmpty && repeatUpdate.revisions.isEmpty)
        let next = word(2, 1, 1.8, text: "теперь")
        let second = try update(&value, words: [next], activity: [a, activity("b", 1, 1.8)], end: 1.8)
        check(second.inserted.count == 1 && second.revisions.count == 1)
        let patch = second.revisions[0]
        check(patch.segmentID == original[1].id && patch.speakerAttribution?.rule == .incomingSpeaker)
        check(patch.speakerID == second.inserted[0].speakerID && patch.speakerID != first.inserted[0].speakerID)
        var concurrent = first.inserted[1]
        concurrent.text = "User corrected <EMAIL>"
        concurrent.originalText = "Original safe <PERSON>"
        concurrent.revision += 1
        concurrent.completeness = .incompleteTrack
        let before = concurrent
        check(try patch.apply(to: &concurrent))
        var expected = before
        expected.speakerID = concurrent.speakerID
        expected.overlap = concurrent.overlap
        expected.attributionState = concurrent.attributionState
        expected.speakerAttribution = concurrent.speakerAttribution
        expected.revision += 1
        check(concurrent == expected, "A speaker revision changed protected/user-edited source fields")
        check(!(try patch.apply(to: &concurrent)), "Identical metadata must not bump revision")
        for (source, emitted) in zip(original, first.inserted) {
            check(source.text == emitted.text && source.originalText == emitted.originalText)
            check(source.nativeTiming == emitted.nativeTiming && source.nativeUnitID == emitted.nativeUnitID)
            check(source.nativeSpeakerAssignment == emitted.nativeSpeakerAssignment)
            check(source.status == emitted.status && source.start == emitted.start && source.end == emitted.end)
        }
        let drained = try update(&value, activity: [a, activity("b", 1, 1.8)], end: 8)
        check(drained.committedIDs == original.map(\.id) + [next.id])
        check(drained.provisionalSpeakerIDs.isEmpty && drained.committedThrough == 1.8)
        let unchanged = try update(&value, activity: [a, activity("b", 1, 1.8)], end: 8)
        check(unchanged.revisions.isEmpty && unchanged.committedIDs.isEmpty)
    }

    static func interruptionsAndSafety() throws {
        let words = [word(10, 0, 0.2), word(11, 0.3, 0.8), word(12, 0.9, 1.1)]
        let activity = [activity("a", 0, 1.1), activity("b", 0.4, 0.6)]
        var value = try tail()
        let beforeAnchor = try update(&value, words: Array(words.prefix(2)), activity: [
            Self.activity("a", 0, 0.8), Self.activity("b", 0.4, 0.6)], end: 0.8)
        check(beforeAnchor.inserted[1].speakerAttribution?.rule != .mainSpeakerContinuation)
        let result = try update(&value, words: [words[2]], activity: activity, end: 1.1)
        let mixed = result.revisions.first { $0.segmentID == words[1].id }
        check(mixed?.speakerAttribution?.rule == .mainSpeakerContinuation)
        check(mixed?.speakerAttribution?.background.isEmpty == true)
        check(mixed?.speakerAttribution?.selectedToken?.label == "a")
        check(mixed?.speakerAttribution?.rawAssignment.tokens.count == 2)
        check(mixed?.overlap == .ambiguous)
        for unsafeIndex in [0, 1, 2] {
            var unsafe = words
            unsafe[unsafeIndex].completeness = .incompleteTrack
            var protected = try tail()
            let blocked = try update(&protected, words: unsafe, activity: activity, end: 1.1)
            check(blocked.inserted[1].speakerAttribution?.rule != .mainSpeakerContinuation)
            check(blocked.inserted.map(\.completeness) == unsafe.map(\.completeness))
        }
        var hiddenThird = try tail()
        let blocked = try update(&hiddenThird, words: words,
            activity: activity + [Self.activity("c", 0.21, 0.25)], end: 1.1)
        check(blocked.inserted[1].speakerAttribution?.rule == .mainSpeakerContinuation)
        check(blocked.inserted[1].speakerAttribution?.selectedToken?.label == "a")
    }

    static func exactWordBoundary() throws {
        var value = try tail()
        let source = [word(20, 0, 0.5, text: "апдейтов,"), word(21, 0.5, 0.8, text: "к сожалению,"),
                      word(22, 0.8, 1, text: "нет."), word(23, 1.1, 1.5, text: "Ничего страшного")]
        let output = try update(&value, words: source,
            activity: [activity("a", 0, 1), activity("b", 1.1, 1.5)], end: 1.5)
        check(output.inserted[2].speakerID == output.inserted[0].speakerID)
        check(output.inserted[2].speakerID != output.inserted[3].speakerID)
        check(output.inserted.map(\.nativeTiming) == source.map(\.nativeTiming))
        var rounded = try tail()
        let precise = word(24, 0, 0.1996)
        let initial = try update(&rounded, words: [precise], activity: [activity("a", 0, 0.1996)], end: 0.1996)
        check(initial.inserted[0].end.seconds == 0.2 && initial.inserted[0].nativeTiming?.end == 0.1996)
        let final = try rounded.finish(activity: [activity("a", 0, 0.1996)], watermarks: marks(0.1996),
            attemptID: attempt, epoch: epoch)
        check(final.committedIDs == [precise.id] && final.retainActivityFrom == 0.1996)
    }

    static func scopesCursorsAndLimits() throws {
        var value = try tail(limits: .init(maximumRetainedWords: 2))
        let source = word(30, 0, 0.2)
        _ = try update(&value, words: [source], end: 0.2)
        expect(.staleAttempt) {
            _ = try value.update(safeWords: .init(segments: []), activity: [], watermarks: marks(1),
                attemptID: UUID(), epoch: epoch)
        }
        var staleBatch = MeetingPCMTranscriptBatch(segments: [])
        staleBatch.speechObservationIdentity = .init(attemptID: UUID(), epochID: epoch)
        expect(.staleAttempt) {
            _ = try value.update(safeWords: staleBatch, activity: [], watermarks: marks(1),
                attemptID: attempt, epoch: epoch)
        }
        expect(.regressedWatermark) { _ = try update(&value, end: 0.1) }
        expect(.invalidWatermark) { _ = try update(&value, end: .nan) }
        var changed = source; changed.text = "Different protected text"
        expect(.conflictingWord) { _ = try update(&value, words: [changed], end: 0.2) }
        expect(.retainedWordLimit) {
            _ = try update(&value, words: [word(31, 0.2, 0.3), word(32, 0.3, 0.4)], end: 0.4)
        }
        let validAfterFailure = try update(&value, words: [word(31, 0.2, 0.3)], end: 0.3)
        check(validAfterFailure.inserted.count == 1 && validAfterFailure.retainedWordCount == 2)
        _ = try update(&value, end: 10)
        expect(.wordBehindSafePrefix) { _ = try update(&value, words: [word(33, 0.4, 0.5)], end: 10) }
        expect(.incompleteActivitySnapshot) {
            _ = try value.update(safeWords: .init(segments: []), activity: [], watermarks: marks(10),
                attemptID: attempt, epoch: epoch, activityAvailableFrom: 10)
        }
        var bounded = try tail(limits: .init(maximumRetainedSeconds: 6))
        expect(.retainedTimeLimit) { _ = try update(&bounded, words: [word(34, 0, 6.1)], end: 6.1) }
        check(bounded.committedThrough == 0, "Limit failure changed the cursor")
        let retry = try update(&bounded, words: [word(35, 0, 0.2)], end: 0.2)
        check(retry.inserted.count == 1)
        var wrongEpoch = word(36, 0.2, 0.3)
        wrongEpoch.sourceTrackID = UUID()
        expect(.invalidWord) { _ = try update(&bounded, words: [wrongEpoch], end: 0.3) }
        var missingNative = word(38, 0.2, 0.3); missingNative.nativeTiming = nil
        expect(.invalidWord) { _ = try update(&bounded, words: [missingNative], end: 0.3) }
        let full = (0..<MeetingSpeakerVoiceSamples.maximumProfiles).map {
            MeetingSessionSpeaker(id: UUID(), displayName: "Known \($0)",
                diarizationClusterID: "\(epoch):known-\($0)", trackKind: .microphone,
                isLocalUser: false, identityCandidates: [])
        }
        var capacity = try tail(prior: full)
        expect(.speakerLimit) {
            _ = try update(&capacity, words: [word(37, 0, 1)], activity: [activity("new", 0, 1)], end: 1)
        }
        check(capacity.committedThrough == 0)
    }

    static func finalization() throws {
        var value = try tail()
        let unknown = word(40, 0, 0.2)
        _ = try update(&value, words: [unknown], end: 0.2)
        expect(.invalidWatermark) {
            _ = try value.finish(activity: [], watermarks: .init(asrStableThrough: 1,
                diarizationProcessedThrough: 1, privacySafeThrough: 0.2), attemptID: attempt, epoch: epoch)
        }
        let final = try value.finish(activity: [], watermarks: marks(0.2), attemptID: attempt, epoch: epoch)
        check(final.isFinal && final.committedIDs == [unknown.id])
        check(final.provisionalSpeakerIDs.isEmpty && final.retainedWordCount == 0)
        check(final.retainActivityFrom == 0.2)
        expect(.alreadyFinished) {
            _ = try value.finish(activity: [], watermarks: marks(0.2), attemptID: attempt, epoch: epoch)
        }
        expect(.alreadyFinished) { _ = try update(&value, end: 1) }
        var cancelled = try tail()
        _ = try update(&cancelled, words: [unknown], end: 0.2)
        cancelled.cancel()
        expect(.cancelled) { _ = try update(&cancelled, end: 1) }
    }

    static func independentWatermarksAndTextBound() throws {
        var value = try tail()
        let original = word(45, 0, 0.2)
        let first = try value.update(safeWords: .init(segments: [original]), activity: [activity("a", 0, 0.2)],
            watermarks: .init(asrStableThrough: 30, diarizationProcessedThrough: 0.2, privacySafeThrough: 0.2),
            attemptID: attempt, epoch: epoch)
        check(first.committedIDs.isEmpty)
        let held = try value.update(safeWords: .init(segments: []), activity: [activity("a", 0, 0.2)],
            watermarks: .init(asrStableThrough: 30, diarizationProcessedThrough: 30, privacySafeThrough: 0.2),
            attemptID: attempt, epoch: epoch)
        check(held.committedIDs.isEmpty, "Diarization cannot commit beyond the privacy-safe cursor")
        let ready = try update(&value, activity: [activity("a", 0, 0.2)], end: 30)
        check(ready.committedIDs == [original.id])
        var bounded = try tail(limits: .init(maximumRetainedTextBytes: 20))
        expect(.retainedTextLimit) { _ = try update(&bounded, words: [word(46, 0, 0.2, text: String(repeating: "ё", count: 20))], end: 0.2) }
        check(bounded.committedThrough == 0)
        expect(.invalidWatermark) {
            _ = try bounded.update(safeWords: .init(segments: []), activity: [],
                watermarks: .init(asrStableThrough: 0, diarizationProcessedThrough: 1, privacySafeThrough: 1),
                attemptID: attempt, epoch: epoch)
        }
    }

    static func knownIdentity() throws {
        let a = activity("a", 0, 6), b = activity("b", 7, 13)
        let established = try MeetingPCMRecordingAttribution.assemble(
            transcript: .init(segments: [word(50, 0, 6), word(51, 7, 13)]), activity: [a, b],
            epoch: epoch, attemptID: attempt, duration: 13, speakerNameFormat: "Speaker %lld")
        var known = established.speakers
        known[1].displayName = "User alias"
        known[1].diarizationEmbedding = [1, 2, 3]
        known[1].isLocalUser = true
        var value = try tail(prior: known)
        let output = try update(&value, words: [word(52, 20, 26), word(53, 26.1, 26.3)],
            activity: [activity("a", 20, 26), activity("b", 26.1, 26.3)], end: 26.3)
        check(output.inserted[1].speakerID == established.segments[1].speakerID,
              "Previously admitted identity disappeared from a short window")
        check(output.speakers.first { $0.id == known[1].id }?.displayName == "User alias")
        check(output.speakers.first { $0.id == known[1].id }?.isLocalUser == true,
              "Speaker attribution revoked identity-owner evidence")
        check(output.speakers.allSatisfy { $0.diarizationEmbedding == nil }, "Tail retained a voice tensor")
        let merged = MeetingPCMTranscriptBatch(segments: [], speakers: output.speakers).mergingSpeakers(into: known)
        check(merged.first { $0.id == known[1].id }?.diarizationEmbedding == [1, 2, 3], "Identity merge lost existing voice evidence")
        var newValue = try tail()
        let fresh = try update(&newValue, words: [word(54, 20, 26), word(55, 26.1, 26.3)],
            activity: [activity("a", 20, 26), activity("b", 26.1, 26.3)], end: 26.3)
        check(fresh.inserted[1].speakerID == nil, "A new short slot bypassed canonical speaker admission")
        var unsafeValue = try tail(prior: known)
        var unsafe = word(56, 26.1, 26.3); unsafe.completeness = .incompleteTrack
        let unsafeOutput = try update(&unsafeValue, words: [word(57, 20, 26), unsafe],
            activity: [activity("a", 20, 26), activity("b", 26.1, 26.3)], end: 26.3)
        check(unsafeOutput.inserted[1].speakerID == nil, "An unsafe short word bypassed publication safety")
    }

    static func knownNeighborIdentity() throws {
        let established = try MeetingPCMRecordingAttribution.assemble(
            transcript: .init(segments: [word(70, 0, 6), word(71, 7, 13)]),
            activity: [activity("a", 0, 6), activity("b", 7, 13)],
            epoch: epoch, attemptID: attempt, duration: 13, speakerNameFormat: "Speaker %lld")
        let knownID = established.segments[1].speakerID
        check(knownID != nil)
        for sameSpeaker in [true, false] {
            var value = try tail(prior: established.speakers)
            let source = sameSpeaker
                ? [word(72, 20, 26), word(73, 26.1, 26.3), word(74, 26.3, 26.4, text: "<PERSON>"), word(75, 26.4, 26.6)]
                : [word(72, 20, 26), word(74, 26, 26.2, text: "<PERSON>"), word(75, 26.2, 26.6)]
            let gapIndex = source.count - 2
            let support = sameSpeaker
                ? [activity("a", 20, 26), activity("b", 26.1, 26.3), activity("b", 26.4, 26.6)]
                : [activity("a", 20, 26), activity("b", 26.2, 26.6)]
            let first = try update(&value, words: Array(source.dropLast()),
                activity: Array(support.dropLast()), end: source[gapIndex].nativeTiming!.end)
            check(first.inserted[gapIndex].speakerID == nil)
            let second = try update(&value, words: [source.last!], activity: support, end: 26.6)
            guard let patch = second.revisions.first(where: { $0.segmentID == source[gapIndex].id }) else {
                check(false, "The future anchor did not revise the retained gap"); continue
            }
            check(patch.speakerAttribution?.rule == (sameSpeaker ? .neighborAgreement : .incomingSpeaker))
            check(patch.speakerAttribution?.selectedToken?.label == "b")
            check(patch.speakerID == knownID, "A canonical neighbor choice lost its globally admitted identity")
            check(patch.speakerAttribution?.selectedSpeakerID == knownID)
            check(patch.speakerAttribution?.rawAssignment == .unassigned)
            check(patch.speakerAttribution?.candidates.isEmpty == true, "Context invented support inside a silent word")
            var projected = first.inserted[gapIndex]
            _ = try patch.apply(to: &projected)
            let original = source[gapIndex]
            check(projected.id == original.id && projected.text == original.text && projected.originalText == original.originalText)
            check(projected.start == original.start && projected.end == original.end && projected.nativeTiming == original.nativeTiming)
            check(projected.nativeUnitID == original.nativeUnitID && projected.nativeSpeakerAssignment == original.nativeSpeakerAssignment)
            check(projected.status == original.status && projected.completeness == original.completeness)
            let final = try value.finish(activity: support, watermarks: marks(26.6), attemptID: attempt, epoch: epoch)
            check(final.revisions.isEmpty, "Finalization changed a canonical known neighbor identity")

            var fresh = try tail()
            let unadmitted = try update(&fresh, words: source, activity: support, end: 26.6)
            check(unadmitted.inserted[gapIndex].speakerAttribution?.rule == (sameSpeaker ? .neighborAgreement : .incomingSpeaker))
            check(unadmitted.inserted[gapIndex].speakerID == nil,
                  "A never-admitted short token gained an identity through context")
            check(unadmitted.inserted[gapIndex].speakerAttribution?.selectedSpeakerID == nil)
            check(unadmitted.speakers.count == 1)
        }
    }

    static func knownNeighborSafety() throws {
        let established = try MeetingPCMRecordingAttribution.assemble(
            transcript: .init(segments: [word(80, 0, 6), word(81, 7, 13)]),
            activity: [activity("a", 0, 6), activity("b", 7, 13)],
            epoch: epoch, attemptID: attempt, duration: 13, speakerNameFormat: "Speaker %lld")
        let source = [word(82, 20, 26), word(83, 26.1, 26.3), word(84, 26.3, 26.4), word(85, 26.4, 26.6)]
        let support = [activity("a", 20, 26), activity("b", 26.1, 26.3), activity("b", 26.4, 26.6)]
        for unsafeIndex in 1...3 {
            for unsafeKind in 0..<4 {
                var words = source
                switch unsafeKind {
                case 0: words[unsafeIndex].completeness = .incompleteTrack
                case 1: words[unsafeIndex].status = .provisional
                case 2: words[unsafeIndex].isLikelyEcho = true
                default: words[unsafeIndex].attributionState = .timingUncertain
                }
                var value = try tail(prior: established.speakers)
                let blocked = try update(&value, words: words, activity: support, end: 26.6)
                check(blocked.inserted[2].speakerID == nil, "An unsafe target or cue restored a neighbor identity")
                check(blocked.inserted[2].speakerAttribution?.rule != .neighborAgreement)
            }
        }
        var mixed = try tail(prior: established.speakers)
        let ambiguous = try update(&mixed, words: source,
            activity: support + [activity("a", 26.3, 26.4), activity("b", 26.3, 26.4), activity("c", 26.3, 26.4)], end: 26.6)
        check(ambiguous.inserted[2].speakerID == established.segments[1].speakerID
              && ambiguous.inserted[2].overlap == .ambiguous,
              "A bounded mixed word lost continuing reading ownership or original overlap evidence")
        check(ambiguous.inserted[2].speakerAttribution?.rule == .mainSpeakerContinuation)
        check(ambiguous.inserted[2].speakerAttribution?.candidates.count == 3)
        check(ambiguous.inserted[2].speakerAttribution?.rule != .neighborAgreement)
        var manualWords = source
        manualWords[2].speakerID = UUID()
        manualWords[2].attributionState = .assigned
        var manual = try tail(prior: established.speakers)
        let manualOutput = try update(&manual, words: manualWords, activity: support, end: 26.6)
        check(manualOutput.inserted[2].speakerID != established.segments[1].speakerID,
              "A manually assigned target was replaced by a contextual known identity")
    }

    static func knownContinuationIdentityAndPartitions() throws {
        let established = try MeetingPCMRecordingAttribution.assemble(
            transcript: .init(segments: [word(90, 0, 6), word(91, 7, 13)]),
            activity: [activity("a", 0, 6), activity("b", 7, 13)],
            epoch: epoch, attemptID: attempt, duration: 13, speakerNameFormat: "Speaker %lld")
        let knownID = established.segments[1].speakerID
        check(knownID != nil)
        let source = [word(92, 20, 26), word(93, 26.1, 26.2), word(94, 26.2, 26.3),
                      word(95, 26.4, 26.5), word(96, 26.5, 26.6), word(97, 26.6, 26.7),
                      word(98, 26.7, 26.8), word(99, 26.9, 27.1)]
        let support = [activity("a", 20, 26), activity("b", 26.1, 26.2), activity("b", 26.4, 26.5),
                       activity("b", 26.6, 26.7), activity("c", 26.45, 26.65), activity("d", 26.47, 26.49),
                       activity("b", 26.9, 27.1)]
        var oneShot = try tail(prior: established.speakers)
        let canonical = try oneShot.finish(safeWords: .init(segments: source), activity: support,
            watermarks: marks(27.1), attemptID: attempt, epoch: epoch)
        for position in 2...6 {
            check(canonical.inserted[position].speakerID == knownID)
            check(canonical.inserted[position].speakerAttribution?.rule == .mainSpeakerContinuation)
            check(canonical.inserted[position].speakerAttribution?.selectedSpeakerID == knownID)
            check(canonical.inserted[position].speakerAttribution?.background.isEmpty == true)
        }
        check(canonical.inserted[2].speakerAttribution?.candidates.isEmpty == true)
        check(canonical.inserted[6].speakerAttribution?.candidates.isEmpty == true)
        check(canonical.inserted[3].speakerAttribution?.rawAssignment.tokens.count == 3)
        check(canonical.inserted[4].speakerAttribution?.rawAssignment.tokens.map(\.label) == ["c"])
        check(canonical.inserted[4].speakerAttribution?.relation == .single)
        for split in 0...source.count {
            var value = try tail(prior: established.speakers)
            let prefix = Array(source.prefix(split)), suffix = Array(source.dropFirst(split))
            let cursor = prefix.last?.nativeTiming?.end ?? 0
            let prefixSupport = support.filter { $0.start < cursor }.map {
                MeetingBackendSpeakerActivity(token: $0.token, start: $0.start, end: min($0.end, cursor))
            }
            let first = try update(&value, words: prefix, activity: prefixSupport, end: cursor)
            if split > 2, split < source.count {
                check(first.inserted[2].speakerAttribution?.rule != .mainSpeakerContinuation,
                      "Continuation used an absent future original anchor")
            }
            let final = try value.finish(safeWords: .init(segments: suffix), activity: support,
                watermarks: marks(27.1), attemptID: attempt, epoch: epoch)
            var observed = Dictionary(uniqueKeysWithValues: (first.inserted + final.inserted).map { ($0.id, $0) })
            for patch in final.revisions {
                guard var row = observed[patch.segmentID] else { check(false); continue }
                _ = try patch.apply(to: &row)
                observed[patch.segmentID] = row
            }
            for expected in canonical.inserted {
                let row = observed[expected.id]!
                check(row.speakerID == expected.speakerID && row.speakerAttribution == expected.speakerAttribution,
                      "Stop partition changed canonical continuation ownership")
                check(row.id == expected.id && row.text == expected.text && row.originalText == expected.originalText)
                check(row.start == expected.start && row.end == expected.end && row.nativeTiming == expected.nativeTiming)
                check(row.nativeUnitID == expected.nativeUnitID && row.nativeSpeakerAssignment == expected.nativeSpeakerAssignment)
            }
            check(final.isFinal && final.provisionalSpeakerIDs.isEmpty)
        }
        var fresh = try tail()
        let unadmitted = try update(&fresh, words: source, activity: support, end: 27.1)
        for position in 2...6 {
            check(unadmitted.inserted[position].speakerID == nil,
                  "Continuation manufactured an identity for a never-admitted short speaker")
            check(unadmitted.inserted[position].speakerAttribution?.rule == .mainSpeakerContinuation)
        }
        for unsafeIndex in 1...7 {
            for kind in 0..<4 {
                var words = source
                switch kind {
                case 0: words[unsafeIndex].completeness = .incompleteTrack
                case 1: words[unsafeIndex].status = .provisional
                case 2: words[unsafeIndex].isLikelyEcho = true
                default: words[unsafeIndex].attributionState = .timingUncertain
                }
                var value = try tail(prior: established.speakers)
                let blocked = try update(&value, words: words, activity: support, end: 27.1)
                check(blocked.inserted[2].speakerAttribution?.rule != .mainSpeakerContinuation)
                check(blocked.inserted[6].speakerAttribution?.rule != .mainSpeakerContinuation)
            }
        }
    }

    static func alternatingContinuationPartitions() throws {
        let established = try MeetingPCMRecordingAttribution.assemble(
            transcript: .init(segments: [word(100, 0, 6)]), activity: [activity("a", 0, 6)],
            epoch: epoch, attemptID: attempt, duration: 6, speakerNameFormat: "Speaker %lld")
        let knownID = established.segments[0].speakerID
        check(knownID != nil)
        let source = (0..<9).map { word(101 + $0, 20 + Double($0) * 0.3, 20.2 + Double($0) * 0.3) }
        let support = [activity("a", 20, 20.5), activity("a", 20.9, 21.7), activity("a", 22.1, 22.6),
                       activity("b", 20.4, 21), activity("b", 21.6, 22.2)]
        var oneShot = try tail(prior: established.speakers)
        let canonical = try oneShot.finish(safeWords: .init(segments: source), activity: support,
            watermarks: marks(22.6), attemptID: attempt, epoch: epoch)
        check(canonical.inserted.allSatisfy { $0.speakerID == knownID },
              "Overlapping alternating claims split continuing A reading ownership")
        for position in [2, 6] {
            check(canonical.inserted[position].speakerAttribution?.rule == .mainSpeakerContinuation)
            check(canonical.inserted[position].speakerAttribution?.rawAssignment.tokens.map(\.label) == ["b"])
            check(canonical.inserted[position].speakerAttribution?.relation == .single)
        }
        for split in 0...source.count {
            var value = try tail(prior: established.speakers)
            let prefix = Array(source.prefix(split)), suffix = Array(source.dropFirst(split))
            let cursor = prefix.last?.nativeTiming?.end ?? 0
            let prefixSupport = support.filter { $0.start < cursor }.map {
                MeetingBackendSpeakerActivity(token: $0.token, start: $0.start, end: min($0.end, cursor))
            }
            let first = try update(&value, words: prefix, activity: prefixSupport, end: cursor)
            let final = try value.finish(safeWords: .init(segments: suffix), activity: support,
                watermarks: marks(22.6), attemptID: attempt, epoch: epoch)
            var observed = Dictionary(uniqueKeysWithValues: (first.inserted + final.inserted).map { ($0.id, $0) })
            for patch in final.revisions {
                guard var row = observed[patch.segmentID] else { check(false); continue }
                _ = try patch.apply(to: &row)
                observed[patch.segmentID] = row
            }
            for expected in canonical.inserted {
                let row = observed[expected.id]!
                check(row.speakerID == expected.speakerID && row.speakerAttribution == expected.speakerAttribution,
                      "A Stop partition changed deterministic alternating-window ownership")
                check(row.text == expected.text && row.nativeTiming == expected.nativeTiming
                      && row.nativeSpeakerAssignment == expected.nativeSpeakerAssignment)
            }
        }
    }

    static func longStream(mode: Int) throws {
        var value = try tail(limits: .init(maximumRetainedWords: 100, maximumRetainedSeconds: 30))
        var inserted = Set<UUID>(), committed = Set<UUID>()
        var previousCommit = 0.0, previousAck = 0.0
        var peakRetained = 0, peakPending = 0
        for index in 0..<2_000 {
            let start = Double(index) * 0.25, end = start + 0.25
            let activity: [MeetingBackendSpeakerActivity]
            if mode == 0 { activity = [] }
            else if mode == 1 { activity = [Self.activity("a", max(0, start - 20), end)] }
            else { activity = [Self.activity("a", max(0, start - 20), end), Self.activity("b", max(0, start - 20), end)] }
            let result = try update(&value, words: [word(1_000 + index, start, end)], activity: activity, end: end)
            check(result.inserted.count == 1 && inserted.insert(result.inserted[0].id).inserted)
            for id in result.committedIDs { check(committed.insert(id).inserted, "Duplicate commit") }
            check(result.retainedWordCount < 100 && result.provisionalSpeakerIDs.count < 30)
            peakRetained = max(peakRetained, result.retainedWordCount)
            peakPending = max(peakPending, result.provisionalSpeakerIDs.count)
            check(result.committedThrough >= previousCommit && result.retainActivityFrom >= previousAck)
            previousCommit = result.committedThrough; previousAck = result.retainActivityFrom
            if mode == 0 { check(result.inserted[0].speakerID == nil) }
            if mode == 2 { check(result.inserted[0].speakerID == nil && result.inserted[0].overlap == .ambiguous) }
        }
        let finalActivity: [MeetingBackendSpeakerActivity] = mode == 0 ? [] : mode == 1
            ? [activity("a", 480, 500)] : [activity("a", 480, 500), activity("b", 480, 500)]
        let final = try value.finish(activity: finalActivity, watermarks: marks(500), attemptID: attempt, epoch: epoch)
        for id in final.committedIDs { check(committed.insert(id).inserted) }
        check(inserted == committed && inserted.count == 2_000 && final.retainedWordCount == 0)
        print("PROTECTED_TAIL_BOUNDS mode=\(mode) words=\(inserted.count) peakRetained=\(peakRetained) peakPending=\(peakPending)")
    }

    static func cancellation() async throws {
        let task = Task {
            var value = try tail()
            withUnsafeCurrentTask { $0?.cancel() }
            do { _ = try update(&value, words: [word(60, 0, 0.1)], end: 0.1); check(false) }
            catch { check(error is CancellationError) }
            check(value.committedThrough == 0 && value.retainActivityFrom == 0)
        }
        try await task.value
    }
}
