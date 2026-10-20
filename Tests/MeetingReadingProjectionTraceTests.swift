import Foundation

@main struct MeetingReadingProjectionTraceTests {
    static func main() async throws {
        func require(_ value: @autoclosure () -> Bool, _ message: String) throws {
            if !value() { throw NSError(domain: message, code: 1) }
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let targetID = UUID(uuidString: CommandLine.arguments[2])!
        let source = UUID(), owner = UUID(), epoch = MeetingAnalysisEpochID(trackID: source, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "synthetic-voice")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic reading trace",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.state = .completed; session.endedAt = session.startedAt.addingTimeInterval(70)
        session.speakers = [.init(id: owner, displayName: "Synthetic participant", diarizationClusterID: nil,
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
        func word(_ id: UUID, _ text: String, _ start: Double, _ end: Double, _ identified: Bool) -> MeetingTranscriptSegment {
            var result = MeetingTranscriptSegment(id: id, start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
                end: .init(value: Int64((end * 1_000).rounded()), timescale: 1_000), sourceTrackID: source,
                speakerID: identified ? owner : nil, text: text, revision: 0, status: .final, overlap: .none,
                completeness: .complete, attributionState: identified ? .assigned : .unassigned)
            result.nativePrecision = .word; result.nativeTiming = .init(start: start, end: end)
            result.nativeUnitID = id.uuidString
            result.nativeSpeakerAssignment = identified ? .assigned(token) : .unassigned
            return result
        }
        let baseline = [word(UUID(), "Предыдущее.", 59.92, 60, true), word(targetID, "А", 60, 60.04, false),
            word(UUID(), "Продолжение.", 62.44, 62.52, true)]
        for mode in 0..<4 {
            session.transcriptSegments = baseline
            if mode == 1 { session.transcriptSegments[0].revision = 1 }
            if mode == 2 { session.transcriptSegments[2].revision = 1 }
            if mode == 3 { session.transcriptSegments[1].isUserTextEdited = true }
            let original = session, originalJSON = try MeetingTranscriptExporter.json(for: session)
            let result = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
            let target = result.first { $0.segments.contains { $0.id == targetID } }!
            try require((target.projectedSpeakerID == owner) == (mode == 0 || mode == 2), "unchanged-boundary-policy")
            let afterJSON = try MeetingTranscriptExporter.json(for: session)
            try require(session == original && originalJSON == afterJSON, "diagnostic-does-not-mutate-canonical-input")
        }
        if let trace = MeetingTimelineTrace.shared {
            await trace.finish()
            let rows = try String(contentsOf: trace.fileURL, encoding: .utf8).split(separator: "\n").map {
                try JSONSerialization.jsonObject(with: Data($0.utf8)) as! [String: Any]
            }
            let scopes = rows.filter { $0["kind"] as? String == "reading_projection" }
            let words = rows.filter { $0["kind"] as? String == "reading_projection_word" }
            try require(scopes.count == 4 && words.count == 12, "bounded-actual-target-and-neighbor-events")
            let fields = scopes[2]["fields"] as! [String: String]
            let owners = try JSONSerialization.jsonObject(with: Data(fields["owners"]!.utf8)) as! [String: String]
            let run = try JSONSerialization.jsonObject(with: Data(fields["boundaryRun"]!.utf8)) as! [String: String]
            try require(fields["targetParagraphMemberCount"] == "3" && owners["boundary"] == owner.uuidString
                && owners["reading"] == owner.uuidString && run["runDecision"] == "accepted-lexical-residual", "actual-map-and-paragraph-result")
            let targetWords = words.filter { ($0["fields"] as? [String: String])?["wordID"] == targetID.uuidString }
            let targetFields = targetWords[2]["fields"] as! [String: String]
            let flags = try JSONSerialization.jsonObject(with: Data(targetFields["boundaryChecks"]!.utf8)) as! [String: String]
            let semantics = try JSONSerialization.jsonObject(with: Data(targetFields["semantics"]!.utf8)) as! [String: String]
            try require(flags["safe"] == "true" && flags["eligible"] == "true"
                && semantics["alphanumericMethodReference"] == "true" && semantics["alphanumericClosure"] == "true"
                && semantics["alphanumericLoop"] == "true", "actual-gate-results-and-equivalent-character-predicates")
            try require(trace.status.dropped == 0 && trace.status.truncated == 0, "bounded-trace-complete-without-truncation")
        } else {
            try require(!FileManager.default.fileExists(atPath: root.path), "disabled-diagnostic-has-no-IO")
        }
        print("Reading projection trace: actual owners/gates/neighbors/canonical preservation passed; enabled=\(MeetingTimelineTrace.enabled)")
    }
}
