import Foundation

extension MeetingSessionStoreCheckpointTests {
    /// Synthetic analogues of the latest meeting. No personal transcript or voice data.
    static func checkReadableTranscriptContract(_ check: (Bool, String) -> Void) throws {
        let source = UUID(), a = UUID(), b = UUID(), extra = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: source, ordinal: 0)
        let ta = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "voice-a")
        let tb = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "voice-b")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic reading contract",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic source")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.state = .completed; session.endedAt = session.startedAt.addingTimeInterval(30)
        session.piiRedactionEnabled = true; session.audioStorageMode = .memoryOnly
        session.speakers = [(a, "Имя Ёё"), (b, "Другое имя"), (extra, "Video voice")].map {
            .init(id: $0.0, displayName: $0.1, diarizationClusterID: nil, trackKind: .microphone,
                  isLocalUser: false, identityCandidates: [])
        }
        func word(_ text: String, _ start: Double, raw: MeetingBackendSpeakerToken?, selected: MeetingBackendSpeakerToken?,
                  owner: UUID?, rule: MeetingSpeakerAttributionRule = .singleAcousticSupport,
                  map: [MeetingBackendSpeakerToken: UUID] = [:]) -> MeetingTranscriptSegment {
            let unit = "synthetic:\(UUID().uuidString)"
            var value = MeetingTranscriptSegment(id: UUID(), start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
                end: .init(value: Int64(((start + 0.08) * 1_000).rounded()), timescale: 1_000), sourceTrackID: source,
                speakerID: owner, text: text, revision: 0, status: .final, overlap: .none, completeness: .complete,
                attributionState: owner == nil ? .unassigned : .assigned)
            value.nativePrecision = .word; value.nativeUnitID = unit
            value.nativeTiming = .init(start: start, end: start + 0.08)
            let assignment: MeetingBackendSpeakerAssignment = raw.map { .assigned($0) } ?? .unassigned
            value.nativeSpeakerAssignment = assignment
            let decision = MeetingSpeakerAttributionDecision(unitID: unit, rawAssignment: assignment, candidates: [],
                activeSupportSeconds: raw == nil ? 0 : 0.08, simultaneousIntervals: [], relation: raw == nil ? .none : .single,
                selectedToken: selected, rule: rule, cueUnitIDs: [], backgroundTokens: [],
                policyVersion: 2, policyFingerprint: "synthetic-old-continuation-policy")
            value.speakerAttribution = .init(decision: decision, speakerIDs: map)
            return value
        }
        let both = [ta: a, tb: b]
        let unknown = word("Я", 0.04, raw: nil, selected: nil, owner: nil, rule: .insufficientSupport)
        let first = word("Начало.", 10.3, raw: ta, selected: ta, owner: a, map: both)
        session.transcriptSegments = [unknown, first]
        let names = Dictionary(uniqueKeysWithValues: session.speakers.map { ($0.id, $0.displayName) })
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
        check(paragraphs.count == 2, "Leading unsupported speech stays separate without inventing its owner")
        for language in [PichiInterfaceLanguage.english, .russian] {
            check(MeetingTranscriptExporter.captionLabel(for: paragraphs[0], in: session, speakerNames: names, language: language) == nil,
                  "Unassigned speech has no unknown or source caption in either interface language")
            check(MeetingTranscriptExporter.captionLabel(for: paragraphs[1], in: session, speakerNames: names, language: language) == "Имя Ёё",
                  "A genuine manual alias is unchanged by interface localization")
            let candidates = MeetingSpeakerPresentation(identity: "synthetic-candidates", label: .candidates([], relation: .simultaneous))
            check(MeetingTranscriptExporter.captionLabel(for: candidates, language: language) == nil,
                  "Several uncertain voices do not manufacture an unknown participant header")
        }
        let text = MeetingTranscriptExporter.text(for: session)
        check(text.hasPrefix("[00:00] Я") && !text.contains("Unknown speaker") && !text.contains("] :"),
              "Plain transcript starts with anonymous text, without an uncertainty label or phantom colon")
        check(MeetingTranscriptExporter.speakerLabel(for: MeetingTranscriptExporter.speakerPresentation(for: unknown, in: session)) == "Unknown speaker",
              "Detailed evidence tools retain uncertainty while product captions omit it")

        let oldOverride = word("Да.", 11.0, raw: tb, selected: ta, owner: a, rule: .mainSpeakerContinuation, map: both)
        let bAnchor = word("Ответ.", 10.6, raw: tb, selected: tb, owner: b, map: both)
        let aAfter = word("Продолжение.", 11.3, raw: ta, selected: ta, owner: a, map: both)
        session.transcriptSegments = [first, bAnchor, oldOverride, aAfter]
        let original = session
        let restored = MeetingTranscriptExporter.speakerPresentations(in: session)
        check(restored[oldOverride.id]?.participantID == b,
              "An old continuation override of an independent native reply reads with its uniquely established original voice")
        check(restored[oldOverride.id]?.isEstimated == true,
              "Historical read repair retains an internal estimate marker rather than rewriting native truth")
        check(session == original, "History repair leaves the original session and every native field unchanged")
        let portable = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: session)) as! [String: Any]
        let portableRows = portable["segments"] as! [[String: Any]]
        check(portableRows.contains { ($0["text"] as? String)?.contains("Да.") == true && $0["speakerID"] as? String == b.uuidString },
              "Portable reading export shares the corrected reading identity with the saved UI")

        var missingID = oldOverride; missingID.speakerID = nil; missingID.attributionState = .unassigned
        missingID.speakerAttribution = .init(decision: .init(unitID: missingID.nativeUnitID!, rawAssignment: .assigned(tb),
            candidates: [], activeSupportSeconds: 0.08, simultaneousIntervals: [], relation: .single,
            selectedToken: ta, rule: .mainSpeakerContinuation, cueUnitIDs: [], backgroundTokens: [],
            policyVersion: 2, policyFingerprint: "synthetic-old-continuation-policy"), speakerIDs: [:])
        session.transcriptSegments = [first, bAnchor, missingID, aAfter]
        check(MeetingTranscriptExporter.speakerPresentations(in: session)[missingID.id]?.participantID == b,
              "A nil UUID left by an old override cannot lose a uniquely mapped independent native reply again")

        var manual = oldOverride; manual.revision = 1; manual.speakerAttribution = nil
        session.transcriptSegments = [first, bAnchor, manual, aAfter]
        check(MeetingTranscriptExporter.speakerPresentations(in: session)[manual.id]?.participantID == a,
              "A manual speaker correction is authoritative over preserved native evidence")
        var edited = oldOverride; edited.isUserTextEdited = true
        session.transcriptSegments = [first, bAnchor, edited, aAfter]
        check(MeetingTranscriptExporter.speakerPresentations(in: session)[edited.id]?.participantID == a,
              "User-edited rows do not enter historical automatic repair")
        session.transcriptSegments = [first, bAnchor, oldOverride, aAfter]
        session.transcriptCoverageGaps = [.init(trackID: source, start: 10.95, end: 11.1, reason: .processingFailed)]
        check(MeetingTranscriptExporter.speakerPresentations(in: session)[oldOverride.id]?.participantID == a,
              "A coverage gap prevents automatic recovery across missing source evidence")
        session.transcriptCoverageGaps = nil
        session.speakers[1].displayName = session.speakers[0].displayName
        check(MeetingTranscriptExporter.speakerPresentations(in: session)[oldOverride.id]?.participantID == b,
              "Equal displayed names never merge distinct speaker UUIDs")
        session.speakers[1].displayName = "Ручное новое имя"
        let renamed = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
        check(renamed.flatMap(\.segments) == session.transcriptSegments, "Reading and renaming preserve every word, order and time")
        check(MeetingTranscriptExporter.text(for: session).contains("Ручное новое имя"),
              "A recovered participant follows the current persisted manual alias")

        let gap = word("фрагмент", 15, raw: nil, selected: nil, owner: nil, rule: .insufficientSupport)
        let returning = word("Возврат.", 22, raw: ta, selected: ta, owner: a, map: both)
        session.transcriptSegments = [first, gap, returning]
        let full = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
        check(full.count == 3 && !full[2].showsSpeakerLabel,
              "An unresolved run does not repeatedly announce the same returning readable participant")
        let excerpt = MeetingTranscriptExporter.text(for: session, segmentIDs: [returning.id])
        check(excerpt.contains("Имя Ёё: Возврат."),
              "Copying an isolated excerpt retains its participant even when the full document suppresses a repeated heading")
    }
}
