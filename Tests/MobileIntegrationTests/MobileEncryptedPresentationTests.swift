import Foundation
import XCTest
@testable import PichiVoiceMobile

/// The publisher retains a trusted read path. Only local presentation omits
/// encrypted content, while ordinary meetings from before opt-in stay visible.
@MainActor
final class MobileEncryptedPresentationTests: XCTestCase {
    private func session(title: String, concealed: Bool = false) -> MeetingSession {
        var value = MeetingSession(configuration: .init(mode: .inRoom, title: title,
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1,
                            machTimebaseDenominator: 1, firstPresentationTime: nil))
        value.requiresEncryptedPersistence = concealed
        return value
    }

    func testHistoryKeepsOrdinaryMeetingsAndOmitsEncryptedTitles() async {
        let ordinary = session(title: "Earlier ordinary meeting")
        let encrypted = session(title: "Synthetic confidential name", concealed: true)
        let trustedSource = [ordinary, encrypted]
        let history = MeetingHistorySnapshot { trustedSource }
        await history.refresh()
        XCTAssertEqual(history.sessions.map(\.id), [ordinary.id])
        XCTAssertFalse(history.sessions.contains { $0.title == encrypted.title })
        XCTAssertEqual(trustedSource.count, 2, "Presentation must not mutate the trusted delivery source")
        XCTAssertTrue(history.hasLoaded)
        XCTAssertNil(history.errorMessage)
    }

    func testConcealedCommitDoesNotAppendOrRetainACachedHistoryRow() async {
        let ordinary = session(title: "Ordinary")
        let encrypted = session(title: "Synthetic confidential row", concealed: true)
        let history = MeetingHistorySnapshot { [ordinary] }
        await history.refresh()
        history.applyCommitted(encrypted)
        XCTAssertEqual(history.sessions.map(\.id), [ordinary.id])
        // Evict an older presentation if a committed source is now protected.
        var stale = encrypted
        stale.requiresEncryptedPersistence = false
        history.applyCommitted(stale)
        XCTAssertTrue(history.sessions.contains { $0.id == encrypted.id })
        history.applyCommitted(encrypted)
        XCTAssertFalse(history.sessions.contains { $0.id == encrypted.id })
        XCTAssertTrue(history.sessions.contains { $0.id == ordinary.id })
    }
}
