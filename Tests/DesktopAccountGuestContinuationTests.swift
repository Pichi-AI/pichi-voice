import Foundation

private actor GuestCredentials: AccountCredentialStoring {
    var grant: AccountGrant?
    var failClear = false
    init(grant: AccountGrant? = nil) { self.grant = grant }
    func load() -> AccountGrant? { self.grant }
    func save(_ grant: AccountGrant) { self.grant = grant }
    func clear() throws {
        if self.failClear { throw AccountError.credentialsUnavailable }
        self.grant = nil
    }
    func rejectClear(_ value: Bool) { self.failClear = value }
}

@MainActor private final class GuestBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        preconditionFailure("Guest continuation must never open a browser")
    }
    func cancel() {}
}

@MainActor private final class GuestLifecycle: AccountSessionLifecycle {
    var isAccountIsolationReady = true
    var failGuest = false
    var guestTransitions = 0
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async throws {
        if to == nil {
            self.guestTransitions += 1
            if self.failGuest { throw AccountError.invalidState }
        }
    }
}

private actor GuestTransport: AccountTransporting {
    var holdRefresh = false
    var refreshGate: CheckedContinuation<Void, Never>?
    var offlineRevocation = false
    func authorizationURL(state: String, nonce: String, challenge: String) throws -> URL {
        preconditionFailure("Guest continuation must never start authorization")
    }
    func exchange(code: String, verifier: String, nonce: String) throws -> AccountTokenResponse {
        preconditionFailure("Guest continuation must never exchange a code")
    }
    func refresh(_ grant: AccountGrant) async -> AccountTokenResponse {
        if self.holdRefresh { await withCheckedContinuation { self.refreshGate = $0 } }
        return .init(accessToken: "synthetic-access", refreshToken: "synthetic-rotated", expiresAt: Date().addingTimeInterval(3600), subject: grant.identity.subject)
    }
    func account(accessToken: String) -> AccountSnapshot {
        .init(schemaVersion: 1, account: .init(id: "synthetic-user", displayName: "Synthetic", email: nil),
              identity: .init(issuer: "https://identity.example", subject: "synthetic-subject"), organizations: [])
    }
    func revoke(refreshToken: String) throws {
        if self.offlineRevocation { throw AccountError.networkUnavailable }
    }
    func suspendRefresh() { self.holdRefresh = true }
    var isRefreshWaiting: Bool { self.refreshGate != nil }
    func releaseRefresh() { self.holdRefresh = false; self.refreshGate?.resume(); self.refreshGate = nil }
    func rejectRevocation() { self.offlineRevocation = true }
}

@main
private struct DesktopAccountGuestContinuationTests {
    @MainActor static func main() async {
        let configuration = AccountConfiguration(issuer: URL(string: "https://identity.example")!, apiBaseURL: URL(string: "https://api.example")!,
                                                clientID: "synthetic-native", apiAudience: "synthetic-api", bundleIdentifier: "example.synthetic.voice")
        let identity = AccountIdentity(issuer: configuration.issuer.absoluteString, subject: "synthetic-subject", internalUserID: "synthetic-user")
        let grant = AccountGrant(identity: identity, accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
                                 expiresAt: Date().addingTimeInterval(3600), nonce: "synthetic-nonce")

        let credentials = GuestCredentials(), lifecycle = GuestLifecycle()
        let account = AccountSessionService(configuration: configuration, browser: GuestBrowser(), transport: GuestTransport(), credentials: credentials, lifecycle: lifecycle)
        await credentials.rejectClear(true)
        await account.logout()
        precondition(account.state == .signedOut && account.presentationError == .credentialsUnavailable)
        let failedCredentials = await DesktopAccountGuestContinuation.prepare(using: account)
        precondition(failedCredentials == nil, "Signed-out with failed credential cleanup cannot finish as guest")
        await credentials.rejectClear(false)
        let ready = await DesktopAccountGuestContinuation.prepare(using: account)
        precondition(ready != nil && DesktopAccountGuestContinuation.isCurrent(ready!, using: account))
        await account.logout()
        precondition(!DesktopAccountGuestContinuation.isCurrent(ready!, using: account), "Guest completion cannot cross a newer generation")

        lifecycle.failGuest = true
        let failedProfile = await DesktopAccountGuestContinuation.prepare(using: account)
        precondition(failedProfile == nil, "Failed profile cleanup cannot finish as guest")
        lifecycle.failGuest = false
        let retriedProfile = await DesktopAccountGuestContinuation.prepare(using: account)
        precondition(retriedProfile != nil && lifecycle.guestTransitions >= 5)

        let suspendedTransport = GuestTransport(), suspendedCredentials = GuestCredentials(grant: grant)
        let restoring = AccountSessionService(configuration: configuration, browser: GuestBrowser(), transport: suspendedTransport,
                                              credentials: suspendedCredentials, lifecycle: GuestLifecycle())
        await suspendedTransport.suspendRefresh()
        let restore = Task { await restoring.restore() }
        for _ in 0..<10000 {
            if await suspendedTransport.isRefreshWaiting { break }
            await Task.yield()
        }
        let refreshIsWaiting = await suspendedTransport.isRefreshWaiting
        precondition(refreshIsWaiting)
        precondition(restoring.state == .signedOut, "A suspended restore still projects signed out")
        var guestFinished = false
        let guest = Task {
            let result = await DesktopAccountGuestContinuation.prepare(using: restoring)
            guestFinished = true
            return result
        }
        for _ in 0..<100 { await Task.yield() }
        precondition(!guestFinished, "Guest continuation must join the suspended restore")
        await suspendedTransport.releaseRefresh()
        await restore.value
        let restoredGuest = await guest.value
        precondition(restoredGuest != nil && restoring.context == nil && restoring.state == .signedOut)
        let clearedGrant = await suspendedCredentials.load()
        precondition(clearedGrant == nil, "Joined guest transition clears the old grant")

        let offlineTransport = GuestTransport()
        await offlineTransport.rejectRevocation()
        let offline = AccountSessionService(configuration: configuration, browser: GuestBrowser(), transport: offlineTransport,
                                            credentials: GuestCredentials(grant: grant), lifecycle: GuestLifecycle())
        let offlineGuest = await DesktopAccountGuestContinuation.prepare(using: offline)
        precondition(offlineGuest != nil && offline.presentationError == .revocationUnavailable,
                     "Offline server revocation does not prevent verified local guest cleanup")
        for service in [account, restoring, offline] { await service.shutdown() }
        print("PASS: guest continuation joins real account service cleanup/restore, rejects credential/profile failures and stale generations, and permits offline local sign-out")
    }
}
