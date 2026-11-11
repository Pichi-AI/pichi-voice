import XCTest
import Foundation
import CryptoKit
#if canImport(Review34DemoAdmissionSupport)
@testable import Review34DemoAdmissionSupport
#endif

final class Review34DemoAdmissionTests: XCTestCase {
    private let baselineID = "E0000000-0000-4000-8000-000000000001"
    func testOwnedRecordingRequiresExactlyOneNewUUIDAndPreservedBaseline() {
        let added = "E0000000-0000-4000-8000-000000000002"
        XCTAssertEqual(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [baselineID], historyIDs: [baselineID, added]), added)
        XCTAssertNil(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [baselineID], historyIDs: [added]))
        XCTAssertNil(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [baselineID], historyIDs: [baselineID]))
        XCTAssertNil(Review34DemoAdmission.newOwnedSessionID(baselineIDs: [baselineID], historyIDs: [baselineID, added, added]))
    }
    func testVirtualizedExistingHistoryAcceptsOnlyUniqueKnownVisibleRows() {
        let other = "E0000000-0000-4000-8000-000000000003"
        XCTAssertTrue(Review34DemoAdmission.knownVisibleHistory(baselineIDs: [baselineID, other], visibleIDs: [baselineID]))
        XCTAssertTrue(Review34DemoAdmission.knownVisibleHistory(baselineIDs: [], visibleIDs: []))
        XCTAssertFalse(Review34DemoAdmission.knownVisibleHistory(baselineIDs: [baselineID], visibleIDs: []))
        XCTAssertFalse(Review34DemoAdmission.knownVisibleHistory(baselineIDs: [baselineID], visibleIDs: [other]))
        XCTAssertFalse(Review34DemoAdmission.knownVisibleHistory(baselineIDs: [baselineID], visibleIDs: [baselineID, baselineID]))
        XCTAssertFalse(Review34DemoAdmission.knownVisibleHistory(baselineIDs: [baselineID, baselineID], visibleIDs: [baselineID]))
        XCTAssertFalse(Review34DemoAdmission.knownVisibleHistory(baselineIDs: [baselineID], visibleIDs: ["bad"]))
    }
    func testVirtualizedOwnedRecordingRequiresOneNewUUIDAgainstFullBackup() {
        let added = "E0000000-0000-4000-8000-000000000002"
        let hidden = "E0000000-0000-4000-8000-000000000003"
        let foreign = "E0000000-0000-4000-8000-000000000004"
        XCTAssertEqual(Review34DemoAdmission.newOwnedVisibleSessionID(baselineIDs: [baselineID, hidden], visibleIDs: [baselineID, added]), added)
        XCTAssertEqual(Review34DemoAdmission.newOwnedVisibleSessionID(baselineIDs: [baselineID], visibleIDs: [added]), added)
        XCTAssertNil(Review34DemoAdmission.newOwnedVisibleSessionID(baselineIDs: [baselineID], visibleIDs: [baselineID]))
        XCTAssertNil(Review34DemoAdmission.newOwnedVisibleSessionID(baselineIDs: [baselineID], visibleIDs: [added, added]))
        XCTAssertNil(Review34DemoAdmission.newOwnedVisibleSessionID(baselineIDs: [baselineID], visibleIDs: [added, foreign]))
        XCTAssertNil(Review34DemoAdmission.newOwnedVisibleSessionID(baselineIDs: [baselineID, baselineID], visibleIDs: [added]))
        XCTAssertNil(Review34DemoAdmission.newOwnedVisibleSessionID(baselineIDs: [baselineID], visibleIDs: ["bad"]))
    }
    func testPlaybackCannotBindBaselineOrForeignParagraphControls() throws {
        let added = "E0000000-0000-4000-8000-000000000002"
        XCTAssertNil(Review34DemoAdmission.PlaybackOwner(sessionID: baselineID, baselineIDs: [baselineID], paragraphID: "transcript.paragraph.a", audioID: "transcript.audio.a"))
        let owner = try XCTUnwrap(Review34DemoAdmission.PlaybackOwner(sessionID: added, baselineIDs: [baselineID], paragraphID: "transcript.paragraph.a", audioID: "transcript.audio.a"))
        XCTAssertTrue(owner.matches(openedSessionID: added, paragraphID: "transcript.paragraph.a", audioID: "transcript.audio.a", paragraphCount: 1, audioCount: 1))
        XCTAssertFalse(owner.matches(openedSessionID: baselineID, paragraphID: "transcript.paragraph.a", audioID: "transcript.audio.a", paragraphCount: 1, audioCount: 1))
        XCTAssertFalse(owner.matches(openedSessionID: added, paragraphID: "transcript.paragraph.other", audioID: "transcript.audio.a", paragraphCount: 1, audioCount: 1))
    }
    private func proof(revision: String = Review34DemoAdmission.coreRevision, build: String = "35", idiom: String = "phone",
                       latest: Bool = true, backup: Bool = true, ids: [String]? = nil,
                       purpose: Review34DemoAdmission.CoreVideoPurpose = .betaObservedOS, schemaVersion: Int = 2,
                       osVersion: String = "synthetic-latest") throws -> Data {
        try JSONEncoder().encode(Review34DemoAdmission.CoreVideoProof(schemaVersion: schemaVersion, purpose: purpose, revision: revision, build: build,
            deviceID: "synthetic-device", idiom: idiom, osVersion: osVersion, latestOSVerified: latest,
            backupVerified: backup, backupSHA256: String(repeating: "a", count: 64),
            appExecutableSHA256: String(repeating: "b", count: 64), baselineIDs: ids ?? [baselineID]))
    }
    private func admitted(_ data: Data, sha: String? = nil, idiom: String = "phone", os: String = "synthetic-latest",
                          revision: String = Review34DemoAdmission.coreRevision,
                          ids: [String]? = nil, backup: String = String(repeating: "a", count: 64)) -> Bool {
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        return Review34DemoAdmission.coreVideoProof(data, expectedSHA: sha ?? digest,
            revision: revision, deviceID: "synthetic-device", idiom: idiom,
            osVersion: os, baselineIDs: ids ?? [baselineID], expectedBackupSHA: backup)
    }
    func testAtomicReleaseBindingsRejectCrossMixAndUnknown() throws {
        let review = Review34DemoAdmission.reviewRevision
        let beta = Review34DemoAdmission.coreRevision
        XCTAssertTrue(admitted(try proof(revision: review, build: "34", purpose: .appleReviewLatestStable), revision: review))
        XCTAssertTrue(admitted(try proof(revision: beta, build: "35"), revision: beta))
        XCTAssertFalse(admitted(try proof(revision: review, build: "35"), revision: review))
        XCTAssertFalse(admitted(try proof(revision: beta, build: "34"), revision: beta))
        XCTAssertFalse(admitted(try proof(revision: "unknown", build: "34"), revision: "unknown"))
        XCTAssertFalse(admitted(try proof(revision: review, build: "34", purpose: .appleReviewLatestStable), revision: beta))
    }
    func testSchema2PurposesKeepLatestReviewSeparateFromObservedBetaOS() throws {
        let review = Review34DemoAdmission.reviewRevision
        XCTAssertTrue(admitted(try proof(revision: review, build: "34", purpose: .appleReviewLatestStable), revision: review))
        XCTAssertFalse(admitted(try proof(revision: review, build: "34", latest: false, purpose: .appleReviewLatestStable), revision: review))
        XCTAssertTrue(admitted(try proof(idiom: "pad", latest: false, osVersion: "17.7.11"), idiom: "pad", os: "17.7.11"))
        XCTAssertTrue(admitted(try proof(idiom: "pad", latest: true, osVersion: "17.7.11"), idiom: "pad", os: "17.7.11"))
        XCTAssertFalse(admitted(try proof(purpose: .appleReviewLatestStable)))
        XCTAssertFalse(admitted(try proof(revision: review, build: "34", purpose: .betaObservedOS), revision: review))
    }
    func testSchema1UnknownOrMissingPurposeCannotFallback() throws {
        XCTAssertFalse(admitted(try proof(schemaVersion: 1)))
        let original = try proof()
        var unknown = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        unknown["purpose"] = "unknownPurpose"
        XCTAssertFalse(admitted(try JSONSerialization.data(withJSONObject: unknown)))
        unknown.removeValue(forKey: "purpose")
        XCTAssertFalse(admitted(try JSONSerialization.data(withJSONObject: unknown)))
        unknown["purpose"] = "betaObservedOS"; unknown.removeValue(forKey: "schemaVersion")
        XCTAssertFalse(admitted(try JSONSerialization.data(withJSONObject: unknown)))
    }
    func testSupplementalReviewBetaCannotClaimLatestStableOrUseBeta35Binding() throws {
        let review = Review34DemoAdmission.reviewRevision
        let beta = Review34DemoAdmission.coreRevision
        XCTAssertTrue(admitted(try proof(revision: review, build: "34", latest: false,
            purpose: .appleReviewObservedBeta, osVersion: "27.3"), os: "27.3", revision: review))
        XCTAssertFalse(admitted(try proof(revision: review, build: "34", latest: true,
            purpose: .appleReviewObservedBeta), revision: review))
        XCTAssertFalse(admitted(try proof(revision: beta, build: "35", latest: false,
            purpose: .appleReviewObservedBeta), revision: beta))
        XCTAssertFalse(admitted(try proof(revision: review, build: "35", latest: false,
            purpose: .appleReviewObservedBeta), revision: review))
        XCTAssertFalse(admitted(try proof(revision: review, build: "34", latest: false,
            purpose: .appleReviewObservedBeta, osVersion: "27.3"), os: "27.2.1", revision: review))
    }
    func testCoreVideoAcceptsPinnedPhoneAndPadProof() throws {
        XCTAssertTrue(admitted(try proof()))
        XCTAssertTrue(admitted(try proof(idiom: "pad"), idiom: "pad"))
    }
    func testCoreVideoRejectsWrongBuildSourceOSBackupAndChangedHistory() throws {
        XCTAssertFalse(admitted(try proof(build: "34")))
        XCTAssertFalse(admitted(try proof(revision: "older")))
        XCTAssertFalse(admitted(try proof(revision: Review34DemoAdmission.reviewRevision, build: "34", latest: false,
            purpose: .appleReviewLatestStable), revision: Review34DemoAdmission.reviewRevision))
        XCTAssertFalse(admitted(try proof(backup: false)))
        XCTAssertFalse(admitted(try proof(), os: "other"))
        XCTAssertFalse(admitted(try proof(), backup: String(repeating: "c", count: 64)))
        XCTAssertFalse(admitted(try proof(), ids: []))
        XCTAssertFalse(admitted(try proof(ids: [baselineID, baselineID])))
    }
    func testCoreVideoRejectsTamperedOrMissingAttestation() throws {
        XCTAssertFalse(admitted(try proof(), sha: String(repeating: "0", count: 64)))
        XCTAssertFalse(admitted(Data("{}".utf8)))
        XCTAssertFalse(admitted(try proof(), idiom: "unsupported"))
    }
    func testAllRecordingProfilesRequireActualAutomaticDeliveryOff() {
        for retained in [false, true] {
            XCTAssertTrue(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: "0", noExistingPlayer: true, requireRetainedAudio: retained))
            XCTAssertFalse(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: "1", noExistingPlayer: true, requireRetainedAudio: retained))
            XCTAssertFalse(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: nil, noExistingPlayer: true, requireRetainedAudio: retained))
        }
    }
    private func guest(conflict: Bool = false, emailCount: Int = 1, secureCount: Int = 1,
                       destination: String? = "app.pichi.ai", ready: Bool = true, noPrompts: Bool = true) -> Bool {
        Review34DemoAdmission.GuestEvidence(emailCount: emailCount, secureFieldCount: secureCount, signInCount: 1,
            destination: destination, fieldsEnabled: ready, signInVisible: ready,
            conflictingAccountState: conflict, foregroundWithoutPrompts: noPrompts).verifiedSignedOut
    }
    func testPositiveGuestCanHaveNoCloudToggleButUnknownCannot() {
        XCTAssertTrue(guest())
        XCTAssertTrue(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: nil,
            noExistingPlayer: true, requireRetainedAudio: true, automaticDeliveryPresent: false, verifiedSignedOut: guest()))
        XCTAssertFalse(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: nil,
            noExistingPlayer: true, requireRetainedAudio: true, automaticDeliveryPresent: false, verifiedSignedOut: false))
        XCTAssertFalse(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: nil,
            noExistingPlayer: true, requireRetainedAudio: true, automaticDeliveryPresent: true, verifiedSignedOut: guest()))
        XCTAssertFalse(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: "1",
            noExistingPlayer: true, requireRetainedAudio: true, automaticDeliveryPresent: true, verifiedSignedOut: guest()))
    }
    func testLoadingHiddenDuplicateOrForeignGuestEvidenceIsRejected() {
        XCTAssertFalse(guest(conflict: true))
        XCTAssertFalse(guest(emailCount: 0))
        XCTAssertFalse(guest(secureCount: 2))
        XCTAssertFalse(guest(destination: nil))
        XCTAssertFalse(guest(destination: "other.example"))
        XCTAssertFalse(guest(ready: false))
        XCTAssertFalse(guest(noPrompts: false))
    }
    func testCancelledEligibilityNeverAdmitsOwnedMutation() {
        XCTAssertFalse(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: "0",
            noExistingPlayer: true, requireRetainedAudio: true, cancelled: true))
        XCTAssertFalse(Review34DemoAdmission.recordingPoliciesReady(idle: true, saveAudio: "1", automaticDelivery: nil,
            noExistingPlayer: true, requireRetainedAudio: true, automaticDeliveryPresent: false,
            verifiedSignedOut: guest(), cancelled: true))
    }
    func testCoreVideoPolicyGatesNeverChangeSettingsOrAdmitUnknownValues() {
        XCTAssertTrue(Review34DemoAdmission.coreReady(idle: true, saveAudio: "1", automaticDelivery: "0", noExistingPlayer: true))
        XCTAssertFalse(Review34DemoAdmission.coreReady(idle: false, saveAudio: "1", automaticDelivery: "0", noExistingPlayer: true))
        XCTAssertFalse(Review34DemoAdmission.coreReady(idle: true, saveAudio: nil, automaticDelivery: "0", noExistingPlayer: true))
        XCTAssertFalse(Review34DemoAdmission.coreReady(idle: true, saveAudio: "0", automaticDelivery: "0", noExistingPlayer: true))
        XCTAssertFalse(Review34DemoAdmission.coreReady(idle: true, saveAudio: "1", automaticDelivery: "1", noExistingPlayer: true))
        XCTAssertFalse(Review34DemoAdmission.coreReady(idle: true, saveAudio: "1", automaticDelivery: nil, noExistingPlayer: true))
        XCTAssertFalse(Review34DemoAdmission.coreReady(idle: true, saveAudio: "1", automaticDelivery: "0", noExistingPlayer: false))
    }
    func testPreparedGuestAdmissionRejectsWrongRevisionAndOccupiedState() {
        let sha = "1a245d0447b08e3fc681d439ea4ef3b392e034c2"
        func check(_ revision: String? = sha, _ flag: String? = "prepared-final-page-only",
                   _ pad: Bool = true, _ out: Bool = true, _ idle: Bool = true, _ empty: Bool = true) -> Bool {
            Review34DemoAdmission.admitted(revision: revision, optIn: flag, isPad: pad,
                signedOut: out, idle: idle, credentialsEmpty: empty)
        }
        XCTAssertTrue(check())
        XCTAssertFalse(check("older")); XCTAssertFalse(check(nil)); XCTAssertFalse(check(sha, nil))
        XCTAssertFalse(check(sha, "prepared-final-page-only", false))
        XCTAssertFalse(check(sha, "prepared-final-page-only", true, false))
        XCTAssertFalse(check(sha, "prepared-final-page-only", true, true, false))
        XCTAssertFalse(check(sha, "prepared-final-page-only", true, true, true, false))
    }

    func testUnknownCredentialStateIsNeverAdmittedAsEmpty() {
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: nil, placeholder: "Password"))
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: nil, placeholder: nil))
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: "synthetic user input", placeholder: "Password"))
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: "••••", placeholder: "Password"))
    }

    func testKnownEmptyAndVisiblePlaceholderAreAdmitted() {
        XCTAssertTrue(Review34DemoAdmission.credentialsAreEmpty(value: "", placeholder: nil))
        XCTAssertTrue(Review34DemoAdmission.credentialsAreEmpty(value: "Password", placeholder: "Password"))
        XCTAssertTrue(Review34DemoAdmission.credentialsAreEmpty(value: "Пароль", placeholder: "Пароль"))
        XCTAssertFalse(Review34DemoAdmission.credentialsAreEmpty(value: "Password", placeholder: nil))
    }
}
