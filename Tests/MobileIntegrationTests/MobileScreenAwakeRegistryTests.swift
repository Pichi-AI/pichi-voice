import XCTest
@testable import PichiVoiceMobile

@MainActor
final class MobileScreenAwakeRegistryTests: XCTestCase {
    func testMultipleOwnersRestoreOnlyAfterLastRelease() {
        var disabled = false, writes: [Bool] = []
        let awake = MobileScreenAwakeRegistry(getDisabled: { disabled }, setDisabled: {
            disabled = $0; writes.append($0)
        })
        let first = awake.acquire(), second = awake.acquire()
        XCTAssertEqual(writes, [true])
        awake.release(first)
        awake.release(first)
        XCTAssertTrue(disabled)
        awake.release(second)
        XCTAssertFalse(disabled)
        XCTAssertEqual(writes, [true, false])
    }

    func testInitiallyDisabledIdleTimerIsPreserved() {
        var disabled = true
        let awake = MobileScreenAwakeRegistry(getDisabled: { disabled }, setDisabled: { disabled = $0 })
        let token = awake.acquire()
        XCTAssertTrue(disabled)
        awake.release(token)
        XCTAssertTrue(disabled, "Releasing restores the value from before the first owner")
    }
}
