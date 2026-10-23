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
              expiresAt: Date().addingTimeInterval(3600), subject: "synthetic-subject")
    }
    func refresh(_ grant: AccountGrant) async -> AccountTokenResponse {
        if holdRefresh { waiting = true; await withCheckedContinuation { refreshGate = $0 }; waiting = false }
        return .init(accessToken: "synthetic-rotated", refreshToken: "synthetic-rotated-refresh",
              expiresAt: Date().addingTimeInterval(3600), subject: "synthetic-subject")
    }
    func suspendRefresh() { holdRefresh = true }
    func releaseRefresh() { holdRefresh = false; refreshGate?.resume(); refreshGate = nil }
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
    var gate: CheckedContinuation<Void, Never>?
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async {
        transitions += 1
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

@main private struct MobileAccountInteractionTests {
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
        print("PASS: \(assertions) focused synthetic mobile account interaction assertions")
    }
}
