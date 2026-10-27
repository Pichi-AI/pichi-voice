import Foundation

typealias AccountConfiguration = BrandDistribution.AccountConfiguration
nonisolated enum AccountSessionState: String, Sendable {
    case unconfigured, signedOut, signingIn, signedIn, reauthenticationRequired
}

/// Stable identity comes from the verified grant and account endpoint, never email.
nonisolated struct AccountIdentity: Codable, Equatable, Sendable {
    let issuer: String
    let subject: String
    let internalUserID: String
    var legacyOrigin: String? = nil
    var isLegacySession: Bool { legacyOrigin != nil }
    var storageComponents: [String] {
        if let legacyOrigin { return ["legacy-session", legacyOrigin, internalUserID] }
        return [issuer, subject, internalUserID]
    }
    static func legacy(origin: URL, internalUserID: String) -> Self {
        .init(issuer: "", subject: "", internalUserID: internalUserID, legacyOrigin: origin.absoluteString)
    }
}

/// Frozen admission context. A generation is process-local and changes at every boundary.
nonisolated struct AccountContext: Equatable, Sendable {
    let identity: AccountIdentity
    let organizationID: String?
    let workspaceID: String?
    let generation: UUID
}

nonisolated struct AccountSnapshot: Codable, Equatable, Sendable {
    struct User: Codable, Equatable, Sendable { let id: String; let displayName: String; let email: String? }
    struct ExternalIdentity: Codable, Equatable, Sendable {
        let issuer: String
        let subject: String
        var legacyOrigin: String? = nil
    }
    struct Workspace: Codable, Equatable, Sendable { let id: String; let name: String; let capabilities: [String] }
    struct Organization: Codable, Equatable, Sendable { let id: String; let name: String; let workspaces: [Workspace] }
    let schemaVersion: Int
    let account: User
    let identity: ExternalIdentity
    let organizations: [Organization]
    var activeOrganizationID: String? = nil

    var stableIdentity: AccountIdentity {
        .init(issuer: identity.issuer, subject: identity.subject, internalUserID: account.id, legacyOrigin: identity.legacyOrigin)
    }

    func validate(issuer: String, subject: String) throws {
        func valid(_ id: String) -> Bool { !id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && id.utf8.count <= 512 }
        guard schemaVersion == 1, identity.legacyOrigin == nil, identity.issuer == issuer, identity.subject == subject,
              valid(account.id), organizations.count <= 100,
              Set(organizations.map(\.id)).count == organizations.count else { throw AccountError.invalidAccount }
        for organization in organizations {
            guard valid(organization.id), organization.workspaces.count <= 1000,
                  Set(organization.workspaces.map(\.id)).count == organization.workspaces.count,
                  organization.workspaces.allSatisfy({ valid($0.id) && $0.capabilities.count <= 100 }) else {
                throw AccountError.invalidAccount
            }
        }
    }

    func contains(organizationID: String, workspaceID: String) -> Bool {
        organizations.contains { $0.id == organizationID && $0.workspaces.contains { $0.id == workspaceID } }
    }
}

/// Presentation-safe codes. UI owners localize these without exposing provider responses.
nonisolated enum AccountError: String, Error, Sendable {
    case unconfigured, isolationRequired, busy, cancelled, invalidCallback, invalidState
    case invalidToken, invalidAccount, invalidConfiguration, invalidResponse
    case credentialsUnavailable, networkUnavailable, reauthenticationRequired, permissionDenied
    case workspaceUnavailable, staleOperation, revocationUnavailable, previousAccountReturned
    case captchaRequired, browserLoginRequired, rateLimited
}

/// Credentials never enter ObservableObject/UI projections, logs or provider API-key storage.
nonisolated struct AccountGrant: Codable, Sendable {
    let identity: AccountIdentity
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let nonce: String
    var organizationID: String?
    var workspaceID: String?
}

nonisolated struct AccountTokenResponse: Sendable {
    let accessToken: String
    let refreshToken: String
    let expiresAt: Date
    let subject: String
}

@MainActor protocol AccountBrowserAuthenticating: AnyObject {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL
    func authenticate(url: URL, callbackScheme: String, requiresExplicitIdentity: Bool) async throws -> URL
    func cancel()
}

nonisolated protocol AccountCredentialStoring: Sendable {
    func load() async throws -> AccountGrant?
    func save(_ grant: AccountGrant) async throws
    func clear() async throws
}

nonisolated protocol AccountTransporting: Sendable {
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse
    func account(accessToken: String) async throws -> AccountSnapshot
    func revoke(refreshToken: String) async throws
    func shutdown() async
}

/// N2 supplies this boundary after all user-data paths are isolated. Calls must cancel/join
/// account-owned work and finish selecting the new local profile before returning.
@MainActor protocol AccountSessionLifecycle: AnyObject {
    var isAccountIsolationReady: Bool { get }
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async throws
}

/// Only the transport consumer receives the bearer; it is bound to a frozen owner/generation.
nonisolated struct AccountAuthorizedAccess: Sendable {
    let context: AccountContext
    let accessToken: String
}

extension AccountTransporting { nonisolated func shutdown() async {} }

/// Composition chooses this policy. Appearance imports and account payloads cannot change it.
nonisolated enum AccountBrowserSessionPolicy: Sendable {
    case sharedDevice, personalDevice
    func prefersEphemeralSession(requiresExplicitIdentity: Bool) -> Bool {
        self == .sharedDevice || requiresExplicitIdentity
    }
}

extension AccountBrowserAuthenticating {
    /// Source-compatible injected adapters receive the already-forced-login URL. Production
    /// overrides this overload to also freeze its system-browser session policy per attempt.
    func authenticate(url: URL, callbackScheme: String, requiresExplicitIdentity: Bool) async throws -> URL {
        try await authenticate(url: url, callbackScheme: callbackScheme)
    }
}
