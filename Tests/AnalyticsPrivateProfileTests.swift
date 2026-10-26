// Appended to the actual AnalyticsService source so its private actor remains production code.
import SQLite3

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var shareDetailedAnalytics = false
    var analyticsOnboardingOrigin: AnalyticsOnboardingOrigin { .firstRun }
}
actor SyntheticUploadGate {
    static let shared = SyntheticUploadGate()
    var started = false
    private var continuation: CheckedContinuation<Void, Never>?
    func wait() async {
        started = true
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { continuation?.resume(); continuation = nil }
}
nonisolated enum AnalyticsUploadTransport {
    static func send(items: [AnalyticsOutboxItem], config: AnalyticsConfig) async throws -> Int {
        await SyntheticUploadGate.shared.wait() // Deliberately ignores cancellation, with no network.
        return 200
    }
}
@MainActor final class Completion { var finished = false }
@main struct AnalyticsPrivateProfileTests {
    static func main() async throws {
        let manager = FileManager.default
        let root = AppBrand.applicationSupportDirectory
        try manager.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? manager.removeItem(at: root) }
        var checks = 0
        func require(_ value: @autoclosure () throws -> Bool, _ code: String) throws {
            checks += 1
            if try !value() { throw NSError(domain: code, code: 1) }
        }
        func rows(_ url: URL) throws -> Int {
            var db: OpaquePointer?
            guard sqlite3_open_v2(url.path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db else { throw NSError(domain: "read-db", code: 1) }
            defer { sqlite3_close(db) }
            var statement: OpaquePointer?
            guard sqlite3_prepare_v2(db, "SELECT COUNT(*) FROM outbox", -1, &statement, nil) == SQLITE_OK else { throw NSError(domain: "read-count", code: 1) }
            defer { sqlite3_finalize(statement) }
            guard sqlite3_step(statement) == SQLITE_ROW else { throw NSError(domain: "read-row", code: 1) }
            return Int(sqlite3_column_int(statement, 0))
        }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        let gate = DetailedAnalyticsConsentGate()
        let core = AnalyticsCore(detailedConsentGate: gate)
        func context(_ profile: PrivateProfileSnapshot, id: String) -> AnalyticsContext {
            .init(profile: profile, detailedAnalyticsEnabled: true, detailedConsentGeneration: gate.currentGeneration,
                config: .init(postHogApiKey: "phc_synthetic_test", postHogHost: "https://synthetic.invalid"),
                distinctID: id, appVersion: "1.0", collectsBetaPerformance: false)
        }
        let old = context(guest, id: "synthetic-guest")
        await core.recordActivity(.app, context: old)
        let oldURL = guest.directory("Analytics").appendingPathComponent("analytics-v2.sqlite3")
        try require(try rows(oldURL) == 1, "guest-queue-created")
        await core.recordOnboardingStarted(origin: .firstRun, context: old)
        let expectedRows = try rows(oldURL)
        let upload = Task { await core.bootstrap(context: old) }
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await SyntheticUploadGate.shared.started), ContinuousClock.now < deadline { await Task.yield() }
        let didStart = await SyntheticUploadGate.shared.started
        try require(didStart, "synthetic-upload-started")
        PrivateProfileStorage.conceal(generation: UUID())
        _ = gate.advance()
        await core.recordActivity(.coreAction, context: old)
        await core.recordUsage(mode: .command, transcriptionModel: nil, aiModel: nil, context: old)
        try require(try rows(oldURL) == expectedRows, "stale-activity-and-detailed-fallback-denied")
        let completion = Completion()
        let join = Task { await core.suspendForProfileTransition(); completion.finished = true }
        try await Task.sleep(for: .milliseconds(20))
        try require(!completion.finished, "transition-waits-for-cancellation-ignoring-upload")
        await SyntheticUploadGate.shared.release()
        await join.value
        await upload.value
        try require(completion.finished && (try rows(oldURL)) == expectedRows, "stale-upload-not-acknowledged")
        let identity = AccountContext(identity: .init(issuer: "https://issuer.invalid", subject: "synthetic-a", internalUserID: "a"),
            organizationID: "org", workspaceID: "workspace", generation: UUID())
        let account = try PrivateProfileStorage.proposed(context: identity, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(account)
        await core.recordActivity(.app, context: context(account, id: "synthetic-account"))
        let newURL = account.directory("Analytics").appendingPathComponent("analytics-v2.sqlite3")
        try require(try rows(newURL) == 1 && rows(oldURL) == expectedRows, "queues-are-not-copied-or-retargeted")
        await core.recordActivity(.coreAction, context: old)
        try require(try rows(newURL) == 1 && rows(oldURL) == expectedRows, "retired-owner-cannot-reopen-database")
        PrivateProfileStorage.conceal(generation: UUID())
        _ = gate.advance()
        await core.suspendForProfileTransition()
        print("Analytics private profiles: \(checks) synthetic stale-admission/separate-queue/joined-transport checks passed; transport is inert")
    }
}
