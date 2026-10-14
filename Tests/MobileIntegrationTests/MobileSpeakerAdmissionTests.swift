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
            let units = MeetingParakeetNemotronBackend.pcmUnits(result: .init(text: "Синтетическая фраза."),
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
}
