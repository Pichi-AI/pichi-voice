import Foundation
import Security

private actor LegacyFixture: LegacyAccountTransporting {
    var userID = "41", editable = true, uploads = 0, logouts = 0
    var gate: CheckedContinuation<Void, Never>?
    var hold = false
    var holdClear = false
    var clearGate: CheckedContinuation<Void, Never>?
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
    func clearSession() async { if holdClear { await withCheckedContinuation { clearGate = $0 } } }
    func shutdown() {}
    func holdAccount() { hold = true }
    var waiting: Bool { gate != nil }
    func releaseAccount() { hold = false; gate?.resume(); gate = nil }
    func changeUser(_ id: String) { userID = id }
    func revoke() { editable = false }
    func restoreWorkspace() { editable = true }
    func holdRetirement() { holdClear = true }
    var retirementWaiting: Bool { clearGate != nil }
    func releaseRetirement() { holdClear = false; clearGate?.resume(); clearGate = nil }
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
    var activatedIdentities: [AccountIdentity] = []
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) {
        transitions += 1
        if let to { activatedIdentities.append(to.identity) }
    }
}

@MainActor enum AccountLegacySessionChecks {
    private static func until(_ predicate: () async -> Bool) async {
        for _ in 0..<10_000 { if await predicate() { return }; await Task.yield() }
        fatalError("Synthetic legacy gate did not open")
    }
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
        await until { await fixture.waiting }
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
        let lateFixture = LegacyFixture()
        let lateService = AccountSessionService(configuration: nil, browser: LegacyUnusedBrowser(), transport: LegacyUnusedOIDC(), credentials: LegacyUnusedCredentials(),
            lifecycle: LegacyLifecycle(), legacyConfiguration: config, legacyTransport: lateFixture)
        await lateService.signIn(email: "synthetic@example.invalid", password: "synthetic-only")
        await lateFixture.holdRetirement()
        let localRetirement = Task { await lateService.retireLegacySession() }
        await until { await lateFixture.retirementWaiting }
        let explicitLogout = Task { await lateService.logout() }
        for _ in 0..<20 { await Task.yield() }
        await lateFixture.releaseRetirement()
        await localRetirement.value; await explicitLogout.value
        expect(await lateFixture.logouts == 0 && lateService.presentationError == .revocationUnavailable, "late all-device logout reports unproved revocation")
        await lateService.shutdown()
        return checks
    }
}

/// Intercepts the actual ephemeral URLSession. These fixtures never open a socket.
private nonisolated final class LegacyHTTPFixtureProtocol: URLProtocol, @unchecked Sendable {
    private final class State: @unchecked Sendable {
        let lock = NSLock()
        var requests: [URLRequest] = []
        var loginStatus = 200
        var loginBody = "{}"
        var cookie = "auth_token=synthetic-cookie; Path=/; HttpOnly; Secure"
        var permission = "edit"
        var offline = false
        var userID = 41
        var meStatus = 200
        var recordingStatus = 200
        var optionsStatus = 200
        var retryAfter: String?
    }
    private static let state = State()
    static func configure(status: Int = 200, body: String = "{}", cookie: String = "auth_token=synthetic-cookie; Path=/; HttpOnly; Secure", permission: String = "edit", offline: Bool = false, userID: Int = 41, meStatus: Int = 200, recordingStatus: Int = 200, optionsStatus: Int = 200, retryAfter: String? = nil) {
        state.lock.lock(); defer { state.lock.unlock() }
        state.requests = []; state.loginStatus = status; state.loginBody = body; state.cookie = cookie; state.permission = permission
        state.offline = offline; state.userID = userID; state.meStatus = meStatus; state.recordingStatus = recordingStatus; state.optionsStatus = optionsStatus; state.retryAfter = retryAfter
    }
    static var requests: [URLRequest] { state.lock.lock(); defer { state.lock.unlock() }; return state.requests }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.state.lock.lock()
        Self.state.requests.append(request)
        let status = Self.state.loginStatus, loginBody = Self.state.loginBody, cookie = Self.state.cookie, permission = Self.state.permission
        let offline = Self.state.offline, userID = Self.state.userID, meStatus = Self.state.meStatus, recordingStatus = Self.state.recordingStatus, optionsStatus = Self.state.optionsStatus
        let retryAfter = Self.state.retryAfter
        Self.state.lock.unlock()
        if offline { client?.urlProtocol(self, didFailWithError: URLError(.notConnectedToInternet)); return }
        var responseStatus = 200, headers = ["Content-Type": "application/json"], body = "{}"
        if let retryAfter { headers["Retry-After"] = retryAfter }
        switch request.url!.path {
        case "/api/auth/login": responseStatus = status; body = loginBody; if status == 200 { headers["Set-Cookie"] = cookie }
        case "/api/auth/me": responseStatus = meStatus; body = "{\"user\":{\"id\":\(userID),\"fullName\":\"Synthetic\",\"organizationId\":7}}"
        case "/api/auth/organizations": body = #"{"organizations":[{"id":7,"name":"Demo"}],"currentOrganizationId":7}"#
        case "/api/workspaces": body = #"{"organization":{"id":7},"workspaces":[{"id":9,"name":"Demo","organizationId":7}]}"#
        case "/api/workspaces/9/user-permission": body = "{\"permission\":\"" + permission + "\"}"
        case "/api/workspaces/9/users", "/api/evaluation-criteria/names": responseStatus = optionsStatus
        case "/api/recordings/transcript": responseStatus = recordingStatus
        case "/api/auth/refresh": headers["Set-Cookie"] = cookie
        case "/api/auth/logout": headers["Set-Cookie"] = "auth_token=; Path=/; HttpOnly; Max-Age=0"
        default: break
        }
        client?.urlProtocol(self, didReceive: HTTPURLResponse(url: request.url!, statusCode: responseStatus, httpVersion: "HTTP/1.1", headerFields: headers)!, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

extension AccountLegacySessionChecks {
    static func http() async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let config = LegacyAccountConfiguration(apiBaseURL: URL(string: "https://legacy.example")!, bundleIdentifier: "ai.example.voice")
        func transport() throws -> LegacyAccountHTTPTransport {
            let session = URLSessionConfiguration.ephemeral; session.protocolClasses = [LegacyHTTPFixtureProtocol.self]
            return try LegacyAccountHTTPTransport(configuration: config, sessionConfiguration: session)
        }
        LegacyHTTPFixtureProtocol.configure()
        let first = try transport()
        let snapshot = try await first.login(email: "synthetic@example.invalid", password: "synthetic-only", captchaToken: nil)
        expect(snapshot.stableIdentity == .legacy(origin: config.apiBaseURL, internalUserID: "41") && snapshot.contains(organizationID: "7", workspaceID: "9"), "actual adapter verifies fresh me and editable workspace")
        let requests = LegacyHTTPFixtureProtocol.requests
        expect(requests.count == 5 && requests.first?.value(forHTTPHeaderField: "Cookie") == nil, "login begins with empty owned jar")
        expect(requests.dropFirst().allSatisfy { $0.value(forHTTPHeaderField: "Cookie") == "auth_token=synthetic-cookie" }, "same isolated cookie used for fresh account ACL checks")
        expect(requests.allSatisfy { $0.value(forHTTPHeaderField: "Authorization") == nil && $0.value(forHTTPHeaderField: "Origin") == nil && $0.value(forHTTPHeaderField: "Referer") == nil }, "no bearer or origin spoofing")
        let second = try transport()
        _ = try await second.perform(URLRequest(url: config.apiBaseURL.appendingPathComponent("api/auth/me")))
        expect(LegacyHTTPFixtureProtocol.requests.last?.value(forHTTPHeaderField: "Cookie") == nil, "second transport never shares a cookie")
        await second.shutdown()
        try await first.logout()
        _ = try await first.perform(URLRequest(url: config.apiBaseURL.appendingPathComponent("api/auth/me")))
        expect(LegacyHTTPFixtureProtocol.requests.last?.value(forHTTPHeaderField: "Cookie") == nil, "logout clears local cookie")
        await first.shutdown()
        for (status, body, expected) in [(429, "{\"requireCaptcha\":true}", AccountError.captchaRequired), (429, "{}", .rateLimited), (403, "{\"message\":\"error.auth.ciam_required\"}", .browserLoginRequired), (401, "{}", .reauthenticationRequired)] {
            LegacyHTTPFixtureProtocol.configure(status: status, body: body)
            let blocked = try transport()
            do { _ = try await blocked.login(email: "synthetic@example.invalid", password: "synthetic-only", captchaToken: nil); fatalError("guard bypass") }
            catch { expect(error as? AccountError == expected, "server guard gives stable actionable failure") }
            await blocked.shutdown()
        }
        LegacyHTTPFixtureProtocol.configure(permission: "view")
        let view = try transport()
        let viewSnapshot = try await view.login(email: "synthetic@example.invalid", password: "synthetic-only", captchaToken: nil)
        expect(!viewSnapshot.contains(organizationID: "7", workspaceID: "9"), "view workspace omitted from import destinations")
        await view.shutdown()
        LegacyHTTPFixtureProtocol.configure(cookie: "auth_token=synthetic; Domain=other.example; Path=/; HttpOnly; Secure")
        let foreign = try transport()
        do { _ = try await foreign.login(email: "synthetic@example.invalid", password: "synthetic-only", captchaToken: nil); fatalError("foreign cookie accepted") } catch { checks += 1 }
        await foreign.shutdown()
        LegacyHTTPFixtureProtocol.configure()
        return checks
    }
}

private actor LegacyMemorySessionStore: LegacyAccountSessionStoring {
    var session: LegacyAccountStoredSession?
    var failLoad = false
    var failClear = false
    var lockedLoad = false, lockedSave = false, lockedDelete = false
    var clearCalls = 0
    var holdLoad = false
    var loadGate: CheckedContinuation<Void, Never>?
    init(_ session: LegacyAccountStoredSession? = nil) { self.session = session }
    func load() async throws -> LegacyAccountStoredSession? {
        if holdLoad { await withCheckedContinuation { loadGate = $0 } }
        if lockedLoad { throw ProtectedDataAccessError.temporarilyUnavailable }
        if failLoad { throw AccountError.credentialsUnavailable }
        return session
    }
    func save(_ session: LegacyAccountStoredSession) throws {
        if lockedSave { throw ProtectedDataAccessError.temporarilyUnavailable }
        self.session = session
    }
    func clear() throws {
        clearCalls += 1
        if lockedDelete { throw ProtectedDataAccessError.temporarilyUnavailable }
        if failClear { throw AccountError.credentialsUnavailable }
        session = nil
    }
    func setLock(load: Bool = false, save: Bool = false, delete: Bool = false) {
        lockedLoad = load; lockedSave = save; lockedDelete = delete
    }
    func corrupt() { failLoad = true }
    func holdRead() { holdLoad = true }
    var waiting: Bool { loadGate != nil }
    func releaseRead() { holdLoad = false; loadGate?.resume(); loadGate = nil }
}

extension AccountLegacySessionChecks {
    static func persistence() async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let config = LegacyAccountConfiguration(apiBaseURL: URL(string: "https://legacy.example")!, bundleIdentifier: "ai.example.voice")
        func make(_ store: LegacyMemorySessionStore, lifecycle: LegacyLifecycle = LegacyLifecycle()) throws -> AccountSessionService {
            let policy = URLSessionConfiguration.ephemeral; policy.protocolClasses = [LegacyHTTPFixtureProtocol.self]
            return AccountSessionService(configuration: nil, browser: LegacyUnusedBrowser(), transport: LegacyUnusedOIDC(),
                credentials: LegacyUnusedCredentials(), lifecycle: lifecycle, legacyConfiguration: config,
                legacyTransport: try LegacyAccountHTTPTransport(configuration: config, sessionConfiguration: policy), legacyCredentials: store)
        }
        let cookie = "auth_token=synthetic-persistent-cookie; Path=/; HttpOnly; Secure; Max-Age=604800"
        LegacyHTTPFixtureProtocol.configure(cookie: cookie)
        let store = LegacyMemorySessionStore(), first = try make(store)
        await first.signIn(email: "synthetic@example.invalid", password: "password-stays-in-memory")
        expect(first.state == .signedIn, "persistent legacy login admitted")
        try await first.selectWorkspace(organizationID: "7", workspaceID: "9")
        let saved = await store.session!
        expect(saved.organizationID == "7" && saved.workspaceID == "9", "workspace persisted after service commit")
        let bytes = try JSONEncoder().encode(saved)
        expect(!String(decoding: bytes, as: UTF8.self).contains("password-stays-in-memory"), "envelope never stores password")
        expect(try LegacyAccountStoredSession.decode(bytes, configuration: config) == saved, "bounded session codec roundtrip")
        await first.shutdown()
        expect(await store.session != nil, "shutdown preserves restart credential")

        for status in [408, 429, 500, 502, 503] {
            LegacyHTTPFixtureProtocol.configure(meStatus: status)
            let temporary = try make(store)
            await temporary.restore()
            expect(temporary.state == .signedIn && temporary.isAwaitingLegacyServerValidation,
                   "Temporary server status \(status) preserves cached local admission")
            let sameOwner = temporary.context
            await temporary.restoreAfterConnectivity()
            expect(temporary.context == sameOwner && temporary.state == .signedIn && temporary.isAwaitingLegacyServerValidation,
                   "Repeated temporary validation cannot retire the admitted owner")
            expect(await store.session != nil, "Maintenance never clears the durable restart cookie")
            LegacyHTTPFixtureProtocol.configure()
            await temporary.restoreAfterConnectivity()
            expect(temporary.context == sameOwner && !temporary.isAwaitingLegacyServerValidation,
                   "Fresh identity/ACL recovery preserves the same generation after maintenance")
            await temporary.shutdown()
        }

        LegacyHTTPFixtureProtocol.configure(offline: true)
        let recoveredLifecycle = LegacyLifecycle(), recovered = try make(store, lifecycle: recoveredLifecycle)
        await recovered.restore()
        expect(recovered.state == .signedIn && recovered.isAwaitingLegacyServerValidation, "offline restart admits local cached profile")
        expect(recovered.context?.identity == saved.snapshot.stableIdentity && recovered.context?.workspaceID == "9", "offline recovery stays in same identity and workspace")
        expect(await store.session?.cookie.expiresAt == saved.cookie.expiresAt, "offline recovery never extends server cookie TTL")
        let offlineOwner = recovered.context!
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent("api/recordings/transcript")); request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        do { _ = try await recovered.performAuthorizedLegacyRequest(for: offlineOwner, request: request); fatalError("cached ACL authorized upload") } catch { checks += 1 }
        expect(!LegacyHTTPFixtureProtocol.requests.contains { $0.url?.path == "/api/recordings/transcript" }, "cached ACL never authorizes remote upload")
        LegacyHTTPFixtureProtocol.configure()
        await recovered.restoreAfterConnectivity()
        expect(recovered.state == .signedIn && !recovered.isAwaitingLegacyServerValidation && recovered.context == offlineOwner, "connectivity validation preserves admitted capture generation")
        _ = try await recovered.performAuthorizedLegacyRequest(for: offlineOwner, request: request)
        expect(LegacyHTTPFixtureProtocol.requests.contains { $0.url?.path == "/api/recordings/transcript" }, "fresh me and ACL allow remote upload after recovery")

        LegacyHTTPFixtureProtocol.configure(meStatus: 429, retryAfter: "1")
        do {
            _ = try await recovered.performAuthorizedLegacyRequest(for: offlineOwner, request: request)
            preconditionFailure("Temporary account validation was not throttled")
        } catch LegacyAccountConnectivityFailure.rateLimited(let header) {
            expect(header == "1", "Account-validation throttling retains Retry-After for publication scheduling")
        }
        expect(recovered.context == offlineOwner && recovered.isAwaitingLegacyServerValidation,
               "Validation throttling preserves the owner and requires fresh remote admission")
        LegacyHTTPFixtureProtocol.configure()
        for _ in 0..<3 { await recovered.restoreAfterConnectivity() }
        do { _ = try await recovered.performAuthorizedLegacyRequest(for: offlineOwner, request: request) } catch {}
        expect(LegacyHTTPFixtureProtocol.requests.filter { $0.url?.path == "/api/auth/me" }.isEmpty,
               "Foreground and authorized requests issue no validation GET before Retry-After")
        expect(recovered.context == offlineOwner && recovered.isAwaitingLegacyServerValidation,
               "Server pacing preserves the cached local owner without granting remote ACL")
        try await Task.sleep(for: .seconds(1.1))
        await recovered.restoreAfterConnectivity()
        expect(LegacyHTTPFixtureProtocol.requests.filter { $0.url?.path == "/api/auth/me" }.count == 1,
               "Validation GET resumes exactly once after the server floor")
        expect(recovered.context == offlineOwner && !recovered.isAwaitingLegacyServerValidation,
               "Foreground validation recovers after throttling without another login")

        LegacyHTTPFixtureProtocol.configure(offline: true)
        do { _ = try await recovered.performAuthorizedLegacyRequest(for: offlineOwner, request: request) } catch {}
        LegacyHTTPFixtureProtocol.configure(userID: 42)
        await recovered.restoreAfterConnectivity()
        expect(recovered.state == .reauthenticationRequired && recovered.context == nil, "fresh different identity fails closed")
        expect(recoveredLifecycle.activatedIdentities.allSatisfy { $0.internalUserID == "41" }, "server B can never activate through A restore")
        expect(await store.session == nil, "identity mismatch clears durable cookie")
        await recovered.shutdown()

        LegacyHTTPFixtureProtocol.configure(meStatus: 429, retryAfter: "120")
        let pacedStore = LegacyMemorySessionStore(saved), paced = try make(pacedStore)
        await paced.restore()
        expect(paced.context != nil && paced.isAwaitingLegacyServerValidation,
               "Cold restore retains the account-scoped validation floor with its cached owner")
        await paced.retireLegacySession()
        LegacyHTTPFixtureProtocol.configure(cookie: cookie, userID: 42)
        await paced.signIn(email: "new@synthetic.example", password: "synthetic")
        expect(paced.state == .signedIn, "Explicit new login succeeds after the prior throttle is retired")
        try await paced.selectWorkspace(organizationID: "7", workspaceID: "9")
        expect(paced.context?.identity.internalUserID == "42" && !paced.isAwaitingLegacyServerValidation,
               "Explicit retirement and new login cannot inherit a prior owner's validation floor")
        await paced.shutdown()

        for failure in [401, 403] {
            LegacyHTTPFixtureProtocol.configure(meStatus: failure)
            let rejectedStore = LegacyMemorySessionStore(saved), rejected = try make(rejectedStore)
            await rejected.restore()
            expect(rejected.context == nil && rejected.state == .reauthenticationRequired && !rejected.isAwaitingLegacyServerValidation, "An authentication or permission rejection is never offline admission")
            expect(await rejectedStore.session == nil, "rejected restart clears cookie")
            await rejected.shutdown()
        }
        LegacyHTTPFixtureProtocol.configure(permission: "view")
        let revokedStore = LegacyMemorySessionStore(saved), revoked = try make(revokedStore)
        await revoked.restore()
        expect(revoked.context == nil && revoked.state == .reauthenticationRequired, "removed edit permission cannot restore selected workspace")
        await revoked.shutdown()

        LegacyHTTPFixtureProtocol.configure()
        let expiredCookie = LegacyAccountCookie(value: saved.cookie.value, receivedAt: Date().addingTimeInterval(-3600), expiresAt: Date().addingTimeInterval(-1))
        let expired = LegacyAccountStoredSession(schemaVersion: 1, configuration: config, cookie: expiredCookie, snapshot: saved.snapshot,
            verifiedAt: Date().addingTimeInterval(-3600), organizationID: "7", workspaceID: "9")
        let expiredStore = LegacyMemorySessionStore(expired), expiredService = try make(expiredStore)
        await expiredService.restore()
        expect(expiredService.state == .reauthenticationRequired && LegacyHTTPFixtureProtocol.requests.isEmpty, "expired session neither restores nor refreshes")
        await expiredService.shutdown()
        let corruptStore = LegacyMemorySessionStore(saved); await corruptStore.corrupt()
        let corrupt = try make(corruptStore); await corrupt.restore()
        expect(corrupt.context == nil && corrupt.state == .reauthenticationRequired, "corrupt credential fails closed")
        await corrupt.shutdown()
        do { _ = try LegacyAccountStoredSession.decode(Data("invalid".utf8), configuration: config); fatalError("corrupt data decoded") } catch { checks += 1 }
        let foreign = LegacyAccountConfiguration(apiBaseURL: URL(string: "https://other.example")!, bundleIdentifier: config.bundleIdentifier)
        do { _ = try LegacyAccountStoredSession.decode(bytes, configuration: foreign); fatalError("foreign origin restored") } catch { checks += 1 }
        let tooLong = LegacyAccountCookie(value: "synthetic", receivedAt: Date(), expiresAt: Date().addingTimeInterval(8 * 86400))
        do { try tooLong.validate(); fatalError("invented cookie TTL accepted") } catch { checks += 1 }

        LegacyHTTPFixtureProtocol.configure(cookie: cookie)
        let logoutStore = LegacyMemorySessionStore(), logout = try make(logoutStore)
        await logout.signIn(email: "synthetic@example.invalid", password: "memory-only")
        await logout.logout()
        expect(await logoutStore.session == nil && LegacyHTTPFixtureProtocol.requests.contains { $0.url?.path == "/api/auth/logout" }, "explicit logout clears durable credential and calls all-session revoke")
        let noResurrection = try make(logoutStore); await noResurrection.restore()
        expect(noResurrection.context == nil && noResurrection.state == .signedOut, "logged-out session cannot resurrect after restart")
        await logout.shutdown(); await noResurrection.shutdown()

        LegacyHTTPFixtureProtocol.configure(offline: true)
        let guestStore = LegacyMemorySessionStore(saved), guest = try make(guestStore)
        await guest.restore(); await guest.retireLegacySession()
        expect(await guestStore.session == nil && !LegacyHTTPFixtureProtocol.requests.contains { $0.url?.path == "/api/auth/logout" }, "guest continuation clears durable local credential without global revoke")
        await guest.shutdown()

        LegacyHTTPFixtureProtocol.configure()
        let heldStore = LegacyMemorySessionStore(saved); await heldStore.holdRead()
        let held = try make(heldStore)
        let restoring = Task { await held.restore() }
        await until { await heldStore.waiting }
        let retiring = Task { await held.retireLegacySession() }
        for _ in 0..<20 { await Task.yield() }
        await heldStore.releaseRead()
        await restoring.value; await retiring.value
        expect(await heldStore.session == nil && held.context == nil && held.state == .signedOut, "joined retirement fences late durable restore")
        await held.shutdown()
        for rejectedStatus in [401, 403] {
        LegacyHTTPFixtureProtocol.configure(cookie: cookie)
        let invalidatedStore = LegacyMemorySessionStore(), invalidated = try make(invalidatedStore)
        await invalidated.signIn(email: "synthetic@example.invalid", password: "memory-only")
        try await invalidated.selectWorkspace(organizationID: "7", workspaceID: "9")
        LegacyHTTPFixtureProtocol.configure(recordingStatus: rejectedStatus)
        _ = try await invalidated.performAuthorizedLegacyRequest(for: invalidated.context!, request: request)
        expect(await invalidatedStore.session == nil && invalidated.state == .reauthenticationRequired, "runtime401/403 inhibits and clears cached restart admission")
        LegacyHTTPFixtureProtocol.configure(offline: true)
        let invalidatedRestart = try make(invalidatedStore); await invalidatedRestart.restore()
        expect(invalidatedRestart.context == nil, "known revoked session cannot resurrect offline")
        await invalidated.shutdown(); await invalidatedRestart.shutdown()

        }
        LegacyHTTPFixtureProtocol.configure(cookie: cookie)
        let selectionStore = LegacyMemorySessionStore(), selection = try make(selectionStore)
        await selection.signIn(email: "synthetic@example.invalid", password: "memory-only")
        LegacyHTTPFixtureProtocol.configure(meStatus: 401)
        do { try await selection.selectWorkspace(organizationID: "7", workspaceID: "9"); fatalError("revoked workspace selection succeeded") } catch { checks += 1 }
        expect(await selectionStore.session == nil && selection.state == .reauthenticationRequired, "known revocation while selecting workspace clears restart admission")
        await selection.shutdown()

        LegacyHTTPFixtureProtocol.configure(cookie: "auth_token=synthetic-short; Path=/; HttpOnly; Secure; Max-Age=30")
        let refreshStore = LegacyMemorySessionStore(), refreshing = try make(refreshStore)
        await refreshing.signIn(email: "synthetic@example.invalid", password: "memory-only")
        LegacyHTTPFixtureProtocol.configure(cookie: "auth_token=synthetic-refreshed; Path=/; HttpOnly; Secure; Max-Age=604800")
        try await refreshing.selectWorkspace(organizationID: "7", workspaceID: "9")
        expect(LegacyHTTPFixtureProtocol.requests.contains { $0.url?.path == "/api/auth/refresh" && $0.value(forHTTPHeaderField: "Cookie") == "auth_token=synthetic-short" }, "refresh requires still-valid original cookie")
        let refreshed = await refreshStore.session!
        expect(refreshed.cookie.value == "synthetic-refreshed" && refreshed.cookie.expiresAt.timeIntervalSince(refreshed.cookie.receivedAt) <= 7 * 86400 + 2, "refresh persists only actual server cookie expiry")
        await refreshing.shutdown()

        LegacyHTTPFixtureProtocol.configure()
        let sessionOnlyStore = LegacyMemorySessionStore(), sessionOnly = try make(sessionOnlyStore)
        await sessionOnly.signIn(email: "synthetic@example.invalid", password: "memory-only")
        expect(await sessionOnlyStore.session == nil && sessionOnly.state != .signedIn, "session cookie without server expiry never gets invented durable TTL")
        await sessionOnly.shutdown()
        LegacyHTTPFixtureProtocol.configure()
        return checks
    }
}

@MainActor private final class LegacyProtectedLifecycle: AccountSessionLifecycle {
    var isAccountIsolationReady = true
    var locked = false
    var isConcealed = false
    var rollbackCalls = 0
    var activated: [AccountIdentity] = []
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) throws {
        isConcealed = true
        if to == nil { rollbackCalls += 1 }
        if locked {
            isAccountIsolationReady = false
            throw ProtectedDataAccessError.temporarilyUnavailable
        }
        if let to { activated.append(to.identity) }
        isConcealed = false; isAccountIsolationReady = true
    }
}

extension AccountLegacySessionChecks {
    static func protectedData() async throws -> Int {
        var checks = 0
        func expect(_ value: Bool, _ label: String) { precondition(value, label); checks += 1 }
        let config = LegacyAccountConfiguration(apiBaseURL: URL(string: "https://legacy.example")!, bundleIdentifier: "ai.example.voice")
        func make(_ store: LegacyMemorySessionStore, lifecycle: any AccountSessionLifecycle = LegacyLifecycle(),
                  restoration: AccountRestorationPolicy = AccountRestorationPolicy()) throws -> AccountSessionService {
            let policy = URLSessionConfiguration.ephemeral; policy.protocolClasses = [LegacyHTTPFixtureProtocol.self]
            return AccountSessionService(configuration: nil, browser: LegacyUnusedBrowser(), transport: LegacyUnusedOIDC(),
                credentials: LegacyUnusedCredentials(), lifecycle: lifecycle, restoration: restoration, legacyConfiguration: config,
                legacyTransport: try LegacyAccountHTTPTransport(configuration: config, sessionConfiguration: policy), legacyCredentials: store)
        }
        let cookie = "auth_token=synthetic-lock-cookie; Path=/; HttpOnly; Secure; Max-Age=604800"
        LegacyHTTPFixtureProtocol.configure(cookie: cookie)
        let seedStore = LegacyMemorySessionStore(), seed = try make(seedStore)
        await seed.signIn(email: "synthetic@example.invalid", password: "memory-only")
        try await seed.selectWorkspace(organizationID: "7", workspaceID: "9")
        let saved = await seedStore.session!
        await seed.shutdown()
        if case .temporarilyUnavailable? = ProtectedDataAccessError.keychainFailure(errSecInteractionNotAllowed) { checks += 1 }
        else { fatalError("interaction lock misclassified") }
        if case .temporarilyUnavailable? = ProtectedDataAccessError.keychainFailure(errSecNotAvailable) { checks += 1 }
        else { fatalError("keystore unavailable misclassified") }
        expect(ProtectedDataAccessError.keychainFailure(errSecItemNotFound) == nil, "missing item is not a normal device lock")

        LegacyHTTPFixtureProtocol.configure()
        let loadStore = LegacyMemorySessionStore(saved), loadPolicy = AccountRestorationPolicy()
        await loadStore.setLock(load: true)
        let load = try make(loadStore, restoration: loadPolicy)
        await load.restore()
        expect(load.isAwaitingProtectedData && load.state != .reauthenticationRequired && load.context == nil, "locked cookie load waits without manual auth pause")
        expect(await loadStore.session == saved && loadPolicy.isAllowed, "cookie load lock preserves credential and restore permission")
        expect(await loadStore.clearCalls == 0 && LegacyHTTPFixtureProtocol.requests.isEmpty, "locked cookie load never deletes or sends")
        await loadStore.setLock()
        await load.restoreAfterProtectedDataAvailable()
        expect(load.context?.workspaceID == "9" && load.state == .signedIn && !load.isAwaitingProtectedData, "unlock restores same cached account without password")
        await load.shutdown()

        LegacyHTTPFixtureProtocol.configure()
        let keyStore = LegacyMemorySessionStore(saved), keyLifecycle = LegacyProtectedLifecycle(), keyPolicy = AccountRestorationPolicy()
        keyLifecycle.locked = true
        let keyLocked = try make(keyStore, lifecycle: keyLifecycle, restoration: keyPolicy)
        await keyLocked.restore()
        expect(keyLocked.isAwaitingProtectedData && keyLocked.context == nil && keyLifecycle.isConcealed, "recording-key activation lock keeps failed profile hidden")
        let keyClearCalls = await keyStore.clearCalls
        expect(await keyStore.session == saved && keyPolicy.isAllowed && keyClearCalls == 0, "recording-key lock preserves cookie and restore intent")
        keyLifecycle.locked = false
        await keyLocked.restoreAfterProtectedDataAvailable()
        expect(keyLocked.state == .signedIn && keyLocked.context?.identity == saved.snapshot.stableIdentity && !keyLifecycle.isConcealed, "unlock retries hidden profile through joined guest rollback")
        expect(keyLifecycle.rollbackCalls >= 2 && keyLifecycle.activated.allSatisfy { $0.internalUserID == "41" }, "guest cleanup restores readiness without activating another person")
        await keyLocked.shutdown()

        LegacyHTTPFixtureProtocol.configure()
        let transferStore = LegacyMemorySessionStore(saved), transferPolicy = AccountRestorationPolicy(), transfer = try make(transferStore, restoration: transferPolicy)
        await transfer.restore()
        let owner = transfer.context!, beforeLock = await transferStore.session
        await transferStore.setLock(save: true)
        var request = URLRequest(url: config.apiBaseURL.appendingPathComponent("api/recordings/transcript")); request.httpMethod = "POST"; request.httpBody = Data("{}".utf8)
        do { _ = try await transfer.performAuthorizedLegacyRequest(for: owner, request: request); fatalError("locked credential save sent upload") }
        catch is ProtectedDataAccessError { checks += 1 }
        expect(transfer.state == .signedIn && transfer.context == owner && transfer.isAwaitingProtectedData, "transfer save lock preserves safe owner for retry")
        let transferClearCalls = await transferStore.clearCalls
        expect(await transferStore.session == beforeLock && transferPolicy.isAllowed && transferClearCalls == 0, "transfer save lock never clears valid credential")
        expect(!LegacyHTTPFixtureProtocol.requests.contains { $0.url?.path == "/api/recordings/transcript" }, "transfer waits while persistence is protected")
        await transferStore.setLock()
        await transfer.restoreAfterProtectedDataAvailable()
        expect(transfer.state == .signedIn && transfer.context == owner && !transfer.isAwaitingProtectedData, "unlock persistence retry preserves capture generation")
        _ = try await transfer.performAuthorizedLegacyRequest(for: owner, request: request)
        expect(LegacyHTTPFixtureProtocol.requests.contains { $0.url?.path == "/api/recordings/transcript" }, "fresh authorized upload resumes after unlock")
        await transfer.shutdown()

        LegacyHTTPFixtureProtocol.configure(offline: true)
        let reconnectStore = LegacyMemorySessionStore(saved), reconnectPolicy = AccountRestorationPolicy(), reconnect = try make(reconnectStore, restoration: reconnectPolicy)
        await reconnect.restore()
        let offlineOwner = reconnect.context!
        LegacyHTTPFixtureProtocol.configure()
        await reconnectStore.setLock(save: true)
        await reconnect.restoreAfterConnectivity()
        expect(reconnect.isAwaitingProtectedData && reconnect.state == .signedIn && reconnect.context == offlineOwner, "connectivity revalidation save lock remains retryable")
        expect(await reconnectStore.clearCalls == 0 && reconnectPolicy.isAllowed, "connectivity save lock preserves durable restore permission")
        await reconnectStore.setLock()
        await reconnect.restoreAfterProtectedDataAvailable()
        expect(!reconnect.isAwaitingProtectedData && !reconnect.isAwaitingLegacyServerValidation && reconnect.context == offlineOwner, "connectivity and protected-data recovery converge on same owner")
        await reconnect.shutdown()

        // A first save blocked after an explicit B login must not allow the older
        // A envelope to restore; the pending freshly verified B stays private memory.
        LegacyHTTPFixtureProtocol.configure(cookie: cookie, userID: 42)
        let newStore = LegacyMemorySessionStore(saved), newPolicy = AccountRestorationPolicy()
        await newStore.setLock(save: true)
        let newLogin = try make(newStore, restoration: newPolicy)
        await newLogin.signIn(email: "synthetic-b@example.invalid", password: "never-persist")
        expect(newLogin.state == .signedIn && newLogin.context?.identity.internalUserID == "42" && newLogin.isAwaitingProtectedData, "first-save lock retains newly verified B in memory")
        expect(!newPolicy.isAllowed, "blocked first B save cannot permit old durable A restoration")
        let other = try make(newStore, restoration: newPolicy); await other.restore()
        expect(other.context == nil, "old A cannot resurrect while first B save waits")
        await other.shutdown()
        await newStore.setLock()
        LegacyHTTPFixtureProtocol.configure(offline: true)
        await newLogin.restoreAfterProtectedDataAvailable()
        expect(await newStore.session?.snapshot.stableIdentity.internalUserID == "42" && newPolicy.isAllowed, "unlock persists exact verified B even while offline")
        expect(newLogin.state == .signedIn && newLogin.isAwaitingLegacyServerValidation && !newLogin.isAwaitingProtectedData, "offline B remains local-only after persistence unlock")
        await newLogin.shutdown()

        for path in ["api/workspaces/9/users", "api/evaluation-criteria/names"] {
            LegacyHTTPFixtureProtocol.configure()
            let optionsStore = LegacyMemorySessionStore(saved), optionsPolicy = AccountRestorationPolicy(), options = try make(optionsStore, restoration: optionsPolicy)
            await options.restore()
            LegacyHTTPFixtureProtocol.configure(optionsStatus: 403)
            let response = try await options.performAuthorizedLegacyRequest(for: options.context!, request: URLRequest(url: config.apiBaseURL.appendingPathComponent(path)))
            expect(response.status == 403 && options.state == .reauthenticationRequired, "late options403 revokes local remote admission")
            expect(await optionsStore.session == nil && !optionsPolicy.isAllowed, "late options403 inhibits offline restore")
            LegacyHTTPFixtureProtocol.configure(offline: true)
            let offline = try make(optionsStore, restoration: optionsPolicy); await offline.restore()
            expect(offline.context == nil, "late options403 cannot resurrect offline")
            await options.shutdown(); await offline.shutdown()
        }
        LegacyHTTPFixtureProtocol.configure()
        return checks
    }
}
