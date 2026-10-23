import Foundation

@main struct PrivateProfileLoggingTests {
    static func main() async throws {
        let manager = FileManager.default
        let root = AppBrand.applicationSupportDirectory
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var checks = 0
        func require(_ condition: @autoclosure () throws -> Bool, _ code: String) throws {
            checks += 1
            if try !condition() { throw NSError(domain: code, code: 1) }
        }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        let logger = FileLogger.shared
        let oldURL = logger.currentLogFileURL()
        logger.appendSync(line: "synthetic-preserved-guest")
        let gate = DispatchSemaphore(value: 0)
        DebugLogger.shared.logLazy { gate.wait(); return "synthetic-admitted-guest" }
        PrivateProfileStorage.conceal(generation: UUID())
        DebugLogger.shared.info("synthetic-concealed-denied")
        gate.signal()
        await DebugLogger.shared.joinForProfileTransition()
        await logger.suspendForProfileTransition()
        let first = try String(contentsOf: oldURL, encoding: .utf8)
        try require(first.contains("synthetic-preserved-guest") && first.contains("synthetic-admitted-guest"), "guest-queue-joined")
        try require(!first.contains("synthetic-concealed-denied"), "concealed-admission-denied")
        let context = AccountContext(identity: .init(issuer: "https://issuer.invalid", subject: "synthetic-a", internalUserID: "a"),
            organizationID: "org", workspaceID: "workspace", generation: UUID())
        let account = try PrivateProfileStorage.proposed(context: context, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(account)
        await logger.activateProfile(account)
        logger.append(line: "synthetic-retired-profile-denied", profile: guest)
        logger.appendSync(line: "synthetic-account-only")
        let current = try String(contentsOf: logger.currentLogFileURL(), encoding: .utf8)
        try require(current.contains("synthetic-account-only"), "new-profile-log")
        try require(!current.contains("synthetic-preserved-guest") && !current.contains("synthetic-retired-profile-denied"), "no-guest-copy-or-retarget")
        try require(try String(contentsOf: oldURL, encoding: .utf8) == first, "legacy-guest-file-preserved")
        await logger.suspendForProfileTransition()
        print("Private profile logging: \(checks) synthetic queue/admission/descriptor/profile-preservation checks passed")
    }
}
