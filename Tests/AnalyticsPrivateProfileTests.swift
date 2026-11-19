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
    func release() {
        continuation?.resume()
        continuation = nil
        started = false
    }
}
nonisolated enum AnalyticsUploadTransport {
    static func send(items: [AnalyticsOutboxItem], config: AnalyticsConfig) async throws -> Int {
        await SyntheticUploadGate.shared.wait() // Deliberately ignores cancellation, with no network.
        return 200
    }
}
@MainActor final class Completion { var finished = false }
private extension AnalyticsCore {
    func flushBeforeConsentTransitionCompletes() async { await self.flushIfNeeded() }
}
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
        func context(_ profile: PrivateProfileSnapshot, id: String, detailed: Bool = true) -> AnalyticsContext {
            .init(profile: profile, detailedAnalyticsEnabled: detailed, detailedConsentGeneration: gate.currentGeneration,
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
        let accountContext = context(account, id: "synthetic-account")
        await core.recordActivity(.app, context: accountContext)
        let newURL = account.directory("Analytics").appendingPathComponent("analytics-v2.sqlite3")
        try require(try rows(newURL) == 1 && rows(oldURL) == expectedRows, "queues-are-not-copied-or-retargeted")
        await core.recordActivity(.coreAction, context: old)
        try require(try rows(newURL) == 1 && rows(oldURL) == expectedRows, "retired-owner-cannot-reopen-database")

        await core.recordOnboardingStarted(origin: .firstRun, context: accountContext)
        try require(try rows(newURL) == 2, "details-queued-before-opt-out")
        _ = gate.advance(revoking: account)
        let optedOut = context(account, id: "synthetic-account", detailed: false)
        await core.recordActivity(.app, context: optedOut)
        let earlyFlush = Task { await core.flushBeforeConsentTransitionCompletes() }
        // Keep this regression bounded even when the stale batch starts an upload.
        let earlyDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        let earlyCompleted = Completion()
        let earlyJoin = Task { await earlyFlush.value; earlyCompleted.finished = true }
        while !earlyCompleted.finished, !(await SyntheticUploadGate.shared.started), ContinuousClock.now < earlyDeadline {
            await Task.yield()
        }
        let earlyUploadStarted = await SyntheticUploadGate.shared.started
        await SyntheticUploadGate.shared.release()
        try require(earlyCompleted.finished && !earlyUploadStarted, "pending-opt-out-blocked-queued-details")
        await earlyJoin.value
        try require(try rows(newURL) == 1, "pending-opt-out-purged-queued-details-and-kept-activity")

        _ = gate.advance()
        let optedBackIn = context(account, id: "synthetic-account")
        await core.recordOnboardingStarted(origin: .manualRestart, context: optedBackIn)
        let consentUpload = Task { await core.bootstrap(context: optedBackIn) }
        let consentDeadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !(await SyntheticUploadGate.shared.started), ContinuousClock.now < consentDeadline { await Task.yield() }
        let consentUploadStarted = await SyntheticUploadGate.shared.started
        try require(consentUploadStarted, "detailed-upload-in-flight-before-opt-out")
        _ = gate.advance(revoking: account)
        let revoked = context(account, id: "synthetic-account", detailed: false)
        await core.setDetailedAnalyticsEnabled(context: revoked)
        await core.recordOnboardingStarted(origin: .firstRun, context: optedBackIn)
        await SyntheticUploadGate.shared.release()
        await consentUpload.value
        try require(try rows(newURL) == 1, "opt-out-cleared-queued-details-and-rejected-stale-write")

        _ = gate.advance()
        let enabledAgain = context(account, id: "synthetic-account")
        await core.recordOnboardingStarted(origin: .firstRun, context: enabledAgain)
        try require(try rows(newURL) == 2, "details-queued-before-quick-opt-out")
        _ = gate.advance(revoking: account)
        _ = gate.advance()
        let quicklyReenabled = context(account, id: "synthetic-account")
        await core.recordOnboardingStarted(origin: .manualRestart, context: quicklyReenabled)
        try require(try rows(newURL) == 2, "quick-opt-in-purged-old-details-before-recording-new-ones")

        _ = gate.advance(revoking: account)
        _ = gate.advance()
        PrivateProfileStorage.conceal(generation: UUID())
        _ = gate.advance()
        await core.suspendForProfileTransition()
        try require(try rows(newURL) == 2, "restart-fixture-still-has-old-details")

        let reopenedAccount = try PrivateProfileStorage.proposed(context: identity, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(reopenedAccount)
        let restartedGate = DetailedAnalyticsConsentGate()
        let restartedCore = AnalyticsCore(detailedConsentGate: restartedGate)
        let restarted = AnalyticsContext(profile: reopenedAccount, detailedAnalyticsEnabled: true,
            detailedConsentGeneration: restartedGate.currentGeneration,
            config: .init(postHogApiKey: "", postHogHost: ""),
            distinctID: "synthetic-account", appVersion: "1.0", collectsBetaPerformance: false)
        try require(try restartedGate.pendingRevocation(for: reopenedAccount) != nil, "pending-revocation-survived-restart")
        await restartedCore.bootstrap(context: restarted)
        try require(try rows(newURL) == 1 && rows(oldURL) == expectedRows, "restart-purged-only-recorded-profile-details")
        try require(try restartedGate.pendingRevocation(for: reopenedAccount) == nil, "restart-cleared-marker-after-purge")

        let marker = reopenedAccount.directory("Analytics").appendingPathComponent("pending-detailed-consent-revocation")
        try manager.createDirectory(at: marker, withIntermediateDirectories: false)
        _ = restartedGate.advance(revoking: reopenedAccount)
        try require(!restartedGate.canEnableDetails(for: reopenedAccount), "failed-marker-write-blocks-quick-opt-in")
        try manager.removeItem(at: marker)
        let disabledAfterFailure = AnalyticsContext(profile: reopenedAccount, detailedAnalyticsEnabled: false,
            detailedConsentGeneration: restartedGate.currentGeneration, config: restarted.config,
            distinctID: restarted.distinctID, appVersion: restarted.appVersion, collectsBetaPerformance: false)
        await restartedCore.bootstrap(context: disabledAfterFailure)
        try require(restartedGate.canEnableDetails(for: reopenedAccount), "successful-purge-unblocks-opt-in")

        print("Analytics private profiles: \(checks) synthetic stale-admission, consent and queue checks passed; transport is inert")
    }
}
