import Foundation

// Synthetic, in-memory collaborators only. This never installs a production lifecycle,
// accesses Keychain/browser/UI, changes user profiles or enables shipped sign-in.
private actor SyntheticAccountCredentials: AccountCredentialStoring {
    var grant: AccountGrant?
    var rejectClear = false
    func load() -> AccountGrant? { grant }
    func save(_ grant: AccountGrant) { self.grant = grant }
    func clear() throws {
        if rejectClear { throw AccountError.credentialsUnavailable }
        grant = nil
    }
    func failClear() { rejectClear = true }
    func seed(_ grant: AccountGrant) { self.grant = grant }
}

private actor SyntheticAccountTransport: AccountTransporting {
    var holdRefresh = false
    var waiting = false
    var refreshGate: CheckedContinuation<Void, Never>?
    var initialTokenLifetime: TimeInterval = 3600
    var rejectRefresh = false
    let snapshot = AccountSnapshot(schemaVersion: 1,
        account: .init(id: "synthetic-user", displayName: "Ёжик Synthetic", email: nil),
        identity: .init(issuer: "https://identity.example/realms/test", subject: "synthetic-subject"),
        organizations: [
            .init(id: "org-a", name: "Synthetic A", workspaces: [.init(id: "same-id", name: "Team A", capabilities: [])]),
            .init(id: "org-b", name: "Synthetic B", workspaces: [.init(id: "same-id", name: "Team B", capabilities: [])])
        ])
    func authorizationURL(state: String, nonce: String, challenge: String) -> URL {
        URL(string: "https://identity.example/auth?state=\(state)")!
    }
    func exchange(code: String, verifier: String, nonce: String) -> AccountTokenResponse {
        .init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
              expiresAt: Date().addingTimeInterval(initialTokenLifetime), subject: "synthetic-subject")
    }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse {
        if holdRefresh { waiting = true; await withCheckedContinuation { refreshGate = $0 }; waiting = false }
        if rejectRefresh { throw AccountError.networkUnavailable }
        return .init(accessToken: "synthetic-rotated", refreshToken: "synthetic-rotated-refresh",
              expiresAt: Date().addingTimeInterval(3600), subject: "synthetic-subject")
    }
    func suspendRefresh() { holdRefresh = true }
    func releaseRefresh() { holdRefresh = false; refreshGate?.resume(); refreshGate = nil }
    func prepareHeldRefreshFailure() { initialTokenLifetime = 30; holdRefresh = true; rejectRefresh = true }
    func account(accessToken: String) -> AccountSnapshot { snapshot }
    func revoke(refreshToken: String) {}
}

@MainActor private final class SyntheticAccountBrowser: AccountBrowserAuthenticating {
    var starts = 0
    var hold = false
    var waiting = false
    var cancelCalls = 0
    var gate: CheckedContinuation<Void, Never>?
    func authenticate(url: URL, callbackScheme: String) async -> URL {
        starts += 1
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        if hold { waiting = true; await withCheckedContinuation { gate = $0 }; waiting = false }
        return URL(string: "\(callbackScheme):/oauth/callback?state=\(state)&code=synthetic")!
    }
    // Deliberately delayed cancellation verifies that guest/disappear joins the owner.
    func cancel() { cancelCalls += 1 }
    func release() { hold = false; gate?.resume(); gate = nil }
}

@MainActor private final class SyntheticAccountLifecycle: AccountSessionLifecycle {
    var isAccountIsolationReady = true
    var explicitTransitionsAllowed = true
    var holdWorkspace = false
    var waiting = false
    var transitions = 0
    var onTransition: (@MainActor () -> Void)?
    var gate: CheckedContinuation<Void, Never>?
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async {
        transitions += 1
        onTransition?()
        if holdWorkspace, to?.workspaceID != nil {
            waiting = true; await withCheckedContinuation { gate = $0 }; waiting = false
        }
    }
    func release() { holdWorkspace = false; gate?.resume(); gate = nil }
}

@MainActor private final class SyntheticAccountUIFixture {
    let browser = SyntheticAccountBrowser()
    let credentials = SyntheticAccountCredentials()
    let transport = SyntheticAccountTransport()
    let lifecycle = SyntheticAccountLifecycle()
    let session: AccountSessionService
    let ui: MobileAccountInteraction
    init(configured: Bool = true, isolated: Bool = true) {
        let configuration = AccountConfiguration(issuer: URL(string: "https://identity.example/realms/test")!,
            apiBaseURL: URL(string: "https://api.example")!, clientID: "synthetic-mobile",
            apiAudience: "synthetic-api", bundleIdentifier: "ai.example.voice")
        session = AccountSessionService(configuration: configured ? configuration : nil,
            browser: browser, transport: transport, credentials: credentials, lifecycle: isolated ? lifecycle : nil)
        let admission = lifecycle
        ui = MobileAccountInteraction(session: session, requireTransitionAdmission: {
            if !admission.explicitTransitionsAllowed { throw AccountError.busy }
        })
    }
    func shutdown() async { await ui.waitUntilIdle(); await session.shutdown() }
}

@main struct MobileAccountInteractionTests {
    @MainActor static var assertions = 0
    @MainActor static func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
        precondition(condition(), message); assertions += 1
    }
    @MainActor static func until(_ condition: () async -> Bool) async {
        for _ in 0..<10_000 {
            if await condition() { return }
            await Task.yield()
        }
        preconditionFailure("Synthetic operation did not reach its explicit gate")
    }
    @MainActor static func main() async throws {
        let absent = SyntheticAccountUIFixture(configured: false)
        absent.ui.signIn()
        expect(!absent.ui.canSignIn && absent.browser.starts == 0, "Unconfigured UI never starts a browser")
        var guest = false
        absent.ui.continueAsGuest { guest = true }
        await absent.ui.waitUntilIdle()
        expect(guest && absent.session.state == .unconfigured, "Guest remains available without configuration")
        await absent.shutdown()

        let unsafe = SyntheticAccountUIFixture(isolated: false)
        unsafe.ui.signIn(); unsafe.ui.switchPerson()
        expect(unsafe.browser.starts == 0 && !unsafe.ui.canSignIn, "UI cannot bypass the real N2 gate")
        await unsafe.shutdown()

        let fixture = SyntheticAccountUIFixture()
        fixture.browser.hold = true
        fixture.ui.signIn(); fixture.ui.signIn()
        await until { fixture.browser.waiting }
        expect(fixture.browser.starts == 1 && !fixture.ui.canSignIn, "Repeated taps share one UI command")
        var guestCompleted = false
        fixture.ui.continueAsGuest { guestCompleted = true }
        await until { fixture.browser.cancelCalls > 0 }
        expect(!guestCompleted, "Guest completion waits for delayed browser cleanup")
        fixture.browser.release()
        await fixture.ui.waitUntilIdle()
        expect(guestCompleted && fixture.session.state == .signedOut && fixture.session.context == nil,
               "Late callback cannot admit an account after guest choice")
        expect(fixture.ui.action == nil, "Joined guest action releases UI ownership")

        fixture.ui.signIn(); await fixture.ui.waitUntilIdle()
        expect(fixture.session.state == .signedIn && fixture.session.context?.workspaceID == nil, "Sign-in never selects a default workspace")
        fixture.lifecycle.explicitTransitionsAllowed = false
        let admitted = fixture.session.context!
        let browserStarts = fixture.browser.starts
        let transitions = fixture.lifecycle.transitions
        fixture.ui.switchPerson(); await fixture.ui.waitUntilIdle()
        expect(fixture.ui.error == .busy && fixture.browser.starts == browserStarts && fixture.session.context == admitted,
               "Rejected person-switch admission preserves the account and starts no browser")
        fixture.ui.selectWorkspace(organizationID: "org-b", workspaceID: "same-id"); await fixture.ui.waitUntilIdle()
        expect(fixture.ui.error == .busy && fixture.lifecycle.transitions == transitions && fixture.session.context == admitted,
               "Rejected workspace admission performs no profile transition")
        fixture.ui.privateProjectionDidChange()
        expect(fixture.ui.error == nil, "Profile revision clears transient selection errors")
        fixture.lifecycle.explicitTransitionsAllowed = true
        fixture.lifecycle.holdWorkspace = true
        let priorContext = fixture.session.context!
        fixture.ui.selectWorkspace(organizationID: "org-b", workspaceID: "same-id")
        await until { fixture.lifecycle.waiting }
        fixture.ui.selectWorkspace(organizationID: "org-a", workspaceID: "same-id")
        expect(fixture.session.context == priorContext, "Suspended transition keeps committed context immutable")
        expect(fixture.ui.action == .workspace, "Workspace operation holds the action lock")
        fixture.lifecycle.release(); await fixture.ui.waitUntilIdle()
        expect(fixture.session.context?.organizationID == "org-b" && fixture.session.context?.workspaceID == "same-id",
               "Organization scopes duplicate workspace identifiers")
        fixture.ui.selectWorkspace(organizationID: "org-a", workspaceID: "missing")
        await fixture.ui.waitUntilIdle()
        expect(fixture.ui.error == .workspaceUnavailable, "Validation failure has a safe visible error")
        await fixture.session.logout()
        expect(fixture.ui.error == nil, "External generation change suppresses a former account's local error")
        fixture.lifecycle.explicitTransitionsAllowed = false
        fixture.ui.logout(); await fixture.ui.waitUntilIdle()
        expect(fixture.ui.error == nil && fixture.session.account == nil && fixture.session.context == nil, "Logout clears former account presentation")
        fixture.lifecycle.explicitTransitionsAllowed = true

        fixture.ui.signIn(); await fixture.ui.waitUntilIdle()
        fixture.ui.switchPerson(); await fixture.ui.waitUntilIdle()
        expect(fixture.session.presentationError == .previousAccountReturned, "Explicit switch rejects the same person through N1")
        expect(fixture.session.state == .signedOut && fixture.session.account == nil, "Rejected switch cannot display the previous profile")
        await fixture.shutdown()

        let dismissed = SyntheticAccountUIFixture()
        dismissed.browser.hold = true
        dismissed.ui.signIn(); await until { dismissed.browser.waiting }
        dismissed.ui.cancelOwnedSignInOnDisappear()
        await until { dismissed.browser.cancelCalls > 0 }
        expect(dismissed.ui.action == .cancel, "Disappearing view owns joined cancellation")
        dismissed.browser.release(); await dismissed.ui.waitUntilIdle()
        expect(dismissed.session.state == .signedOut && dismissed.ui.action == nil, "Disappearance cannot finish a late sign-in")
        await dismissed.shutdown()

        let concealedPanel = SyntheticAccountUIFixture()
        let interaction = concealedPanel.ui
        concealedPanel.lifecycle.onTransition = { [weak interaction] in
            interaction?.cancelOwnedSignInOnDisappear(profileBoundaryChanged: true)
        }
        concealedPanel.ui.signIn(); await concealedPanel.ui.waitUntilIdle()
        expect(concealedPanel.session.state == .signedIn, "Profile-driven disappearance cannot cancel final sign-in admission")
        concealedPanel.ui.switchPerson(); await concealedPanel.ui.waitUntilIdle()
        expect(concealedPanel.browser.starts == 2 && concealedPanel.session.presentationError == .previousAccountReturned,
               "Switch preflight concealment does not cancel its fresh browser admission")
        concealedPanel.lifecycle.onTransition = nil
        await concealedPanel.shutdown()

        let activeWindow = SyntheticAccountUIFixture()
        let passiveWindow = MobileAccountInteraction(session: activeWindow.session, requireTransitionAdmission: {})
        activeWindow.browser.hold = true
        activeWindow.ui.signIn(); await until { activeWindow.browser.waiting }
        passiveWindow.cancelOwnedSignInOnDisappear()
        passiveWindow.cancelOwnedSignInOnDisappear(profileBoundaryChanged: false) // Same hook used by navigation.
        expect(activeWindow.browser.cancelCalls == 0 && activeWindow.session.state == .signingIn,
               "Passive window dismissal/navigation cannot cancel another window's admission")
        activeWindow.browser.release(); await activeWindow.ui.waitUntilIdle()
        expect(activeWindow.session.state == .signedIn && passiveWindow.action == nil,
               "The initiating window retains its command through passive window disappearance")
        await activeWindow.shutdown()

        let explicitCancellation = SyntheticAccountUIFixture()
        let explicitOtherWindow = MobileAccountInteraction(session: explicitCancellation.session, requireTransitionAdmission: {})
        explicitCancellation.browser.hold = true
        explicitCancellation.ui.signIn(); await until { explicitCancellation.browser.waiting }
        explicitOtherWindow.cancelSignIn()
        await until { explicitCancellation.browser.cancelCalls > 0 }
        explicitCancellation.browser.release()
        await explicitOtherWindow.waitUntilIdle(); await explicitCancellation.ui.waitUntilIdle()
        expect(explicitCancellation.session.state == .signedOut,
               "Explicit Cancel remains a user request to join shared sign-in cancellation")
        await explicitCancellation.shutdown()

        let restoring = SyntheticAccountUIFixture()
        await restoring.credentials.seed(AccountGrant(identity: .init(issuer: "https://identity.example/realms/test",
            subject: "synthetic-subject", internalUserID: "synthetic-user"), accessToken: "synthetic-old-access",
            refreshToken: "synthetic-old-refresh", expiresAt: Date().addingTimeInterval(-1), nonce: "synthetic-nonce"))
        await restoring.transport.suspendRefresh()
        let restore = Task { await restoring.session.restore() }
        await until { await restoring.transport.waiting }
        expect(restoring.session.state == .signedOut, "Startup restoration is not inferred from public sign-in state")
        var restoredGuest = false
        restoring.ui.continueAsGuest { restoredGuest = true }
        await until { restoring.browser.cancelCalls > 0 }
        expect(!restoredGuest, "Guest completion joins a pending restoration")
        await restoring.transport.releaseRefresh()
        await restore.value; await restoring.ui.waitUntilIdle()
        expect(restoredGuest && restoring.session.context == nil && restoring.session.state == .signedOut,
               "Restoration cannot admit an account after explicit guest choice")
        await restoring.shutdown()

        let failedCleanup = SyntheticAccountUIFixture()
        failedCleanup.browser.hold = true
        failedCleanup.ui.signIn(); await until { failedCleanup.browser.waiting }
        await failedCleanup.credentials.failClear()
        var unsafeGuestCompletion = false
        failedCleanup.ui.continueAsGuest { unsafeGuestCompletion = true }
        await until { failedCleanup.browser.cancelCalls > 0 }
        failedCleanup.browser.release(); await failedCleanup.ui.waitUntilIdle()
        expect(!unsafeGuestCompletion && failedCleanup.session.presentationError == .credentialsUnavailable,
               "Failed guest transition cannot advance onboarding")
        expect(!failedCleanup.ui.canSignIn, "Failed cleanup cannot admit another person")
        await failedCleanup.shutdown()

        let errors: [AccountError] = [.unconfigured, .isolationRequired, .busy, .cancelled, .invalidCallback,
            .invalidState, .invalidToken, .invalidAccount, .invalidConfiguration, .invalidResponse,
            .credentialsUnavailable, .networkUnavailable, .reauthenticationRequired, .permissionDenied,
            .workspaceUnavailable, .staleOperation, .revocationUnavailable, .previousAccountReturned]
        for error in errors {
            let text = MobileAccountCopy.error(error, language: .english)
            expect(!text.isEmpty && !text.hasPrefix("account.error."), "Every service error has safe fallback copy")
        }
        await initialCloudStatusReadinessTest()
        try await privatePublicationTests()
        print("PASS: \(assertions) focused synthetic mobile account interaction assertions")
    }

    @MainActor private static func initialCloudStatusReadinessTest() async {
        let fixture = SyntheticAccountUIFixture()
        await fixture.transport.prepareHeldRefreshFailure()
        fixture.ui.signIn(); await fixture.ui.waitUntilIdle()
        let context = fixture.session.context!, generation = fixture.session.generation
        let source = MobilePrivatePublicationContext(profile: .init(id: "synthetic-status-a", context: context,
            generation: generation, rootDirectory: URL(fileURLWithPath: "/synthetic-unused"),
            legacyRootDirectory: URL(fileURLWithPath: "/synthetic-unused"), isReadable: true), projectionRevision: UUID())
        let refresh = Task { try? await fixture.session.authorizedAccess(for: context) }
        await until { await fixture.transport.waiting }
        let priorTransitions = fixture.lifecycle.transitions
        let workspace = Task { () -> AccountError? in
            do { try await fixture.session.selectWorkspace(organizationID: "org-b", workspaceID: "same-id"); return nil }
            catch { return error as? AccountError }
        }
        await until { !fixture.session.isCurrent(context) }
        let jobs = MobilePrivatePublicationTasks(capture: {
            fixture.session.isCurrent(context) ? source : nil
        }, validate: { $0 == source && fixture.session.isCurrent(context) })
        var waits = 0, reads = 0, reports = 0
        let interaction = MobileCloudInteraction(publications: jobs, statusSource: {
            fixture.session.context == context && fixture.session.generation == generation
                && fixture.session.state == .signedIn ? source : nil
        }, readinessDelay: { waits += 1; await Task.yield() })
        let request = interaction.readStatus(presentationID: UUID(), report: { _ in reports += 1 }) { admission in
            expect(jobs.canPublish(admission) && fixture.session.isCurrent(context), "The deferred status read still uses actual N1 admission")
            reads += 1
            return true
        }
        await until { waits > 0 }
        expect(request != nil && interaction.pendingStatusReadCount == 1 && jobs.admit() == nil && reads == 0,
               "An initial known-record read is retained while the real N1 workspace command holds its slot")
        await fixture.transport.releaseRefresh()
        _ = await refresh.value
        let workspaceFailure = await workspace.value
        expect(workspaceFailure == .networkUnavailable && fixture.lifecycle.transitions == priorTransitions,
               "Workspace selection fails on the held refresh before any profile transition begins")
        expect(fixture.session.context == context && fixture.session.generation == generation && fixture.session.isCurrent(context),
               "A failed refresh joined by workspace selection leaves the same source and generation current")
        await request?.value
        expect(reads == 1 && reports == 0 && interaction.pendingStatusReadCount == 0,
               "The same-source initial status read runs once after the failed N1 command joins without a task-key change")
        interaction.invalidate(); await interaction.waitUntilFinished(); await fixture.shutdown()
    }
}
