import Foundation

nonisolated enum Review34DemoAdmission {
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
