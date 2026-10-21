import CoreMedia
import Foundation
import XCTest
@testable import PichiVoiceMobile

final class MobileSpeakerAdmissionTests: XCTestCase {
    private func profile(track: UUID, epoch: Int, slot: Int = 0, angle: Float = 0,
                         secondAngle: Float? = nil) -> MeetingSpeakerVoiceProfile {
        func vector(_ angle: Float) -> [Float] {
            [cos(angle), sin(angle)] + [Float](repeating: 0, count: 254)
        }
        return .init(token: .init(analysisEpochID: .init(trackID: track, ordinal: epoch), label: "slot-\(slot)"),
                     embeddings: [vector(angle), vector(secondAngle ?? angle)])
    }

    func testNativeSegmentIntervalsPreserveSpeakerTransitionsAndMonologuePresentation() throws {
        let track = UUID(), attempt = UUID()
        let epoch = MeetingAnalysisEpochID(trackID: track, ordinal: 0)
        let first = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        let second = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-1")
        let timings = [ASRSegmentTiming(text: "Здравствуйте, обсудим документ.", start: 0.2, end: 3),
                       .init(text: "Я уточню результаты.", start: 3.2, end: 5.5),
                       // Both real voice turns must meet the existing 5-second evidence
                       // policy; a 3-second secondary response is correctly kept unknown.
                       .init(text: "Хорошо, я вас слушаю.", start: 6, end: 11)]
        let result = ASRTranscriptionResult(text: timings.map(\.text).joined(separator: " "), segmentTimings: timings)
        let activity = [MeetingBackendSpeakerActivity(token: first, start: 0, end: 5.8),
                        .init(token: second, start: 5.8, end: 12)]
        let coarse = try MeetingParakeetNemotronBackend.pcmUnits(result: .init(text: result.text), words: [],
            epoch: epoch, duration: 12, activity: activity, identityTokens: [first, second])
        XCTAssertEqual(coarse.count, 1)
        guard case .ambiguous = coarse[0].speaker else { return XCTFail("Whole-window timing cannot choose between two voices") }
        let units = try MeetingParakeetNemotronBackend.pcmUnits(result: result, words: [],
            epoch: epoch, duration: 12, activity: activity, identityTokens: [first, second])
        XCTAssertEqual(units.map(\.precision), [.utterance, .utterance, .utterance])
        XCTAssertEqual(units.map(\.analysisStart), [0.2, 3.2, 6])
        XCTAssertEqual(units.map(\.analysisEnd), [3, 5.5, 11])
        XCTAssertEqual(units.map(\.speaker), [.assigned(first), .assigned(first), .assigned(second)])
        let batch = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: attempt,
            epoch: epoch, offset: 10, duration: 12, units: units)
        XCTAssertEqual(batch.speakers.count, 2)
        XCTAssertEqual(batch.segments.map { $0.start.seconds }, [10.2, 13.2, 16])
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic native segments",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.speakers = batch.speakers
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: batch.segments, in: session)
        XCTAssertEqual(paragraphs.count, 2, "Multiple native intervals from the same speaker remain one readable turn")
        let firstParagraph = try XCTUnwrap(paragraphs.first)
        let secondParagraph = try XCTUnwrap(paragraphs.dropFirst().first)
        XCTAssertEqual(firstParagraph.text, "Здравствуйте, обсудим документ. Я уточню результаты.")
        XCTAssertEqual(secondParagraph.text, "Хорошо, я вас слушаю.")
        XCTAssertEqual(paragraphs.flatMap(\.segments), batch.segments, "Presentation must retain canonical boundaries")
        let noIdentity = try MeetingParakeetNemotronBackend.pcmUnits(result: result, words: [], epoch: epoch,
            duration: 12, activity: activity, identityTokens: [])
        XCTAssertTrue(noIdentity.allSatisfy { $0.speaker == .unassigned }, "Timing alone cannot mint identity")
    }

    func testNativeSegmentThatCrossesTwoVoicesRemainsAmbiguous() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        let first = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-0")
        let second = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "slot-1")
        let units = try MeetingParakeetNemotronBackend.pcmUnits(result: .init(text: "Mixed native segment.",
            segmentTimings: [.init(text: "Mixed native segment.", start: 0.2, end: 9)]), words: [],
            epoch: epoch, duration: 12, activity: [.init(token: first, start: 0, end: 6),
                .init(token: second, start: 6, end: 12)], identityTokens: [first, second])
        XCTAssertEqual(units.count, 1)
        XCTAssertEqual(units[0].precision, .utterance)
        guard case .ambiguous = units[0].speaker else { return XCTFail("Never split a native utterance at fabricated word boundaries") }
    }

    func testInvalidNativeSegmentMetadataFallsBackWithoutDroppingUnalignedText() throws {
        let epoch = MeetingAnalysisEpochID(trackID: UUID(), ordinal: 0)
        for segments: [ASRSegmentTiming] in [
            [.init(text: "Keep", start: 0, end: 1)],
            [.init(text: "Keep every word.", start: 0, end: 13)],
            [.init(text: "Keep every", start: 0, end: 8), .init(text: "word.", start: 7, end: 9)]
        ] {
            let units = try MeetingParakeetNemotronBackend.pcmUnits(result: .init(text: "Keep every word.",
                segmentTimings: segments), words: [], epoch: epoch, duration: 12, activity: [], identityTokens: [])
            XCTAssertEqual(units.count, 1)
            XCTAssertEqual(units[0].text, "Keep every word.")
            XCTAssertEqual(units[0].analysisStart, 0)
            XCTAssertEqual(units[0].analysisEnd, 12)
            XCTAssertEqual(units[0].speaker, .unassigned)
        }
    }

    func testInconsistentExcerptsCannotMintANamedParticipant() throws {
        let track = UUID(), attempt = UUID()
        let invalid = profile(track: track, epoch: 0, secondAngle: .pi / 2)
        let epoch = invalid.token.analysisEpochID
        let admission = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: [], currentProfiles: [invalid], epoch: epoch)
        XCTAssertEqual(admission.rejectedCurrentProfileCount, 1)
        XCTAssertEqual(admission.selfInconsistentCurrentProfileCount, 1)
        XCTAssertTrue(admission.retainedProfiles.isEmpty)
        XCTAssertTrue(admission.identityTokens.isEmpty)
        XCTAssertTrue(admission.links.isEmpty)
        let activity = [MeetingBackendSpeakerActivity(token: invalid.token, start: 0, end: 12)]
        let words = [ASRWordTiming(text: "Синтетическая", start: 0.2, end: 0.7),
                     ASRWordTiming(text: "фраза.", start: 0.8, end: 1.4)]
        func batch(tokens: Set<MeetingBackendSpeakerToken>) throws -> MeetingPCMTranscriptBatch {
            let units = try MeetingParakeetNemotronBackend.pcmUnits(result: .init(text: "Синтетическая фраза."),
                words: words, epoch: epoch, duration: 12, activity: activity, identityTokens: tokens)
            return try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: attempt, epoch: epoch,
                offset: 0, duration: 12, units: units)
        }
        // Reproduces the old mismatch: the matcher rejects this profile, while accepting its
        // mere existence as product evidence used to produce an extra named participant.
        let old = try batch(tokens: [invalid.token])
        XCTAssertEqual(old.speakers.count, 1)
        let corrected = try batch(tokens: admission.identityTokens)
        XCTAssertTrue(corrected.speakers.isEmpty)
        XCTAssertTrue(corrected.segments.allSatisfy { $0.speakerID == nil && $0.attributionState == .unassigned })
        XCTAssertEqual(corrected.segments.map(\.id), old.segments.map(\.id))
        XCTAssertEqual(corrected.segments.map(\.text), old.segments.map(\.text))
        XCTAssertEqual(corrected.segments.map(\.start), old.segments.map(\.start))
        XCTAssertEqual(corrected.segments.map(\.end), old.segments.map(\.end))
    }

    func testMalformedAndDuplicateProfilesStayUnassigned() {
        let track = UUID()
        let p = profile(track: track, epoch: 0)
        let invalid = [MeetingSpeakerVoiceProfile(token: p.token, embeddings: [[Float.nan], [0]]),
                       MeetingSpeakerVoiceProfile(token: p.token, embeddings: [[Float](repeating: 0, count: 256), [Float](repeating: 0, count: 256)])]
        for profiles in [invalid, [p, p]] {
            let a = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: [], currentProfiles: profiles, epoch: p.token.analysisEpochID)
            XCTAssertEqual(a.rejectedCurrentProfileCount, 2)
            XCTAssertTrue(a.identityTokens.isEmpty)
            XCTAssertTrue(a.retainedProfiles.isEmpty)
        }
    }

    func testReturningVoiceLinksAcrossSlotSwapWithoutChangingThresholds() {
        let track = UUID()
        let prior = profile(track: track, epoch: 0, slot: 0)
        let current = profile(track: track, epoch: 1, slot: 1, angle: 0.05)
        let a = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: [prior], currentProfiles: [current], epoch: current.token.analysisEpochID)
        XCTAssertEqual(a.links, [.init(token: current.token, canonicalToken: prior.token)])
        XCTAssertEqual(a.identityTokens, [current.token])
        XCTAssertEqual(a.rejectedCurrentProfileCount, 0)
        XCTAssertTrue(a.diagnosticFields.contains("linkedProfiles=1"))
        XCTAssertTrue(a.diagnosticFields.contains("newIdentities=0"))
        XCTAssertTrue(a.diagnosticFields.contains("nearestDistanceBins=1,0,0,0"))
        XCTAssertEqual(MeetingSpeakerVoiceMatcher.maximumDistance, 0.25)
        XCTAssertEqual(MeetingSpeakerVoiceMatcher.ambiguityMargin, 0.10)
    }

    func testDifferentVoicesRemainSeparateAndDiagnosticDistanceIsCoarse() {
        let track = UUID()
        let prior = profile(track: track, epoch: 0)
        let current = profile(track: track, epoch: 1, angle: .pi / 2)
        let a = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: [prior], currentProfiles: [current], epoch: current.token.analysisEpochID)
        XCTAssertTrue(a.links.isEmpty)
        XCTAssertEqual(a.identityTokens, [current.token])
        XCTAssertTrue(a.diagnosticFields.contains("referenceComparisons=1"))
        XCTAssertTrue(a.diagnosticFields.contains("thresholdFailedCandidates=1"))
        XCTAssertTrue(a.diagnosticFields.contains("nearestDistanceBins=0,0,0,1"))
    }

    func testAmbiguousReturningVoiceAndSameEpochCollisionDoNotMerge() {
        let track = UUID()
        let first = profile(track: track, epoch: 0, slot: 0)
        let other = profile(track: track, epoch: 0, slot: 1, angle: 0.4)
        let between = profile(track: track, epoch: 1, angle: 0.2)
        let ambiguous = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: [first, other], currentProfiles: [between], epoch: between.token.analysisEpochID)
        XCTAssertTrue(ambiguous.links.isEmpty)
        XCTAssertTrue(ambiguous.diagnosticFields.contains("ambiguityRejectedObservations=1"))
        let a = profile(track: track, epoch: 1, slot: 0, angle: 0.01)
        let b = profile(track: track, epoch: 1, slot: 1, angle: 0.02)
        let collision = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: [first], currentProfiles: [a, b], epoch: a.token.analysisEpochID)
        XCTAssertTrue(collision.links.isEmpty)
        XCTAssertEqual(collision.identityTokens, [a.token, b.token])
        XCTAssertTrue(collision.diagnosticFields.contains("sameEpochCollisions=2"))
    }

    func testCapacityRejectsANewIdentityButAllowsLinkToRetainedEvidence() {
        let track = UUID()
        let prior = (0..<MeetingSpeakerVoiceSamples.maximumProfiles).map { profile(track: track, epoch: $0) }
        let returned = profile(track: track, epoch: 128, slot: 0, angle: 0.01)
        let different = profile(track: track, epoch: 128, slot: 1, angle: .pi / 2)
        let a = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: prior, currentProfiles: [returned, different], epoch: returned.token.analysisEpochID)
        XCTAssertEqual(a.retainedProfiles.count, MeetingSpeakerVoiceSamples.maximumProfiles)
        XCTAssertEqual(a.links, [.init(token: returned.token, canonicalToken: prior[0].token)])
        XCTAssertEqual(a.identityTokens, [returned.token])
        XCTAssertEqual(a.capacityExcludedCurrentProfileCount, 1)
    }

    func testDifferentTracksNeverLinkAndDiagnosticsExcludePrivateEvidence() {
        let prior = profile(track: UUID(), epoch: 0)
        let current = profile(track: UUID(), epoch: 1)
        let a = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: [prior], currentProfiles: [current], epoch: current.token.analysisEpochID)
        XCTAssertTrue(a.links.isEmpty)
        XCTAssertFalse(a.diagnosticFields.contains(prior.token.analysisEpochID.trackID.uuidString))
        XCTAssertFalse(a.diagnosticFields.contains(current.token.analysisEpochID.trackID.uuidString))
        XCTAssertFalse(a.diagnosticFields.contains("slot-"))
        XCTAssertFalse(a.diagnosticFields.contains("embedding"))
        XCTAssertFalse(a.diagnosticFields.contains("0.25"))
        XCTAssertTrue(a.diagnosticFields.contains("referenceComparisons=0"))
    }

    func testMissingVoiceEvidenceStaysUnknownWithoutRetainingPCM() {
        let a = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: [], currentProfiles: [], epoch: .init(trackID: UUID(), ordinal: 0))
        XCTAssertTrue(a.retainedProfiles.isEmpty)
        XCTAssertTrue(a.identityTokens.isEmpty)
        XCTAssertTrue(a.links.isEmpty)
        XCTAssertEqual(a.currentProfileCount, 0)
        XCTAssertEqual(a.rejectedCurrentProfileCount, 0)
        XCTAssertTrue(a.diagnosticFields.contains("newIdentities=0"))
    }

    private func ownerSnapshot() -> MeetingOwnerVoiceProfileSnapshot {
        .init(metadata: .init(generation: UUID(), enrolledAt: Date(timeIntervalSince1970: 1)),
              encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint,
              embeddings: [[1, 0] + [Float](repeating: 0, count: 254),
                           [1, 0] + [Float](repeating: 0, count: 254)])
    }

    /// Real matching, canonical assembly and attempt-local state; only the encoder's input
    /// embeddings are synthetic. No runtime, capture or model behavior is reimplemented.
    private func ownerBatch(current: [MeetingSpeakerVoiceProfile], attempt: UUID,
                            state: MeetingPCMIdentityState) throws -> MeetingPCMTranscriptBatch {
        let epoch = try XCTUnwrap(current.first).token.analysisEpochID
        let prior = try state.begin(attemptID: attempt)
        defer { state.end() }
        let admission = MeetingSpeakerVoiceMatcher.pcmAdmission(priorProfiles: prior.profiles,
            currentProfiles: current, epoch: epoch)
        let allLinks = MeetingSpeakerVoiceMatcher.links(profiles: admission.retainedProfiles,
            allowedTokens: Set(admission.retainedProfiles.map(\.token)))
        let owner = MeetingOwnerVoiceVerifier.confirmedTokens(owner: self.ownerSnapshot(),
            profiles: admission.retainedProfiles, identityLinks: allLinks)
        let units = current.enumerated().map { index, profile in
            MeetingFinalTextUnit(id: "owner-reconciliation:\(epoch):\(index)", trackID: epoch.trackID,
                analysisEpochID: epoch, precision: .utterance, text: "Synthetic voice phrase",
                analysisStart: Double(index * 6), analysisEnd: Double(index * 6 + 6),
                speaker: admission.identityTokens.contains(profile.token) ? .assigned(profile.token) : .unassigned,
                analysisSpanIDs: [])
        }
        let batch = try MeetingTranscriptAssembler().assemblePCMWindow(attemptID: attempt,
            epoch: epoch, offset: Double(epoch.ordinal * 6), duration: Double(current.count * 6),
            units: units, identityLinks: admission.links, priorSpeakers: prior.speakers,
            confirmedLocalUserTokens: owner)
        state.commit(profiles: admission.retainedProfiles, batch: batch)
        return batch
    }

    func testLaterAmbiguousVoiceRevokesEarlierOwnerAbsentFromCurrentWindow() throws {
        let state = MeetingPCMIdentityState(), track = UUID(), attempt = UUID()
        let first = try self.ownerBatch(current: [profile(track: track, epoch: 0, angle: 0.4)],
            attempt: attempt, state: state)
        let owner = try XCTUnwrap(first.speakers.first)
        XCTAssertTrue(owner.isLocalUser)
        XCTAssertEqual(owner.displayName, "Speaker 1", "The owner marker must never replace the stable raw alias")
        let ambiguous = try self.ownerBatch(current: [profile(track: track, epoch: 1, angle: -0.4)],
            attempt: attempt, state: state)
        XCTAssertEqual(ambiguous.speakers.count, 2)
        XCTAssertTrue(ambiguous.speakers.allSatisfy { !$0.isLocalUser })
        XCTAssertEqual(ambiguous.speakers.first(where: { $0.id == owner.id })?.displayName, "Speaker 1")
        let next = try state.begin(attemptID: attempt)
        state.end()
        XCTAssertTrue(next.speakers.allSatisfy { !$0.isLocalUser }, "Revocation must survive the runtime's next begin")
        XCTAssertEqual(Set(next.speakers.map(\.displayName)), ["Speaker 1", "Speaker 2"])
    }

    func testLaterEvidencePromotesExistingOwnerAndPreservesStableIdentity() throws {
        let state = MeetingPCMIdentityState(), track = UUID(), attempt = UUID()
        let initial = try self.ownerBatch(current: [profile(track: track, epoch: 0),
            profile(track: track, epoch: 0, slot: 1, angle: 0.3)], attempt: attempt, state: state)
        XCTAssertTrue(initial.speakers.allSatisfy { !$0.isLocalUser })
        let firstID = try XCTUnwrap(initial.segments.first?.speakerID)
        let resolved = try self.ownerBatch(current: [profile(track: track, epoch: 1, angle: 0.8)],
            attempt: attempt, state: state)
        XCTAssertEqual(resolved.speakers.filter(\.isLocalUser).map(\.id), [firstID],
            "Global owner evidence can promote a prior speaker absent from this window")
        let returned = try self.ownerBatch(current: [profile(track: track, epoch: 2)],
            attempt: attempt, state: state)
        XCTAssertEqual(returned.segments.first?.speakerID, firstID)
        let persistedState = try state.begin(attemptID: attempt)
        state.end()
        XCTAssertEqual(persistedState.speakers.filter(\.isLocalUser).map(\.id), [firstID])
        XCTAssertEqual(persistedState.speakers.first(where: { $0.id == firstID })?.displayName, "Speaker 1")
        let newAttempt = try state.begin(attemptID: UUID())
        state.end()
        XCTAssertTrue(newAttempt.speakers.isEmpty, "A new attempt cannot inherit another attempt's identity evidence")
    }

    @MainActor
    func testDurablePCMCheckpointsPromoteAndRevokeOwnerWithoutReplacingManualAliases() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("OwnerCheckpoint-\(UUID())")
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "OwnerCheckpoint.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .parakeetTDTv2
        settings.meetingTranscriptionBackendID = .productionDefault
        let store = MeetingSessionStore(rootDirectory: root)
        let processing = OwnerCheckpointProcessing()
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic-mic",
            sourceDisplayName: "Synthetic microphone", format: nil,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [])
        let coordinator = MeetingSessionCoordinator(store: store, capture: OwnerCheckpointCapture(track: track),
            processing: processing, audioArbiter: OwnerCheckpointArbiter(), settings: settings)
        addTeardownBlock { await coordinator.shutdownForTermination() }
        var configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic owner checkpoint",
            microphone: .init(captureDeviceID: "synthetic-mic", displayName: "Synthetic microphone"))
        configuration.languageCode = "en"
        configuration.audioStorageMode = .memoryOnly
        configuration.transcriptionBackendID = MeetingBackendID.productionDefault.rawValue
        let session = try await coordinator.startRecording(configuration: configuration)
        let state = MeetingPCMIdentityState(), attempt = UUID()
        var initial = try self.ownerBatch(current: [profile(track: track.id, epoch: 0),
            profile(track: track.id, epoch: 0, slot: 1, angle: 0.3)], attempt: attempt, state: state)
        let firstID = try XCTUnwrap(initial.segments.first?.speakerID)
        let firstIndex = try XCTUnwrap(initial.speakers.firstIndex(where: { $0.id == firstID }))
        initial.speakers[firstIndex].displayName = "Synthetic custom alias"
        initial.speakers[firstIndex].generatedParticipantNumber = nil
        try await processing.checkpoint(initial)
        let promoted = try self.ownerBatch(current: [profile(track: track.id, epoch: 1, angle: 0.8)],
            attempt: attempt, state: state)
        try await processing.checkpoint(promoted)
        let promotedStored = try await store.load(id: session.id)
        let promotedDisk = try XCTUnwrap(promotedStored)
        XCTAssertEqual(promotedDisk.speakers.filter(\.isLocalUser).map(\.id), [firstID])
        XCTAssertEqual(promotedDisk.speakers.first(where: { $0.id == firstID })?.displayName, "Synthetic custom alias")
        // A newly admitted independent near-owner voice makes the full evidence ambiguous.
        let revoked = try self.ownerBatch(current: [profile(track: track.id, epoch: 2, angle: 0.1),
            profile(track: track.id, epoch: 2, slot: 1, angle: -0.1)],
            attempt: attempt, state: state)
        XCTAssertTrue(revoked.speakers.allSatisfy { !$0.isLocalUser })
        try await processing.checkpoint(revoked)
        let revokedStored = try await store.load(id: session.id)
        let revokedDisk = try XCTUnwrap(revokedStored)
        XCTAssertTrue(revokedDisk.speakers.allSatisfy { !$0.isLocalUser })
        XCTAssertEqual(revokedDisk.speakers.first(where: { $0.id == firstID })?.displayName, "Synthetic custom alias")
        XCTAssertEqual(revokedDisk.transcriptSegments.map(\.id), (initial.segments + promoted.segments + revoked.segments).map(\.id))
        XCTAssertEqual(revokedDisk.transcriptSegments.map(\.text), (initial.segments + promoted.segments + revoked.segments).map(\.text))
        XCTAssertEqual(coordinator.activeSession?.speakers, revokedDisk.speakers)
        await coordinator.shutdownForTermination()
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains { ["caf", "wav", "m4a"].contains(URL(fileURLWithPath: $0).pathExtension) })
    }

}


/// Explicit synthetic checkpoint processor. The coordinator, session store and speaker
/// reconciliation run unchanged; this fixture never owns microphone or inference resources.
@MainActor
private final class OwnerCheckpointProcessing: MeetingProcessingControlling {
    private var operation: (@MainActor (MeetingPCMTranscriptBatch) async throws -> Void)?
    func validateMemoryAudioInput(configuration: MeetingCaptureConfiguration, backendID: MeetingBackendID) throws -> MeetingBackendDescriptor {
        try XCTUnwrap(MeetingTranscriptionBackendRegistry.makeDefault().descriptor(for: backendID))
    }
    func prepareMemoryAudio(session: MeetingSession, sessionDirectory: URL,
        checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void) async throws {
        self.operation = checkpoint
    }
    func checkpoint(_ batch: MeetingPCMTranscriptBatch) async throws { try await XCTUnwrap(self.operation)(batch) }
    func cancelMemoryAudio(sessionID: MeetingSessionID) async { self.operation = nil }
    func process(session: MeetingSession, sessionDirectory: URL,
        progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingProcessingResult {
        throw CancellationError()
    }
}

private struct OwnerCheckpointCapture: MeetingCaptureControlling {
    let track: MeetingAudioTrack
    func preflightPermissions() async throws {}
    func start(session: MeetingSession, configuration: MeetingCaptureConfiguration, sessionDirectory: URL,
        eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
        liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) async throws -> MeetingCaptureStartResult {
        .init(tracks: [self.track], firstPresentationTime: nil)
    }
    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult { .init(tracks: [self.track], stoppedAt: Date()) }
    func shutdownForTermination() async {}
}

@MainActor
private final class OwnerCheckpointArbiter: MeetingAudioActivityArbitrating {
    func acquireMeetingCapture() async throws -> MeetingAudioActivityLease { .init(id: UUID()) }
    func release(_ lease: MeetingAudioActivityLease) async {}
}
