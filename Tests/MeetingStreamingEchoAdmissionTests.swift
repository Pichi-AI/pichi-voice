import Foundation

private enum TestFailure: Error { case assertion(String) }
@main
nonisolated struct MeetingStreamingEchoAdmissionTests {
    static let microphone = MeetingAudioTrack(id: UUID(), kind: .microphone)
    static let application = MeetingAudioTrack(id: UUID(), kind: .applicationAudio)
    static let phrase = ["alpha", "bravo", "charlie", "delta", "echo", "foxtrot"]

    static func check(_ value: Bool, _ message: String) throws {
        if !value { throw TestFailure.assertion(message) }
    }
    static func owner(limits: MeetingStreamingEchoAdmission.Limits = .init()) throws -> MeetingStreamingEchoAdmission {
        try .init(tracks: [microphone, application], limits: limits)
    }
    static func words(track: MeetingAudioTrack, start: Double = 1, texts: [String] = phrase) -> [MeetingTranscriptSegment] {
        texts.enumerated().map { index, text in
            let begin = start + Double(index) * 0.3
            return .init(id: UUID(), sourceTrackID: track.id, text: text,
                nativeTiming: .init(start: begin, end: begin + 0.25), nativePrecision: .word,
                nativeSpeakerAssignment: .assigned(.init(analysisEpochID: .init(trackID: track.id, ordinal: 0), label: "a")))
        }
    }
    static func observation(track: MeetingAudioTrack, words: [MeetingTranscriptSegment] = [], through: Double = 5,
                            processed: Double? = nil, sealedASR: Bool = true,
                            activity: [MeetingBackendSpeakerActivity]? = nil) -> MeetingStreamingPCMObservation {
        let process = processed ?? through
        return .init(batch: .init(segments: words), activity: activity ?? [
            .init(token: .init(analysisEpochID: .init(trackID: track.id, ordinal: 0), label: "a"), start: 0, end: process)],
            acceptedThroughSample: Int(through * 16_000), processedThroughSample: Int(process * 16_000),
            retainedFromSample: 0, isFinal: false, asrStableThroughSample: sealedASR ? Int(through * 16_000) : nil)
    }
    static func main() async throws {
        try await lateApplicationCorrectsProtectedMicrophone()
        try await applicationFirstAndCausalShortPhraseRules()
        try await acousticProgressCanRevokeEcho()
        try await sourceAbsenceAndEOFNeverWait()
        try await physicalProjectionSeparatesCompactSourceClocks()
        try await unpublishedPrivacyTailKeepsLatestFlag()
        try await longSingleSourceStaysBoundedWithoutWaiting()
        try await boundsAndLateEvidenceFailExplicitly()
        try await cancellationReleasesRawEvidence()
        print("Streaming echo admission: 9 groups passed (actual raw evidence owner, shared scorer, no models or audio)")
    }

    static func lateApplicationCorrectsProtectedMicrophone() async throws {
        let owner = try owner(), mic = words(track: microphone)
        let first = try await owner.observe(track: microphone, observation: observation(track: microphone, words: mic))
        try check(first.batch.segments.allSatisfy { $0.isLikelyEcho == false }, "No unseen remote text is guessed")
        _ = try await owner.admitting(first.batch)
        _ = try await owner.observe(track: application, observation: observation(track: application, words: words(track: application)))
        let patches = await owner.pendingRevisionBatch()
        try check(patches?.segments.isEmpty == true && patches?.echoRevisions.count == mic.count,
                  "Later remote inference publishes echo-only revisions")
        try check(patches?.echoRevisions.allSatisfy { $0.isLikelyEcho } == true, "Every actual duplicated target is suppressed")
        try check(Set(patches!.echoRevisions.map(\.segmentID)) == Set(mic.map(\.id)), "Only original microphone IDs are patched")
    }

    static func applicationFirstAndCausalShortPhraseRules() async throws {
        let owner = try owner()
        _ = try await owner.observe(track: application, observation: observation(track: application, words: words(track: application)))
        let first = try await owner.observe(track: microphone, observation: observation(track: microphone, words: words(track: microphone)))
        try check(first.batch.segments.allSatisfy { $0.isLikelyEcho == true }, "Remote-first ordering uses exactly the same scoring policy")
        let unrelated = try self.owner()
        _ = try await unrelated.observe(track: application, observation: observation(track: application, words: words(track: application)))
        let distinct = try await unrelated.observe(track: microphone,
            observation: observation(track: microphone, words: words(track: microphone, texts: ["local", "unique", "spoken", "phrase"])))
        try check(distinct.batch.segments.allSatisfy { $0.isLikelyEcho == false }, "Independent local speech is retained")
        let short = try self.owner()
        _ = try await short.observe(track: application, observation: observation(track: application, words: words(track: application, texts: ["alpha", "bravo"])))
        let brief = try await short.observe(track: microphone,
            observation: observation(track: microphone, words: words(track: microphone, texts: ["alpha", "bravo"])))
        try check(brief.batch.segments.allSatisfy { $0.isLikelyEcho == false }, "The existing minimum phrase rule remains unchanged")
        let causal = try self.owner()
        _ = try await causal.observe(track: application, observation: observation(track: application, words: words(track: application, start: 3.5), through: 6))
        let early = try await causal.observe(track: microphone,
            observation: observation(track: microphone, words: words(track: microphone), through: 6))
        try check(early.batch.segments.allSatisfy { $0.isLikelyEcho == false }, "A future remote phrase cannot prove earlier microphone echo")
    }

    static func acousticProgressCanRevokeEcho() async throws {
        let owner = try owner(), mic = words(track: microphone)
        _ = try await owner.observe(track: application, observation: observation(track: application, words: words(track: application)))
        let first = try await owner.observe(track: microphone, observation: observation(track: microphone, words: mic))
        _ = try await owner.admitting(first.batch)
        // A later native activity refinement makes these remote words outside its own speech.
        let laterActivity: [MeetingBackendSpeakerActivity] = [
            .init(token: .init(analysisEpochID: .init(trackID: application.id, ordinal: 0), label: "b"), start: 4, end: 5)]
        _ = try await owner.observe(track: application,
            observation: observation(track: application, sealedASR: false, activity: laterActivity))
        let patches = await owner.pendingRevisionBatch()
        try check(patches?.echoRevisions.count == mic.count && patches?.echoRevisions.allSatisfy { !$0.isLikelyEcho } == true,
                  "Remote words outside acoustic speech cannot remain echo targets")
    }

    static func sourceAbsenceAndEOFNeverWait() async throws {
        let owner = try owner()
        _ = try await owner.observe(track: microphone, observation: observation(track: microphone, words: words(track: microphone)))
        try await owner.markSealed(trackID: application.id)
        try await owner.markSealed(trackID: microphone.id)
        let first = try await owner.admitting(.init(segments: []))
        try check(first.echoRevisions.isEmpty, "An empty source needs no guessed echo and never blocks Stop")
    }

    static func physicalProjectionSeparatesCompactSourceClocks() async throws {
        let owner = try MeetingStreamingEchoAdmission(tracks: [microphone, application],
            presentationInterval: { track, start, end in
                let offset = track == application.id ? 30.0 : 0.0
                return (start + offset, end + offset)
            }, presentationThrough: { track, time in time + (track == application.id ? 30 : 0) })
        _ = try await owner.observe(track: application, observation: observation(track: application, words: words(track: application)))
        let first = try await owner.observe(track: microphone, observation: observation(track: microphone, words: words(track: microphone)))
        try check(first.batch.segments.allSatisfy { $0.isLikelyEcho == false }, "Equal compact ASR clocks across a source gap are not simultaneous speech")
    }

    static func unpublishedPrivacyTailKeepsLatestFlag() async throws {
        let owner = try owner(), mic = words(track: microphone)
        let privateInput = try await owner.observe(track: microphone, observation: observation(track: microphone, words: mic))
        _ = try await owner.observe(track: application, observation: observation(track: application, words: words(track: application)))
        _ = await owner.pendingRevisionBatch() // Store ignores an ID not yet privacy-admitted.
        _ = try await owner.observe(track: microphone, observation: observation(track: microphone, through: 100))
        let value = await owner.diagnostics
        try check(value.retainedRawUnits == 0 && value.unpublishedFlags == mic.count, "Only bounded scalar flags survive raw text expiry")
        let admitted = try await owner.admitting(privateInput.batch)
        try check(admitted.segments.allSatisfy { $0.isLikelyEcho == true }, "First protected publication receives the newest echo identity")
        try check(await owner.diagnostics.unpublishedFlags == 0, "Admitted scalar flags are released after raw evidence expired")
    }

    static func longSingleSourceStaysBoundedWithoutWaiting() async throws {
        var limits = MeetingStreamingEchoAdmission.Limits()
        limits.maximumRawUnits = 100
        let owner = try owner(limits: limits)
        for window in 0..<100 {
            let start = Double(window * 5)
            let value = try await owner.observe(track: microphone,
                observation: observation(track: microphone, words: words(track: microphone, start: start + 1), through: start + 5))
            _ = try await owner.admitting(value.batch)
        }
        let value = await owner.diagnostics
        try check(value.retainedRawUnits <= 100 && value.unpublishedFlags == 0 && !value.closed,
                  "A silent or absent remote source cannot block a long microphone stream or retain its whole history")
    }

    static func boundsAndLateEvidenceFailExplicitly() async throws {
        var limits = MeetingStreamingEchoAdmission.Limits()
        limits.maximumRawUnits = 2
        let bounded = try owner(limits: limits)
        do {
            _ = try await bounded.observe(track: microphone, observation: observation(track: microphone, words: words(track: microphone)))
            throw TestFailure.assertion("Expected bounded raw evidence rejection")
        } catch MeetingStreamingEchoAdmission.Failure.resourceLimit {}
        try check(await bounded.diagnostics.closed, "A bounded failure closes raw admission")
        let delayed = try owner()
        _ = try await delayed.observe(track: microphone, observation: observation(track: microphone, through: 100))
        let original = words(track: application)
        let result = try await delayed.observe(track: application, observation: observation(track: application, words: original))
        try check(result.batch.segments.map(\.id) == original.map(\.id)
                  && zip(result.batch.segments, original).allSatisfy({ $0.text == $1.text && $0.isLikelyEcho == $1.isLikelyEcho }),
                  "Expired echo evidence preserves original words/flags for normal admission")
        let diagnostics = await delayed.diagnostics
        try check(!diagnostics.closed && diagnostics.retainedRawUnits == 0
                  && diagnostics.expiredEvidenceUnits == original.count,
                  "Late valid ASR does not revive expired echo history or stop either source")
    }

    static func cancellationReleasesRawEvidence() async throws {
        let owner = try owner()
        _ = try await owner.observe(track: microphone, observation: observation(track: microphone, words: words(track: microphone)))
        await owner.cancel()
        let value = await owner.diagnostics
        try check(value.closed && value.retainedRawUnits == 0 && value.unpublishedFlags == 0 && value.pendingRevisions == 0,
                  "Cancellation releases all attempt-owned raw and scalar evidence")
        do { _ = try await owner.admitting(.init(segments: [])); throw TestFailure.assertion("Closed attempt accepted publication") }
        catch MeetingStreamingEchoAdmission.Failure.closed {}
    }
}
