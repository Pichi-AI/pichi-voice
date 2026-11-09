import Foundation
import CryptoKit

nonisolated enum Review34DemoAdmission {
    static let coreRevision = "62d9d54450a8612a8c9bbbeb348baf41214de63b"
    static let reviewRevision = "1a245d0447b08e3fc681d439ea4ef3b392e034c2"
    static func releaseBuild(for revision: String) -> String? {
        switch revision {
        case reviewRevision: "34"
        case coreRevision: "35"
        default: nil
        }
    }
    static let fixtureSHA = "81998993976a2804d414b261d3af679d49a1b1e08d952bace5ffc31291a392c8"
    struct CoreVideoProof: Codable {
        let schemaVersion: Int
        let revision: String
        let build: String
        let deviceID: String
        let idiom: String
        let osVersion: String
        let latestOSVerified: Bool
        let backupVerified: Bool
        let backupSHA256: String
        let appExecutableSHA256: String
        let baselineIDs: [String]
    }
    /// A hash-pinned HOST attestation, not an independent backup/install verifier.
    static func coreVideoProof(_ data: Data, expectedSHA: String?, revision: String?, deviceID: String?,
                               idiom: String, osVersion: String, baselineIDs: [String], expectedBackupSHA: String?) -> Bool {
        guard data.count <= 65_536, let expectedSHA, validSHA(expectedSHA),
              SHA256.hash(data: data).map({ String(format: "%02x", $0) }).joined() == expectedSHA.lowercased(),
              let proof = try? JSONDecoder().decode(CoreVideoProof.self, from: data),
              proof.schemaVersion == 1, revision == proof.revision, let expectedBuild = releaseBuild(for: proof.revision),
              proof.build == expectedBuild, let deviceID, !deviceID.isEmpty, proof.deviceID == deviceID,
              ["phone", "pad"].contains(idiom), proof.idiom == idiom,
              !osVersion.isEmpty, proof.osVersion == osVersion, proof.latestOSVerified,
              proof.backupVerified, validSHA(proof.backupSHA256), proof.backupSHA256 == expectedBackupSHA,
              validSHA(proof.appExecutableSHA256),
              uniqueIDs(proof.baselineIDs), uniqueIDs(baselineIDs), Set(proof.baselineIDs) == Set(baselineIDs)
        else { return false }
        return true
    }
    static func coreReady(idle: Bool, saveAudio: String?, automaticDelivery: String?, noExistingPlayer: Bool) -> Bool {
        recordingPoliciesReady(idle: idle, saveAudio: saveAudio, automaticDelivery: automaticDelivery,
            noExistingPlayer: noExistingPlayer, requireRetainedAudio: true)
    }
    static func recordingPoliciesReady(idle: Bool, saveAudio: String?, automaticDelivery: String?,
                                       noExistingPlayer: Bool, requireRetainedAudio: Bool,
                                       automaticDeliveryPresent: Bool = true, verifiedSignedOut: Bool = false,
                                       cancelled: Bool = false) -> Bool {
        let localOnly = automaticDeliveryPresent ? automaticDelivery == "0"
            : automaticDelivery == nil && verifiedSignedOut
        return !cancelled && idle && localOnly && noExistingPlayer && (!requireRetainedAudio || saveAudio == "1")
    }
    struct GuestEvidence {
        let emailCount: Int
        let secureFieldCount: Int
        let signInCount: Int
        let destination: String?
        let fieldsEnabled: Bool
        let signInVisible: Bool
        let conflictingAccountState: Bool
        let foregroundWithoutPrompts: Bool
        var verifiedSignedOut: Bool {
            emailCount == 1 && secureFieldCount == 1 && signInCount == 1 && destination == "app.pichi.ai"
                && fieldsEnabled && signInVisible && !conflictingAccountState && foregroundWithoutPrompts
        }
    }
    static func validSHA(_ value: String) -> Bool { value.count == 64 && value.allSatisfy(\.isHexDigit) }
    private static func uniqueIDs(_ ids: [String]) -> Bool {
        ids.allSatisfy({ UUID(uuidString: $0) != nil }) && Set(ids.compactMap(UUID.init(uuidString:))).count == ids.count
    }
    static func admitted(revision: String?, optIn: String?, isPad: Bool,
                         signedOut: Bool, idle: Bool, credentialsEmpty: Bool) -> Bool {
        revision == "1a245d0447b08e3fc681d439ea4ef3b392e034c2"
            && optIn == "prepared-final-page-only" && isPad && signedOut && idle && credentialsEmpty
    }

    static func credentialsAreEmpty(value: String?, placeholder: String?) -> Bool {
        guard let value else { return false }
        return value.isEmpty || (placeholder?.isEmpty == false && value == placeholder)
    }

    /// A saved recording is owned only after the unchanged baseline gains exactly one UUID.
    static func newOwnedSessionID(baselineIDs: [String], historyIDs: [String]) -> String? {
        let baseline = baselineIDs.compactMap(UUID.init(uuidString:))
        let history = historyIDs.compactMap(UUID.init(uuidString:))
        guard baseline.count == baselineIDs.count, history.count == historyIDs.count,
              Set(baseline).count == baseline.count, Set(history).count == history.count,
              Set(baseline).isSubset(of: Set(history)) else { return nil }
        let added = Set(history).subtracting(baseline)
        return added.count == 1 ? added.first?.uuidString : nil
    }

    struct PlaybackOwner {
        let sessionID: String
        let paragraphID: String
        let audioID: String

        init?(sessionID: String, baselineIDs: [String], paragraphID: String, audioID: String) {
            guard let session = UUID(uuidString: sessionID),
                  baselineIDs.allSatisfy({ UUID(uuidString: $0) != nil }),
                  Set(baselineIDs.compactMap(UUID.init(uuidString:))).count == baselineIDs.count,
                  !baselineIDs.contains(where: { UUID(uuidString: $0) == session }),
                  paragraphID.hasPrefix("transcript.paragraph."), paragraphID.count > "transcript.paragraph.".count,
                  audioID.hasPrefix("transcript.audio."), audioID.count > "transcript.audio.".count else { return nil }
            self.sessionID = session.uuidString
            self.paragraphID = paragraphID
            self.audioID = audioID
        }

        func matches(openedSessionID: String?, paragraphID: String, audioID: String,
                     paragraphCount: Int, audioCount: Int) -> Bool {
            openedSessionID == self.sessionID && paragraphID == self.paragraphID && audioID == self.audioID
                && paragraphCount == 1 && audioCount == 1
        }
    }
}
