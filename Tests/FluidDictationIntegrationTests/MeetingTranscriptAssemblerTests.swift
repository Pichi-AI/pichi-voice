#if os(iOS)
@testable import PichiVoiceMobile
#else
@testable import FluidVoice_Debug
#endif
import Foundation
import XCTest

private nonisolated struct AssemblerFixtureObserver: MeetingChunkAudioObserving {
    let results: [MeetingAnalysisChunkKey: MeetingChunkObservationResult]

    func observe(
        chunk: MeetingAudioChunk,
        trackID: MeetingAudioTrackID
    ) -> MeetingChunkObservationResult {
        self.results[MeetingAnalysisChunkKey(trackID: trackID, chunkID: chunk.id)]
            ?? .failed(.unreadable, detail: "No fixture observation")
    }
}

/// Stage C2b1 of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md`: the pure assembler. Every fixture
/// builds a real manifest through `MeetingAnalysisManifestBuilder` so units, receipts and gaps are
/// exercised against spans the validator actually proved.
final class MeetingTranscriptAssemblerTests: XCTestCase {
    private let backendID = MeetingBackendID(rawValue: "fixture.assembler")
    // Frozen attempts predating stable opening retain preliminary reading identities. These
    // fixtures exercise that replay contract explicitly instead of inheriting today's default.
    private let provisionalPolicy = MeetingSpeakerAttributionPolicy(enableProvisionalSpeakerIdentities: true)

    // Deliberately disable the historical-reading fallbacks. These fixtures must acquire
    // coherent participants from the production emission context before any renderer runs.
    private var emissionPolicy: MeetingSpeakerAttributionPolicy {
        .init(enableNeighborResolution: false, enableBriefInterruption: false,
              enableMainSpeakerContinuation: false, enableTokenEmissionContext: true)
    }

    private func emissionFixture(epoch: MeetingAnalysisEpochID, spans: [String] = [])
        -> (units: [MeetingFinalTextUnit], activity: [MeetingBackendSpeakerActivity]) {
        let first = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "first")
        let second = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "second")
        let specs: [(String, Double, Double, MeetingBackendSpeakerAssignment, String, Int)] = [
            ("Earlier", 0, 1.2, .assigned(second), "previous", 2),
            ("New", 3.08, 3.12, .unassigned, "current", 0),
            ("phrase", 4.44, 4.84, .assigned(first), "current", 1),
            ("continues", 5, 5.4, .assigned(first), "current", 2),
            ("Reply", 8, 8.04, .assigned(second), "current", 3)]
        let units = specs.enumerated().map { index, value in
            MeetingFinalTextUnit(id: "emission-\(index)", trackID: epoch.trackID, analysisEpochID: epoch,
                precision: .word, text: value.0, analysisStart: value.1, analysisEnd: value.2,
                speaker: value.3, analysisSpanIDs: spans,
                wordTimingProvenance: .init(basis: .tokenEmission,
                    sourceWindowID: "\(epoch):\(value.4)", sourceWordIndex: value.5))
        }
        return (units, [.init(token: second, start: 0, end: 1.3),
                        .init(token: first, start: 4.09, end: 7),
                        .init(token: second, start: 8, end: 10)])
    }

    func testEmissionOnsetJoinsItsTurnBeforeReadingFallbackWithoutChangingNativeEvidence() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let fixture = self.emissionFixture(epoch: epoch)
        let result = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: UUID(), epoch: epoch,
            offset: 0, duration: 11, units: fixture.units, activity: fixture.activity,
            speakerAttributionPolicy: self.emissionPolicy)
        let opening = result.segments[1], anchor = result.segments[2]
        XCTAssertNotNil(opening.speakerID)
        XCTAssertEqual(opening.speakerID, anchor.speakerID)
        XCTAssertNotEqual(opening.speakerID, result.segments[0].speakerID)
        XCTAssertEqual(result.segments[4].speakerID, result.segments[0].speakerID,
                       "A real short reply remains with its independently supported participant")
        XCTAssertEqual(result.segments.map(\.text), fixture.units.map(\.text))
        XCTAssertEqual(opening.nativeTiming, .init(start: 3.08, end: 3.12))
        XCTAssertEqual(opening.nativeSpeakerAssignment, .unassigned)
        XCTAssertEqual(opening.speakerAttribution?.rawAssignment, .unassigned)
        XCTAssertEqual(opening.speakerAttribution?.rule, .incomingSpeaker)
        XCTAssertEqual(opening.nativeWordTimingProvenance, fixture.units[1].wordTimingProvenance)
        let decisions = try MeetingSpeakerAttribution.resolve(units: fixture.units,
            activity: fixture.activity, policy: self.emissionPolicy)
        let decision = try XCTUnwrap(decisions.first { $0.unitID == fixture.units[1].id })
        XCTAssertEqual(decision.activeSupportSeconds, 0, "Context does not invent voice in a decoder frame")
        XCTAssertEqual(decision.cueUnitIDs, [fixture.units[2].id])
        let raw = try MeetingSpeakerAttribution.acousticAssignments(
            units: fixture.units.map { $0.assigningSpeaker(.unassigned) },
            activity: fixture.activity, policy: self.emissionPolicy)
        XCTAssertEqual(raw[fixture.units[1].id], .unassigned)
        var session = self.readingFixture([]).0
        session.audioTracks[0].id = epoch.trackID
        session.speakers = result.speakers
        session.transcriptSegments = result.segments
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: result.segments, in: session)
        let turn = try XCTUnwrap(paragraphs.first { $0.segments.contains { $0.id == opening.id } })
        XCTAssertTrue(turn.segments.contains { $0.id == anchor.id }, "The opening is published in its following turn")
    }

    func testEmissionContextRefusesDifferentWindowFilteredPrefixAndMissingProvenance() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let fixture = self.emissionFixture(epoch: epoch)
        let original = fixture.units[1]
        let variants: [ASRWordTimingProvenance?] = [nil,
            .init(basis: .tokenEmission),
            .init(basis: .tokenEmission, sourceWindowID: "different", sourceWordIndex: 0),
            .init(basis: .tokenEmission, sourceWindowID: original.wordTimingProvenance?.sourceWindowID, sourceWordIndex: 2),
            .init(basis: .tokenEmission, sourceWindowID: "", sourceWordIndex: 0)]
        for metadata in variants {
            var units = fixture.units
            units[1] = .init(id: original.id, trackID: epoch.trackID, analysisEpochID: epoch,
                precision: .word, text: original.text, analysisStart: original.analysisStart,
                analysisEnd: original.analysisEnd, speaker: .unassigned, analysisSpanIDs: [],
                wordTimingProvenance: metadata)
            let decisions = try MeetingSpeakerAttribution.resolve(units: units,
                activity: fixture.activity, policy: self.emissionPolicy)
            XCTAssertNil(decisions.first { $0.unitID == original.id }?.selectedToken)
        }
    }

    func testEmissionAtRecordingOpeningDoesNotNeedAnInventedPreviousParticipant() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let fixture = self.emissionFixture(epoch: epoch)
        let units = Array(fixture.units.dropFirst())
        let decisions = try MeetingSpeakerAttribution.resolve(units: units,
            activity: Array(fixture.activity.dropFirst()), policy: self.emissionPolicy)
        let first = try XCTUnwrap(decisions.first { $0.unitID == units[0].id })
        guard case let .assigned(expected) = units[1].speaker else { return XCTFail("Fixture needs a real anchor") }
        XCTAssertEqual(first.selectedToken, expected)
        XCTAssertEqual(first.rule, .incomingSpeaker)
        XCTAssertEqual(first.rawAssignment, .unassigned)
    }

    func testEmissionContextRefusesInterveningVoicePrivacyBarrierAndAbsentAnchor() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let fixture = self.emissionFixture(epoch: epoch)
        let rival = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "other")
        let barrier = MeetingSpeakerAttributionContextBarrier(analysisEpochID: epoch,
            interval: .init(start: 3.5, end: 3.6))
        let cases: [([MeetingBackendSpeakerActivity], [MeetingSpeakerAttributionContextBarrier], Set<String>)] = [
            (fixture.activity + [.init(token: rival, start: 3.5, end: 3.54)], [], []),
            (fixture.activity, [barrier], []),
            (fixture.activity, [], [fixture.units[2].id]),
            ([], [], [])]
        for (activity, barriers, blocked) in cases {
            let decisions = try MeetingSpeakerAttribution.resolve(units: fixture.units, activity: activity,
                policy: self.emissionPolicy, barrierUnitIDs: blocked, contextualBarriers: barriers)
            XCTAssertNil(decisions.first { $0.unitID == fixture.units[1].id }?.selectedToken)
        }
        let supported = fixture.units[1].assigningSpeaker(.assigned(rival))
        var units = fixture.units; units[1] = supported
        let direct = try MeetingSpeakerAttribution.resolve(units: units,
            activity: fixture.activity + [.init(token: rival, start: 3.08, end: 3.12)], policy: self.emissionPolicy)
        XCTAssertEqual(direct.first { $0.unitID == supported.id }?.selectedToken, rival)
    }

    func testEmissionContextBoundIncludesTheWholeAnchorAndIsFrozen() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let fixture = self.emissionFixture(epoch: epoch)
        let first = fixture.units[1], next = fixture.units[2]
        for delta in [0.0, 0.000_01] {
            var units = fixture.units
            units[2] = .init(id: next.id, trackID: epoch.trackID, analysisEpochID: epoch, precision: .word,
                text: next.text, analysisStart: next.analysisStart,
                analysisEnd: first.analysisEnd + 2 + delta, speaker: next.speaker, analysisSpanIDs: [],
                wordTimingProvenance: next.wordTimingProvenance)
            units.remove(at: 3) // Keep this fixture free from an unrelated overlap barrier.
            let decisions = try MeetingSpeakerAttribution.resolve(units: units,
                activity: fixture.activity, policy: self.emissionPolicy)
            XCTAssertEqual(decisions.first { $0.unitID == first.id }?.selectedToken != nil, delta == 0)
        }
        let old = MeetingSpeakerAttributionPolicy(enableNeighborResolution: false,
            enableBriefInterruption: false, enableMainSpeakerContinuation: false)
        var encoded = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        encoded.removeValue(forKey: "enableTokenEmissionContext")
        encoded.removeValue(forKey: "maximumEmissionContextSeconds")
        let decoded = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONSerialization.data(withJSONObject: encoded))
        XCTAssertFalse(decoded.enableTokenEmissionContext)
        XCTAssertEqual(decoded.fingerprint, old.fingerprint)
        XCTAssertNotEqual(decoded.fingerprint, self.emissionPolicy.fingerprint)
        XCTAssertNil(try MeetingSpeakerAttribution.resolve(units: fixture.units,
            activity: fixture.activity, policy: decoded).first { $0.unitID == first.id }?.selectedToken)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONEncoder().encode(self.emissionPolicy)), self.emissionPolicy)
    }

    func testCanonicalEmissionTextSurvivesActivityGapButEchoSuppressionStillWins() throws {
        let (plan, manifest, span) = try self.onlineMicFixture(duration: 11)
        let fixture = self.emissionFixture(epoch: span.analysisEpochID, spans: [span.id])
        for suppressed in [false, true] {
            var echo = Dictionary(uniqueKeysWithValues: fixture.units.map { ($0.id, MeetingUnitEchoVerdict.notEcho) })
            if suppressed { echo[fixture.units[1].id] = .echoSuppressed(duplicateOfUnitID: nil) }
            let result = try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest,
                evidence: self.evidence(plan: plan, units: fixture.units, activity: fixture.activity),
                coverageReceipts: self.receipts(for: manifest), echoVerdicts: echo,
                speakerAttributionPolicy: self.emissionPolicy))
            let emitted = result.segments.first { $0.nativeUnitID == fixture.units[1].id }
            XCTAssertEqual(emitted != nil, !suppressed)
            if let emitted {
                XCTAssertNotNil(emitted.speakerID)
                XCTAssertEqual(emitted.speakerAttribution?.rule, .incomingSpeaker)
                XCTAssertEqual(emitted.nativeSpeakerAssignment, .unassigned)
            }
        }
        XCTAssertTrue(MeetingSpeakerActivityCoverage.isOutside(fixture.units[1],
            activityByEpoch: [span.analysisEpochID: fixture.activity]), "Old frozen admission remains unchanged")
        XCTAssertFalse(MeetingSpeakerActivityCoverage.isOutside(fixture.units[1],
            activityByEpoch: [span.analysisEpochID: fixture.activity], preservesTokenEmissions: true))
    }

    func testLiveEmissionWaitsForItsBoundedFollowingTurnAndMatchesStop() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0), attempt = UUID()
        let fixture = self.emissionFixture(epoch: epoch)
        let assembler = MeetingTranscriptAssembler()
        let early = try assembler.assemblePCMWindow(attemptID: attempt, epoch: epoch, offset: 0,
            duration: 3.2, units: Array(fixture.units.prefix(2)), activity: Array(fixture.activity.prefix(1)),
            speakerAttributionPolicy: self.emissionPolicy)
        let opening = early.segments[1]
        XCTAssertNil(opening.speakerID)
        var tail = try MeetingStreamingProtectedWordTail(attemptID: attempt, epoch: epoch,
            speakerNameFormat: "Speaker %lld", policy: self.emissionPolicy)
        let waiting = try tail.update(safeWords: early, activity: Array(fixture.activity.prefix(1)),
            watermarks: .init(asrStableThrough: 3.2, diarizationProcessedThrough: 3.2, privacySafeThrough: 3.2),
            attemptID: attempt, epoch: epoch)
        XCTAssertFalse(waiting.committedIDs.contains(opening.id),
                       "An emission cannot become final before its declared context horizon")
        let later = try assembler.assemblePCMWindow(attemptID: attempt, epoch: epoch, offset: 0,
            duration: 11, units: Array(fixture.units.dropFirst(2)), priorSpeakers: early.speakers,
            activity: fixture.activity, speakerAttributionPolicy: self.emissionPolicy)
        let resolved = try tail.update(safeWords: later, activity: fixture.activity,
            watermarks: .init(asrStableThrough: 11, diarizationProcessedThrough: 11, privacySafeThrough: 11),
            attemptID: attempt, epoch: epoch)
        let revision = try XCTUnwrap(resolved.revisions.first { $0.segmentID == opening.id })
        var published = opening
        XCTAssertTrue(try revision.apply(to: &published))
        XCTAssertNotNil(published.speakerID)
        XCTAssertEqual(published.speakerID, later.segments[0].speakerID)
        XCTAssertEqual(published.nativeTiming, opening.nativeTiming)
        XCTAssertEqual(published.nativeSpeakerAssignment, .unassigned)
        XCTAssertEqual(published.nativeWordTimingProvenance, opening.nativeWordTimingProvenance)
        XCTAssertTrue(resolved.committedIDs.contains(opening.id))
        let stopped = try assembler.assemblePCMWindow(attemptID: attempt, epoch: epoch, offset: 0,
            duration: 11, units: fixture.units, activity: fixture.activity, speakerAttributionPolicy: self.emissionPolicy)
        XCTAssertEqual(published.speakerID, stopped.segments[1].speakerID)
        _ = try tail.finish(activity: fixture.activity,
            watermarks: .init(asrStableThrough: 11, diarizationProcessedThrough: 11, privacySafeThrough: 11),
            attemptID: attempt, epoch: epoch)
    }

    /// Explicit local audit input only. Private sessions never become repository fixtures.
    func testOptInSavedMeetingReadingCoverage() throws {
        guard let path = ProcessInfo.processInfo.environment["PICHI_SPEAKER_AUDIT_ROOT"] else {
            throw XCTSkip("Set PICHI_SPEAKER_AUDIT_ROOT to an authorized read-only metadata snapshot")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = MeetingSessionDateCodec.decodingStrategy
        var reports: [[String: Any]] = []
        for platform in ["ipad", "mac"] {
            let files = try FileManager.default.contentsOfDirectory(at: root.appendingPathComponent(platform),
                includingPropertiesForKeys: nil).filter { $0.pathExtension == "json" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
            for file in files {
                let data = try Data(contentsOf: file)
                guard let session = try? decoder.decode(MeetingSession.self, from: data),
                      session.state == .completed, session.speakerLabelsEnabled != false else { continue }
                let original = session.transcriptSegments
                let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: original.filter { !$0.isEcho }, in: session)
                let names = Dictionary(session.activeSpeakers.map { ($0.id, $0.displayName) }, uniquingKeysWith: { first, _ in first })
                let missing = paragraphs.filter {
                    $0.segments.contains(where: \.hasReadableContent)
                        && (!($0.showsSpeakerLabel) || MeetingTranscriptExporter.speakerPresentation(
                            for: $0, in: session, speakerNames: names).participantID == nil)
                }.count
                XCTAssertEqual(missing, 0, "Unowned reading turn in \(platform)/\(file.lastPathComponent)")
                XCTAssertEqual(session.transcriptSegments, original)
                XCTAssertEqual(try Data(contentsOf: file), data, "Audit must not modify the stored source")
                reports.append(["platform": platform, "snapshot": file.lastPathComponent,
                    "segments": original.count,
                    "originalUnownedLexical": original.filter { $0.hasLexicalContent && !$0.isEcho && $0.speakerID == nil }.count,
                    "readingParagraphs": paragraphs.count, "unownedReadingParagraphs": missing])
            }
        }
        XCTAssertFalse(reports.isEmpty)
        let report = root.appendingPathComponent("reading-coverage-replay.json")
        try JSONSerialization.data(withJSONObject: reports, options: [.prettyPrinted, .sortedKeys]).write(to: report, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: report.path)
    }

    private func readingFixture(_ spans: [(Double, Double, Int?)]) -> (MeetingSession, MeetingAnalysisEpochID) {
        let track = UUID(), attempt = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic participant coverage",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(60)
        session.audioStorageMode = .memoryOnly
        session.transcriptTimeDomain = .meetingRelative
        session.audioTracks = [.init(id: track, kind: .microphone, sourceIdentifier: "fixture",
            sourceDisplayName: "Fixture", format: nil, timebase: timebase, health: .waiting, chunks: [])]
        session.speakers = (0..<3).map { number in
            let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "voice-\(number)")
            return .init(id: MeetingTranscriptAssembler.speakerID(attemptID: attempt, token: token),
                displayName: "Speaker \(number + 1)", diarizationClusterID: "\(epoch):voice-\(number)",
                trackKind: .microphone, isLocalUser: false, identityCandidates: [],
                generatedParticipantNumber: number + 1, identityIsProvisional: false)
        }
        session.transcriptSegments = spans.enumerated().map { position, span in
            .init(id: UUID(), start: .init(value: Int64((span.0 * 1000).rounded()), timescale: 1000),
                end: .init(value: Int64((span.1 * 1000).rounded()), timescale: 1000), sourceTrackID: track,
                speakerID: span.2.map { session.speakers[$0].id }, text: "Synthetic \(position)", revision: 0,
                status: .final, overlap: .none, completeness: .complete,
                attributionState: span.2 == nil ? .unassigned : .assigned,
                nativePrecision: .word, nativeUnitID: "synthetic-\(position)",
                nativeSpeakerAssignment: span.2.map { .assigned(.init(analysisEpochID: epoch, label: "voice-\($0)")) } ?? .unassigned,
                nativeTiming: .init(start: span.0, end: span.1))
        }
        return (session, epoch)
    }

    private func resolveReading(_ session: MeetingSession, epoch: MeetingAnalysisEpochID,
                                barriers: [MeetingSpeakerAttributionInterval] = []) throws -> MeetingReadingSpeakerResolver.Result {
        try MeetingReadingSpeakerResolver.resolve(segments: session.transcriptSegments, speakers: session.speakers,
            barriersByTrack: [epoch.trackID: barriers], scopeForSegment: { _ in epoch },
            fallbackSpeaker: { MeetingTranscriptAssembler().readingFallbackSpeaker(attemptID: session.id, epoch: $0) })
    }

    func testDominantContextIncludesSpeakerBehindBriefInterveningTurns() throws {
        let (session, epoch) = self.readingFixture([(0, 10, 0), (10, 10.1, 1), (10.1, 10.2, nil), (10.2, 10.3, 2)])
        let result = try self.resolveReading(session, epoch: epoch)
        XCTAssertEqual(result.segments[2].speakerID, session.speakers[0].id)
        XCTAssertEqual(result.speakers.count, 3)
        XCTAssertEqual(result.segments[1].speakerID, session.speakers[1].id, "A genuine assigned short reply remains intact")
        XCTAssertEqual(result.segments[3].speakerID, session.speakers[2].id)
    }

    func testUnscoredWordInPauseFollowsIncomingVoiceInsteadOfEarlierLongTurn() throws {
        var (session, epoch) = self.readingFixture([(0, 10, 0), (12, 12.04, nil), (13, 19, 1)])
        let result = try self.resolveReading(session, epoch: epoch)
        XCTAssertEqual(result.segments[1].speakerID, session.speakers[1].id)
        XCTAssertEqual(result.segments[1].nativeSpeakerAssignment, .unassigned)
        XCTAssertNil(result.segments[1].speakerAttribution?.selectedToken)
        let oldPolicy = MeetingSpeakerAttributionPolicy(enableProvisionalSpeakerIdentities: true,
            enableStableSpeakerOpening: true, enableCompleteReadingAssignment: true)
        let old = try MeetingReadingSpeakerResolver.resolve(segments: session.transcriptSegments,
            speakers: session.speakers, policy: oldPolicy, scopeForSegment: { _ in epoch },
            fallbackSpeaker: { MeetingTranscriptAssembler().readingFallbackSpeaker(attemptID: session.id, epoch: $0) })
        XCTAssertEqual(old.segments[1].speakerID, session.speakers[0].id)
        XCTAssertNotEqual(oldPolicy.fingerprint, MeetingSpeakerAttributionPolicy.standard.fingerprint)
        let word = session.transcriptSegments[1]
        let decision = try XCTUnwrap(MeetingSpeakerAttribution.resolve(units: [.init(
            id: word.nativeUnitID!, trackID: epoch.trackID, analysisEpochID: epoch, precision: .word,
            text: word.text, analysisStart: 12, analysisEnd: 12.04, speaker: .unassigned, analysisSpanIDs: [])], activity: []).first)
        session.transcriptSegments[1].speakerAttribution = .init(decision: decision, speakerIDs: [:])
        XCTAssertEqual(session.transcriptSegments[1].speakerAttribution?.relation, MeetingSpeakerAttributionRelation.none)
        XCTAssertEqual(try self.resolveReading(session, epoch: epoch).segments[1].speakerID, session.speakers[1].id)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(oldPolicy)) as? [String: Any])
        json.removeValue(forKey: "enableIncomingGapReading")
        let decoded = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.enableIncomingGapReading)
        XCTAssertEqual(decoded.fingerprint, oldPolicy.fingerprint)
    }

    func testIncomingPauseRuleCannotReachBeyondLiveReadingHorizon() throws {
        for nextStart in [27.04, 100] {
            let (session, epoch) = self.readingFixture([(0, 10, 0), (12, 12.04, nil), (nextStart, nextStart + 1, 1)])
            let result = try self.resolveReading(session, epoch: epoch)
            XCTAssertEqual(result.segments[1].speakerID, session.speakers[0].id)
        }
    }

    func testReadingOwnershipDoesNotCrossCoverageBarrierOrReplaceManualCorrection() throws {
        var (session, epoch) = self.readingFixture([(0, 10, 0), (12, 12.2, nil), (13, 14, 1), (15, 16, 2)])
        session.transcriptSegments[3].isUserSpeakerAssigned = true
        let result = try self.resolveReading(session, epoch: epoch, barriers: [.init(start: 10.5, end: 11.5)])
        XCTAssertEqual(result.segments[1].speakerID, session.speakers[1].id)
        XCTAssertEqual(result.segments[3], session.transcriptSegments[3])
    }

    func testCompleteReadingSummaryPassesProductionStoreValidationAndReopen() async throws {
        var (session, epoch) = self.readingFixture([(0, 6, 0), (8, 8.04, nil), (9.5, 15, 0)])
        let result = try self.resolveReading(session, epoch: epoch)
        session.transcriptSegments = result.segments
        session.speakers = result.speakers
        XCTAssertNoThrow(try session.validateTranscriptStructure())
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("speaker-coverage-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        try await store.create(session)
        let reopened = try await MeetingSessionStore(rootDirectory: root).loadTranscript(id: session.id)
        let loaded = try XCTUnwrap(reopened)
        XCTAssertEqual(loaded.transcriptSegments, session.transcriptSegments)
        XCTAssertTrue(loaded.transcriptSegments.allSatisfy { $0.speakerID != nil })
        let paragraphs = try await MeetingTranscriptExporter.readingParagraphs(for: loaded)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertTrue(paragraphs.allSatisfy { $0.showsSpeakerLabel })
    }

    func testArchiveProjectionNamesEveryReadableFragmentWithoutRewritingSavedMembers() throws {
        let (session, _) = self.readingFixture([(0, 6, 0), (8, 8.04, nil), (9.5, 15, 0)])
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs.flatMap(\.segments), session.transcriptSegments)
        XCTAssertTrue(paragraphs.allSatisfy { $0.showsSpeakerLabel })
        let presentations = MeetingTranscriptExporter.speakerPresentations(in: session)
        XCTAssertEqual(Set(presentations.values.compactMap(\.participantID)), [session.speakers[0].id])
        XCTAssertNil(session.transcriptSegments[1].speakerID)
    }

    func testArchiveNeighborAgreementCannotBeOutvotedByALaterLongTurn() throws {
        var (session, _) = self.readingFixture([(0, 1, 0), (1.1, 1.2, nil), (1.3, 2.3, 0), (2.4, 12.4, 1)])
        session.transcriptIsComplete = true
        session.processingAttempts = [.init(id: UUID(), startedAt: session.startedAt, completedAt: session.endedAt,
            stage: .completed, pipelineVersion: 13, asrProvider: nil, asrModel: nil, languageCode: "en",
            diarizationModel: nil, lastCompletedTrackID: nil, errorCode: nil)]
        for index in session.transcriptSegments.indices {
            session.transcriptSegments[index].nativePrecision = nil
            session.transcriptSegments[index].nativeUnitID = nil
            session.transcriptSegments[index].nativeSpeakerAssignment = nil
            session.transcriptSegments[index].nativeTiming = nil
        }
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: session.transcriptSegments, in: session)
        XCTAssertEqual(paragraphs.count, 2)
        XCTAssertEqual(paragraphs.first?.segments, Array(session.transcriptSegments.prefix(3)))
        XCTAssertEqual(MeetingTranscriptExporter.speakerPresentations(in: session)[session.transcriptSegments[1].id]?.participantID,
            session.speakers[0].id)
        XCTAssertNil(session.transcriptSegments[1].speakerID)
    }

    func testReadingScopePreservesBothOnlineTracksAndEpochReset() throws {
        var (session, epoch) = self.readingFixture([(0, 10, 0), (12, 12.1, nil), (13, 14, 1)])
        let nextEpoch = MeetingAnalysisEpochID(trackID: epoch.trackID, ordinal: 1, generation: 1)
        session.transcriptSegments[2].nativeSpeakerAssignment = .assigned(.init(analysisEpochID: nextEpoch, label: "later"))
        let (other, _) = self.readingFixture([(0, 6, 0), (8, 8.1, nil), (9, 15, 0)])
        session.transcriptSegments += other.transcriptSegments
        session.speakers += other.speakers
        let scopes = MeetingReadingSpeakerResolver.readingScopes(for: session.transcriptSegments)
        XCTAssertEqual(scopes[session.transcriptSegments[1].id], nextEpoch)
        let finalized = try MeetingStreamingProtectedWordTail.finalizingProtectedTranscript(
            .init(segments: session.transcriptSegments, speakers: session.speakers),
            attemptID: session.id, policy: .standard, speakerNameFormat: "Speaker %lld",
            epochForSegment: { scopes[$0.id] })
        XCTAssertEqual(finalized.segments[1].speakerID, session.speakers[1].id)
        XCTAssertEqual(finalized.segments[4].speakerID, other.speakers[0].id)
        XCTAssertEqual(finalized.segments.map(\.sourceTrackID), session.transcriptSegments.map(\.sourceTrackID))
    }

    func testLiveCommitWaitsForCompleteReadingContext() throws {
        let (session, epoch) = self.readingFixture([(0, 2, 0), (2.2, 2.24, nil)])
        let attempt = UUID()
        var tail = try MeetingStreamingProtectedWordTail(attemptID: attempt, epoch: epoch,
            speakerNameFormat: "Speaker %lld", priorSpeakers: session.speakers)
        XCTAssertGreaterThanOrEqual(tail.policyLookahead, MeetingReadingSpeakerResolver.contextRadiusSeconds)
        let update = try tail.update(safeWords: .init(segments: session.transcriptSegments, speakers: session.speakers),
            activity: [], watermarks: .init(asrStableThrough: 9, diarizationProcessedThrough: 9, privacySafeThrough: 9),
            attemptID: attempt, epoch: epoch)
        XCTAssertFalse(update.committedIDs.contains(session.transcriptSegments[1].id),
            "A later dominant participant inside the reading horizon must still be able to revise this word")
        tail.cancel()
    }

    func testDurableFallbackKeepsItsIdentityAcrossArchiveAndPortableExport() throws {
        var (session, epoch) = self.readingFixture([(0, 0.1, nil), (8, 8.1, nil)])
        session.speakers = []
        session.piiRedactionEnabled = true
        let result = try MeetingStreamingProtectedWordTail.finalizingProtectedTranscript(
            .init(segments: session.transcriptSegments), attemptID: UUID(), policy: .standard,
            speakerNameFormat: "Speaker %lld", epochForSegment: { _ in epoch })
        session.transcriptSegments = result.segments
        session.speakers = result.speakers
        let id = try XCTUnwrap(result.speakers.first?.id)
        XCTAssertEqual(result.speakers.count, 1)
        let presentations = MeetingTranscriptExporter.speakerPresentations(in: session)
        XCTAssertEqual(Set(presentations.values.compactMap(\.participantID)), [id])
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: session)) as? [String: Any])
        let people = try XCTUnwrap(json["speakers"] as? [[String: Any]])
        XCTAssertEqual(people.count, 1)
        XCTAssertEqual(people[0]["id"] as? String, id.uuidString)
    }

    func testNamedOrOwnerConfirmedFallbackIsNotReassignedByLaterContext() throws {
        let (fixture, epoch) = self.readingFixture([(0, 0.1, nil), (4, 10, 0)])
        var session = fixture
        session.speakers = []
        session.transcriptSegments = Array(fixture.transcriptSegments.prefix(1))
        let first = try self.resolveReading(session, epoch: epoch)
        for customName in [false, true] {
            var named = first.speakers[0]
            named.displayName = "Explicit participant"
            named.usesCustomDisplayName = customName
            named.isLocalUser = !customName
            session.speakers = [named, fixture.speakers[0]]
            session.transcriptSegments = first.segments + Array(fixture.transcriptSegments.suffix(1))
            let next = try self.resolveReading(session, epoch: epoch)
            XCTAssertEqual(next.segments[0], first.segments[0])
            XCTAssertEqual(next.speakers[0], named)
        }
    }

    func testPrunedLiveContextReusesKnownSourceParticipantWithoutOpeningAnother() throws {
        var (session, epoch) = self.readingFixture([(30, 30.1, nil)])
        session.speakers = [session.speakers[0]]
        let result = try self.resolveReading(session, epoch: epoch)
        XCTAssertEqual(result.speakers, session.speakers)
        XCTAssertEqual(result.segments[0].speakerID, session.speakers[0].id)
        XCTAssertEqual(result.segments[0].nativeSpeakerAssignment, .unassigned)
    }

    func testMixedUtteranceSelectsDominantReadingVoiceWithoutChangingAcousticAssignment() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let a = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "a")
        let b = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "b")
        let unit = MeetingFinalTextUnit(id: "mixture", trackID: epoch.trackID, analysisEpochID: epoch,
            precision: .utterance, text: "One indivisible mixed phrase", analysisStart: 0, analysisEnd: 10,
            speaker: .unassigned, analysisSpanIDs: [])
        let activity: [MeetingBackendSpeakerActivity] = [.init(token: a, start: 0, end: 10),
            .init(token: b, start: 3, end: 7)]
        let raw = try MeetingSpeakerAttribution.acousticAssignments(units: [unit], activity: activity)
        guard case let .ambiguous(candidates) = raw[unit.id] else { return XCTFail("Mixed native evidence must stay ambiguous") }
        XCTAssertEqual(Set(candidates), [a, b])
        let decision = try XCTUnwrap(MeetingSpeakerAttribution.resolve(units: [unit], activity: activity).first)
        XCTAssertEqual(decision.selectedToken, a)
        XCTAssertEqual(decision.rule, .foregroundDominance)
        XCTAssertFalse(decision.rule.isIndependentAcousticSelection)
        let old = try XCTUnwrap(MeetingSpeakerAttribution.resolve(units: [unit], activity: activity,
            policy: .init(enableProvisionalSpeakerIdentities: true, enableStableSpeakerOpening: true)).first)
        XCTAssertNil(old.selectedToken)
    }

    func testCompleteReadingPolicyIsFrozenAndOlderEncodedPolicyDoesNotOptIn() throws {
        let old = MeetingSpeakerAttributionPolicy(enableProvisionalSpeakerIdentities: true,
            enableStableSpeakerOpening: true)
        XCTAssertNotEqual(old.fingerprint, MeetingSpeakerAttributionPolicy.standard.fingerprint)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(old)) as? [String: Any])
        json.removeValue(forKey: "enableCompleteReadingAssignment")
        let decoded = try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONSerialization.data(withJSONObject: json))
        XCTAssertFalse(decoded.enableCompleteReadingAssignment)
        XCTAssertEqual(decoded.fingerprint, old.fingerprint)
        XCTAssertEqual(try JSONDecoder().decode(MeetingSpeakerAttributionPolicy.self,
            from: JSONEncoder().encode(MeetingSpeakerAttributionPolicy.standard)), .standard)
    }

    func testCanonicalFinalPublicationNamesUnresolvedSpeechWithoutChangingNativeEvidence() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(kind: .microphone, chunks: [chunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)])
        let plan = self.plan(mode: .inRoom, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan,
            observations: [(mic.id, chunk, self.observed(chunk, duration: 10))])
        let span = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let units = [
            self.unit(id: "unknown-first", span: span, analysisStart: 1, analysisEnd: 1.2, speaker: .unassigned),
            self.unit(id: "unknown-continuation", span: span, analysisStart: 1.5, analysisEnd: 1.7, speaker: .unassigned),
            self.unit(id: "unknown-later", span: span, analysisStart: 7, analysisEnd: 7.2, speaker: .unassigned)]
        func assemble(_ policy: MeetingSpeakerAttributionPolicy) throws -> MeetingAssemblyResult {
            try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest,
                evidence: self.evidence(plan: plan, units: units), coverageReceipts: self.receipts(for: manifest),
                echoVerdicts: Dictionary(uniqueKeysWithValues: units.map { ($0.id, MeetingUnitEchoVerdict.notEcho) }),
                speakerAttributionPolicy: policy))
        }
        let result = try assemble(self.provisionalPolicy)
        let legacy = try assemble(.init())
        let standard = try assemble(.standard)
        XCTAssertTrue(standard.segments.allSatisfy { $0.speakerID != nil && $0.speakerIdentityIsProvisional == true })
        XCTAssertEqual(standard.speakers.count, 1, "Unresolved speech shares one reading participant instead of creating a person per bout")
        XCTAssertEqual(Set(standard.segments.compactMap(\.speakerID)).count, 1)
        XCTAssertEqual(standard.sidecar.units, result.sidecar.units)
        XCTAssertEqual(standard.sidecar.dispositions, result.sidecar.dispositions)
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerID != nil && $0.speakerIdentityIsProvisional == true })
        XCTAssertEqual(result.segments[0].speakerID, result.segments[1].speakerID)
        XCTAssertNotEqual(result.segments[1].speakerID, result.segments[2].speakerID)
        XCTAssertEqual(result.segments.map(\.nativeSpeakerAssignment), legacy.segments.map(\.nativeSpeakerAssignment))
        XCTAssertEqual(result.segments.map(\.nativeTiming), legacy.segments.map(\.nativeTiming))
        XCTAssertEqual(result.sidecar.units, legacy.sidecar.units)
        XCTAssertEqual(result.sidecar.speakerActivity, legacy.sidecar.speakerActivity)
        XCTAssertEqual(result.sidecar.dispositions, legacy.sidecar.dispositions)
    }

    func testCompleteReadingAssignmentKeepsLongUntimedSpeechWithItsContinuingParticipant() throws {
        let attempt = UUID(), track = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "voice-a")
        let units: [MeetingFinalTextUnit] = [
            .init(id: "before", trackID: track, analysisEpochID: epoch, precision: .word,
                  text: "Synthetic beginning", analysisStart: 0, analysisEnd: 6,
                  speaker: .assigned(token), analysisSpanIDs: []),
            .init(id: "long-uncertain", trackID: track, analysisEpochID: epoch, precision: .utterance,
                  text: "A complete uncertain phrase remains readable", analysisStart: 7, analysisEnd: 15,
                  speaker: .unassigned, analysisSpanIDs: []),
            .init(id: "after", trackID: track, analysisEpochID: epoch, precision: .word,
                  text: "Synthetic continuation", analysisStart: 16, analysisEnd: 22,
                  speaker: .assigned(token), analysisSpanIDs: [])]
        let source = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: attempt, epoch: epoch,
            offset: 0, duration: 22, units: units)
        let result = try MeetingStreamingProtectedWordTail.finalizingProtectedTranscript(source,
            attemptID: attempt, policy: .standard, speakerNameFormat: "Speaker %lld",
            epochForSegment: { _ in epoch })
        let owner = try XCTUnwrap(source.segments.first?.speakerID)
        XCTAssertEqual(result.segments.map(\.speakerID), [owner, owner, owner])
        XCTAssertEqual(result.speakers, source.speakers)
        XCTAssertEqual(result.segments.map(\.id), source.segments.map(\.id))
        XCTAssertEqual(result.segments.map(\.text), source.segments.map(\.text))
        XCTAssertEqual(result.segments.map(\.nativeTiming), source.segments.map(\.nativeTiming))
        XCTAssertEqual(result.segments.map(\.nativeSpeakerAssignment), source.segments.map(\.nativeSpeakerAssignment))
        let replay = try MeetingStreamingProtectedWordTail.finalizingProtectedTranscript(result,
            attemptID: attempt, policy: .standard, speakerNameFormat: "Speaker %lld",
            epochForSegment: { _ in epoch })
        XCTAssertEqual(replay.segments, result.segments)
        XCTAssertEqual(replay.speakers, result.speakers)
    }

    func testCompleteReadingAssignmentDoesNotCreateParticipantsForPunctuation() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0), attempt = UUID()
        let units: [MeetingFinalTextUnit] = [
            .init(id: "punctuation", trackID: epoch.trackID, analysisEpochID: epoch, precision: .word,
                  text: "...", analysisStart: 0, analysisEnd: 1, speaker: .unassigned, analysisSpanIDs: [])]
        let source = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: attempt, epoch: epoch,
            offset: 0, duration: 1, units: units)
        let result = try MeetingStreamingProtectedWordTail.finalizingProtectedTranscript(source,
            attemptID: attempt, policy: .standard, speakerNameFormat: "Speaker %lld",
            epochForSegment: { _ in epoch })
        XCTAssertTrue(result.speakers.isEmpty)
        XCTAssertEqual(result.segments, source.segments)
    }

    func testPCMWindowUsesExistingIdentityAndOffsetWithoutCreatingAudioManifest() throws {
        let attempt = UUID()
        let track = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        let unit = MeetingFinalTextUnit(id: "pcm:first", trackID: track, analysisEpochID: epoch,
                                       precision: .utterance, text: "Synthetic transcript", analysisStart: 0,
                                       analysisEnd: 6, speaker: .assigned(token), analysisSpanIDs: [])
        let assembler = MeetingTranscriptAssembler()
        let first = try assembler.assemblePCMWindow(attemptID: attempt, epoch: epoch, offset: 10, duration: 6, units: [unit])
        XCTAssertEqual(first.segments.first?.start.seconds, 10)
        XCTAssertEqual(first.segments.first?.end.seconds, 16)
        XCTAssertEqual(first.speakers.count, 1)
        XCTAssertFalse(try XCTUnwrap(first.speakers.first).isLocalUser)
        let replay = try assembler.assemblePCMWindow(attemptID: attempt, epoch: epoch, offset: 10, duration: 6, units: [unit])
        XCTAssertEqual(first.segments, replay.segments)
        XCTAssertEqual(first.speakers, replay.speakers)
        let nextEpoch = MeetingAnalysisEpochID(trackID: track, ordinal: 96_000)
        let nextToken = MeetingBackendSpeakerToken(analysisEpochID: nextEpoch, label: "slot-3")
        let nextUnit = MeetingFinalTextUnit(id: "pcm:second", trackID: track, analysisEpochID: nextEpoch,
                                           precision: .utterance, text: "Another synthetic phrase", analysisStart: 0,
                                           analysisEnd: 6, speaker: .assigned(nextToken), analysisSpanIDs: [])
        let next = try assembler.assemblePCMWindow(attemptID: attempt, epoch: nextEpoch, offset: 16, duration: 6,
                                                   units: [nextUnit], identityLinks: [.init(token: nextToken, canonicalToken: token)],
                                                   priorSpeakers: first.speakers)
        XCTAssertEqual(next.segments.first?.speakerID, first.segments.first?.speakerID)
        XCTAssertEqual(next.speakers.first?.displayName, first.speakers.first?.displayName)
        XCTAssertThrowsError(try assembler.assemblePCMWindow(attemptID: attempt, epoch: epoch, offset: 0,
                                                            duration: 5, units: [unit]))
    }

    func testConfirmedOwnerUsesExistingSpeakerIdentityAndKeepsStableParticipantAliases() throws {
        let track = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let owner = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        let other = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-1")
        let units = [owner, other].enumerated().map { index, token in
            MeetingFinalTextUnit(id: "owner-fixture:\(index)", trackID: track, analysisEpochID: epoch,
                precision: .utterance, text: "Synthetic meeting voice", analysisStart: Double(index * 6),
                analysisEnd: Double(index * 6 + 6), speaker: .assigned(token), analysisSpanIDs: [])
        }
        let assembler = MeetingTranscriptAssembler()
        let result = try assembler.assemblePCMWindow(attemptID: UUID(), epoch: epoch, offset: 0,
            duration: 12, units: units, confirmedLocalUserTokens: [owner])
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertEqual(result.speakers.filter(\.isLocalUser).map(\.displayName), ["Speaker 1"])
        XCTAssertEqual(result.speakers.filter { !$0.isLocalUser }.map(\.displayName), ["Speaker 1"])
        XCTAssertEqual(result.speakers.filter(\.isLocalUser).map(\.generatedParticipantNumber), [0])
        XCTAssertEqual(result.speakers.filter { !$0.isLocalUser }.map(\.generatedParticipantNumber), [1])
        XCTAssertTrue(result.segments.allSatisfy { $0.speakerID != nil })
    }

    func testPCMInvalidWordTimingPreservesCompleteUntimedTextWithUncertainAttribution() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        let units = try MeetingParakeetNemotronBackend.pcmUnits(
            result: ASRTranscriptionResult(text: "Keep the complete phrase"),
            words: [.init(text: "Keep", start: 0, end: 0.5), .init(text: "invalid", start: 20, end: 21)],
            epoch: epoch, duration: 6,
            activity: [.init(token: token, start: 0, end: 6)], identityTokens: []
        )
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units.first?.precision, .utterance)
        XCTAssertEqual(units.first?.text, "Keep the complete phrase")
        XCTAssertEqual(units.first?.speaker, .unassigned)
        let batch = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: UUID(), epoch: epoch, offset: 0,
                                                                       duration: 6, units: units)
        XCTAssertTrue(batch.isComplete)
        XCTAssertTrue(batch.speakers.isEmpty)
        XCTAssertNil(batch.segments.first?.speakerID)
        XCTAssertEqual(batch.segments.first?.attributionState, .unassigned)
    }

    func testWholeRecordingContinuationPreservesNativeWordPrecisionAndInterruptionEvidence() throws {
        let attempt = UUID(), track = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let main = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "voice-a")
        let other = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "voice-b")
        let specs: [(String, Double, Double)] = [
            ("main", 0, 5.5), ("before", 5.6, 6), ("mixed", 6, 6.8),
            ("after", 6.8, 7.2), ("known second speaker", 8, 14)]
        let units = specs.enumerated().map { index, item in
            MeetingFinalTextUnit(id: "native-\(index)", trackID: track, analysisEpochID: epoch,
                precision: .word, text: item.0, analysisStart: item.1, analysisEnd: item.2,
                speaker: .unassigned, analysisSpanIDs: [])
        }
        let assembler = MeetingTranscriptAssembler()
        let transcript = try assembler.assemblePCMWindow(attemptID: attempt, epoch: epoch,
            offset: 0, duration: 14, units: units)
        let activity: [MeetingBackendSpeakerActivity] = [
            .init(token: main, start: 0, end: 7.2), .init(token: other, start: 6.2, end: 6.6),
            .init(token: other, start: 8, end: 14)]
        let result = try MeetingPCMRecordingAttribution.assemble(transcript: transcript,
            activity: activity, epoch: epoch, attemptID: attempt, duration: 14, speakerNameFormat: "Speaker %lld")
        XCTAssertEqual(result.segments.map(\.id), transcript.segments.map(\.id))
        XCTAssertEqual(result.segments.map(\.text), transcript.segments.map(\.text))
        XCTAssertEqual(result.segments.map(\.start), transcript.segments.map(\.start))
        XCTAssertEqual(result.segments.map(\.end), transcript.segments.map(\.end))
        XCTAssertTrue(result.segments.allSatisfy { $0.nativePrecision == .word })
        let mixed = result.segments[2]
        let attribution = try XCTUnwrap(mixed.speakerAttribution)
        XCTAssertEqual(attribution.rawAssignment, .ambiguous([main, other]))
        // The standard reading policy keeps a short interruption inside the continuing
        // speaker's turn, without changing native word timing or acoustic evidence.
        XCTAssertEqual(attribution.selectedToken, main)
        XCTAssertEqual(attribution.rule, .mainSpeakerContinuation)
        XCTAssertTrue(attribution.background.isEmpty)
        XCTAssertEqual(Set(attribution.candidates.map(\.token)), [main, other])
        XCTAssertEqual(attribution.relation, .simultaneous)
        XCTAssertNotNil(mixed.speakerID)
        XCTAssertEqual(mixed.speakerID, result.segments[1].speakerID)
        XCTAssertEqual(mixed.speakerID, result.segments[3].speakerID)
        XCTAssertNotNil(result.segments[4].speakerID)
        XCTAssertNotEqual(mixed.speakerID, result.segments[4].speakerID)
        XCTAssertEqual(mixed.overlap, .ambiguous, "Selecting a reading owner does not erase simultaneous speech")
    }

    func testVoiceAdmissionCountsActualSupportInsteadOfASRWordEnvelope() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let main = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "a")
        let weak = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "b")
        let units = [
            MeetingFinalTextUnit(id: "main", trackID: epoch.trackID, analysisEpochID: epoch,
                precision: .word, text: "Main voice", analysisStart: 0, analysisEnd: 6,
                speaker: .assigned(main), analysisSpanIDs: []),
            MeetingFinalTextUnit(id: "weak", trackID: epoch.trackID, analysisEpochID: epoch,
                precision: .word, text: "This long recognized phrase has more than ten words but only a short voice",
                analysisStart: 7, analysisEnd: 13, speaker: .assigned(weak), analysisSpanIDs: [])]
        let result = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: UUID(), epoch: epoch,
            offset: 0, duration: 13, units: units,
            activity: [.init(token: main, start: 0, end: 6), .init(token: weak, start: 7, end: 7.1)],
            speakerAttributionPolicy: self.provisionalPolicy)
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertNotNil(result.segments[1].speakerID)
        XCTAssertEqual(result.segments[1].speakerIdentityIsProvisional, true)
        XCTAssertEqual(result.speakers.first { $0.id == result.segments[1].speakerID }?.identityIsProvisional, true,
            "A long ASR envelope cannot qualify a short acoustic identity")
        XCTAssertEqual(result.segments[1].nativeSpeakerAssignment, .assigned(weak))
        let standard = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: UUID(), epoch: epoch,
            offset: 0, duration: 13, units: units,
            activity: [.init(token: main, start: 0, end: 6), .init(token: weak, start: 7, end: 7.1)])
        XCTAssertEqual(standard.speakers.count, 1)
        XCTAssertNil(standard.segments[1].speakerID, "A short acoustic identity cannot open an extra participant")
        XCTAssertEqual(standard.segments[1].nativeSpeakerAssignment, .assigned(weak))
    }

    func testSidecarAttributionReplaysAndRejectsChangedPolicyWithoutRewritingNativeEvidence() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "native", span: span, analysisStart: 1, analysisEnd: 2)
        let activity = [MeetingBackendSpeakerActivity(token: try XCTUnwrap(unit.speaker.tokens.first), start: 0, end: 3)]
        let evidence = MeetingFinalTranscriptEvidence(backendID: plan.backendID, attemptID: plan.attemptID,
            units: [unit], speakerActivity: activity)
        let assembled = try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest,
            evidence: evidence, coverageReceipts: self.receipts(for: manifest), echoVerdicts: [unit.id: .notEcho]))
        XCTAssertEqual(assembled.sidecar.units, [unit])
        XCTAssertEqual(assembled.sidecar.speakerActivity, activity)
        XCTAssertEqual(assembled.sidecar.speakerAttributionPolicy, .standard)
        XCTAssertEqual(assembled.sidecar.speakerAttributionDecisions.first?.rawAssignment, unit.speaker)
        let decoded = try JSONDecoder().decode(MeetingResultSidecar.self, from: JSONEncoder().encode(assembled.sidecar))
        XCTAssertEqual(try decoded.validated(), assembled.sidecar)
        let forged = MeetingResultSidecar(backendID: plan.backendID, backendVersion: plan.backendVersion,
            attemptID: plan.attemptID, analysisManifest: manifest, units: [unit],
            dispositions: assembled.sidecar.dispositions, coverageReceipts: assembled.sidecar.coverageReceipts,
            speakerActivity: activity, speakerAttributionPolicy: nil,
            speakerAttributionDecisions: assembled.sidecar.speakerAttributionDecisions)
        XCTAssertThrowsError(try forged.validated()) { error in
            XCTAssertEqual(error as? MeetingResultSidecarError, .invalidSpeakerAttribution)
        }
    }

    func testExcludedAndTimingUncertainWordsCannotBecomeContextAnchors() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let token = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "a")
        let before = self.unit(id: "before", span: span, analysisStart: 1, analysisEnd: 2, speaker: .assigned(token))
        let excluded = self.unit(id: "excluded", span: span, analysisStart: 2, analysisEnd: 2.5, speaker: .unassigned)
        let after = self.unit(id: "after", span: span, analysisStart: 2.5, analysisEnd: 3, speaker: .assigned(token))
        let units = [before, excluded, after]
        let result = try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest,
            evidence: .init(backendID: plan.backendID, attemptID: plan.attemptID, units: units,
                speakerActivity: [.init(token: token, start: 1, end: 3)]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [before.id: .notEcho, excluded.id: .echoSuppressed(duplicateOfUnitID: nil), after.id: .notEcho]))
        XCTAssertEqual(result.segments.count, 2)
        let decision = try XCTUnwrap(result.sidecar.speakerAttributionDecisions.first { $0.unitID == excluded.id })
        XCTAssertEqual(decision.rule, .barrier)
        XCTAssertNil(decision.selectedToken)
        XCTAssertEqual(result.sidecar.units, units.sorted { $0.id < $1.id })
    }

    func testExcludedWordsBreakProvisionalPublicationBout() throws {
        for outsideActivity in [false, true] {
            let (plan, manifest, span) = try self.onlineMicFixture()
            let a = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "a")
            let b = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "b")
            let assignment: MeetingBackendSpeakerAssignment = outsideActivity ? .ambiguous([a, b]) : .unassigned
            let before = self.unit(id: "before", span: span, analysisStart: 1, analysisEnd: 1.2, speaker: assignment)
            let excluded = self.unit(id: "excluded", span: span, analysisStart: 1.3, analysisEnd: 1.5, speaker: .unassigned)
            let after = self.unit(id: "after", span: span, analysisStart: 1.6, analysisEnd: 1.8, speaker: assignment)
            let units = [before, excluded, after]
            let activity = outsideActivity ? [a, b].flatMap { token in
                [MeetingBackendSpeakerActivity(token: token, start: 1, end: 1.2),
                 .init(token: token, start: 1.6, end: 1.8)]
            } : []
            let result = try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest,
                evidence: .init(backendID: plan.backendID, attemptID: plan.attemptID, units: units, speakerActivity: activity),
                coverageReceipts: self.receipts(for: manifest),
                echoVerdicts: [before.id: .notEcho, after.id: .notEcho,
                    excluded.id: outsideActivity ? .notEcho : .echoSuppressed(duplicateOfUnitID: nil)],
                speakerAttributionPolicy: self.provisionalPolicy))
            XCTAssertEqual(result.segments.count, 2)
            XCTAssertTrue(result.segments.allSatisfy { $0.speakerID != nil && $0.speakerIdentityIsProvisional == true })
            XCTAssertNotEqual(result.segments[0].speakerID, result.segments[1].speakerID)
            XCTAssertEqual(result.sidecar.units, units.sorted { $0.id < $1.id })
            XCTAssertEqual(result.sidecar.dispositions.first { $0.unitID == excluded.id }?.disposition,
                outsideActivity ? .outsideActivity : .echoSuppressed)
        }
    }

    func testPostStopIndexedBatchHandlesNestedUtteranceWithoutMovingNativeWords() throws {
        let attempt = UUID(), track = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let first = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "a")
        let second = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "b")
        let count = 2_000
        let duration = Double(count * 2)
        let coarse = MeetingTranscriptSegment(id: UUID(), start: self.mediaTime(0), end: self.mediaTime(duration),
            sourceTrackID: track, speakerID: nil, text: "Synthetic coarse utterance", revision: 0,
            status: .final, overlap: .none, completeness: .complete, nativePrecision: .utterance,
            nativeUnitID: "coarse", nativeTiming: .init(start: 0, end: duration))
        var words: [MeetingTranscriptSegment] = []
        words.reserveCapacity(count)
        for index in 0..<count {
            let start = Double(index * 2)
            let end = start + 1
            words.append(MeetingTranscriptSegment(id: UUID(), start: self.mediaTime(start),
                end: self.mediaTime(end), sourceTrackID: track, speakerID: nil,
                text: "word-\(index)", revision: 0, status: .final, overlap: .none, completeness: .complete,
                nativePrecision: .word, nativeUnitID: "native-\(index)",
                nativeTiming: .init(start: start, end: end)))
        }
        let transcript = MeetingPCMTranscriptBatch(segments: [coarse] + words)
        var activity: [MeetingBackendSpeakerActivity] = []
        activity.reserveCapacity(count * 2)
        for index in 0..<count {
            let start = Double(index * 2)
            let boundary = start + 1
            let end = start + 2
            activity.append(MeetingBackendSpeakerActivity(token: first, start: start, end: boundary))
            activity.append(MeetingBackendSpeakerActivity(token: second, start: boundary, end: end))
        }
        let result = try MeetingPCMRecordingAttribution.assemble(transcript: transcript, activity: activity,
            epoch: epoch, attemptID: attempt, duration: duration, speakerNameFormat: "Speaker %lld")
        XCTAssertEqual(result.segments.map(\.id), transcript.segments.map(\.id))
        XCTAssertEqual(result.segments.map(\.text), transcript.segments.map(\.text))
        XCTAssertEqual(result.segments.map(\.nativeTiming), transcript.segments.map(\.nativeTiming))
        XCTAssertEqual(result.segments.map(\.nativePrecision), transcript.segments.map(\.nativePrecision))
        XCTAssertEqual(result.segments[0].speakerAttribution?.rawAssignment, .ambiguous([first, second]))
        XCTAssertNil(result.segments[0].speakerID)
        XCTAssertTrue(result.segments.dropFirst().allSatisfy { $0.speakerID != nil })
    }

    func testCancelledSidecarReplayPreservesCancellationInsteadOfReportingCorruptAttribution() async throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "native", span: span, analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]), coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [unit.id: .notEcho]))
        let replay = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try result.sidecar.validated()
        }
        do { _ = try await replay.value; XCTFail("Cancelled replay must not publish a result") }
        catch is CancellationError { }
        catch { XCTFail("Cancellation was converted into a different error: \(error)") }
    }

    func testSkippedReceiptBlocksContinuationContextAndSurvivesSidecarReplay() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let main = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "a")
        let other = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "b")
        let units = [
            self.unit(id: "before", span: span, text: "before", analysisStart: 5.6, analysisEnd: 6, speaker: .assigned(main)),
            self.unit(id: "mixed", span: span, text: "mixed", analysisStart: 6.1, analysisEnd: 6.8, speaker: .ambiguous([main, other])),
            self.unit(id: "after", span: span, text: "after", analysisStart: 6.8, analysisEnd: 7.2, speaker: .assigned(main))]
        let evidence = MeetingFinalTranscriptEvidence(backendID: plan.backendID, attemptID: plan.attemptID,
            units: units, speakerActivity: [.init(token: main, start: 0, end: 7.2), .init(token: other, start: 6.2, end: 6.6)])
        let echoes = Dictionary(uniqueKeysWithValues: units.map { ($0.id, MeetingUnitEchoVerdict.notEcho) })
        func assemble(_ receipts: [MeetingSpanCoverageReceipt]) throws -> MeetingAssemblyResult {
            try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest, evidence: evidence,
                coverageReceipts: receipts, echoVerdicts: echoes))
        }
        let baseline = try assemble(self.receipts(for: manifest))
        let baselineMixed = try XCTUnwrap(baseline.sidecar.speakerAttributionDecisions.first { $0.unitID == "mixed" })
        XCTAssertEqual(baselineMixed.rule, .mainSpeakerContinuation)
        XCTAssertEqual(baselineMixed.selectedToken, main)
        XCTAssertEqual(baselineMixed.cueUnitIDs, ["before", "after"])
        for status in [MeetingSpanCoverageStatus.skipped, .failed, .providerTruncated] {
            let result = try assemble([
                .init(id: "processed-before", spanID: span.id, analysisStart: 0, analysisEnd: 6, status: .processed),
                .init(id: "gap", spanID: span.id, analysisStart: 6, analysisEnd: 6.1, status: status),
                .init(id: "processed-after", spanID: span.id, analysisStart: 6.1, analysisEnd: 10, status: .processed)])
            let decision = try XCTUnwrap(result.sidecar.speakerAttributionDecisions.first { $0.unitID == "mixed" })
            XCTAssertFalse(decision.rule.isHeuristic,
                "A coverage gap blocks interruption and continuing-speaker context alike")
            XCTAssertEqual(decision.rule, .ambiguous)
            XCTAssertNil(decision.selectedToken)
            XCTAssertTrue(decision.cueUnitIDs.isEmpty)
            XCTAssertEqual(decision.rawAssignment, units[1].speaker)
            XCTAssertEqual(decision.candidates, baselineMixed.candidates)
            XCTAssertEqual(decision.simultaneousIntervals, baselineMixed.simultaneousIntervals)
            XCTAssertEqual(result.sidecar.units, baseline.sidecar.units)
            XCTAssertEqual(result.sidecar.speakerActivity, baseline.sidecar.speakerActivity)
            XCTAssertEqual(result.segments.map(\.nativeSpeakerAssignment), units.map { Optional($0.speaker) })
            let replay = try JSONDecoder().decode(MeetingResultSidecar.self, from: JSONEncoder().encode(result.sidecar))
            XCTAssertEqual(try replay.validated(), result.sidecar)
        }
    }

    func testProvenanceQuarantineNeverEntersCoreAndDisablesBothPossibleEpochContexts() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 110)
        let second = self.chunk(sequence: 1, start: 110, end: 120,
            discontinuities: [.init(kind: .clockDiscontinuity, presentationTime: self.mediaTime(110), gapSeconds: nil, detail: "synthetic")])
        let mic = self.track(kind: .microphone, chunks: [first, second], eras: [self.era(protection: .voiceProcessed, start: 100)])
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 10)), (mic.id, second, self.observed(second, duration: 10))])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        var units: [MeetingFinalTextUnit] = [], activity: [MeetingBackendSpeakerActivity] = []
        for (index, span) in spans.enumerated() {
            let main = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "a")
            let other = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "b")
            let offset = span.analysisInterval.start
            units += [
                self.unit(id: "before-\(index)", span: span, analysisStart: offset + 1, analysisEnd: offset + 2, speaker: .assigned(main)),
                self.unit(id: "mixed-\(index)", span: span, analysisStart: offset + 2.1, analysisEnd: offset + 2.8, speaker: .ambiguous([main, other])),
                self.unit(id: "after-\(index)", span: span, analysisStart: offset + 2.8, analysisEnd: offset + 3.2, speaker: .assigned(main))]
            activity += [.init(token: main, start: offset, end: offset + 3.2), .init(token: other, start: offset + 2.2, end: offset + 2.6)]
        }
        let echoes = Dictionary(uniqueKeysWithValues: units.map { ($0.id, MeetingUnitEchoVerdict.notEcho) })
        func assemble(_ source: [MeetingFinalTextUnit]) throws -> MeetingAssemblyResult {
            try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest,
                evidence: .init(backendID: plan.backendID, attemptID: plan.attemptID, units: source, speakerActivity: activity),
                coverageReceipts: self.receipts(for: manifest), echoVerdicts: echoes))
        }
        let baseline = try assemble(units)
        let baselineMixed = baseline.sidecar.speakerAttributionDecisions.filter { $0.rule == .mainSpeakerContinuation }
        XCTAssertEqual(Set(baselineMixed.map(\.unitID)), ["mixed-0", "mixed-1"])
        for decision in baselineMixed {
            XCTAssertEqual(decision.selectedToken?.label, "a")
            XCTAssertEqual(Set(decision.rawAssignment.tokens.map(\.label)), ["a", "b"])
        }
        let quarantined = self.unit(id: "invalid-provenance", span: spans[1], analysisStart: 11.9, analysisEnd: 12.05,
            epoch: spans[0].analysisEpochID, speaker: .unassigned, spanIDs: [spans[1].id])
        let result = try assemble(units + [quarantined])
        let quarantineRecord = try XCTUnwrap(result.sidecar.dispositions.first { $0.unitID == quarantined.id })
        XCTAssertEqual(quarantineRecord.disposition, .rejectedInvalidTiming)
        XCTAssertEqual(quarantineRecord.reasonCode, MeetingUnitQuarantineReason.analysisEpochMismatch.rawValue)
        XCTAssertEqual(Set(result.sidecar.speakerAttributionDecisions.map(\.unitID)), Set(units.map(\.id)))
        XCTAssertFalse(result.sidecar.speakerAttributionDecisions.contains { $0.unitID == quarantined.id },
            "No interval query or clipped support is legal for quarantined provenance")
        XCTAssertFalse(result.sidecar.speakerAttributionDecisions.contains { $0.rule.isHeuristic })
        for original in baselineMixed {
            let decision = try XCTUnwrap(result.sidecar.speakerAttributionDecisions.first { $0.unitID == original.unitID })
            XCTAssertEqual(decision.rule, .ambiguous)
            XCTAssertNil(decision.selectedToken)
            XCTAssertTrue(decision.cueUnitIDs.isEmpty)
            XCTAssertEqual(decision.rawAssignment, original.rawAssignment)
            XCTAssertEqual(decision.candidates, original.candidates)
            XCTAssertEqual(decision.simultaneousIntervals, original.simultaneousIntervals)
        }
        XCTAssertEqual(result.segments.map(\.id), baseline.segments.map(\.id))
        XCTAssertEqual(result.segments.map(\.nativeSpeakerAssignment), baseline.segments.map(\.nativeSpeakerAssignment))
        XCTAssertTrue(result.sidecar.units.contains(quarantined))
        let replay = try JSONDecoder().decode(MeetingResultSidecar.self, from: JSONEncoder().encode(result.sidecar))
        XCTAssertEqual(try replay.validated(), result.sidecar)
    }

    // MARK: - Session/manifest fixtures

    private func chunk(
        id: UUID = UUID(),
        sequence: Int,
        start: Double,
        end: Double,
        discontinuities: [MeetingAudioDiscontinuity] = []
    ) -> MeetingAudioChunk {
        MeetingAudioChunk(
            id: id,
            sequence: sequence,
            relativeFilePath: "tracks/chunk-\(sequence).m4a",
            presentationStart: self.mediaTime(start),
            presentationEnd: self.mediaTime(end),
            discontinuities: discontinuities,
            sha256: String(repeating: String((sequence % 9) + 1), count: 64),
            byteCount: 1024,
            finalizationState: .finalized
        )
    }

    private func mediaTime(_ seconds: Double) -> MeetingMediaTime {
        MeetingMediaTime(value: Int64((seconds * 1000).rounded()), timescale: 1000)
    }

    private func era(
        protection: MeetingMicrophoneEchoProtection,
        start: Double,
        deviceUID: String = "mic-a",
        drift: MeetingClockDriftRecord? = nil
    ) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: .voiceProcessing,
            deviceUID: deviceUID,
            deviceName: deviceUID,
            roleAtElection: .unknown,
            echoProtection: protection,
            startSeconds: start,
            clockDrift: drift
        )
    }

    private func track(
        id: UUID = UUID(),
        kind: MeetingAudioTrackKind,
        chunks: [MeetingAudioChunk],
        captureMethod: MeetingAudioTrackCaptureMethod? = nil,
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        eras: [MeetingCaptureEra]? = nil
    ) -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: id,
            kind: kind,
            sourceIdentifier: kind.rawValue,
            sourceDisplayName: kind.rawValue,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 42,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: chunks,
            captureMethod: captureMethod,
            captureEras: eras
        )
    }

    private func plan(
        mode: MeetingCaptureMode,
        tracks: [MeetingAudioTrack]
    ) -> MeetingBackendPlan {
        let application = mode == .onlineCall
            ? MeetingApplicationIdentity(bundleIdentifier: "fixture.app", displayName: "Fixture")
            : nil
        var session = MeetingSession(
            configuration: MeetingCaptureConfiguration(
                mode: mode,
                title: "Assembler fixture",
                application: application,
                microphone: MeetingMicrophoneIdentity(
                    captureDeviceID: "mic-a",
                    coreAudioUID: "mic-a",
                    displayName: "Mic"
                )
            ),
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 1,
                machTimebaseNumerator: 1,
                machTimebaseDenominator: 1,
                firstPresentationTime: nil
            )
        )
        session.audioTracks = tracks
        let request = MeetingBackendRequest(
            attemptID: UUID(),
            session: session,
            sessionDirectory: FileManager.default.temporaryDirectory,
            configuration: MeetingFinalProcessingConfiguration()
        )
        return MeetingBackendPlan(
            request: request,
            descriptor: MeetingBackendDescriptor(
                id: self.backendID,
                version: "c2b1-test",
                execution: .local,
                supportedLanguageCodes: ["en"],
                supportedTrackKinds: Set(MeetingAudioTrackKind.allCases),
                supportedFinalPrecisions: [.word, .utterance],
                resultContract: .canonicalEvidence,
                knownLimits: []
            )
        )
    }

    private func observed(
        _ chunk: MeetingAudioChunk,
        duration: Double,
        priming: MeetingCodecPriming = .measuredFrames(0)
    ) -> MeetingChunkObservationResult {
        .observed(MeetingChunkObservedAudio(
            byteCount: chunk.byteCount,
            sha256: chunk.sha256,
            decoded: MeetingChunkDecodedFacts(
                sampleRate: 100,
                channelCount: 1,
                frameCount: Int64((duration * 100).rounded()),
                durationSeconds: duration,
                codecPriming: priming,
                processingFormatDescription: "fixture"
            )
        ))
    }

    private func buildManifest(
        plan: MeetingBackendPlan,
        observations: [(MeetingAudioTrackID, MeetingAudioChunk, MeetingChunkObservationResult)]
    ) throws -> MeetingAnalysisManifest {
        try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: AssemblerFixtureObserver(results: Dictionary(
                uniqueKeysWithValues: observations.map {
                    (MeetingAnalysisChunkKey(trackID: $0.0, chunkID: $0.1.id), $0.2)
                }
            ))
        ).build()
    }

    /// One online microphone chunk, presentation 100..<100+duration>, one admissible era.
    private func onlineMicFixture(
        duration: Double = 10,
        priming: MeetingCodecPriming = .measuredFrames(0),
        drift: MeetingClockDriftRecord? = nil
    ) throws -> (plan: MeetingBackendPlan, manifest: MeetingAnalysisManifest, span: MeetingAnalysisSpan) {
        let chunk = self.chunk(sequence: 0, start: 100, end: 100 + duration)
        let track = self.track(
            kind: .microphone,
            chunks: [chunk],
            eras: [self.era(protection: .voiceProcessed, start: 100, drift: drift)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [track])
        let manifest = try self.buildManifest(
            plan: plan,
            observations: [(track.id, chunk, self.observed(chunk, duration: duration, priming: priming))]
        )
        let span = try XCTUnwrap(manifest.track(track.id)?.spans.first)
        return (plan, manifest, span)
    }

    private func receipts(
        for manifest: MeetingAnalysisManifest,
        status: MeetingSpanCoverageStatus = .processed
    ) -> [MeetingSpanCoverageReceipt] {
        manifest.allSpans.enumerated().map { index, span in
            MeetingSpanCoverageReceipt(
                id: "receipt-\(index)",
                spanID: span.id,
                analysisStart: span.analysisInterval.start,
                analysisEnd: span.analysisInterval.end,
                status: status
            )
        }
    }

    private func unit(
        id: String,
        span: MeetingAnalysisSpan,
        text: String = "word",
        analysisStart: TimeInterval? = nil,
        analysisEnd: TimeInterval? = nil,
        epoch: MeetingAnalysisEpochID? = nil,
        speaker: MeetingBackendSpeakerAssignment? = nil,
        // nil requests the fixture default; an empty collection tests explicitly missing data.
        // swiftlint:disable:next discouraged_optional_collection
        spanIDs: [String]? = nil,
        confidence: Double? = nil
    ) -> MeetingFinalTextUnit {
        let resolvedEpoch = epoch ?? span.analysisEpochID
        return MeetingFinalTextUnit(
            id: id,
            trackID: span.trackID,
            analysisEpochID: resolvedEpoch,
            precision: .word,
            text: text,
            analysisStart: analysisStart ?? span.analysisInterval.start,
            analysisEnd: analysisEnd ?? span.analysisInterval.end,
            speaker: speaker ?? .assigned(
                MeetingBackendSpeakerToken(analysisEpochID: resolvedEpoch, label: "slot-0")
            ),
            analysisSpanIDs: spanIDs ?? [span.id],
            confidence: confidence
        )
    }

    private func evidence(
        plan: MeetingBackendPlan,
        units: [MeetingFinalTextUnit],
        activity: [MeetingBackendSpeakerActivity] = []
    ) -> MeetingFinalTranscriptEvidence {
        MeetingFinalTranscriptEvidence(
            backendID: plan.backendID,
            attemptID: plan.attemptID,
            units: units,
            speakerActivity: activity
        )
    }

    private func dispositions(
        _ result: MeetingAssemblyResult
    ) -> [String: MeetingTextUnitDispositionRecord] {
        Dictionary(
            result.sidecar.dispositions.map { ($0.unitID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
    }

    // MARK: - Deterministic identity

    func testDeterministicIDsAndSpeakerIsolationAcrossTracksAndAttempts() throws {
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let plan = self.plan(mode: .onlineCall, tracks: [mic, app])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            (app.id, appChunk, self.observed(appChunk, duration: 10)),
        ])
        let micSpan = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let appSpan = try XCTUnwrap(manifest.track(app.id)?.spans.first)

        // The same backend label on two tracks: the product speakers must never merge.
        let units = [
            self.unit(id: "m-0", span: micSpan, text: "mine", analysisStart: 1, analysisEnd: 2),
            self.unit(id: "a-0", span: appSpan, text: "remote", analysisStart: 1, analysisEnd: 2),
        ]
        let input = MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["m-0": .notEcho]
        )
        let first = try MeetingTranscriptAssembler().assemble(input)
        let second = try MeetingTranscriptAssembler().assemble(input)
        XCTAssertEqual(first, second)

        XCTAssertEqual(first.speakers.count, 2)
        XCTAssertEqual(Set(first.speakers.map(\.id)).count, 2)
        XCTAssertTrue(first.speakers.allSatisfy { !$0.isLocalUser && $0.identityCandidates.isEmpty })
        XCTAssertEqual(Set(first.speakers.map(\.trackKind)), [.microphone, .applicationAudio])

        let micSegment = try XCTUnwrap(first.segments.first { $0.sourceTrackID == mic.id })
        let appSegment = try XCTUnwrap(first.segments.first { $0.sourceTrackID == app.id })
        XCTAssertNotEqual(micSegment.speakerID, appSegment.speakerID)
        XCTAssertNotNil(micSegment.speakerID)
        XCTAssertNotNil(appSegment.speakerID)
        XCTAssertEqual(micSegment.start.seconds, 1, accuracy: 1e-3)
        XCTAssertEqual(micSegment.end.seconds, 2, accuracy: 1e-3)
    }

    private func twoEpochMicrophone() throws -> (plan: MeetingBackendPlan, manifest: MeetingAnalysisManifest, spans: [MeetingAnalysisSpan]) {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(
            sequence: 1,
            start: 105,
            end: 110,
            discontinuities: [MeetingAudioDiscontinuity(
                kind: .microphoneDisconnected,
                presentationTime: self.mediaTime(105),
                gapSeconds: 0,
                detail: "fixture"
            )]
        )
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 2)
        return (plan, manifest, spans)
    }

    func testRetainedUnsupportedAmbiguityDoesNotRunLegacyProductContinuity() throws {
        let (plan, manifest, spans) = try self.twoEpochMicrophone()
        let span = spans[0]
        let a = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0")
        let b = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-1")
        let units = [
            self.unit(id: "before", span: span, text: "one two three four five six seven eight nine ten",
                      analysisStart: 0, analysisEnd: 1, speaker: .assigned(a)),
            self.unit(id: "unknown", span: span, text: "hello", analysisStart: 1, analysisEnd: 1.2,
                      speaker: .ambiguous([a, b])),
            self.unit(id: "after", span: span, text: "one two three four five six seven eight nine ten",
                      analysisStart: 1.2, analysisEnd: 3, speaker: .assigned(b))]
        let result = try MeetingTranscriptAssembler().assemble(.init(plan: plan, manifest: manifest,
            evidence: self.evidence(plan: plan, units: units), coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: Dictionary(uniqueKeysWithValues: units.map { ($0.id, .notEcho) }),
            speakerAttributionPolicy: self.provisionalPolicy))
        XCTAssertNotNil(result.segments[1].speakerID)
        XCTAssertNotEqual(result.segments[1].speakerID, result.segments[0].speakerID)
        XCTAssertNotEqual(result.segments[1].speakerID, result.segments[2].speakerID,
                     "A preliminary identity cannot become a guessed incoming voice")
        XCTAssertEqual(result.segments[1].speakerIdentityIsProvisional, true)
        XCTAssertNil(result.segments[1].speakerAttributionInference)
        XCTAssertEqual(result.segments[1].nativeUnitID, "unknown")
        XCTAssertEqual(result.segments[1].nativeSpeakerAssignment, .ambiguous([a, b]))
        let decision = try XCTUnwrap(result.sidecar.speakerAttributionDecisions.first { $0.unitID == "unknown" })
        XCTAssertEqual(decision.rawAssignment, .ambiguous([a, b]))
        XCTAssertTrue(decision.cueUnitIDs.isEmpty)
        XCTAssertNil(decision.selectedToken)
        XCTAssertEqual(result.sidecar.units.first { $0.id == "unknown" }?.speaker, .ambiguous([a, b]))
        XCTAssertEqual(result.sidecar.dispositions.first { $0.unitID == "unknown" }?.disposition, .ambiguousUnassigned)
        XCTAssertNoThrow(try result.sidecar.validated())
    }

    func testContinuousDiarizerLinksOnlyTheSameSlotAcrossEpochs() throws {
        let (plan, manifest, spans) = try self.twoEpochMicrophone()
        let slot = { (span: MeetingAnalysisSpan, label: String) in
            MeetingBackendSpeakerAssignment.assigned(.init(analysisEpochID: span.analysisEpochID, label: label))
        }
        let units = [
            self.unit(id: "u-0", span: spans[0], analysisStart: 1, analysisEnd: 2, speaker: slot(spans[0], "slot-0")),
            self.unit(id: "u-1", span: spans[1], analysisStart: 6, analysisEnd: 7, speaker: slot(spans[1], "slot-0")),
            self.unit(id: "u-2", span: spans[1], analysisStart: 8, analysisEnd: 9, speaker: slot(spans[1], "slot-1")),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: MeetingFinalTranscriptEvidence(
                backendID: plan.backendID,
                attemptID: plan.attemptID,
                units: units,
                speakerSlotsContinueAcrossEpochs: true
            ),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho, "u-1": .notEcho, "u-2": .notEcho]
        ))
        let speakerByUnit = Dictionary(uniqueKeysWithValues: zip(["u-0", "u-1", "u-2"], result.segments.map(\.speakerID)))
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertNotNil(speakerByUnit["u-0"] ?? nil)
        XCTAssertEqual(result.segments.map(\.nativeSpeakerAssignment), units.map { Optional($0.speaker) })
        XCTAssertEqual(speakerByUnit["u-0"], speakerByUnit["u-1"], "slot-0 keeps its name across the reset")
        XCTAssertEqual(speakerByUnit["u-2"], speakerByUnit["u-1"], "A brief unresolved slot reuses the reading participant")
        XCTAssertEqual(result.segments[2].speakerAttribution?.rule, .readingParticipantContext)
        XCTAssertNil(result.segments[2].speakerAttribution?.selectedToken, "Reading ownership cannot fabricate an acoustic identity link")
        XCTAssertEqual(result.sidecar.speakerIdentityLinks.count, 1)
    }

    func testBriefSpeakerBesideSubstantialSpeakerKeepsTextWithPreliminaryName() throws {
        let (plan, manifest, spans) = try self.twoEpochMicrophone()
        let slot = { (label: String) in
            MeetingBackendSpeakerAssignment.assigned(.init(analysisEpochID: spans[0].analysisEpochID, label: label))
        }
        let talker = self.unit(
            id: "u-0",
            span: spans[0],
            text: "one two three four five six seven eight nine ten",
            analysisStart: 0.5,
            analysisEnd: 3,
            speaker: slot("slot-0")
        )
        let cough = self.unit(id: "u-1", span: spans[0], text: "hmm", analysisStart: 3.5, analysisEnd: 4, speaker: slot("slot-1"))
        let assemble = { (units: [MeetingFinalTextUnit], speakerNameFormat: String) in
            try MeetingTranscriptAssembler(speakerNameFormat: speakerNameFormat).assemble(MeetingAssemblyInput(
                plan: plan,
                manifest: manifest,
                evidence: self.evidence(plan: plan, units: units),
                coverageReceipts: self.receipts(for: manifest),
                echoVerdicts: Dictionary(uniqueKeysWithValues: units.map { ($0.id, .notEcho) }),
                speakerAttributionPolicy: self.provisionalPolicy
            ))
        }

        let result = try assemble([talker, cough], "Speaker %lld")

        XCTAssertEqual(result.speakers.map(\.displayName), ["Speaker 1", "Speaker 2"])
        let coughSegment = try XCTUnwrap(result.segments.first { $0.text == "hmm" }, "brief speech stays in the transcript")
        XCTAssertNotNil(coughSegment.speakerID)
        XCTAssertEqual(coughSegment.speakerIdentityIsProvisional, true)
        XCTAssertEqual(coughSegment.attributionState, .assigned)
        XCTAssertNotNil(result.segments.first { $0.text.hasPrefix("one") }?.speakerID)
        // A track where every slot is brief keeps its speakers.
        XCTAssertEqual(try assemble([cough], "Speaker %lld").speakers.count, 1)
        let russian = try assemble([talker, cough], PichiLocalization.text("Speaker %lld", language: .russian, bundle: .main))
        XCTAssertEqual(russian.speakers.map(\.displayName), ["Участник 1", "Участник 2"])
        XCTAssertEqual(russian.speakers.map(\.id), result.speakers.map(\.id))
        XCTAssertEqual(russian.speakers.map(\.diarizationClusterID), result.speakers.map(\.diarizationClusterID))
        XCTAssertEqual(russian.segments, result.segments)
        XCTAssertEqual(russian.sidecar, result.sidecar)
    }

    func testContinuityFlagRoundTripsAndDefaultsOffForOlderEvidence() throws {
        let attemptID = UUID()
        let continuous = MeetingFinalTranscriptEvidence(
            backendID: .parakeetNemotron, attemptID: attemptID, units: [], speakerSlotsContinueAcrossEpochs: true
        )
        let decoded = try JSONDecoder().decode(
            MeetingFinalTranscriptEvidence.self, from: JSONEncoder().encode(continuous)
        )
        XCTAssertTrue(decoded.speakerSlotsContinueAcrossEpochs)

        let older = try JSONEncoder().encode(
            MeetingFinalTranscriptEvidence(backendID: .parakeetNemotron, attemptID: attemptID, units: [])
        )
        let encodedText = try XCTUnwrap(String(bytes: older, encoding: .utf8))
        XCTAssertFalse(encodedText.contains("speakerSlotsContinueAcrossEpochs"))
        XCTAssertFalse(try JSONDecoder().decode(MeetingFinalTranscriptEvidence.self, from: older).speakerSlotsContinueAcrossEpochs)
    }

    func testSameLabelAcrossEpochsNeverMerges() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(
            sequence: 1,
            start: 105,
            end: 110,
            discontinuities: [MeetingAudioDiscontinuity(
                kind: .microphoneDisconnected,
                presentationTime: self.mediaTime(105),
                gapSeconds: 0,
                detail: "fixture"
            )]
        )
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 2)
        XCTAssertNotEqual(spans[0].analysisEpochID, spans[1].analysisEpochID)

        let units = [
            self.unit(id: "u-0", span: spans[0], analysisStart: 1, analysisEnd: 2),
            self.unit(id: "u-1", span: spans[1], analysisStart: 6, analysisEnd: 7),
        ]
        let standard = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho, "u-1": .notEcho]
        ))
        XCTAssertEqual(standard.speakers.count, 1, "An unlinked brief voice cannot open an extra participant")
        XCTAssertNotNil(standard.segments.first?.speakerID)
        XCTAssertEqual(standard.segments.last?.speakerID, standard.segments.first?.speakerID)
        XCTAssertEqual(standard.segments.last?.speakerAttribution?.rule, .readingParticipantContext)
        XCTAssertNil(standard.segments.last?.speakerAttribution?.selectedToken,
            "The reading fallback does not establish native identity across epochs")
        XCTAssertTrue(standard.sidecar.speakerIdentityLinks.isEmpty)
        XCTAssertEqual(standard.segments.map(\.nativeSpeakerAssignment), units.map { Optional($0.speaker) })
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho, "u-1": .notEcho],
            speakerAttributionPolicy: self.provisionalPolicy
        ))
        // Same label, same track, different epochs: two speakers, never one.
        XCTAssertEqual(result.speakers.count, 2)
        XCTAssertNotEqual(result.speakers[0].id, result.speakers[1].id)
        XCTAssertEqual(Set(result.speakers.compactMap(\.diarizationClusterID)).count, 2)
        XCTAssertEqual(Set(result.segments.compactMap(\.speakerID)).count, 2)
        let embedding = [Float](repeating: 0.0625, count: 256)
        let profiles = spans.map {
            MeetingSpeakerVoiceProfile(
                token: .init(analysisEpochID: $0.analysisEpochID, label: "slot-0"),
                embeddings: [embedding, embedding]
            )
        }
        let matched = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: MeetingFinalTranscriptEvidence(
                backendID: plan.backendID, attemptID: plan.attemptID, units: units, voiceProfiles: profiles
            ),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho, "u-1": .notEcho],
            speakerAttributionPolicy: self.provisionalPolicy
        ))
        XCTAssertEqual(matched.speakers.count, 1)
        XCTAssertEqual(Set(matched.segments.compactMap(\.speakerID)).count, 1)
        XCTAssertEqual(matched.segments.map(\.text), result.segments.map(\.text))
        XCTAssertEqual(matched.segments.map(\.start), result.segments.map(\.start))
        XCTAssertEqual(matched.coverageGaps, result.coverageGaps)
        XCTAssertEqual(matched.sidecar.speakerIdentityLinks.count, 1)
        let decoded = try JSONDecoder().decode(MeetingResultSidecar.self, from: JSONEncoder().encode(matched.sidecar))
        XCTAssertEqual(try decoded.validated(), matched.sidecar)
    }

    // MARK: - Mapping

    func testAnalysisIntervalMapsThroughSpansExactlyOnceIncludingDrift() throws {
        // An eligible VPIO drift fit: factor 1.00006. The segment must carry exactly one
        // application of that rate — the manifest's transform — never a second correction.
        let drift = MeetingClockDriftRecord(
            cumulativeAbsorbedSeconds: 0.006,
            elapsedValidHostSeconds: 100,
            eligible: true
        )
        let (plan, manifest, span) = try self.onlineMicFixture(drift: drift)
        guard case .appliedOnce = span.timing.deDrift else {
            return XCTFail("fixture must exercise a real de-drift application")
        }
        let transform = span.presentationMapping
        XCTAssertNotEqual(transform.rateRatio, 1)

        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho]
        ))
        let segment = try XCTUnwrap(result.segments.first)
        let expectedStart = transform.presentationTime(forAnalysisTime: 1)
        let expectedEnd = transform.presentationTime(forAnalysisTime: 2)
        XCTAssertEqual(segment.start.seconds, expectedStart, accuracy: 1e-3)
        XCTAssertEqual(segment.end.seconds, expectedEnd, accuracy: 1e-3)
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .emitted)
    }

    @MainActor
    func testPlaybackResetClearsCompletedFailureAndRejectsStaleLoads() async throws {
        let playback = MeetingSegmentPlayback()
        playback.toggle(sessionID: UUID(), segmentID: UUID())
        let deadline = Date().addingTimeInterval(2)
        while playback.isLoading, Date() < deadline {
            try await Task.sleep(for: .milliseconds(1))
        }
        XCTAssertNotNil(playback.errorMessage, "A completed load failure must still be visible")
        playback.stop()
        XCTAssertNil(playback.errorMessage, "Changing meetings clears the old warning")
        playback.toggle(sessionID: UUID(), segmentID: UUID())
        playback.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(playback.errorMessage)
        XCTAssertNil(playback.activeSegmentID)
        XCTAssertFalse(playback.isLoading)
        XCTAssertFalse(playback.progress.isPlaying)
        XCTAssertEqual(playback.progress.elapsed, 0)
        XCTAssertEqual(playback.progress.duration, 0)
    }

    @MainActor
    func testPlaybackCancellationCannotRestartOrReportStaleFailure() async throws {
        let playback = MeetingSegmentPlayback()
        playback.toggle(sessionID: UUID(), segmentID: UUID())
        playback.toggle(sessionID: UUID(), segmentID: UUID())
        playback.stop()
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(playback.activeSegmentID)
        XCTAssertFalse(playback.isLoading)
        XCTAssertNil(playback.errorMessage)
    }

    @MainActor
    func testStoppedPlaybackReleasesOwner() async throws {
        weak var releasedPlayback: MeetingSegmentPlayback?
        do {
            let playback = MeetingSegmentPlayback()
            releasedPlayback = playback
            playback.toggle(sessionID: UUID(), segmentID: UUID())
            playback.stop()
        }
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertNil(releasedPlayback)
    }

    func testPlaybackInvertsDriftAndDoesNotChangeTranscript() throws {
        let drift = MeetingClockDriftRecord(cumulativeAbsorbedSeconds: 0.006, elapsedValidHostSeconds: 100, eligible: true)
        let (plan, manifest, span) = try self.onlineMicFixture(drift: drift)
        let unit = self.unit(id: "playback", span: span, analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["playback": .notEcho]
        ))
        let segment = try XCTUnwrap(result.segments.first)
        let original = segment
        let slices = try MeetingSegmentPlaybackPlan.slices(segment: segment, spans: manifest.allSpans, directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(slices.count, 1)
        XCTAssertEqual(try XCTUnwrap(slices.first).start, 1, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(slices.first).end, 2, accuracy: 0.001)
        XCTAssertEqual(segment, original)
        var otherTrack = segment
        otherTrack.sourceTrackID = UUID()
        XCTAssertThrowsError(try MeetingSegmentPlaybackPlan.slices(segment: otherTrack, spans: manifest.allSpans, directory: FileManager.default.temporaryDirectory))
        var outside = segment
        outside.start = self.mediaTime(1000)
        outside.end = self.mediaTime(1001)
        XCTAssertThrowsError(try MeetingSegmentPlaybackPlan.slices(segment: outside, spans: manifest.allSpans, directory: FileManager.default.temporaryDirectory))
    }

    func testCrossSpanUnitMapsOnceAcrossChunkBoundary() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(sequence: 1, start: 105, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 2)

        let unit = self.unit(
            id: "u-0",
            span: spans[0],
            analysisStart: 4.5,
            analysisEnd: 5.5,
            spanIDs: spans.map(\.id)
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho]
        ))
        let segment = try XCTUnwrap(result.segments.first)
        let slices = try MeetingSegmentPlaybackPlan.slices(segment: segment, spans: manifest.allSpans, directory: FileManager.default.temporaryDirectory)
        XCTAssertEqual(slices.count, 2)
        XCTAssertEqual(slices[0].start, 4.5, accuracy: 0.001)
        XCTAssertEqual(slices[0].end, 5, accuracy: 0.001)
        XCTAssertEqual(slices[1].start, 0, accuracy: 0.001)
        XCTAssertEqual(slices[1].end, 0.5, accuracy: 0.001)
        // Start maps through the first span's transform, end through the last's — once each.
        let expectedStart = spans[0].presentationMapping.presentationTime(forAnalysisTime: 4.5)
        let expectedEnd = spans[1].presentationMapping.presentationTime(forAnalysisTime: 5.5)
        XCTAssertEqual(segment.start.seconds, expectedStart, accuracy: 1e-3)
        XCTAssertEqual(segment.end.seconds, expectedEnd, accuracy: 1e-3)
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .emitted)
    }

    // MARK: - Quarantine

    func testInvalidTimingAndBrokenSpanProvenanceQuarantineUnits() throws {
        let chunks = (0..<3).map { self.chunk(sequence: $0, start: 100 + 2 * Double($0), end: 102 + 2 * Double($0)) }
        let mic = self.track(
            kind: .microphone,
            chunks: chunks,
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(
            plan: plan,
            observations: chunks.map { (mic.id, $0, self.observed($0, duration: 2)) }
        )
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 3)

        let units = [
            self.unit(id: "bad-time", span: spans[0], analysisStart: 2, analysisEnd: 2),
            self.unit(
                id: "skip-span",
                span: spans[0],
                analysisStart: 0.5,
                analysisEnd: 5.5,
                spanIDs: [spans[0].id, spans[2].id]
            ),
            self.unit(id: "out-of-bounds", span: spans[2], analysisStart: 5.5, analysisEnd: 6.5),
            self.unit(id: "bad-confidence", span: spans[1], confidence: 2),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [:]
        ))
        let ledger = self.dispositions(result)
        XCTAssertEqual(
            ledger["bad-time"]?.reasonCode,
            MeetingUnitQuarantineReason.invalidTiming.rawValue
        )
        XCTAssertEqual(
            ledger["skip-span"]?.reasonCode,
            MeetingUnitQuarantineReason.spansNotContiguousWithinEpoch.rawValue
        )
        XCTAssertEqual(
            ledger["out-of-bounds"]?.reasonCode,
            MeetingUnitQuarantineReason.spansDoNotCoverUnitInterval.rawValue
        )
        XCTAssertEqual(
            ledger["bad-confidence"]?.reasonCode,
            MeetingUnitQuarantineReason.invalidConfidence.rawValue
        )
        XCTAssertTrue(ledger.values.allSatisfy { $0.disposition == .rejectedInvalidTiming })
        // Quarantined units never reach segments, and quarantine needs no echo verdicts.
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertNoThrow(try result.sidecar.validated())
    }

    func testUnitWhoseSpansBelongToAnotherEpochIsQuarantined() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(
            sequence: 1,
            start: 105,
            end: 110,
            discontinuities: [MeetingAudioDiscontinuity(
                kind: .clockDiscontinuity,
                presentationTime: self.mediaTime(105),
                gapSeconds: nil,
                detail: "fixture"
            )]
        )
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        XCTAssertEqual(spans.count, 2)

        // Declares epoch 0, points at an epoch-1 span: provenance the assembler cannot honor.
        let unit = self.unit(
            id: "epoch-mismatch",
            span: spans[1],
            analysisStart: 5.5,
            analysisEnd: 6.5,
            epoch: spans[0].analysisEpochID,
            spanIDs: [spans[1].id]
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest)
        ))
        let record = try XCTUnwrap(self.dispositions(result)[unit.id])
        XCTAssertEqual(record.disposition, .rejectedInvalidTiming)
        XCTAssertEqual(record.reasonCode, MeetingUnitQuarantineReason.analysisEpochMismatch.rawValue)
        XCTAssertTrue(result.segments.isEmpty)
    }

    // MARK: - Ambiguity and activity

    func testAmbiguousUnitAppearsExactlyOnceWithPreliminaryIdentity() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(
            id: "u-amb",
            span: span,
            text: "overlapped",
            analysisStart: 1,
            analysisEnd: 2,
            speaker: .ambiguous([
                MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0"),
                MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-1"),
            ])
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-amb": .notEcho],
            speakerAttributionPolicy: self.provisionalPolicy
        ))
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .ambiguousUnassigned)
        let matching = result.segments.filter { $0.text == "overlapped" }
        XCTAssertEqual(matching.count, 1)
        XCTAssertNotNil(matching[0].speakerID)
        XCTAssertEqual(matching[0].speakerIdentityIsProvisional, true)
        XCTAssertEqual(matching[0].overlap, .ambiguous)
        XCTAssertEqual(matching[0].attributionState, .overlappingSpeakers)
        // A preliminary reading identity never resolves the native ambiguity candidates.
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertEqual(result.speakers[0].identityIsProvisional, true)
    }

    func testUncertainTimingIsAdmittedAsAmbiguous() throws {
        // Unknown codec priming leaves the span timing-uncertain: the text stays visible but is
        // never confidently assigned to a speaker.
        let (plan, manifest, span) = try self.onlineMicFixture(priming: .unknown(.decoderDidNotReport))
        XCTAssertEqual(span.timing.certainty, .timingUncertain)
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho],
            speakerAttributionPolicy: self.provisionalPolicy
        ))
        let record = try XCTUnwrap(self.dispositions(result)[unit.id])
        XCTAssertEqual(record.disposition, .ambiguousUnassigned)
        XCTAssertEqual(record.reasonCode, "timingUncertain")
        let segment = try XCTUnwrap(result.segments.first)
        XCTAssertNotNil(segment.speakerID)
        XCTAssertEqual(segment.speakerIdentityIsProvisional, true)
        // Timing uncertainty is not speaker overlap: the segment carries no cross-speaker overlap
        // marker, only the distinct `timingUncertain` attribution state.
        XCTAssertEqual(segment.overlap, .none)
        XCTAssertEqual(segment.attributionState, .timingUncertain)
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertEqual(result.speakers[0].identityIsProvisional, true)
    }

    func testUnitOutsideSpeakerActivityIsExcluded() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let activity = [
            MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0"),
                start: 0,
                end: 1
            ),
        ]
        let inside = self.unit(id: "u-in", span: span, text: "inside", analysisStart: 0.2, analysisEnd: 0.8)
        let outside = self.unit(id: "u-out", span: span, text: "outside", analysisStart: 2, analysisEnd: 3)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [inside, outside], activity: activity),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-in": .notEcho, "u-out": .notEcho]
        ))
        let ledger = self.dispositions(result)
        XCTAssertEqual(ledger[inside.id]?.disposition, .emitted)
        XCTAssertEqual(ledger[outside.id]?.disposition, .outsideActivity)
        XCTAssertEqual(result.segments.map(\.text), ["inside"])
    }

    func testBoundaryRetentionKeepsTailButEchoVetoStillWins() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let token = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0")
        let activity = [MeetingBackendSpeakerActivity(token: token, start: 0, end: 1.439_999_938)]
        let anchor = self.unit(id: "anchor", span: span, analysisStart: 1.2, analysisEnd: 1.52)
        let tail = self.unit(id: "tail", span: span, text: "ending", analysisStart: 1.52, analysisEnd: 2.16)
        for suppressed in [false, true] {
            let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
                plan: plan,
                manifest: manifest,
                evidence: self.evidence(plan: plan, units: [anchor, tail], activity: activity),
                coverageReceipts: self.receipts(for: manifest),
                echoVerdicts: [anchor.id: .notEcho, tail.id: suppressed ? .echoSuppressed(duplicateOfUnitID: nil) : .notEcho]
            ))
            XCTAssertEqual(self.dispositions(result)[tail.id]?.disposition, suppressed ? .echoSuppressed : .emitted)
            XCTAssertEqual(result.segments.map(\.text).contains("ending"), !suppressed)
        }
    }

    func testBoundaryRecoveryRetainsCompetingTailWithoutAssigningPreviousSpeaker() throws {
        let (_, _, span) = try self.onlineMicFixture()
        let token = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0")
        let other = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-1")
        let anchor = self.unit(id: "anchor", span: span, analysisStart: 1.2, analysisEnd: 1.52)
        let tail = self.unit(id: "tail", span: span, analysisStart: 1.52, analysisEnd: 2.16, speaker: .unassigned)
        for otherInterval in [(1.4, 1.48), (1.55, 1.56), (2.17, 2.3)] {
            let activity = [
                MeetingBackendSpeakerActivity(token: token, start: 0, end: 1.439_999_938),
                MeetingBackendSpeakerActivity(token: other, start: otherInterval.0, end: otherInterval.1),
            ]
            let assignments = MeetingWordBoundaryRecovery.assignments(
                units: [anchor, tail], activityByEpoch: [span.analysisEpochID: activity]
            )
            XCTAssertEqual(assignments[tail.id], .unassigned, "a competing onset must veto inherited identity")
            XCTAssertFalse(MeetingSpeakerActivityCoverage.isOutside(
                tail, activityByEpoch: [span.analysisEpochID: activity], boundaryAssignments: assignments
            ), "timing uncertainty must not remove recognized text")
        }
    }

    func testFloat32EndpointAllowanceIsBoundedForLongEpochs() throws {
        let (_, _, span) = try self.onlineMicFixture(duration: 7210)
        let token = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0")
        for endpoint in [19.2, 7201.44] {
            let roundedEndpoint = Double(Float(endpoint))
            let start = endpoint + 0.08
            let anchor = self.unit(id: "anchor", span: span, analysisStart: start - 0.32, analysisEnd: start)
            let tail = self.unit(id: "tail", span: span, analysisStart: start, analysisEnd: start + 0.32, speaker: .unassigned)
            let activity = [MeetingBackendSpeakerActivity(token: token, start: 0, end: roundedEndpoint)]
            let recovered = MeetingWordBoundaryRecovery.assignments(
                units: [anchor, tail], activityByEpoch: [span.analysisEpochID: activity]
            )
            XCTAssertEqual(recovered[tail.id], .assigned(token), "Float32 rounding must not exclude the last word")
            let later = self.unit(id: "later", span: span, analysisStart: start + 0.003, analysisEnd: start + 0.32, speaker: .unassigned)
            XCTAssertNil(MeetingWordBoundaryRecovery.assignments(
                units: [anchor, later], activityByEpoch: [span.analysisEpochID: activity]
            )[later.id], "precision allowance must not become an unbounded speech extension")
        }
    }

    func testDirectlySupportedShortWordCanStillAnchorAnEnding() throws {
        let (_, _, span) = try self.onlineMicFixture()
        let token = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0")
        let words = [
            self.unit(id: "first", span: span, analysisStart: 0.6, analysisEnd: 1),
            self.unit(id: "short", span: span, analysisStart: 1, analysisEnd: 1.16),
            self.unit(id: "tail", span: span, analysisStart: 1.16, analysisEnd: 1.6, speaker: .unassigned),
        ]
        let result = MeetingWordBoundaryRecovery.assignments(
            units: words,
            activityByEpoch: [span.analysisEpochID: [
                MeetingBackendSpeakerActivity(token: token, start: 0, end: 1.08),
            ]]
        )
        XCTAssertNil(result["short"], "direct evidence needs no repair")
        XCTAssertEqual(result["tail"], .assigned(token))
    }

    func testBoundaryRecoveryCannotChainThroughSilenceOrOverrideSpeakers() throws {
        let (_, _, span) = try self.onlineMicFixture()
        let token = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-0")
        let other = MeetingBackendSpeakerToken(analysisEpochID: span.analysisEpochID, label: "slot-1")
        let activity = [MeetingBackendSpeakerActivity(token: token, start: 0, end: 1.439_999_938)]
        let anchor = self.unit(id: "anchor", span: span, analysisStart: 1.2, analysisEnd: 1.52)
        let tail = self.unit(id: "tail", span: span, analysisStart: 1.52, analysisEnd: 2.16)
        let silence = self.unit(id: "silence", span: span, analysisStart: 2.16, analysisEnd: 2.4, speaker: .unassigned)
        let recovered = MeetingWordBoundaryRecovery.assignments(
            units: [anchor, tail, silence], activityByEpoch: [span.analysisEpochID: activity]
        )
        XCTAssertEqual(recovered[tail.id], .assigned(token))
        XCTAssertNil(recovered[silence.id], "a recovered tail cannot anchor another recovery")
        for candidate in [
            self.unit(id: "gap", span: span, analysisStart: 1.61, analysisEnd: 2.16, speaker: .unassigned),
            self.unit(id: "long", span: span, analysisStart: 1.52, analysisEnd: 3, speaker: .unassigned),
            self.unit(id: "other", span: span, analysisStart: 1.52, analysisEnd: 2.16, speaker: .assigned(other)),
            self.unit(id: "ambiguous", span: span, analysisStart: 1.52, analysisEnd: 2.16, speaker: .ambiguous([token, other])),
            self.unit(id: "span", span: span, analysisStart: 1.52, analysisEnd: 2.16, spanIDs: ["another-span"]),
            self.unit(id: "epoch", span: span, analysisStart: 1.52, analysisEnd: 2.16, epoch: .init(trackID: span.trackID, ordinal: 9)),
            self.unit(id: "invalid", span: span, analysisStart: .nan, analysisEnd: 2.16),
        ] {
            XCTAssertNil(MeetingWordBoundaryRecovery.assignments(
                units: [anchor, candidate], activityByEpoch: [span.analysisEpochID: activity]
            )[candidate.id], "unsafe candidate \(candidate.id) must not recover")
        }
    }

    func testSpeakerActivityMustStayInsideItsEpoch() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let activity = MeetingBackendSpeakerActivity(
            token: MeetingBackendSpeakerToken(
                analysisEpochID: span.analysisEpochID,
                label: "slot-0"
            ),
            start: 9,
            end: 11
        )
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit], activity: [activity]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [unit.id: .notEcho]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingBackendEvidenceError,
                .activityOutsideEpoch(index: 0)
            )
        }
    }

    // MARK: - Echo

    func testOnlineMicrophoneWithoutEchoVerdictFailsAssembly() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest)
        ))) { error in
            XCTAssertEqual(error as? MeetingAssemblyError, .missingEchoVerdict(unitID: "u-0"))
        }
    }

    func testEchoSuppressedMicrophoneIsLedgerOnlyAndApplicationCopyIsRetained() throws {
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let plan = self.plan(mode: .onlineCall, tracks: [mic, app])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            (app.id, appChunk, self.observed(appChunk, duration: 10)),
        ])
        let micSpan = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let appSpan = try XCTUnwrap(manifest.track(app.id)?.spans.first)

        let micUnit = self.unit(id: "m-echo", span: micSpan, text: "remote words", analysisStart: 1, analysisEnd: 2)
        let appUnit = self.unit(id: "a-0", span: appSpan, text: "remote words", analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [micUnit, appUnit]),
            coverageReceipts: self.receipts(for: manifest),
            // The application track is remote evidence and needs no verdict; the microphone copy
            // is suppressed by a real one.
            echoVerdicts: ["m-echo": .echoSuppressed(duplicateOfUnitID: "a-0")]
        ))
        let ledger = self.dispositions(result)
        XCTAssertEqual(ledger[micUnit.id]?.disposition, .echoSuppressed)
        XCTAssertEqual(ledger[appUnit.id]?.disposition, .emitted)
        XCTAssertEqual(result.segments.map(\.text), ["remote words"])
        XCTAssertEqual(result.segments[0].sourceTrackID, app.id)
        // Ledger-only still means ledger: the suppressed mic copy stays in the sidecar.
        XCTAssertTrue(result.sidecar.units.contains { $0.id == micUnit.id })
        XCTAssertEqual(result.speakers.count, 1)
        XCTAssertEqual(result.speakers[0].trackKind, .applicationAudio)
    }

    func testInRoomMicrophoneBypassesEchoAdmission() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [chunk],
            captureMethod: .avCaptureSession
        )
        let plan = self.plan(mode: .inRoom, tracks: [mic])
        let manifest = try self.buildManifest(
            plan: plan,
            observations: [(mic.id, chunk, self.observed(chunk, duration: 10))]
        )
        let span = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest)
        ))
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .emitted)
        XCTAssertEqual(result.segments.count, 1)
    }

    func testEchoVerdictForUnknownUnitThrows() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-0": .notEcho, "ghost": .notEcho]
        ))) { error in
            XCTAssertEqual(error as? MeetingAssemblyError, .echoVerdictForUnknownUnit(unitID: "ghost"))
        }
    }

    // MARK: - Coverage

    func testExactReceiptTilingAndTruncationGap() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        let receipts = [
            MeetingSpanCoverageReceipt(
                id: "r-0", spanID: span.id, analysisStart: 0, analysisEnd: 4, status: .processed
            ),
            MeetingSpanCoverageReceipt(
                id: "r-1",
                spanID: span.id,
                analysisStart: 4,
                analysisEnd: 10,
                status: .providerTruncated
            ),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: receipts,
            echoVerdicts: ["u-0": .notEcho]
        ))
        XCTAssertFalse(result.isComplete)
        let gap = try XCTUnwrap(result.coverageGaps.first)
        XCTAssertEqual(gap.reason, .providerTruncated)
        XCTAssertEqual(gap.trackID, span.trackID)
        XCTAssertEqual(gap.start, 4, accuracy: 1e-3)
        XCTAssertEqual(gap.end, 10, accuracy: 1e-3)
        // Truncation is a coverage fact, not a text fact: the recognized unit is still emitted.
        XCTAssertEqual(self.dispositions(result)[unit.id]?.disposition, .emitted)
    }

    func testMissingReceiptFailsEvenWhenTextExists() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let unit = self.unit(id: "u-0", span: span, analysisStart: 1, analysisEnd: 2)
        // A span full of recognized text but no receipt: text never implies coverage.
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: [],
            echoVerdicts: ["u-0": .notEcho]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .missingCoverageReceipt(spanID: span.id)
            )
        }
    }

    func testDuplicateUnknownOutOfBoundsAndPartialReceiptsThrow() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let validReceipts = self.receipts(for: manifest)
        let baseEvidence = self.evidence(plan: plan, units: [])

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: validReceipts + [MeetingSpanCoverageReceipt(
                id: "receipt-0", spanID: span.id, analysisStart: 9, analysisEnd: 10, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(error as? MeetingAssemblyError, .duplicateCoverageReceiptID("receipt-0"))
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "r-x", spanID: "no-such-span", analysisStart: 0, analysisEnd: 1, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .unknownCoverageReceiptSpan(spanID: "no-such-span")
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "r-oob", spanID: span.id, analysisStart: 0, analysisEnd: 99, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .coverageReceiptOutOfBounds(receiptID: "r-oob")
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [
                MeetingSpanCoverageReceipt(
                    id: "r-0", spanID: span.id, analysisStart: 0, analysisEnd: 6, status: .processed
                ),
                MeetingSpanCoverageReceipt(
                    id: "r-1", spanID: span.id, analysisStart: 5, analysisEnd: 10, status: .processed
                ),
            ]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .overlappingCoverageReceipts(spanID: span.id)
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "r-partial", spanID: span.id, analysisStart: 0, analysisEnd: 5, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .missingCoverageReceipt(spanID: span.id)
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: baseEvidence,
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "r-flat", spanID: span.id, analysisStart: 5, analysisEnd: 5, status: .processed
            )]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError, .invalidCoverageReceiptInterval(receiptID: "r-flat")
            )
        }
    }

    func testFailedAndSkippedReceiptsSurfaceAsGapsAndSkippedChunks() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(sequence: 1, start: 105, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        let receipts = [
            MeetingSpanCoverageReceipt(
                id: "r-0", spanID: spans[0].id, analysisStart: 0, analysisEnd: 5, status: .failed
            ),
            MeetingSpanCoverageReceipt(
                id: "r-1", spanID: spans[1].id, analysisStart: 5, analysisEnd: 10, status: .skipped
            ),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: []),
            coverageReceipts: receipts
        ))
        XCTAssertFalse(result.isComplete)
        XCTAssertEqual(result.coverageGaps.map(\.reason), [.processingFailed, .skipped])
        XCTAssertEqual(
            result.skippedChunks,
            [MeetingAnalysisChunkIdentity(trackID: mic.id, chunk: second)]
        )
        XCTAssertTrue(result.segments.isEmpty)
    }

    func testTextCannotEmitFromFailedOrTruncatedReceiptRegion() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let failedUnit = self.unit(
            id: "failed-text", span: span, analysisStart: 1, analysisEnd: 2
        )
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [failedUnit]),
            coverageReceipts: [MeetingSpanCoverageReceipt(
                id: "failed-receipt",
                spanID: span.id,
                analysisStart: 0,
                analysisEnd: 10,
                status: .failed
            )],
            echoVerdicts: [failedUnit.id: .notEcho]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .textContradictsCoverage(
                    unitID: failedUnit.id,
                    receiptID: "failed-receipt",
                    status: .failed
                )
            )
        }

        let truncatedUnit = self.unit(
            id: "truncated-text", span: span, analysisStart: 5, analysisEnd: 6
        )
        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [truncatedUnit]),
            coverageReceipts: [
                MeetingSpanCoverageReceipt(
                    id: "processed-prefix",
                    spanID: span.id,
                    analysisStart: 0,
                    analysisEnd: 4,
                    status: .processed
                ),
                MeetingSpanCoverageReceipt(
                    id: "truncated-tail",
                    spanID: span.id,
                    analysisStart: 4,
                    analysisEnd: 10,
                    status: .providerTruncated
                ),
            ],
            echoVerdicts: [truncatedUnit.id: .notEcho]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .textContradictsCoverage(
                    unitID: truncatedUnit.id,
                    receiptID: "truncated-tail",
                    status: .providerTruncated
                )
            )
        }
    }

    func testManifestGapsSurfaceAsProductCoverageGaps() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [chunk],
            eras: [
                self.era(protection: .voiceProcessed, start: 100),
                self.era(protection: .unprotected, start: 105),
                self.era(protection: .softwareEchoCancelled, start: 108),
            ]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(
            plan: plan,
            observations: [(mic.id, chunk, self.observed(chunk, duration: 10))]
        )
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        let units = spans.enumerated().map { index, span in
            self.unit(id: "u-\(index)", span: span)
        }
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: Dictionary(uniqueKeysWithValues: units.map { ($0.id, MeetingUnitEchoVerdict.notEcho) })
        ))
        XCTAssertFalse(result.isComplete)
        let inadmissible = try XCTUnwrap(result.coverageGaps.first { $0.reason == .inadmissibleCaptureEra })
        XCTAssertEqual(inadmissible.start, 5, accuracy: 1e-3)
        XCTAssertEqual(inadmissible.end, 8, accuracy: 1e-3)
        // The unprotected era was never analyzed, so both admissible pieces' text is emitted.
        XCTAssertEqual(Set(result.segments.map(\.text)), Set(units.map(\.text)))
    }

    // MARK: - Conservation

    func testEveryInputUnitHasExactlyOneDispositionAndExcludedUnitsNeverAppear() throws {
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let plan = self.plan(mode: .onlineCall, tracks: [mic, app])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            (app.id, appChunk, self.observed(appChunk, duration: 10)),
        ])
        let micSpan = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let appSpan = try XCTUnwrap(manifest.track(app.id)?.spans.first)
        let activity = [
            MeetingBackendSpeakerActivity(
                token: MeetingBackendSpeakerToken(analysisEpochID: micSpan.analysisEpochID, label: "slot-0"),
                start: 0,
                end: 5
            ),
        ]

        let units = [
            self.unit(id: "emitted", span: micSpan, text: "kept", analysisStart: 1, analysisEnd: 2),
            self.unit(
                id: "ambiguous",
                span: micSpan,
                text: "fuzzy",
                analysisStart: 1.5,
                analysisEnd: 2.5,
                speaker: .ambiguous([
                    MeetingBackendSpeakerToken(analysisEpochID: micSpan.analysisEpochID, label: "slot-0"),
                    MeetingBackendSpeakerToken(analysisEpochID: micSpan.analysisEpochID, label: "slot-1"),
                ])
            ),
            self.unit(id: "quarantined", span: micSpan, text: "broken", analysisStart: 3, analysisEnd: 3),
            self.unit(id: "echo", span: micSpan, text: "copy", analysisStart: 2, analysisEnd: 3),
            self.unit(id: "inactive", span: micSpan, text: "idle", analysisStart: 7, analysisEnd: 8),
            self.unit(id: "remote", span: appSpan, text: "remote", analysisStart: 1, analysisEnd: 2),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: units, activity: activity),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [
                "emitted": .notEcho,
                "ambiguous": .notEcho,
                "echo": .echoSuppressed(duplicateOfUnitID: "remote"),
                "inactive": .notEcho,
            ]
        ))

        let ledger = self.dispositions(result)
        XCTAssertEqual(Set(ledger.keys), Set(units.map(\.id)))
        XCTAssertEqual(result.sidecar.dispositions.count, units.count)
        XCTAssertEqual(ledger["emitted"]?.disposition, .emitted)
        XCTAssertEqual(ledger["ambiguous"]?.disposition, .ambiguousUnassigned)
        XCTAssertEqual(ledger["quarantined"]?.disposition, .rejectedInvalidTiming)
        XCTAssertEqual(ledger["echo"]?.disposition, .echoSuppressed)
        XCTAssertEqual(ledger["inactive"]?.disposition, .outsideActivity)
        XCTAssertEqual(ledger["remote"]?.disposition, .emitted)
        XCTAssertNoThrow(try result.sidecar.validated())

        // Admitted text renders once each; excluded text never renders at all.
        XCTAssertEqual(
            result.segments.map(\.text).sorted(),
            ["fuzzy", "kept", "remote"]
        )
        XCTAssertEqual(
            Set(result.sidecar.units.map(\.id)),
            Set(units.map(\.id))
        )
    }

    func testExtraReferencedSpanIsQuarantinedAndCannotReportComplete() throws {
        let first = self.chunk(sequence: 0, start: 100, end: 105)
        let second = self.chunk(sequence: 1, start: 105, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [first, second],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, first, self.observed(first, duration: 5)),
            (mic.id, second, self.observed(second, duration: 5)),
        ])
        let spans = try XCTUnwrap(manifest.track(mic.id)?.spans)
        let unit = self.unit(
            id: "extra-span",
            span: spans[1],
            analysisStart: 5.2,
            analysisEnd: 5.8,
            spanIDs: spans.map(\.id)
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [unit]),
            coverageReceipts: self.receipts(for: manifest)
        ))
        XCTAssertEqual(
            self.dispositions(result)[unit.id]?.reasonCode,
            MeetingUnitQuarantineReason.spansDoNotCoverUnitInterval.rawValue
        )
        XCTAssertTrue(result.segments.isEmpty)
        XCTAssertFalse(result.isComplete)
    }

    func testEchoDuplicateTargetMustExistAndBeApplicationAudio() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let first = self.unit(id: "mic-0", span: span, analysisStart: 1, analysisEnd: 2)
        let second = self.unit(id: "mic-1", span: span, analysisStart: 2, analysisEnd: 3)
        let evidence = self.evidence(plan: plan, units: [first, second])

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: evidence,
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [
                first.id: .echoSuppressed(duplicateOfUnitID: "missing"),
                second.id: .notEcho,
            ]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .echoDuplicateTargetUnknown(unitID: first.id, duplicateID: "missing")
            )
        }

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: evidence,
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [
                first.id: .echoSuppressed(duplicateOfUnitID: second.id),
                second.id: .notEcho,
            ]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .echoDuplicateTargetNotApplicationAudio(unitID: first.id, duplicateID: second.id)
            )
        }
    }

    func testEchoDuplicateTargetMustRemainVisible() throws {
        let micChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let appChunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [micChunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let app = self.track(kind: .applicationAudio, chunks: [appChunk])
        let plan = self.plan(mode: .onlineCall, tracks: [mic, app])
        let manifest = try self.buildManifest(plan: plan, observations: [
            (mic.id, micChunk, self.observed(micChunk, duration: 10)),
            (app.id, appChunk, self.observed(appChunk, duration: 10)),
        ])
        let micSpan = try XCTUnwrap(manifest.track(mic.id)?.spans.first)
        let appSpan = try XCTUnwrap(manifest.track(app.id)?.spans.first)
        let micUnit = self.unit(id: "mic", span: micSpan, analysisStart: 1, analysisEnd: 2)
        let invalidApp = self.unit(
            id: "app-invalid",
            span: appSpan,
            analysisStart: 1,
            analysisEnd: 1
        )

        XCTAssertThrowsError(try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [micUnit, invalidApp]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: [
                micUnit.id: .echoSuppressed(duplicateOfUnitID: invalidApp.id),
            ]
        ))) { error in
            XCTAssertEqual(
                error as? MeetingAssemblyError,
                .echoDuplicateTargetNotVisible(unitID: micUnit.id, duplicateID: invalidApp.id)
            )
        }
    }

    func testEpochGenerationChangesProductSpeakerIdentityWithoutChangingOrdinal() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 110)
        let mic = self.track(
            kind: .microphone,
            chunks: [chunk],
            eras: [self.era(protection: .voiceProcessed, start: 100)]
        )
        let plan = self.plan(mode: .onlineCall, tracks: [mic])
        let observations = [(mic.id, chunk, self.observed(chunk, duration: 10))]
        let firstManifest = try self.buildManifest(plan: plan, observations: observations)
        let key = MeetingAnalysisEpochGenerationKey(trackID: mic.id, ordinal: 0)
        let secondManifest = try MeetingAnalysisManifestBuilder(
            plan: plan,
            observer: AssemblerFixtureObserver(results: [
                MeetingAnalysisChunkKey(trackID: mic.id, chunkID: chunk.id):
                    self.observed(chunk, duration: 10),
            ]),
            epochGenerations: [key: 1]
        ).build()
        let firstSpan = try XCTUnwrap(firstManifest.track(mic.id)?.spans.first)
        let secondSpan = try XCTUnwrap(secondManifest.track(mic.id)?.spans.first)
        XCTAssertEqual(firstSpan.analysisEpochID.ordinal, secondSpan.analysisEpochID.ordinal)
        XCTAssertNotEqual(firstSpan.analysisEpochID.generation, secondSpan.analysisEpochID.generation)

        func speakerID(
            manifest: MeetingAnalysisManifest,
            span: MeetingAnalysisSpan
        ) throws -> UUID {
            let unit = self.unit(id: "same-unit", span: span, analysisStart: 1, analysisEnd: 2)
            let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
                plan: plan,
                manifest: manifest,
                evidence: self.evidence(plan: plan, units: [unit]),
                coverageReceipts: self.receipts(for: manifest),
                echoVerdicts: [unit.id: .notEcho]
            ))
            return try XCTUnwrap(result.speakers.first?.id)
        }
        XCTAssertNotEqual(
            try speakerID(manifest: firstManifest, span: firstSpan),
            try speakerID(manifest: secondManifest, span: secondSpan)
        )
    }

    func testSidecarOrderingIsCanonicalAcrossBackendOrdering() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let a = self.unit(id: "a", span: span, analysisStart: 1, analysisEnd: 2)
        let z = self.unit(id: "z", span: span, analysisStart: 3, analysisEnd: 4)
        let receipts = [
            MeetingSpanCoverageReceipt(
                id: "z-receipt",
                spanID: span.id,
                analysisStart: 5,
                analysisEnd: 10,
                status: .processed
            ),
            MeetingSpanCoverageReceipt(
                id: "a-receipt",
                spanID: span.id,
                analysisStart: 0,
                analysisEnd: 5,
                status: .processed
            ),
        ]
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [z, a]),
            coverageReceipts: receipts,
            echoVerdicts: [a.id: .notEcho, z.id: .notEcho]
        ))
        XCTAssertEqual(result.sidecar.units.map(\.id), ["a", "z"])
        XCTAssertEqual(result.sidecar.dispositions.map(\.unitID), ["a", "z"])
        XCTAssertEqual(result.sidecar.coverageReceipts.map(\.id), ["a-receipt", "z-receipt"])
    }

    func testUnpositionedManifestGapCannotReportComplete() throws {
        let chunk = self.chunk(sequence: 0, start: 100, end: 100)
        let mic = self.track(kind: .microphone, chunks: [chunk], captureMethod: .avCaptureSession)
        let plan = self.plan(mode: .inRoom, tracks: [mic])
        let manifest = try self.buildManifest(plan: plan, observations: [])
        XCTAssertEqual(manifest.allGaps.count, 1)
        XCTAssertNil(manifest.allGaps[0].recordedInterval)

        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: []),
            coverageReceipts: []
        ))
        XCTAssertTrue(result.coverageGaps.isEmpty)
        XCTAssertFalse(result.isComplete)
    }

    // MARK: - Attribution state

    func testNormallyEmittedSegmentsCarryAssignedOrUnassignedAttributionState() throws {
        let (plan, manifest, span) = try self.onlineMicFixture()
        let assignedUnit = self.unit(id: "u-assigned", span: span, text: "clear", analysisStart: 1, analysisEnd: 2)
        let unassignedUnit = self.unit(
            id: "u-unassigned",
            span: span,
            text: "noEvidence",
            analysisStart: 3,
            analysisEnd: 4,
            speaker: .unassigned
        )
        let result = try MeetingTranscriptAssembler().assemble(MeetingAssemblyInput(
            plan: plan,
            manifest: manifest,
            evidence: self.evidence(plan: plan, units: [assignedUnit, unassignedUnit]),
            coverageReceipts: self.receipts(for: manifest),
            echoVerdicts: ["u-assigned": .notEcho, "u-unassigned": .notEcho],
            speakerAttributionPolicy: self.provisionalPolicy
        ))
        XCTAssertEqual(self.dispositions(result)["u-assigned"]?.disposition, .emitted)
        XCTAssertEqual(self.dispositions(result)["u-unassigned"]?.disposition, .emitted)

        let assignedSegment = try XCTUnwrap(result.segments.first { $0.text == "clear" })
        XCTAssertNotNil(assignedSegment.speakerID)
        XCTAssertEqual(assignedSegment.overlap, .none)
        XCTAssertEqual(assignedSegment.attributionState, .assigned)

        let unassignedSegment = try XCTUnwrap(result.segments.first { $0.text == "noEvidence" })
        XCTAssertNotNil(unassignedSegment.speakerID)
        XCTAssertEqual(unassignedSegment.speakerIdentityIsProvisional, true)
        XCTAssertEqual(unassignedSegment.overlap, .none)
        XCTAssertEqual(unassignedSegment.attributionState, .unassigned)
    }

    /// `attributionState` must stay optional: a non-optional defaulted property makes the
    /// synthesized decoder require the key, and the store silently drops sessions that fail to
    /// decode.
    func testSegmentWithoutAttributionStateKeyStillDecodes() throws {
        let legacySegmentJSON = """
        {
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "start": { "value": 0, "timescale": 1000 },
          "end": { "value": 1000, "timescale": 1000 },
          "sourceTrackID": "3F2504E0-4F89-11D3-9A0C-0305E82C3302",
          "text": "legacy segment",
          "revision": 0,
          "status": "final",
          "overlap": "none",
          "completeness": "complete"
        }
        """
        let segment = try JSONDecoder().decode(
            MeetingTranscriptSegment.self,
            from: Data(legacySegmentJSON.utf8)
        )
        XCTAssertNil(segment.attributionState)
    }
}
