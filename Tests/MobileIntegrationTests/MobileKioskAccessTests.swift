import XCTest
@testable import PichiVoiceMobile

@MainActor
final class MobileKioskAccessTests: XCTestCase {
    private nonisolated final class MemoryStore: MobileKioskCredentialStoring, @unchecked Sendable {
        var data: Data?
        var failRead = false
        var failWrite = false
        var writes = 0

        func read() throws -> Data? {
            if failRead { throw MobileKioskAccess.AccessError.unavailable }
            return data
        }

        func write(_ value: Data) throws {
            if failWrite { throw MobileKioskAccess.AccessError.unavailable }
            data = value
            writes += 1
        }
    }

    private func expect(_ expected: MobileKioskAccess.AccessError,
                        operation: () async throws -> Void,
                        file: StaticString = #filePath, line: UInt = #line) async {
        do { try await operation(); XCTFail("Expected \(expected)", file: file, line: line) }
        catch { XCTAssertEqual(error as? MobileKioskAccess.AccessError, expected, file: file, line: line) }
    }

    func testFirstEnableRequiresMatchingValidPasswordWithoutSavingPlaintext() async throws {
        let store = MemoryStore()
        let access = MobileKioskAccess(storage: store)
        XCTAssertFalse(access.isEnabled)
        XCTAssertFalse(access.hasPassword)
        XCTAssertTrue(access.isAvailable)
        await expect(.invalidPassword) { try await access.enable(password: "12345", confirmation: "12345") }
        await expect(.invalidPassword) { try await access.enable(password: String(repeating: "a", count: 129)) }
        await expect(.confirmationMismatch) { try await access.enable(password: "sample-password", confirmation: "different") }
        XCTAssertNil(store.data)
        try await access.enable(password: "sample-password", confirmation: "sample-password")
        XCTAssertTrue(access.isEnabled)
        XCTAssertTrue(access.hasPassword)
        XCTAssertFalse(String(decoding: try XCTUnwrap(store.data), as: UTF8.self).contains("sample-password"))
    }

    func testRelaunchRemainsLockedAndOnlyCorrectPasswordCanExitAndReenable() async throws {
        let store = MemoryStore()
        let first = MobileKioskAccess(storage: store)
        try await first.enable(password: "пароль Ёжик", confirmation: "пароль Ёжик")
        let relaunched = MobileKioskAccess(storage: store)
        XCTAssertTrue(relaunched.isEnabled)
        await expect(.incorrectPassword) { try await relaunched.unlock(password: "пароль ёжик") }
        XCTAssertTrue(relaunched.isEnabled)
        try await relaunched.unlock(password: "пароль Ёжик")
        XCTAssertFalse(relaunched.isEnabled)
        XCTAssertFalse(MobileKioskAccess(storage: store).isEnabled)
        XCTAssertTrue(relaunched.hasPassword)
        await expect(.incorrectPassword) { try await relaunched.enable(password: "new-password", confirmation: "new-password") }
        XCTAssertFalse(relaunched.isEnabled)
        try await relaunched.enable(password: "пароль Ёжик")
        XCTAssertTrue(relaunched.isEnabled)
    }

    func testPasswordsAreNotTrimmed() async throws {
        let store = MemoryStore()
        let access = MobileKioskAccess(storage: store)
        try await access.enable(password: " secret ", confirmation: " secret ")
        await expect(.incorrectPassword) { try await access.unlock(password: "secret") }
        try await access.unlock(password: " secret ")
        XCTAssertFalse(access.isEnabled)
    }

    func testIndependentCredentialsUseFreshRandomSalt() async throws {
        let first = MemoryStore(), second = MemoryStore()
        try await MobileKioskAccess(storage: first).enable(password: "same-password", confirmation: "same-password")
        try await MobileKioskAccess(storage: second).enable(password: "same-password", confirmation: "same-password")
        let firstJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(first.data)) as? [String: Any])
        let secondJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(second.data)) as? [String: Any])
        XCTAssertNotEqual(firstJSON["salt"] as? String, secondJSON["salt"] as? String)
        XCTAssertNotEqual(firstJSON["verifier"] as? String, secondJSON["verifier"] as? String)
    }

    func testFiveFailedAttemptsSurviveRelaunchAndCooldownExpires() async throws {
        let store = MemoryStore()
        var date = Date(timeIntervalSince1970: 1_000)
        let access = MobileKioskAccess(storage: store, now: { date })
        try await access.enable(password: "password", confirmation: "password")
        for _ in 0..<4 { await expect(.incorrectPassword) { try await access.unlock(password: "wrong") } }
        await expect(.temporarilyLocked) { try await access.unlock(password: "wrong") }
        let writes = store.writes
        let relaunched = MobileKioskAccess(storage: store, now: { date })
        await expect(.temporarilyLocked) { try await relaunched.unlock(password: "password") }
        XCTAssertEqual(store.writes, writes)
        XCTAssertTrue(relaunched.isEnabled)
        date = date.addingTimeInterval(-120)
        await expect(.temporarilyLocked) { try await relaunched.unlock(password: "password") }
        date = Date(timeIntervalSince1970: 1_060)
        try await relaunched.unlock(password: "password")
        XCTAssertFalse(relaunched.isEnabled)
        try await relaunched.enable(password: "password")
        await expect(.incorrectPassword) { try await relaunched.unlock(password: "wrong") }
    }

    func testWriteFailureCannotUnlockAndCanRecoverOnRetry() async throws {
        let store = MemoryStore()
        let access = MobileKioskAccess(storage: store)
        try await access.enable(password: "password", confirmation: "password")
        let saved = store.data
        store.failWrite = true
        await expect(.unavailable) { try await access.unlock(password: "password") }
        XCTAssertTrue(access.isEnabled)
        XCTAssertFalse(access.isAvailable)
        XCTAssertEqual(store.data, saved)
        store.failWrite = false
        try await access.unlock(password: "password")
        XCTAssertFalse(access.isEnabled)
        XCTAssertTrue(access.isAvailable)
    }

    func testFailedAttemptPersistenceFailureLocksAccess() async throws {
        let store = MemoryStore()
        let access = MobileKioskAccess(storage: store)
        try await access.enable(password: "password", confirmation: "password")
        store.failWrite = true
        await expect(.unavailable) { try await access.unlock(password: "wrong") }
        XCTAssertTrue(access.isEnabled)
        XCTAssertFalse(access.isAvailable)
    }

    func testCorruptOrUnavailableCredentialFailsClosed() async throws {
        let store = MemoryStore()
        store.data = Data("corrupt".utf8)
        let corrupt = MobileKioskAccess(storage: store)
        XCTAssertTrue(corrupt.isEnabled)
        XCTAssertTrue(corrupt.hasPassword)
        XCTAssertFalse(corrupt.isAvailable)
        await expect(.unavailable) { try await corrupt.enable(password: "replacement", confirmation: "replacement") }
        XCTAssertEqual(store.data, Data("corrupt".utf8))
        store.data = nil
        store.failRead = true
        let unavailable = MobileKioskAccess(storage: store)
        XCTAssertTrue(unavailable.isEnabled)
        XCTAssertFalse(unavailable.isAvailable)
    }

    func testUnsupportedCredentialVersionFailsClosed() async throws {
        let store = MemoryStore()
        try await MobileKioskAccess(storage: store).enable(password: "password", confirmation: "password")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(store.data)) as? [String: Any])
        object["version"] = 2
        store.data = try JSONSerialization.data(withJSONObject: object)
        let access = MobileKioskAccess(storage: store)
        XCTAssertTrue(access.isEnabled)
        XCTAssertFalse(access.isAvailable)
        await expect(.unavailable) { try await access.unlock(password: "password") }
    }

    func testConcurrentRequestsCannotInterleaveCredentialWrites() async throws {
        let store = MemoryStore()
        let access = MobileKioskAccess(storage: store)
        let first = Task { try await access.enable(password: "password", confirmation: "password") }
        for _ in 0..<100 where !access.isBusy { await Task.yield() }
        XCTAssertTrue(access.isBusy)
        await expect(.busy) { try await access.enable(password: "second-password", confirmation: "second-password") }
        try await first.value
        XCTAssertEqual(store.writes, 1)
        try await access.unlock(password: "password")
    }
}
