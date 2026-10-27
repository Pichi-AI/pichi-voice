import Foundation

extension AccountSessionService {
    /// No credentials, browser or network operations occur until an explicit operation is admitted.
    /// Installing N2's lifecycle participant remains mandatory even with signed configuration.
    static func production(bundle: Bundle = .main, browserSessionPolicy: AccountBrowserSessionPolicy = .sharedDevice) -> AccountSessionService {
        let distribution = BrandDistribution.load(bundle: bundle)
        if let legacy = distribution.legacyAccount, legacy.bundleIdentifier == bundle.bundleIdentifier,
           let transport = try? LegacyAccountHTTPTransport(configuration: legacy) {
            return AccountSessionService(configuration: nil, browser: AccountSystemBrowser(policy: browserSessionPolicy),
                transport: UnconfiguredAccountTransport(), credentials: UnconfiguredAccountCredentials(),
                legacyConfiguration: legacy, legacyTransport: transport)
        }
        let candidate = distribution.account
        let schemes = (bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])?
            .flatMap { $0["CFBundleURLSchemes"] as? [String] ?? [] } ?? []
        let configuration = candidate.flatMap { value in
            value.bundleIdentifier == bundle.bundleIdentifier && schemes.contains(value.bundleIdentifier) ? value : nil
        }
        guard let configuration else {
            return AccountSessionService(configuration: nil, browser: AccountSystemBrowser(policy: browserSessionPolicy),
                transport: UnconfiguredAccountTransport(), credentials: UnconfiguredAccountCredentials())
        }
        return AccountSessionService(configuration: configuration, browser: AccountSystemBrowser(policy: browserSessionPolicy),
            transport: AccountHTTPTransport(configuration: configuration), credentials: AccountKeychainStore(configuration: configuration),
            restoration: AccountRestorationPolicy(defaults: .standard, scope: AccountKeychainStore.scope(configuration: configuration)))
    }
}

private nonisolated struct UnconfiguredAccountTransport: AccountTransporting {
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL { throw AccountError.unconfigured }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func account(accessToken: String) async throws -> AccountSnapshot { throw AccountError.unconfigured }
    func revoke(refreshToken: String) async throws { throw AccountError.unconfigured }
}
private nonisolated struct UnconfiguredAccountCredentials: AccountCredentialStoring {
    func load() async throws -> AccountGrant? { nil }
    func save(_ grant: AccountGrant) async throws { throw AccountError.unconfigured }
    func clear() async throws {}
}
