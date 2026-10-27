import Foundation

private actor LegacyFixture: LegacyAccountTransporting {
    var userID = "41", editable = true, uploads = 0, logouts = 0
    var gate: CheckedContinuation<Void, Never>?
    var hold = false
    func snapshot() -> AccountSnapshot {
        .init(schemaVersion: 1, account: .init(id: userID, displayName: "Synthetic", email: nil),
            identity: .init(issuer: "", subject: "", legacyOrigin: "https://legacy.example"),
            organizations: [.init(id: "7", name: "Demo", workspaces: editable ? [.init(id: "9", name: "Demo", capabilities: ["recordings:import"])] : [])],
            activeOrganizationID: "7")
    }
    func login(email: String, password: String, captchaToken: String?) -> AccountSnapshot { snapshot() }
    func account() async -> AccountSnapshot { if hold { await withCheckedContinuation { gate = $0 } }; return snapshot() }
    func switchOrganization(_ id: String) -> AccountSnapshot { snapshot() }
    func perform(_ request: URLRequest) -> LegacyAccountHTTPResponse { uploads += 1; return .init(status: 202, body: Data("{}".utf8), retryAfter: nil) }
    func logout() { logouts += 1 }
    func clearSession() {}
    func shutdown() {}
    func holdAccount() { hold = true }
    var waiting: Bool { gate != nil }
    func releaseAccount() { hold = false; gate?.resume(); gate = nil }
    func changeUser(_ id: String) { userID = id }
    func revoke() { editable = false }
    func restoreWorkspace() { editable = true }
}
private actor LegacyUnusedCredentials: AccountCredentialStoring {
    var saves = 0
    func load() -> AccountGrant? { nil }
    func save(_ grant: AccountGrant) { saves += 1 }
    func clear() {}
}
private nonisolated struct LegacyUnusedOIDC: AccountTransporting {
    func authorizationURL(state: String, nonce: String, challenge: String) throws -> URL { throw AccountError.unconfigured }
    func exchange(code: String, verifier: String, nonce: String) throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func refresh(_ grant: AccountGrant) throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func account(accessToken: String) throws -> AccountSnapshot { throw AccountError.unconfigured }
    func revoke(refreshToken: String) throws { throw AccountError.unconfigured }
}
@MainActor private final class LegacyUnusedBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) throws -> URL { throw AccountError.unconfigured }
    func cancel() {}
}
@MainActor private final class LegacyLifecycle: AccountSessionLifecycle {
    var isAccountIsolationReady = true
    var transitions = 0
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) { transitions += 1 }
}

@MainActor enum AccountLegacySessionChecks {
    static func run() async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let config = LegacyAccountConfiguration(apiBaseURL: URL(string: "https://legacy.example")!, bundleIdentifier: "ai.example.voice")
        try config.validate()
        for origin in ["http://legacy.example", "https://legacy.example/", "https://user@legacy.example", "https://legacy.example/path", "https://legacy.example?x=1"] {
            do { try LegacyAccountConfiguration(apiBaseURL: URL(string: origin)!, bundleIdentifier: config.bundleIdentifier).validate(); fatalError("invalid origin accepted") } catch { checks += 1 }
        }
        let identity = AccountIdentity.legacy(origin: config.apiBaseURL, internalUserID: "41")
        expect(identity.issuer.isEmpty && identity.subject.isEmpty && identity.isLegacySession, "no fabricated OIDC identity")
        let wrapped = AccountPublicationConfiguration.legacy(config)
        expect(wrapped.matches(identity), "legacy destination matches trusted identity")
        let encoded = try JSONEncoder().encode(wrapped)
        expect(try JSONDecoder().decode(AccountPublicationConfiguration.self, from: encoded) == wrapped, "durable legacy destination roundtrip")
        let oidc = AccountConfiguration(issuer: URL(string: "https://identity.example")!, apiBaseURL: URL(string: "https://api.example")!, clientID: "client", apiAudience: "audience", bundleIdentifier: config.bundleIdentifier)
        let oldEncoded = try JSONEncoder().encode(oidc)
        let decoded = try JSONDecoder().decode(AccountPublicationConfiguration.self, from: oldEncoded)
        expect(decoded == .oidc(oidc) && !decoded.matches(identity), "old OIDC decode and identity isolation")
        let roundtrip = try JSONEncoder().encode(decoded)
        expect(try JSONSerialization.jsonObject(with: oldEncoded) as? NSDictionary == JSONSerialization.jsonObject(with: roundtrip) as? NSDictionary, "old OIDC encoding unchanged")
        let fixture = LegacyFixture(), credentials = LegacyUnusedCredentials(), lifecycle = LegacyLifecycle()
        let service = AccountSessionService(configuration: nil, browser: LegacyUnusedBrowser(), transport: LegacyUnusedOIDC(), credentials: credentials,
            lifecycle: lifecycle, legacyConfiguration: config, legacyTransport: fixture)
        expect(service.isConfigured && service.isLegacySession && service.legacyLogoutRevokesAllSessions, "explicit legacy configuration")
        await service.signIn(email: "synthetic@example.invalid", password: "synthetic-only")
        expect(service.state == .signedIn && service.context?.identity == identity, "shared service legacy admission")
        try await service.selectWorkspace(organizationID: "7", workspaceID: "9")
        let old = service.context!
        expect(old.organizationID == "7" && old.workspaceID == "9", "fresh editable workspace selected")
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent("api/recordings/transcript")); request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        _ = try await service.performAuthorizedLegacyRequest(for: old, request: request)
        expect(await fixture.uploads == 1, "protected request sent")
        do { _ = try await service.authorizedAccess(for: old); fatalError("legacy bearer escaped") } catch { checks += 1 }
        var bad = request; bad.url = URL(string: "https://other.example/api/recordings/transcript")!
        do { _ = try await service.performAuthorizedLegacyRequest(for: old, request: bad); fatalError("cross-origin accepted") } catch { checks += 1 }
        bad = request; bad.setValue("Bearer forbidden", forHTTPHeaderField: "Authorization")
        do { _ = try await service.performAuthorizedLegacyRequest(for: old, request: bad); fatalError("mixed credentials accepted") } catch { checks += 1 }
        await fixture.holdAccount()
        let delayed = Task { try await service.performAuthorizedLegacyRequest(for: old, request: request) }
        while !(await fixture.waiting) { await Task.yield() }
        await service.logout()
        expect(service.context == nil && service.account == nil && lifecycle.transitions >= 3, "logout clears profile projection")
        expect(await fixture.logouts == 1, "explicit server logout once")
        await fixture.changeUser("42")
        await service.signIn(email: "synthetic-b@example.invalid", password: "synthetic-only")
        await fixture.releaseAccount()
        do { _ = try await delayed.value; fatalError("A callback crossed B") } catch { checks += 1 }
        expect(await fixture.uploads == 1 && service.context?.identity.internalUserID == "42", "late A cannot upload or replace B")
        try await service.selectWorkspace(organizationID: "7", workspaceID: "9")
        await fixture.revoke()
        do { _ = try await service.performAuthorizedLegacyRequest(for: service.context!, request: request); fatalError("revoked workspace accepted") } catch { checks += 1 }
        expect(await fixture.uploads == 1 && service.state == .reauthenticationRequired, "fresh ACL denial stops upload")
        await fixture.restoreWorkspace()
        await service.signIn(email: "synthetic-b@example.invalid", password: "synthetic-only")
        expect(await fixture.logouts == 1 && service.state == .signedIn, "reconnect never revokes other devices")
        await service.retireLegacySession()
        expect(await fixture.logouts == 1 && service.state == .signedOut, "guest continuation retires only local session")
        await service.shutdown()
        expect(await credentials.saves == 0, "legacy never persists a grant")
        return checks
    }
}
