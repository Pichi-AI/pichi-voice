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
        do {
            var value = session
            for index in value.speakers.indices {
                value.speakers[index].generatedParticipantNumber = index + 1
                value.speakers[index].usesCustomDisplayName = false
            }
            value.speakers[2].identityIsProvisional = true
            let quote = word("\"", 0, raw: nil, selected: nil, owner: extra)
            let body = word("Следующая реплика.", 0.08, raw: tb, selected: tb, owner: b, map: both)
            value.transcriptSegments = [quote, body]
            let original = value.transcriptSegments
            let names = Dictionary(uniqueKeysWithValues: value.speakers.map { ($0.id, $0.displayName) })
            let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: original, in: value)
            check(paragraphs.count == 1 && paragraphs[0].firstSegment.id == quote.id
                  && paragraphs[0].captionSegment.id == body.id,
                  "Leading typography keeps its source member while the lexical word owns its caption")
            let presentation = MeetingTranscriptExporter.speakerPresentation(for: paragraphs[0],
                in: value, speakerNames: names)
            let reading = MeetingTranscriptExporter.speakerPresentations(in: value)
            check(presentation.participantID == b && presentation.participantIndex == 1
                  && reading[quote.id] == presentation && reading[body.id] == presentation,
                  "Paragraph and live reading map share the lexical owner's full-list color slot")
            check(value.readableSpeakers.map(\.id) == [b]
                  && value.speakers.firstIndex(where: { $0.id == extra }) == 2,
                  "Hidden typography-only people reserve palette slots without entering the readable roster")
            let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(value))
            check(MeetingTranscriptExporter.speakerPresentations(in: restored)[body.id] == presentation
                  && restored.transcriptSegments == original,
                  "Reopen preserves the resolved color owner and every original source member")
        }
        do {
            var value = session
            for index in value.speakers.indices { value.speakers[index].generatedParticipantNumber = index + 1 }
            let tc = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "noise-c")
            let punctuation = word(".", 5, raw: tc, selected: tc, owner: extra, map: [tc: extra])
            let short = word("я", 5.1, raw: nil, selected: nil, owner: nil, rule: .insufficientSupport)
            let real = word("Следующая реплика.", 10, raw: tb, selected: tb, owner: b, map: both)
            value.transcriptSegments = [punctuation, short, real]
            let reading = MeetingTranscriptExporter.speakerPresentations(in: value)
            check(reading[short.id]?.participantID == nil,
                  "Punctuation-only native evidence cannot sponsor a phantom owner for a short lexical fragment")
            check(value.readableSpeakers.map(\.id) == [b], "A punctuation-only native person stays out of the roster")
            let portable = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: value)) as! [String: Any]
            let roster = Set((portable["speakers"] as! [[String: Any]]).compactMap { $0["id"] as? String })
            check((portable["segments"] as! [[String: Any]]).allSatisfy {
                ($0["speakerID"] as? String).map(roster.contains) ?? true
            }, "Every readable export participant reference belongs to its visible roster")
        }
        do {
            var value = session
            value.speakers[0].generatedParticipantNumber = 1
            value.speakers[0].isLocalUser = true
            value.speakers[1].generatedParticipantNumber = 2
            value.speakers[2].generatedParticipantNumber = 3
            value.speakers[2].identityIsProvisional = true
            let first = word("Да", 0, raw: ta, selected: ta, owner: a, map: both)
            let comma = word(",", 0.08, raw: nil, selected: nil, owner: extra)
            let reply = word("нет", 1, raw: tb, selected: tb, owner: b, map: both)
            let number = word("42", 1.2, raw: tb, selected: tb, owner: b, map: both)
            let noise = ["-", "\u{2014}", "...", " \t\n", "\u{200B}\u{2060}\u{FEFF}",
                         "\u{034F}", "\u{FE0F}", "\u{0301}", "\u{115F}"]
                .enumerated().map { word($0.element, 6 + Double($0.offset), raw: nil, selected: nil, owner: extra) }
            var mask = word("***", 20, raw: tb, selected: tb, owner: b, map: both)
            mask.containsPrivacyReplacement = true
            value.transcriptSegments = [first, comma, reply, number] + noise + [mask]
            let original = value.transcriptSegments
            let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: original, in: value)
            check(paragraphs.first?.text == "Да,", "Adjacent punctuation remains inside a normal phrase")
            check(paragraphs.flatMap(\.segments).map(\.id) == [first.id, comma.id, reply.id, number.id, mask.id],
                  "Standalone artifacts have no readable paragraph; useful replies, numbers and privacy masks survive")
            check(value.readableSpeakers.map(\.id) == [a, b], "Noise-only generated people stay out of the roster")
            check(value.speakers.map(\.generatedParticipantNumber) == [1, 2, 3],
                  "Rendering never renumbers existing people or rewrites evidence")
            let reading = MeetingTranscriptExporter.speakerPresentations(in: value)
            check(noise.allSatisfy { reading[$0.id] == nil } && reading[comma.id]?.participantID == a,
                  "Live projection shares artifact suppression and typography ownership without native reassignment")
            check(value.transcriptSegments == original, "Reading does not mutate original native evidence")
            var onlyNoise = value
            onlyNoise.transcriptSegments = noise
            check(onlyNoise.readableSpeakers.isEmpty
                  && MeetingTranscriptExporter.displayParagraphs(for: noise, in: onlyNoise).isEmpty
                  && MeetingTranscriptExporter.speakerPresentations(in: onlyNoise).isEmpty
                  && MeetingTranscriptExporter.text(for: onlyNoise).isEmpty,
                  "A noise-only meeting has no readable rows, speaker headers or automatically visible people")
            var adjacent = value
            let quote = word("\"", 0.16, raw: nil, selected: nil, owner: extra)
            adjacent.transcriptSegments = [first, comma, quote]
            check(MeetingTranscriptExporter.displayParagraphs(for: adjacent.transcriptSegments, in: adjacent)
                .flatMap(\.segments).map(\.id) == [first.id, comma.id, quote.id],
                "A contiguous run of punctuation retains every original member")
            let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(value))
            check(restored.transcriptSegments == original && restored.readableSpeakers.map(\.id) == [a, b],
                  "Stop and reopen preserve source evidence while keeping noise out of the roster")
            check(MeetingTranscriptExporter.text(for: restored) == MeetingTranscriptExporter.text(for: value)
                  && MeetingTranscriptExporter.text(for: value).contains("***"),
                  "Readable export preserves protected masks and remains stable after reopen")
            value.speakers[2].usesCustomDisplayName = true
            value.speakers[2].displayName = "Manual alias"
            check(value.readableSpeakers.last?.displayName == "Manual alias", "A manual alias is never removed by automatic roster filtering")
            for text in ["да", "нет", "я", "Ёё", "0", "3.14", "[ИМЯ]"] {
                check(MeetingTranscriptSegment.textContainsLexicalContent(text), "Useful short text remains lexical: \(text)")
            }
            for text in ["\u{034F}", "\u{FE0F}", "\u{0301}", "\u{115F}", "\u{1160}"] {
                check(!MeetingTranscriptSegment.textContainsLexicalContent(text), "Invisible and combining-only scalars do not sponsor speech")
            }
            check(MeetingTranscriptSegment.textContainsLexicalContent("е\u{0301}"), "Diacritics in actual lexical speech remain intact")
        }
        do {
            var provisional = word("A synthetic reply.", 4, raw: nil, selected: nil, owner: b,
                rule: .insufficientSupport)
            provisional.attributionState = .unassigned
            provisional.speakerIdentityIsProvisional = true
            var value = session
            value.speakers[1].identityIsProvisional = true
            value.transcriptSegments = [word("An earlier voice.", 0, raw: ta, selected: ta, owner: a, map: both), provisional]
            let reading = MeetingTranscriptExporter.speakerPresentations(in: value)
            let presentation = reading[provisional.id]!
            check(presentation.participantID == b && presentation.isEstimated,
                  "A saved legacy participant retains its readable identity and internal uncertainty")
            let speakerNames = Dictionary(uniqueKeysWithValues: value.speakers.map { ($0.id, $0.displayName) })
            let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: value.transcriptSegments, in: value)
            for language in [PichiInterfaceLanguage.english, .russian] {
                check(MeetingTranscriptExporter.speakerLabel(for: presentation, language: language) == "Другое имя"
                      && MeetingTranscriptExporter.captionLabel(for: presentation, language: language) == "Другое имя"
                      && MeetingTranscriptExporter.captionLabel(for: paragraphs[1], in: value,
                          speakerNames: speakerNames, language: language) == "Другое имя",
                      "Live, history and readable-export captions never append legacy uncertainty in either language")
            }
            check(MeetingTranscriptExporter.text(for: value) == "[00:00] Имя Ёё: An earlier voice.\n\n[00:04] Другое имя: A synthetic reply.",
                  "Readable export keeps the complete reply and unqualified participant name")
            let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(value))
            check(MeetingTranscriptExporter.speakerPresentations(in: restored)[provisional.id] == presentation,
                  "Legacy identity and internal uncertainty survive Stop and reopen")
            check(MeetingTranscriptExporter.text(for: restored) == MeetingTranscriptExporter.text(for: value),
                  "Stop and reopen keep readable export free of generated uncertainty suffixes")
            let exported = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.json(for: value)) as! [String: Any]
            let exportedSpeakers = exported["speakers"] as! [[String: Any]]
            check(exportedSpeakers.contains { $0["identityIsProvisional"] as? Bool == true },
                  "Canonical export preserves preliminary identity provenance")
            let portable = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: value)) as! [String: Any]
            check((portable["speakers"] as! [[String: Any]]).contains { $0["identityIsProvisional"] as? Bool == true },
                  "Protected transcript-only export preserves preliminary provenance without native acoustic data")
            value.transcriptSegments[1].isUserSpeakerAssigned = true
            value.transcriptSegments[1].attributionState = .assigned
            value.transcriptSegments[1].speakerAttribution = nil
            check(!MeetingTranscriptExporter.speakerPresentation(for: value.transcriptSegments[1], in: value).isEstimated,
                  "An explicit user participant correction overrides the preliminary marker")
            value.transcriptSegments[1] = provisional
            value.speakers[1].identityIsProvisional = false
            value.transcriptSegments[1].attributionState = .assigned
            value.transcriptSegments[1].speakerAttribution = nil
            check(!MeetingTranscriptExporter.speakerPresentation(for: value.transcriptSegments[1], in: value).isEstimated,
                  "One qualified identity record refines older word references without rewriting text")
        }
        for alias in ["Участник 2", "Имя (provisional)", "Имя (предварительно)"] {
            for isLocalUser in [false, true] {
                let name = MeetingSpeakerPresentation.Name(displayName: alias, isLocalUser: isLocalUser,
                    usesCustomDisplayName: true, isProvisional: true)
                for label in [MeetingSpeakerPresentation.Label.identified(name), .estimated(name)] {
                    let presentation = MeetingSpeakerPresentation(identity: "synthetic-legacy-alias", label: label)
                    for language in [PichiInterfaceLanguage.english, .russian] {
                        check(MeetingTranscriptExporter.captionLabel(for: presentation, language: language) == alias,
                              "Uncertainty formatting never rewrites a user-provided alias, including literal suffix words")
                    }
                }
            }
        }
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

        let incoming = word("Начало.", 2.16, raw: ta, selected: ta, owner: a, map: both)
        let secondUnknown = word("ещё", 0.2, raw: nil, selected: nil, owner: nil, rule: .insufficientSupport)
        for revision in [0, 1, 7] {
            var prefix = unknown
            prefix.revision = revision
            if revision == 0 { prefix.speakerAttribution = nil } // Current compact native publication.
            session.transcriptSegments = [prefix, secondUnknown, incoming]
            let original = session, originalJSON = try MeetingTranscriptExporter.json(for: session)
            let reading = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
            check(reading.count == 1 && reading[0].segments == session.transcriptSegments,
                  "A bounded leading unsupported phrase joins its first independent incoming participant")
            check(reading[0].firstSegment.start == prefix.start
                  && MeetingTranscriptExporter.timestampText(reading[0].firstSegment.start.seconds) == "00:00",
                  "The joined turn keeps the leading speech's original start time")
            let labels = MeetingTranscriptExporter.speakerPresentations(in: session)
            check(labels.values.allSatisfy { $0.participantID == a && $0.isEstimated },
                  "The leading-neighbor convention is an estimated reading owner, not new acoustic evidence")
            let paragraphPresentation = MeetingTranscriptExporter.speakerPresentation(
                for: reading[0], in: session, speakerNames: names)
            check(paragraphPresentation == labels[prefix.id],
                  "Mobile paragraph styling and the desktop/live map resolve the same reading participant")
            check(paragraphPresentation.participantIndex == 0 && paragraphPresentation.markingEstimated().participantIndex == 0,
                  "Reading labels retain the participant's canonical admission slot")
            var merged = session
            merged.speakers[0].mergedIntoSpeakerID = b
            let mergedParagraph = MeetingTranscriptExporter.speakerPresentation(
                for: reading[0], in: merged, speakerNames: names)
            check(mergedParagraph.participantID == b && mergedParagraph.participantIndex == 1,
                  "A projected alias uses its active participant's color without recoloring other identities")
            check(MeetingTranscriptExporter.text(for: session) == "[00:00] Имя Ёё: Я ещё Начало.",
                  "Text export and the saved reading view share the incoming participant and complete phrase")
            let projected = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: session)) as! [String: Any]
            let projectedRows = projected["segments"] as! [[String: Any]]
            check(projectedRows.count == 1 && projectedRows[0]["speakerID"] as? String == a.uuidString
                  && projectedRows[0]["text"] as? String == "Я ещё Начало.",
                  "Portable reading export retains every leading word under the same projected participant")
            let unchangedJSON = try MeetingTranscriptExporter.json(for: session)
            check(session == original && originalJSON == unchangedJSON,
                  "Leading-neighbor projection preserves canonical JSON, native timing, frozen metadata and manual names")
        }
        for (start, expectedOwner) in [(2.16, true), (3.54, true), (3.540_001, false)] {
            session.transcriptSegments = [unknown, word("Начало.", start, raw: ta, selected: ta, owner: a, map: both)]
            check((MeetingTranscriptExporter.speakerPresentations(in: session)[unknown.id]?.participantID == a) == expectedOwner,
                  "A single leading word uses the exact existing unknown horizon including its wait for the incoming voice")
        }
        func leadingRemainsAnonymous(_ value: MeetingSession, _ reason: String) {
            check(MeetingTranscriptExporter.speakerPresentations(in: value)[unknown.id]?.participantID == nil, reason)
        }
        let leadingBase: MeetingSession = {
            var value = session; value.transcriptSegments = [unknown, secondUnknown, incoming]; return value
        }()
        for kind in 0..<8 {
            var blocked = leadingBase
            switch kind {
            case 0:
                blocked.transcriptSegments[1].sourceTrackID = UUID()
            case 1:
                blocked.transcriptCoverageGaps = [.init(trackID: source, start: 0.15, end: 1, reason: .processingFailed)]
            case 2:
                blocked.transcriptSegments[0].isUserTextEdited = true
            case 3:
                blocked.transcriptSegments[1] = word("другой голос", 0.2, raw: tb, selected: nil, owner: nil,
                                                    rule: .insufficientSupport)
            case 4:
                blocked.transcriptSegments[0].attributionState = .timingUncertain
            case 5:
                blocked.transcriptSegments[0].isLikelyEcho = true
            case 6:
                blocked.transcriptSegments[2] = first // Incoming source evidence arrives beyond the existing horizon.
            default:
                blocked.transcriptSegments[0].originalText = "Manually corrected original"
            }
            leadingRemainsAnonymous(blocked, "A source, acoustic, edit, timing or long-gap barrier blocks leading-neighbor ownership (\(kind))")
        }
        let independentFirst = word("Да.", 0.04, raw: tb, selected: tb, owner: b, map: both)
        session.transcriptSegments = [independentFirst, incoming]
        let independentLeading = MeetingTranscriptExporter.speakerPresentations(in: session)
        check(independentLeading[independentFirst.id]?.participantID == b
              && independentLeading[incoming.id]?.participantID == a,
              "An independently assigned first short reply is never reassigned to the next participant")

        let previousTurn = word("Прошлая реплика.", 1_921.88, raw: ta, selected: ta, owner: a, map: both)
        let incomingPrefix = word("А", 1_934.32, raw: nil, selected: nil, owner: nil, rule: .insufficientSupport)
        let nextTurn = word("ты", 1_934.48, raw: tb, selected: tb, owner: b, map: both)
        var pauseBase = session
        pauseBase.transcriptSegments = [previousTurn, incomingPrefix, nextTurn]
        for compact in [true, false] {
            var value = pauseBase
            value.transcriptSegments[1].revision = compact ? 0 : 7
            if compact { value.transcriptSegments[1].speakerAttribution = nil }
            let original = value, beforeJSON = try MeetingTranscriptExporter.json(for: value)
            let reading = MeetingTranscriptExporter.displayParagraphs(for: value.transcriptSegments, in: value)
            check(reading.count == 2 && reading[1].segments == Array(value.transcriptSegments.suffix(2)),
                  "An unsupported new-turn prefix after a pause joins its immediate independent incoming neighbor")
            check(reading[1].firstSegment.start == incomingPrefix.start && reading[1].projectedSpeakerID == b,
                  "The incoming turn keeps the original prefix time and the next participant's existing UUID")
            let projected = MeetingTranscriptExporter.speakerPresentations(in: value)
            check(projected[incomingPrefix.id]?.participantID == b && projected[incomingPrefix.id]?.isEstimated == true,
                  "New-turn incoming ownership remains a contextual reading estimate")
            check(MeetingTranscriptExporter.text(for: value).contains("[32:14] Другое имя: А ты"),
                  "The complete reading export includes the unsupported prefix under the incoming manual name")
            let afterJSON = try MeetingTranscriptExporter.json(for: value)
            check(value == original && beforeJSON == afterJSON,
                  "Pause-prefix projection preserves native uncertainty, frozen metadata, source words and manual names")
        }
        var multiplePrefix = pauseBase
        multiplePrefix.transcriptSegments = [previousTurn, incomingPrefix,
            word("ещё", 1_934.44, raw: nil, selected: nil, owner: nil, rule: .insufficientSupport),
            word("ты", 1_934.64, raw: tb, selected: tb, owner: b, map: both)]
        let multipleReading = MeetingTranscriptExporter.displayParagraphs(for: multiplePrefix.transcriptSegments, in: multiplePrefix)
        check(multipleReading.count == 2 && multipleReading[1].segments == Array(multiplePrefix.transcriptSegments.dropFirst())
              && multipleReading[1].projectedSpeakerID == b,
              "Every unsupported member of a bounded new-turn prefix joins the incoming participant without losing words")
        for kind in 0..<11 {
            var blocked = pauseBase
            switch kind {
            case 0: blocked.transcriptSegments[1].isUserTextEdited = true
            case 1:
                blocked.transcriptSegments[1] = word("А", 1_934.32, raw: ta, selected: nil, owner: nil,
                                                    rule: .insufficientSupport)
            case 2:
                blocked.transcriptCoverageGaps = [.init(trackID: source, start: 1_930, end: 1_931, reason: .processingFailed)]
            case 3:
                let otherEpoch = MeetingAnalysisEpochID(trackID: source, ordinal: 1)
                let otherToken = MeetingBackendSpeakerToken(analysisEpochID: otherEpoch, label: "voice-b")
                blocked.transcriptSegments[2] = word("ты", 1_934.48, raw: otherToken, selected: otherToken, owner: b,
                                                    map: [otherToken: b])
            case 4:
                blocked.transcriptSegments[0] = word("Рядом.", 1_934.12, raw: ta, selected: ta, owner: a, map: both)
                blocked.transcriptSegments[2] = word("ты", 1_936.4, raw: tb, selected: tb, owner: b, map: both)
            case 5: blocked.transcriptSegments[1].sourceTrackID = UUID()
            case 6:
                blocked.transcriptSegments[2] = word("ты", 1_938, raw: tb, selected: tb, owner: b, map: both)
            case 7:
                blocked.transcriptSegments[1].attributionState = .timingUncertain
            case 8: blocked.transcriptSegments[0].isUserTextEdited = true
            case 9: blocked.transcriptSegments[2].isUserTextEdited = true
            default: blocked.transcriptSegments[1].overlap = .ambiguous
            }
            check(MeetingTranscriptExporter.speakerPresentations(in: blocked)[blocked.transcriptSegments[1].id]?.participantID == nil,
                  "A manual, candidate, gap, epoch, nearby outgoing, source or timing barrier blocks one-sided incoming ownership (\(kind))")
        }

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

        var gap = word("фрагмент", 15, raw: nil, selected: nil, owner: nil, rule: .insufficientSupport)
        gap.end = .init(value: 15_200, timescale: 1_000)
        gap.nativeTiming = .init(start: 15, end: 15.2) // Outside the tiny residual convention.
        let returning = word("Возврат.", 22, raw: ta, selected: ta, owner: a, map: both)
        session.transcriptSegments = [first, gap, returning]
        let full = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
        check(full.count == 3 && full[2].showsSpeakerLabel,
              "Every known paragraph timestamp repeats its participant even after an unresolved run")
        check(MeetingTranscriptExporter.captionLabel(for: full[2], in: session, speakerNames: names) == "Имя Ёё",
              "A returning known paragraph never leaves a bare timestamp")
        let excerpt = MeetingTranscriptExporter.text(for: session, segmentIDs: [returning.id])
        check(excerpt.contains("Имя Ёё: Возврат."),
              "An isolated excerpt retains the same participant as the complete document")

        // The ordinary optimized app previously rejected Cyrillic lexical residuals while
        // the isolated core accepted them. Exercise the actual reading rule, not a copy
        // of the Unicode predicate; native Release UI checks cover the full-module route.
        for lexical in ["А", "И", "я", "Ё", "ё", "7", "A"] {
            var outgoing = word("Конец.", 58.84, raw: ta, selected: ta, owner: a, map: both)
            outgoing.end = .init(value: 60_000, timescale: 1_000)
            outgoing.nativeTiming = .init(start: 58.84, end: 60)
            outgoing.speakerAttribution = nil
            var residual = word(lexical, 60, raw: nil, selected: nil, owner: nil, rule: .insufficientSupport)
            residual.end = .init(value: 60_040, timescale: 1_000)
            residual.nativeTiming = .init(start: 60, end: 60.04)
            residual.speakerAttribution = nil
            let next = word("Вопрос?", 62.44, raw: tb, selected: tb, owner: b, map: both)
            session.transcriptSegments = [outgoing, residual, next]
            let unchanged = session
            let reading = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
            check(reading.count == 2 && reading[0].segments.map(\.id) == [outgoing.id, residual.id]
                  && reading[0].text == "Конец. " + lexical,
                  "A short supported-boundary lexical residual remains in its outgoing reading turn: " + lexical)
            check(reading.last?.segments == [next] && session == unchanged,
                  "Residual typography preserves the next independent participant and all canonical evidence")
        }

        session.speakers[0].isLocalUser = true
        session.transcriptSegments = [unknown, incoming]
        for custom in [nil, false, true] as [Bool?] {
            session.speakers[0].usesCustomDisplayName = custom
            for language in [PichiInterfaceLanguage.english, .russian] {
                let expected = custom == true ? session.speakers[0].displayName
                    : PichiLocalization.text("You", language: language, bundle: .main)
                check(MeetingTranscriptExporter.speakerDisplayName(session.speakers[0], language: language) == expected,
                      "An explicit owner alias replaces the localized owner marker without inspecting the name")
                let presentation = MeetingTranscriptExporter.speakerPresentation(for: incoming, in: session)
                check(MeetingTranscriptExporter.speakerLabel(for: presentation, language: language) == expected,
                      "Direct participant labels honor the explicit owner alias")
                if case let .identified(name) = presentation.label {
                    check(name.isLocalUser, "A custom owner alias preserves the presentation's owner identity")
                } else { check(false, "The independent owner word remains identified") }
                let projected = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)[0]
                check(MeetingTranscriptExporter.speakerLabel(for: projected, in: session,
                    speakerNames: names, language: language) == expected,
                      "Estimated reading paragraphs use the same owner alias as independent words")
                check(MeetingTranscriptExporter.captionLabel(for: projected, in: session,
                    speakerNames: names, language: language) == expected,
                      "Live and saved captions share the custom owner label")
            }
        }
        let ownerJSON = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.json(for: session)) as! [String: Any]
        let ownerRows = ownerJSON["speakers"] as! [[String: Any]]
        check(ownerRows.first(where: { $0["id"] as? String == a.uuidString })?["usesCustomDisplayName"] as? Bool == true,
              "Canonical speaker export retains explicit custom-name provenance")
        try self.checkTinyUnsupportedReadingResidual(check)
    }

    private static func checkTinyUnsupportedReadingResidual(_ check: (Bool, String) -> Void) throws {
        let track = UUID(), owner = UUID(), other = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "synthetic-owner")
        let otherToken = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "synthetic-other")
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic residual reading",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic source")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.state = .completed; session.endedAt = session.startedAt.addingTimeInterval(100)
        session.piiRedactionEnabled = true; session.audioStorageMode = .memoryOnly
        session.transcriptIsComplete = true
        session.speakers = [(owner, "Synthetic owner"), (other, "Synthetic reply")].map {
            .init(id: $0.0, displayName: $0.1, diarizationClusterID: nil, trackKind: .microphone,
                  isLocalUser: false, identityCandidates: [])
        }
        func word(_ text: String, _ start: Double, _ end: Double,
                  speaker: UUID?, native: MeetingBackendSpeakerToken?) -> MeetingTranscriptSegment {
            .init(id: UUID(), start: .init(value: Int64((start * 1_000).rounded()), timescale: 1_000),
                end: .init(value: Int64((end * 1_000).rounded()), timescale: 1_000), sourceTrackID: track,
                speakerID: speaker, text: text, revision: 0, status: .final, overlap: .none, completeness: .complete,
                attributionState: speaker == nil ? .unassigned : .assigned, nativePrecision: .word,
                nativeUnitID: "synthetic-residual:\(UUID())", nativeSpeakerAssignment: native.map { .assigned($0) } ?? .unassigned,
                nativeTiming: .init(start: start, end: end))
        }
        func fixture(beforeEnd: Double = 7.28, start: Double = 40, end: Double = 40.04,
                     incomingStart: Double = 47.12) -> MeetingSession {
            var value = session
            value.transcriptSegments = [word("Первая реплика.", max(0, beforeEnd - 0.36), beforeEnd, speaker: owner, native: token),
                word("А", start, end, speaker: nil, native: nil),
                word("продолжение.", incomingStart, incomingStart + 0.12, speaker: owner, native: token)]
            return value
        }
        func residualOwner(_ value: MeetingSession) -> UUID? {
            MeetingTranscriptExporter.speakerPresentations(in: value)[value.transcriptSegments[1].id]?.participantID
        }
        for shape in [(7.28, 40.0, 40.04, 47.12), (51.72, 80.0, 80.04, 86.72)] {
            let base = fixture(beforeEnd: shape.0, start: shape.1, end: shape.2, incomingStart: shape.3)
            for state in [MeetingSessionState.recording, .completed] {
                var value = base; value.state = state
                let original = value, canonical = try MeetingTranscriptExporter.json(for: value)
                let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: value.transcriptSegments, in: value)
                check(paragraphs.count == 1 && paragraphs[0].segments == value.transcriptSegments
                    && paragraphs[0].text == "Первая реплика. А продолжение.",
                      "A tiny unsupported island between the same independent voice stays in its reading phrase across silence")
                let presentations = MeetingTranscriptExporter.speakerPresentations(in: value)
                check(presentations.values.allSatisfy { $0.participantID == owner },
                      "Every reading member, including the unsupported island, shares the established participant")
                let startLabel = MeetingTranscriptExporter.timestampText(value.transcriptSegments[0].start.seconds)
                check(MeetingTranscriptExporter.text(for: value) == "[\(startLabel)] Synthetic owner: Первая реплика. А продолжение.",
                      "Plain export uses the same joined phrase as live and saved reading")
                if state == .completed {
                    let portable = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: value)) as! [String: Any]
                    let rows = portable["segments"] as! [[String: Any]]
                    check(rows.count == 1 && rows[0]["speakerID"] as? String == owner.uuidString
                        && rows[0]["text"] as? String == paragraphs[0].text,
                          "Protected export shares the joined reading phrase and its existing participant UUID")
                }
                let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(value))
                check(restored == original && MeetingTranscriptExporter.speakerPresentations(in: restored)
                    == presentations, "Production archive round-trip preserves the same reading result")
                let repeatedCanonical = try MeetingTranscriptExporter.json(for: value)
                check(value == original && repeatedCanonical == canonical
                    && value.transcriptSegments[1].nativeSpeakerAssignment == .unassigned
                    && value.transcriptSegments[1].speakerID == nil,
                      "Reading attachment preserves raw ownership, IDs, native timestamps, revisions and canonical JSON")
            }
        }
        check(residualOwner(fixture(end: 40.08)) == owner,
              "The existing 80 ms residual boundary is inclusive without extending the acoustic policy")
        check(residualOwner(fixture(end: 40.080_001)) == nil,
              "A residual above the existing cap cannot bridge arbitrary pauses")
        var multiple = fixture(end: 40.04)
        multiple.transcriptSegments.insert(word("ё", 40.04, 40.08, speaker: nil, native: nil), at: 2)
        check(MeetingTranscriptExporter.displayParagraphs(for: multiple.transcriptSegments, in: multiple).count == 1,
              "A tiny multiword residual uses its total native span rather than per-word caps")

        for kind in 0..<23 {
            var blocked = fixture()
            switch kind {
            case 0: blocked.transcriptSegments[1].nativePrecision = .utterance
            case 1: blocked.transcriptSegments[0].nativePrecision = .utterance
            case 2: blocked.transcriptSegments[2].nativePrecision = .utterance
            case 3: blocked.transcriptSegments[1].overlap = .ambiguous
            case 4: blocked.transcriptSegments[2].overlap = .ambiguous
            case 5: blocked.transcriptSegments[1].isUserTextEdited = true
            case 6: blocked.transcriptSegments[0].isUserSpeakerAssigned = true
            case 7: blocked.transcriptSegments[1].isUserSpeakerAssigned = true
            case 8: blocked.transcriptSegments[2].isUserSpeakerAssigned = true
            case 9: blocked.transcriptSegments[1].attributionState = .timingUncertain
            case 10: blocked.transcriptSegments[1].completeness = .incompleteTrack
            case 11: blocked.transcriptSegments[1].status = .provisional
            case 12: blocked.transcriptSegments[1].originalText = "Synthetic manual original"
            case 13: blocked.transcriptSegments[0].revision = 1 // Absent explicit provenance retains the legacy guard.
            case 14: blocked.transcriptSegments[2].nativeSpeakerAssignment = .assigned(otherToken)
            case 15: blocked.transcriptSegments[2].speakerID = other
            case 16:
                let newToken = MeetingBackendSpeakerToken(analysisEpochID: .init(trackID: track, ordinal: 1), label: token.label)
                blocked.transcriptSegments[2].nativeSpeakerAssignment = .assigned(newToken)
            case 17: blocked.transcriptSegments[2].sourceTrackID = UUID()
            case 18: blocked.transcriptSegments[1].start = .init(value: 40_020, timescale: 1_000)
            case 19: blocked.transcriptCoverageGaps = [.init(trackID: track, start: 20, end: 21, reason: .processingFailed)]
            case 20: blocked.transcriptCoverageGaps = [.init(trackID: track, start: 43, end: 44, reason: .processingFailed)]
            case 21:
                var excluded = word("Synthetic excluded evidence", 43, 44, speaker: nil, native: nil)
                excluded.isLikelyEcho = true
                blocked.transcriptSegments.insert(excluded, at: 2)
            default:
                let id = blocked.transcriptSegments[1].nativeUnitID!
                let candidate = MeetingSpeakerAttributionCandidateSupport(token: otherToken,
                    intervals: [.init(start: 40, end: 40.04)], supportSeconds: 0.04, isSuppressed: false)
                let decision = MeetingSpeakerAttributionDecision(unitID: id, rawAssignment: .unassigned,
                    candidates: [candidate], activeSupportSeconds: 0.04, simultaneousIntervals: [], relation: .single,
                    selectedToken: nil, rule: .insufficientSupport, cueUnitIDs: [], backgroundTokens: [],
                    policyVersion: 2, policyFingerprint: "synthetic-other-candidate")
                blocked.transcriptSegments[1].speakerAttribution = .init(decision: decision, speakerIDs: [:])
            }
            check(residualOwner(blocked) == nil,
                  "Manual, competing, overlapping, imprecise or discontinuous evidence blocks tiny residual reading (\(kind))")
        }
        var leading = fixture(); leading.transcriptSegments.removeFirst()
        check(MeetingTranscriptExporter.speakerPresentations(in: leading)[leading.transcriptSegments[0].id]?.participantID == nil,
              "The pause exception never assigns a leading fragment without two independent anchors")
        var trailing = fixture(); trailing.transcriptSegments.removeLast()
        check(residualOwner(trailing) == nil,
              "The pause exception never assigns a terminal lexical fragment without an incoming anchor")
        var nextTurn = fixture()
        nextTurn.transcriptSegments.append(word("Другой ответ.", 95, 96, speaker: other, native: otherToken))
        let turns = MeetingTranscriptExporter.displayParagraphs(for: nextTurn.transcriptSegments, in: nextTurn)
        check(turns.count == 2 && turns[0].segments.count == 3 && turns[1].segments.count == 1,
              "Joining the residual preserves the next independent participant's paragraph break")
        var explicit = fixture()
        explicit.transcriptSegments[1].isUserSpeakerAssigned = true
        let object = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.json(for: explicit)) as! [String: Any]
        check((object["segments"] as! [[String: Any]])[1]["isUserSpeakerAssigned"] as? Bool == true,
              "Canonical export preserves the explicit participant-assignment boundary")
    }
}
