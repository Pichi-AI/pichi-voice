import CryptoKit
import Foundation

extension MeetingSessionStoreCheckpointTests {
    static func checkProtectedPublicationSource(check: (Bool, String) -> Void) async throws {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic cloud source Ёё",
            languageCode: "ru", microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(5)
        session.piiRedactionEnabled = true
        session.transcriptIsComplete = true
        let trackID = UUID()
        session.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1),
            end: .init(value: 5, timescale: 1), sourceTrackID: trackID, speakerID: nil,
            text: "Синтетический контакт [PERSON].", revision: 0, status: .final,
            overlap: .none, completeness: .complete, attributionState: .unassigned)]
        let original = session
        let source = try PichiProtectedPublicationSource.prepare(for: session)
        let portableBytes = try MeetingTranscriptExporter.protectedTranscriptJSON(for: session)
        check(source.sessionID == session.id && source.transcriptBytes == portableBytes,
              "Cloud source reuses the exact production protected exporter bytes")
        check(source.sourceSHA256 == SHA256.hash(data: portableBytes).map { String(format: "%02x", $0) }.joined()
              && source.sourceSHA256.count == 64 && source.sourceSHA256 == source.sourceSHA256.lowercased(),
              "The source fingerprint is SHA-256 of exact UTF-8 file bytes")
        check(session == original, "Cloud eligibility does not mutate the saved transcript")
        session.transcriptSegments[0].text = "A later edit"
        check(source.transcriptBytes == portableBytes,
              "Later transcript edits cannot mutate an admitted byte snapshot")

        func rejects(_ value: MeetingSession, _ expected: PichiPublicationWithholdingReason,
                     _ message: String) throws {
            do { _ = try PichiProtectedPublicationSource.prepare(for: value); check(false, message) }
            catch let reason as PichiPublicationWithholdingReason { check(reason == expected, message) }
        }
        for state in [MeetingSessionState.recording, .processing, .interrupted] {
            var value = original; value.state = state
            try rejects(value, .notCompleted, "Nonterminal sources stay local")
        }
        var value = original; value.endedAt = nil
        try rejects(value, .notCompleted, "Completed state without a persisted end is withheld")
        for flag: Bool? in [nil, false] {
            value = original; value.piiRedactionEnabled = flag
            try rejects(value, .redactionNotEnabled, "Current opt-in cannot protect an earlier unprotected capture")
        }
        value = original; value.transcriptSegments[0].originalText = "PRIVATE SYNTHETIC ORIGINAL"
        try rejects(value, .originalTextRetained, "Original text blocks cloud admission")
        value.transcriptSegments[0].isLikelyEcho = true
        try rejects(value, .originalTextRetained, "Even omitted echo units cannot retain original text")
        value = original; value.transcriptIsComplete = nil; value.transcriptCoverageGaps = []
        try rejects(value, .completenessUnknown, "Empty gaps cannot establish unknown recognition completeness")
        value = original; value.transcriptIsComplete = false
        try rejects(value, .incompleteTranscript, "Completed state alone cannot establish complete recognition")
        for reason in [MeetingTranscriptCoverageGapReason.unprotectedMicrophone, .missingOrUnreadableAudio,
                       .processingFailed, .processingSkipped, .providerTruncated,
                       .excludedUnitIncompleteCoverage, .inadmissibleCaptureEra] {
            value = original
            value.transcriptCoverageGaps = [.init(trackID: trackID, start: 1, end: 2, reason: reason)]
            try rejects(value, .excludedIntervals, "Any excluded coverage stays local even with a contradictory complete flag")
        }
        for completeness in [MeetingTranscriptCompleteness.incompleteTrack, .processingFailed] {
            value = original; value.transcriptSegments[0].completeness = completeness
            try rejects(value, .incompleteTranscript, "Segment-level partial recognition cannot pass a complete flag")
        }
        value = original; value.transcriptCoverageGaps = []
        check(try PichiProtectedPublicationSource.prepare(for: value) == source,
              "Explicit empty gaps and coordinator-persisted nil gaps have identical complete-source semantics")
        value = original; value.transcriptSegments[0].status = .provisional
        try rejects(value, .invalidTranscript, "The production final-segment requirement remains enforced")
        value = original; value.transcriptSegments[0].start.timescale = 0
        try rejects(value, .invalidTranscript, "The production timing validation remains enforced")
        value = original; value.transcriptSegments[0].text = String(repeating: "😀", count: 50_001)
        try rejects(value, .exportLimitExceeded, "UTF-16 source limits remain enforced by the protected exporter")
        value = original
        value.speakers = (0..<4_000).map { _ in
            .init(id: UUID(), displayName: String(repeating: "я", count: 200), diarizationClusterID: nil,
                trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        }
        try rejects(value, .exportLimitExceeded, "The final byte limit includes personal metadata and JSON overhead")
        value = original; value.transcriptIsComplete = false
        check(!((try MeetingTranscriptExporter.protectedTranscriptJSON(for: value)).isEmpty),
              "Cloud withholding leaves the existing explicit protected manual export usable")
        value = original; value.transcriptSegments = []
        try rejects(value, .emptyTranscript, "Measured-complete no-speech source is empty, not incomplete")
        value = original; value.transcriptSegments[0].end = value.transcriptSegments[0].start
        try rejects(value, .invalidTranscript, "Server-positive interval requirements apply before admission")
        value = original; value.endedAt = value.startedAt.addingTimeInterval(86_401)
        try rejects(value, .exportLimitExceeded, "Sources longer than the existing server limit stay local")
        value = original
        value.speakers = (0..<101).map { _ in
            .init(id: UUID(), displayName: "Synthetic", diarizationClusterID: nil,
                trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        }
        try rejects(value, .exportLimitExceeded, "The server speaker limit applies before enqueueing")
        value = original
        var provisional = MeetingSessionSpeaker(id: UUID(), displayName: "Синтетический участник Ёё", diarizationClusterID: nil,
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        provisional.identityIsProvisional = true
        value.speakers = [provisional]; value.transcriptSegments[0].speakerID = provisional.id
        let exportedSource = try PichiProtectedPublicationSource.prepare(for: value)
        let exportedObject = try JSONSerialization.jsonObject(with: exportedSource.transcriptBytes) as! [String: Any]
        check((exportedObject["speakers"] as! [[String: Any]])[0]["identityIsProvisional"] as? Bool == true,
              "Actual exporter provisional metadata survives source preparation byte-for-byte")
        check(try PichiProtectedPublicationPayload.validate(exportedSource.transcriptBytes).contains(provisional.id),
              "Shared wire guard accepts actual exporter-shaped provisional participant bytes")

        let cancelled = Task { () throws -> PichiProtectedPublicationSource in
            withUnsafeCurrentTask { $0?.cancel() }
            return try PichiProtectedPublicationSource.prepare(for: original)
        }
        do { _ = try await cancelled.value; check(false, "Cancelled preparation must not produce an admission") }
        catch is CancellationError { check(true, "Cancellation remains distinct from a source withholding reason") }
        for reason in PichiPublicationWithholdingReason.allCases {
            let decoded = try JSONDecoder().decode(PichiPublicationWithholdingReason.self,
                from: JSONEncoder().encode(reason))
            check(decoded == reason, "Stable withholding codes survive durable encoding")
        }
    }
}
