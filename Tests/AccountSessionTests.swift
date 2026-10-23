import Foundation
import Security

private actor MemoryCredentials: AccountCredentialStoring {
    var grant: AccountGrant?
    var saves = 0
    var failSave = false
    var failClear = false
    init(_ grant: AccountGrant? = nil) { self.grant = grant }
    func load() -> AccountGrant? { grant }
    func save(_ grant: AccountGrant) throws { if failSave { throw AccountError.credentialsUnavailable }; self.grant = grant; saves += 1 }
    func clear() throws { if failClear { throw AccountError.credentialsUnavailable }; grant = nil }
    func rejectSaves() { failSave = true }
    func setClearFailure(_ value: Bool) { failClear = value }
}
private actor FakeTransport: AccountTransporting {
    var blockAuthorization = false
    var authorizationGate: CheckedContinuation<Void, Never>?
    var refreshes = 0
    var refreshFailure: AccountError?
    var refreshExpiry = Date().addingTimeInterval(3600)
    var revocations: [String] = []
    var failAccount = false
    var blockRefresh = false
    var blockExchange = false
    var refreshGate: CheckedContinuation<Void, Never>?
    var exchangeGate: CheckedContinuation<Void, Never>?
    var initialExpiry = Date().addingTimeInterval(-1)
    var snapshot = fixtureSnapshot()
    func authorizationURL(state: String, nonce: String, challenge: String) async -> URL {
        if blockAuthorization { await withCheckedContinuation { authorizationGate = $0 } }
        return URL(string: "https://identity.example/auth?state=\(state)&nonce=\(nonce)&code_challenge=\(challenge)")!
    }
    func exchange(code: String, verifier: String, nonce: String) async -> AccountTokenResponse {
        if blockExchange { await withCheckedContinuation { exchangeGate = $0 } }
        return .init(accessToken: "initial", refreshToken: "initial-refresh", expiresAt: initialExpiry, subject: "subject-a")
    }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse {
        refreshes += 1
        if let refreshFailure { throw refreshFailure }
        if blockRefresh { await withCheckedContinuation { refreshGate = $0 } }
        return .init(accessToken: "rotated", refreshToken: "rotated-refresh", expiresAt: refreshExpiry, subject: "subject-a")
    }
    func account(accessToken: String) throws -> AccountSnapshot { if failAccount { throw AccountError.networkUnavailable }; return snapshot }
    func setAccountFailure(_ value: Bool) { failAccount = value }
    func revoke(refreshToken: String) { revocations.append(refreshToken) }
    var isAuthorizationWaiting: Bool { authorizationGate != nil }
    func holdAuthorization() { blockAuthorization = true }
    func releaseAuthorization() { blockAuthorization = false; authorizationGate?.resume(); authorizationGate = nil }
    func holdRefresh() { blockRefresh = true }
    func setRefreshExpiry(_ value: Date) { refreshExpiry = value }
    func setRefreshFailure(_ value: AccountError?) { refreshFailure = value }
    func holdExchange() { blockExchange = true }
    func releaseRefresh() { blockRefresh = false; refreshGate?.resume(); refreshGate = nil }
    func releaseExchange() { blockExchange = false; exchangeGate?.resume(); exchangeGate = nil }
    var isExchangeWaiting: Bool { exchangeGate != nil }
    var isRefreshWaiting: Bool { refreshGate != nil }
}
private actor FixtureHTTP: AccountHTTPRequesting {
    var requests: [URLRequest] = []
    let discovery: Data
    init(endpoint: String = "https://identity.example") throws {
        discovery = try JSONSerialization.data(withJSONObject: [
            "issuer": "https://identity.example/realms/test",
            "authorization_endpoint": endpoint + "/auth", "token_endpoint": endpoint + "/token",
            "jwks_uri": endpoint + "/jwks", "revocation_endpoint": endpoint + "/revoke",
            "code_challenge_methods_supported": ["S256"]])
    }
    func request(_ request: URLRequest) throws -> Data {
        requests.append(request)
        if request.url!.path.hasSuffix("openid-configuration") { return discovery }
        if request.url!.path == "/api/v1/account" { return try JSONEncoder().encode(fixtureSnapshot()) }
        if request.url!.path == "/revoke" { return Data() }
        throw AccountError.invalidResponse
    }
    func shutdown() {}
}
@MainActor private final class FakeBrowser: AccountBrowserAuthenticating {
    var wrongState = false
    var requests = 0
    var explicitRequests: [Bool] = []
    var authorizationURLs: [URL] = []
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        requests += 1; authorizationURLs.append(url)
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        return URL(string: callbackScheme + ":/oauth/callback?code=synthetic-code&state=" + (wrongState ? "wrong" : state))!
    }
    func authenticate(url: URL, callbackScheme: String, requiresExplicitIdentity: Bool) async throws -> URL {
        explicitRequests.append(requiresExplicitIdentity)
        return try await authenticate(url: url, callbackScheme: callbackScheme)
    }
    func cancel() {}
}
@MainActor private final class Lifecycle: AccountSessionLifecycle {
    var isAccountIsolationReady = true
    var transitions: [(AccountContext?, AccountContext?)] = []
    var failTransition = false
    var blockRollback = false
    var rollbackGate: CheckedContinuation<Void, Never>?
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async throws {
        transitions.append((from, to))
        if to == nil && blockRollback { await withCheckedContinuation { rollbackGate = $0 } }
        if failTransition { throw AccountError.invalidState }
    }
    func releaseRollback() { blockRollback = false; rollbackGate?.resume(); rollbackGate = nil }
}
nonisolated private func fixtureSnapshot() -> AccountSnapshot {
    .init(schemaVersion: 1, account: .init(id: "user-a", displayName: "Synthetic", email: nil),
        identity: .init(issuer: "https://identity.example/realms/test", subject: "subject-a"),
        organizations: [.init(id: "org", name: "Synthetic", workspaces: [.init(id: "workspace", name: "Synthetic", capabilities: ["recordings:create-own"])])])
}
nonisolated private func fixtureConfiguration(_ bundle: String = "ai.example.voice") -> AccountConfiguration {
    .init(issuer: URL(string: "https://identity.example/realms/test")!, apiBaseURL: URL(string: "https://api.example")!,
        clientID: "native-test", apiAudience: "pichi-api", bundleIdentifier: bundle)
}

@main private struct AccountSessionTests {
    @MainActor static var count = 0
    @MainActor static func expect(_ value: Bool, _ label: String) {
        guard value else { fatalError("FAIL: " + label) }; count += 1
    }
    @MainActor static func reject(_ label: String, _ work: () throws -> Void) {
        do { try work(); fatalError("FAIL: " + label) } catch { count += 1 }
    }
    @MainActor static func until(_ predicate: () async -> Bool) async {
        for _ in 0..<10000 { if await predicate() { return }; await Task.yield() }
        fatalError("Synthetic gate did not open")
    }
    @MainActor static func main() async throws {
        let configuration = fixtureConfiguration()
        try configuration.validate()
        let attempt = try AccountAuthorizationAttempt(redirectURI: configuration.redirectURI)
        expect(attempt.verifier.count == 43 && attempt.challenge.count == 43 && attempt.state != attempt.nonce, "PKCE secure random shape")
        let callback = configuration.redirectURI.absoluteString + "?state=" + attempt.state + "&code=one"
        expect(try attempt.code(from: URL(string: callback)!) == "one", "valid exact callback")
        for suffix in ["&state=duplicate", "#fragment", "&error=access_denied"] { reject("ambiguous callback") { _ = try attempt.code(from: URL(string: callback + suffix)!) } }
        reject("wrong path") { _ = try attempt.code(from: URL(string: callback.replacingOccurrences(of: "oauth/callback", with: "wrong"))!) }
        reject("wrong state") { _ = try attempt.code(from: URL(string: callback.replacingOccurrences(of: attempt.state, with: "wrong"))!) }
        reject("wrong scheme") { _ = try attempt.code(from: URL(string: callback.replacingOccurrences(of: "ai.example.voice:", with: "ai.other.voice:"))!) }
        expect(AccountKeychainStore.scope(configuration: configuration) != AccountKeychainStore.scope(configuration: fixtureConfiguration("ai.other.voice")), "branded credentials separated")
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(configuration)) as! [String: Any]
        object["issuer"] = "http://identity.example/realms/test"
        reject("insecure issuer") { try JSONDecoder().decode(AccountConfiguration.self, from: JSONSerialization.data(withJSONObject: object)).validate() }
        try jwtTests()
        try await transportTests(configuration)
        let browser = FakeBrowser(), transport = FakeTransport(), credentials = MemoryCredentials(), lifecycle = Lifecycle()
        let service = AccountSessionService(configuration: configuration, browser: browser, transport: transport, credentials: credentials)
        await service.signIn()
        expect(service.presentationError == .isolationRequired && browser.requests == 0, "configuration cannot bypass N2")
        try service.installLifecycle(lifecycle)
        await service.signIn()
        expect(service.state == .signedIn && service.context?.identity.internalUserID == "user-a", "verified account projected")
        expect(service.context?.workspaceID == nil, "no default workspace")
        let original = service.context!
        await transport.holdRefresh()
        let first = Task { try await service.authorizedAccess(for: original) }
        await until { await transport.isRefreshWaiting }
        let second = Task { try await service.authorizedAccess(for: original) }
        await Task.yield(); await transport.releaseRefresh()
        expect(try await first.value.accessToken == "rotated", "first refresh waiter")
        expect(try await second.value.accessToken == "rotated", "joined refresh waiter")
        expect(await transport.refreshes == 1, "single concurrent refresh")
        try await service.selectWorkspace(organizationID: "org", workspaceID: "workspace")
        expect(service.context?.workspaceID == "workspace" && service.generation != original.generation, "workspace changes generation")
        do { _ = try await service.authorizedAccess(for: original); fatalError("old context authorized") } catch { count += 1 }
        do { try await service.selectWorkspace(organizationID: "org", workspaceID: "other"); fatalError("invalid workspace selected") } catch { count += 1 }
        await service.logout()
        expect(service.state == .signedOut && service.context == nil && service.account == nil, "logout clears projections")
        expect(await credentials.load() == nil, "logout clears credentials")
        expect(await transport.revocations == ["rotated-refresh"], "device grant revoke only")
        expect(lifecycle.transitions.last?.1 == nil, "logout joins profile transition")
        await staleRefreshTest(configuration)
        await staleSignInTest(configuration)
        try await rotationLookupFailureTest(configuration)
        try await cleanupFailuresTest(configuration)
        await joinedFailedAdmissionTest(configuration)
        try restorationMarkerTest()
        try await ambiguousRefreshRestartTest(configuration)
        await shutdownDuringRestorationTest(configuration)
        await operationKindAfterLogoutTest(configuration)
        await browserPolicyAndSwitchTest(configuration)
        try await workspaceRefreshOwnershipTest(configuration)
        let failedCredentials = MemoryCredentials(); await failedCredentials.rejectSaves()
        let failedBrowser = FakeBrowser(), failedTransport = FakeTransport(), failedLifecycle = Lifecycle()
        let failed = AccountSessionService(configuration: configuration, browser: failedBrowser, transport: failedTransport,
            credentials: failedCredentials, lifecycle: failedLifecycle)
        await failed.signIn()
        expect(failed.state == .signedOut && failed.presentationError == .credentialsUnavailable, "save failure fails closed")
        expect(failedLifecycle.transitions.last?.1 == nil, "save failure returns guest profile")
        expect(await failedTransport.revocations == ["initial-refresh"], "failed login revokes acquired device grant")
        let invalidBrowser = FakeBrowser(); invalidBrowser.wrongState = true
        let invalid = AccountSessionService(configuration: configuration, browser: invalidBrowser, transport: FakeTransport(), credentials: MemoryCredentials(), lifecycle: Lifecycle())
        await invalid.signIn()
        expect(invalid.state == .signedOut && invalid.presentationError == .invalidState, "wrong callback state never signs in")
        let inactive = AccountSessionService(configuration: nil, browser: FakeBrowser(), transport: FakeTransport(), credentials: MemoryCredentials())
        await inactive.restore(); await inactive.signIn()
        expect(inactive.state == .unconfigured && !inactive.isSignInAvailable, "absent config stays inactive")
        print("PASS: \(count) native account synthetic assertions; no real account, browser, Keychain, model or UI access")
    }
    @MainActor static func staleRefreshTest(_ configuration: AccountConfiguration) async {
        let transport = FakeTransport(), credentials = MemoryCredentials()
        let service = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: transport, credentials: credentials, lifecycle: Lifecycle())
        await service.signIn(); let old = service.context!
        await transport.holdRefresh()
        let refresh = Task { try await service.authorizedAccess(for: old) }
        await until { await transport.isRefreshWaiting }
        let logout = Task { await service.logout() }
        await until { service.generation != old.generation }
        expect(!service.isCurrent(old), "logout invalidates generation before joining")
        await transport.releaseRefresh(); await logout.value
        do { _ = try await refresh.value; fatalError("stale refresh accepted") } catch { count += 1 }
        expect(await credentials.load() == nil && service.state == .signedOut, "late refresh cannot resurrect logout")
        expect(await transport.revocations == ["rotated-refresh"], "late rotated grant revoked")
    }
    @MainActor static func staleSignInTest(_ configuration: AccountConfiguration) async {
        let transport = FakeTransport(), credentials = MemoryCredentials()
        await transport.holdExchange()
        let service = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: transport, credentials: credentials, lifecycle: Lifecycle())
        let signIn = Task { await service.signIn() }
        await until { await transport.isExchangeWaiting }
        let old = service.generation
        let logout = Task { await service.logout() }
        await until { service.generation != old }
        await transport.releaseExchange(); await logout.value; await signIn.value
        expect(await credentials.load() == nil && service.state == .signedOut, "late exchange cannot publish account")
        expect(await transport.revocations == ["initial-refresh"], "late exchange grant revoked")
    }
    @MainActor static func rotationLookupFailureTest(_ configuration: AccountConfiguration) async throws {
        let transport = FakeTransport(), credentials = MemoryCredentials()
        let service = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: transport, credentials: credentials, lifecycle: Lifecycle())
        await service.signIn(); let original = service.context!
        await transport.setAccountFailure(true)
        do { _ = try await service.authorizedAccess(for: original); fatalError("lookup failure accepted") } catch { count += 1 }
        expect(await credentials.load()?.refreshToken == "rotated-refresh", "rotation survives membership lookup failure")
        await transport.setAccountFailure(false)
        let access = try await service.authorizedAccess(for: original)
        expect(access.accessToken == "rotated", "retry validates already rotated access")
        expect(await transport.refreshes == 1, "lookup retry does not reuse consumed refresh")
        await service.logout()
    }
    @MainActor static func cleanupFailuresTest(_ configuration: AccountConfiguration) async throws {
        let credentials = MemoryCredentials(), lifecycle = Lifecycle(), policy = AccountRestorationPolicy()
        let service = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: FakeTransport(), credentials: credentials, lifecycle: lifecycle, restoration: policy)
        await service.signIn(); await credentials.setClearFailure(true)
        await service.logout()
        expect(!service.isSignInAvailable && !policy.isAllowed, "failed credential deletion blocks new admission and restore")
        await service.restore()
        expect(service.context == nil, "failed deletion cannot restore old grant")
        await credentials.setClearFailure(false); await service.logout()
        expect(service.isSignInAvailable, "explicit logout retry releases cleanup block")
        await service.signIn(); lifecycle.failTransition = true
        await service.logout()
        expect(!service.isSignInAvailable && service.context == nil, "failed profile cleanup blocks new account")
        lifecycle.failTransition = false; await service.logout()
        expect(service.isSignInAvailable, "profile cleanup retry succeeds")
    }
    @MainActor static func joinedFailedAdmissionTest(_ configuration: AccountConfiguration) async {
        let credentials = MemoryCredentials(), lifecycle = Lifecycle(), browser = FakeBrowser()
        await credentials.rejectSaves(); lifecycle.blockRollback = true
        let service = AccountSessionService(configuration: configuration, browser: browser, transport: FakeTransport(), credentials: credentials, lifecycle: lifecycle)
        let failed = Task { await service.signIn() }
        await until { lifecycle.rollbackGate != nil }
        let original = service.generation
        let logout = Task { await service.logout() }
        await until { service.generation != original }
        await service.signIn()
        expect(browser.requests == 1, "new login blocked while failed admission cleanup is joining")
        lifecycle.releaseRollback(); await failed.value; await logout.value
        expect(await credentials.load() == nil, "joined failed admission cannot leave stale credential")
        expect(service.state == .signedOut && service.isSignInAvailable, "joined cleanup finishes before admission reopens")
    }
    @MainActor static func restorationMarkerTest() throws {
        let suite = "account.synthetic." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = AccountRestorationPolicy(defaults: defaults, scope: "synthetic")
        try first.inhibit()
        let restarted = AccountRestorationPolicy(defaults: defaults, scope: "synthetic")
        expect(!restarted.isAllowed, "logout marker survives policy reconstruction")
        try restarted.permit()
        expect(first.isAllowed, "explicit completed login permits restoration")
    }
    @MainActor static func ambiguousRefreshRestartTest(_ configuration: AccountConfiguration) async throws {
        let suite = "account.synthetic." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let transport = FakeTransport(), credentials = MemoryCredentials()
        let policy = AccountRestorationPolicy(defaults: defaults, scope: "restart")
        let service = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: transport,
            credentials: credentials, lifecycle: Lifecycle(), restoration: policy)
        await service.signIn(); let context = service.context!
        await transport.setRefreshFailure(.reauthenticationRequired)
        do { _ = try await service.authorizedAccess(for: context); fatalError("ambiguous refresh accepted") } catch { count += 1 }
        expect(service.state == .reauthenticationRequired && !policy.isAllowed, "ambiguous refresh durably blocks restoration")
        let restart = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: transport,
            credentials: credentials, lifecycle: Lifecycle(), restoration: AccountRestorationPolicy(defaults: defaults, scope: "restart"))
        await restart.restore()
        expect(restart.context == nil && restart.state == .signedOut, "fresh service does not replay ambiguous grant")
        expect(await transport.refreshes == 1, "potentially consumed refresh token never replayed")
        await service.logout()
    }
    @MainActor static func shutdownDuringRestorationTest(_ configuration: AccountConfiguration) async {
        let credentials = MemoryCredentials(), policy = AccountRestorationPolicy()
        let initial = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: FakeTransport(), credentials: credentials, lifecycle: Lifecycle(), restoration: policy)
        await initial.signIn(); await initial.shutdown()
        let transport = FakeTransport(); await transport.holdRefresh()
        let restored = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: transport, credentials: credentials, lifecycle: Lifecycle(), restoration: policy)
        let restore = Task { await restored.restore() }
        await until { await transport.isRefreshWaiting }
        let shutdown = Task { await restored.shutdown() }
        await Task.yield(); await transport.releaseRefresh()
        await shutdown.value; await restore.value
        expect(await credentials.load()?.refreshToken == "rotated-refresh", "termination preserves restoration rotation")
        expect(policy.isAllowed, "joined restoration remains restartable")
    }
    @MainActor static func operationKindAfterLogoutTest(_ configuration: AccountConfiguration) async {
        let transport = FakeTransport(), credentials = MemoryCredentials(), browser = FakeBrowser()
        let seeded = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: FakeTransport(), credentials: credentials, lifecycle: Lifecycle())
        await seeded.signIn(); await seeded.shutdown()
        let service = AccountSessionService(configuration: configuration, browser: browser, transport: transport, credentials: credentials, lifecycle: Lifecycle())
        await transport.holdRefresh()
        let restore = Task { await service.restore() }
        await until { await transport.isRefreshWaiting }
        let prior = service.generation
        let logout = Task { await service.logout() }
        await until { service.generation != prior }
        await transport.releaseRefresh(); await logout.value; await restore.value
        await transport.holdAuthorization()
        let signIn = Task { await service.signIn() }
        await until { await transport.isAuthorizationWaiting }
        let shutdown = Task { await service.shutdown() }
        await Task.yield(); await transport.releaseAuthorization()
        await shutdown.value; await signIn.value
        expect(browser.requests == 0, "old restoration kind cannot open browser after shutdown")
        expect(await credentials.load() == nil, "cancelled post-logout admission persists no grant")
    }
    @MainActor static func browserPolicyAndSwitchTest(_ configuration: AccountConfiguration) async {
        expect(AccountBrowserSessionPolicy.sharedDevice.prefersEphemeralSession(requiresExplicitIdentity: false), "shared-device default ephemeral")
        expect(!AccountBrowserSessionPolicy.personalDevice.prefersEphemeralSession(requiresExplicitIdentity: false), "personal composition permits browser reuse")
        expect(AccountBrowserSessionPolicy.personalDevice.prefersEphemeralSession(requiresExplicitIdentity: true), "explicit switch requests ephemeral browser")
        let credentials = MemoryCredentials(), browser = FakeBrowser(), transport = FakeTransport()
        let service = AccountSessionService(configuration: configuration, browser: browser, transport: transport, credentials: credentials, lifecycle: Lifecycle())
        await service.signIn(); await service.switchPerson()
        expect(browser.explicitRequests == [false, true], "switch-person intent reaches browser")
        let query = URLComponents(url: browser.authorizationURLs.last!, resolvingAgainstBaseURL: false)!.queryItems!
        expect(query.filter { $0.name == "prompt" }.map(\.value) == ["login"], "switch has exactly one forced-login prompt")
        expect(query.contains { $0.name == "state" } && query.contains { $0.name == "nonce" } && query.contains { $0.name == "code_challenge" }, "switch preserves authorization attempt")
        expect(service.state == .signedOut && service.presentationError == .previousAccountReturned, "prior identity cannot silently reappear during person switch")
        expect(await credentials.load() == nil, "refused previous identity keeps guest credentials empty")
        await service.signIn(); await credentials.setClearFailure(true)
        let requestCount = browser.requests
        await service.switchPerson()
        expect(browser.requests == requestCount && !service.isSignInAvailable, "cleanup failure blocks switch-person browser")
        await credentials.setClearFailure(false); await service.logout()
    }
    @MainActor static func workspaceRefreshOwnershipTest(_ configuration: AccountConfiguration) async throws {
        // Exercise both scheduler resumptions repeatedly using production task ownership.
        for _ in 0..<16 {
            let transport = FakeTransport(), credentials = MemoryCredentials()
            await transport.setRefreshExpiry(Date().addingTimeInterval(-1))
            let service = AccountSessionService(configuration: configuration, browser: FakeBrowser(), transport: transport, credentials: credentials, lifecycle: Lifecycle())
            await service.signIn(); let original = service.context!
            await transport.holdRefresh()
            let access = Task { try await service.authorizedAccess(for: original) }
            await until { await transport.isRefreshWaiting }
            let switchWorkspace = Task { try await service.selectWorkspace(organizationID: "org", workspaceID: "workspace") }
            await Task.yield(); await transport.releaseRefresh()
            _ = try? await access.value; try await switchWorkspace.value
            await transport.setRefreshExpiry(Date().addingTimeInterval(3600))
            let selected = service.context!
            _ = try await service.authorizedAccess(for: selected)
            expect(await transport.refreshes == 2, "workspace switch cannot retain completed refresh")
            expect(await credentials.load()?.workspaceID == "workspace", "workspace keeps rotated owner grant")
            await service.logout()
        }
    }
    @MainActor static func transportTests(_ configuration: AccountConfiguration) async throws {
        let http = try FixtureHTTP()
        let transport = AccountHTTPTransport(configuration: configuration, http: http)
        let url = try await transport.authorizationURL(state: "state", nonce: "nonce", challenge: "challenge")
        let query = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!
        expect(query.first { $0.name == "code_challenge_method" }?.value == "S256", "system URL uses S256")
        expect(query.first { $0.name == "redirect_uri" }?.value == configuration.redirectURI.absoluteString, "exact registered redirect sent")
        expect(!query.contains { $0.name == "client_secret" }, "public client has no secret")
        _ = try await transport.account(accessToken: "synthetic-api-access")
        let accountRequest = await http.requests.last!
        expect(accountRequest.url!.path == "/api/v1/account" && accountRequest.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-api-access", "account endpoint uses API bearer")
        try await transport.revoke(refreshToken: "synthetic&refresh=token")
        let revokeRequest = await http.requests.last!
        let body = String(data: revokeRequest.httpBody!, encoding: .utf8)!
        expect(revokeRequest.url!.path == "/revoke" && body.contains("token_type_hint=refresh_token") && body.contains("synthetic%26refresh%3Dtoken"), "device revoke form escapes token")
        for endpoint in ["http://identity.example", "https://attacker.example", "https://identity.example:444", "https://user@identity.example", "https://identity.example/path?injected=true"] {
            let bad = AccountHTTPTransport(configuration: configuration, http: try FixtureHTTP(endpoint: endpoint))
            do { _ = try await bad.authorizationURL(state: "s", nonce: "n", challenge: "c"); fatalError("untrusted endpoint accepted") } catch { count += 1 }
        }
        await transport.shutdown()
    }
    @MainActor static func jwtTests() throws {
        let privateKey = SecKeyCreateRandomKey([kSecAttrKeyType: kSecAttrKeyTypeRSA, kSecAttrKeySizeInBits: 2048,
            kSecAttrIsPermanent: false] as CFDictionary, nil)!
        let publicKey = SecKeyCopyPublicKey(privateKey)!
        let der = SecKeyCopyExternalRepresentation(publicKey, nil)! as Data
        var cursor = 0
        func block(_ tag: UInt8) -> Data {
            precondition(der[cursor] == tag); cursor += 1
            var size = Int(der[cursor]); cursor += 1
            if size >= 128 { let digits = size & 127; size = 0; for _ in 0..<digits { size = size * 256 + Int(der[cursor]); cursor += 1 } }
            let data = der.subdata(in: cursor..<cursor+size); cursor += size; return data
        }
        _ = der[cursor]; cursor += 1
        let length = Int(der[cursor]); cursor += 1; if length >= 128 { cursor += length & 127 }
        let n = Data(block(2).drop(while: { $0 == 0 })), e = block(2)
        let keys = AccountJWTValidator.JWKSet(keys: [.init(kty: "RSA", kid: "synthetic", alg: "RS256", use: "sig", n: n.accountBase64URL, e: e.accountBase64URL, key_ops: ["verify"])])
        let now = Date().timeIntervalSince1970
        let payload: [String: Any] = ["iss": "https://identity.example/realms/test", "sub": "subject-a", "aud": "native-test", "nonce": "expected", "iat": now, "exp": now + 3600]
        func signed(_ claims: [String: Any], algorithm: String = "RS256") throws -> String {
            let header = try JSONSerialization.data(withJSONObject: ["kid": "synthetic", "alg": algorithm]).accountBase64URL
            let input = header + "." + (try JSONSerialization.data(withJSONObject: claims)).accountBase64URL
            let signature = SecKeyCreateSignature(privateKey, .rsaSignatureMessagePKCS1v15SHA256, Data(input.utf8) as CFData, nil)! as Data
            return input + "." + signature.accountBase64URL
        }
        let token = try signed(payload)
        func validate(_ token: String, nonce: String = "expected") throws {
            _ = try AccountJWTValidator.validate(token, keys: keys, issuer: "https://identity.example/realms/test", audience: "native-test", nonce: nonce, authorizedParty: "native-test")
        }
        try validate(token); count += 1
        reject("duplicate signing key identifier") {
            _ = try AccountJWTValidator.validate(token, keys: .init(keys: keys.keys + keys.keys), issuer: "https://identity.example/realms/test", audience: "native-test")
        }
        reject("unknown signing key") {
            _ = try AccountJWTValidator.validate(token, keys: .init(keys: []), issuer: "https://identity.example/realms/test", audience: "native-test")
        }
        reject("oversized token") { try validate(String(repeating: "a", count: 32769)) }
        reject("wrong nonce") { try validate(token, nonce: "wrong") }
        for pair: (String, Any) in [("iss", "https://attacker.example"), ("aud", "another-client"), ("exp", now - 100), ("iat", now + 100), ("exp", true)] {
            var changed = payload; changed[pair.0] = pair.1
            reject("invalid signed claim \(pair.0)") { try validate(signed(changed)) }
        }
        reject("algorithm confusion") { try validate(signed(payload, algorithm: "HS256")) }
        let pieces = token.split(separator: "."); let corrupt = pieces[0] + "." + pieces[1] + "." + Data(repeating: 0, count: 256).accountBase64URL
        reject("wrong signature") { try validate(String(corrupt)) }
    }
}
