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
    var refreshes = 0
    var revocations: [String] = []
    var failAccount = false
    var blockRefresh = false
    var blockExchange = false
    var refreshGate: CheckedContinuation<Void, Never>?
    var exchangeGate: CheckedContinuation<Void, Never>?
    var initialExpiry = Date().addingTimeInterval(-1)
    var snapshot = fixtureSnapshot()
    func authorizationURL(state: String, nonce: String, challenge: String) -> URL {
        URL(string: "https://identity.example/auth?state=\(state)&nonce=\(nonce)&code_challenge=\(challenge)")!
    }
    func exchange(code: String, verifier: String, nonce: String) async -> AccountTokenResponse {
        if blockExchange { await withCheckedContinuation { exchangeGate = $0 } }
        return .init(accessToken: "initial", refreshToken: "initial-refresh", expiresAt: initialExpiry, subject: "subject-a")
    }
    func refresh(_ grant: AccountGrant) async -> AccountTokenResponse {
        refreshes += 1
        if blockRefresh { await withCheckedContinuation { refreshGate = $0 } }
        return .init(accessToken: "rotated", refreshToken: "rotated-refresh", expiresAt: Date().addingTimeInterval(3600), subject: "subject-a")
    }
    func account(accessToken: String) throws -> AccountSnapshot { if failAccount { throw AccountError.networkUnavailable }; return snapshot }
    func setAccountFailure(_ value: Bool) { failAccount = value }
    func revoke(refreshToken: String) { revocations.append(refreshToken) }
    func holdRefresh() { blockRefresh = true }
    func holdExchange() { blockExchange = true }
    func releaseRefresh() { blockRefresh = false; refreshGate?.resume(); refreshGate = nil }
    func releaseExchange() { blockExchange = false; exchangeGate?.resume(); exchangeGate = nil }
    var isExchangeWaiting: Bool { exchangeGate != nil }
    var isRefreshWaiting: Bool { refreshGate != nil }
}
@MainActor private final class FakeBrowser: AccountBrowserAuthenticating {
    var wrongState = false
    var requests = 0
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        requests += 1
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        return URL(string: callbackScheme + ":/oauth/callback?code=synthetic-code&state=" + (wrongState ? "wrong" : state))!
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
