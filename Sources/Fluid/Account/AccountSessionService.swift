import Combine
import Foundation

/// One operation owner for mobile and desktop. Guest recording has no dependency on this service.
@MainActor final class AccountSessionService: ObservableObject {
    @Published private(set) var state: AccountSessionState
    @Published private(set) var account: AccountSnapshot?
    @Published private(set) var context: AccountContext?
    @Published private(set) var presentationError: AccountError?
    @Published private(set) var generation = UUID()
    let configuration: AccountConfiguration?
    private let browser: any AccountBrowserAuthenticating
    private let transport: any AccountTransporting
    private let credentials: any AccountCredentialStoring
    private let restoration: AccountRestorationPolicy
    private var lifecycle: (any AccountSessionLifecycle)?
    private var grant: AccountGrant?
    private var operation: Task<Void, Error>?
    private var operationID: UUID?
    private var refreshTask: Task<AccountGrant, Error>?
    private var refreshID: UUID?
    private var logoutTask: Task<Void, Never>?
    private var boundaryInProgress = false
    private var cleanupRequired = false
    private var requiresAccountValidation = false
    private var latestDeviceRefreshToken: String?

    var isSignInAvailable: Bool {
        configuration != nil && lifecycle?.isAccountIsolationReady == true && !boundaryInProgress && !cleanupRequired
    }

    init(configuration: AccountConfiguration?, browser: any AccountBrowserAuthenticating,
         transport: any AccountTransporting, credentials: any AccountCredentialStoring,
         lifecycle: (any AccountSessionLifecycle)? = nil, restoration: AccountRestorationPolicy? = nil) {
        self.configuration = configuration; self.browser = browser; self.transport = transport
        self.credentials = credentials; self.lifecycle = lifecycle; self.restoration = restoration ?? AccountRestorationPolicy()
        self.state = configuration == nil ? .unconfigured : .signedOut
    }

    /// Composition-only handoff. UI must never manufacture an isolation participant.
    func installLifecycle(_ lifecycle: any AccountSessionLifecycle) throws {
        guard self.lifecycle == nil, operation == nil, refreshTask == nil, grant == nil, !boundaryInProgress else { throw AccountError.busy }
        self.lifecycle = lifecycle
    }

    func signIn() async {
        if state == .reauthenticationRequired { await logout() }
        guard let configuration else { presentationError = .unconfigured; return }
        guard isSignInAvailable else { presentationError = cleanupRequired ? .credentialsUnavailable : .isolationRequired; return }
        guard operation == nil, grant == nil else { presentationError = .busy; return }
        presentationError = nil; state = .signingIn; generation = UUID()
        let captured = generation, id = UUID()
        let task = Task { @MainActor in
            do {
                let attempt = try AccountAuthorizationAttempt(redirectURI: configuration.redirectURI)
                let url = try await self.transport.authorizationURL(state: attempt.state, nonce: attempt.nonce, challenge: attempt.challenge)
                try self.check(captured)
                let callback = try await self.browser.authenticate(url: url, callbackScheme: configuration.bundleIdentifier)
                try self.check(captured)
                let token = try await self.transport.exchange(code: attempt.code(from: callback), verifier: attempt.verifier, nonce: attempt.nonce)
                self.latestDeviceRefreshToken = token.refreshToken
                try self.check(captured)
                let snapshot = try await self.transport.account(accessToken: token.accessToken)
                try snapshot.validate(issuer: configuration.issuer.absoluteString, subject: token.subject)
                try self.check(captured)
                let next = AccountGrant(identity: snapshot.stableIdentity, accessToken: token.accessToken,
                    refreshToken: token.refreshToken, expiresAt: token.expiresAt, nonce: attempt.nonce)
                try await self.credentials.save(next)
                try self.check(captured)
                let nextContext = AccountContext(identity: next.identity, organizationID: nil, workspaceID: nil, generation: captured)
                try await self.lifecycle?.transition(from: nil, to: nextContext, generation: captured)
                try self.check(captured)
                try self.restoration.permit()
                self.grant = next; self.account = snapshot; self.context = nextContext; self.state = .signedIn
            } catch {
                // Cleanup is part of the joined operation. Logout cannot finish while it is suspended.
                if self.generation == captured { await self.failedAdmission(error, generation: captured) }
                throw error
            }
        }
        operation = task; operationID = id
        _ = try? await task.value
        if operationID == id { operation = nil; operationID = nil }
    }

    /// Explicit startup operation, only after N2 has installed the safe profile boundary.
    func restore() async {
        guard let configuration, isSignInAvailable, restoration.isAllowed, operation == nil, grant == nil else { return }
        let captured = generation, id = UUID()
        let task = Task { @MainActor in
            do {
                guard let saved = try await self.credentials.load() else { return }
                try self.check(captured)
                guard saved.identity.issuer == configuration.issuer.absoluteString else { throw AccountError.invalidAccount }
                let response = try await self.transport.refresh(saved)
                self.latestDeviceRefreshToken = response.refreshToken
                try self.check(captured)
                guard response.subject == saved.identity.subject else { throw AccountError.invalidToken }
                var next = self.rotated(saved, response)
                // Persist rotation before any subsequent network request can fail.
                try await self.credentials.save(next)
                try self.check(captured)
                let snapshot = try await self.transport.account(accessToken: next.accessToken)
                try snapshot.validate(issuer: saved.identity.issuer, subject: saved.identity.subject)
                guard snapshot.stableIdentity == saved.identity else { throw AccountError.invalidAccount }
                try self.check(captured)
                if let org = next.organizationID, let workspace = next.workspaceID,
                   !snapshot.contains(organizationID: org, workspaceID: workspace) {
                    next.organizationID = nil; next.workspaceID = nil
                    try await self.credentials.save(next)
                    try self.check(captured)
                }
                let nextContext = AccountContext(identity: next.identity, organizationID: next.organizationID,
                    workspaceID: next.workspaceID, generation: captured)
                try await self.lifecycle?.transition(from: nil, to: nextContext, generation: captured)
                try self.check(captured)
                self.grant = next; self.account = snapshot; self.context = nextContext; self.state = .signedIn
            } catch {
                if self.generation == captured {
                    if [.reauthenticationRequired, .invalidToken, .invalidAccount, .credentialsUnavailable].contains(self.sanitized(error)) {
                        do { try self.restoration.inhibit() } catch { self.cleanupRequired = true }
                        if self.sanitized(error) == .credentialsUnavailable { self.cleanupRequired = true }
                    }
                    // There is no exposed account until full validation and profile selection complete.
                    // Keep a successfully rotated grant for an explicit retry, but roll back local profile.
                    do { try await self.lifecycle?.transition(from: nil, to: nil, generation: captured) }
                    catch { self.cleanupRequired = true }
                    if self.generation == captured {
                        self.state = .reauthenticationRequired; self.presentationError = self.sanitized(error)
                    }
                }
                throw error
            }
        }
        operation = task; operationID = id
        _ = try? await task.value
        if operationID == id { operation = nil; operationID = nil }
    }

    func cancelSignIn() async {
        guard state == .signingIn else { return }
        await logout()
        if !cleanupRequired { presentationError = nil }
    }

    func selectWorkspace(organizationID: String, workspaceID: String) async throws {
        guard !boundaryInProgress, !cleanupRequired, operation == nil, state == .signedIn,
              let account, grant != nil, let oldContext = context else { throw AccountError.busy }
        guard account.contains(organizationID: organizationID, workspaceID: workspaceID) else { throw AccountError.workspaceUnavailable }
        let id = UUID()
        let task = Task { @MainActor in
            // Complete an admitted rotation before freezing the replacement workspace grant.
            if let refresh = self.refreshTask {
                _ = try await refresh.value
                self.refreshTask = nil; self.refreshID = nil
            }
            try Task.checkCancellation()
            guard var next = self.grant else { throw AccountError.staleOperation }
            self.generation = UUID()
            let captured = self.generation
            next.organizationID = organizationID; next.workspaceID = workspaceID
            let nextContext = AccountContext(identity: next.identity, organizationID: organizationID, workspaceID: workspaceID, generation: captured)
            do {
                try await self.credentials.save(next)
                try self.check(captured)
                try await self.lifecycle?.transition(from: oldContext, to: nextContext, generation: captured)
                try self.check(captured)
                self.grant = next; self.context = nextContext
            } catch {
                if self.generation == captured { await self.failedAdmission(error, generation: captured) }
                throw error
            }
        }
        operation = task; operationID = id
        do { try await task.value }
        catch { if operationID == id { operation = nil; operationID = nil }; throw error }
        if operationID == id { operation = nil; operationID = nil }
    }

    /// N2 checks this immutable context again before accepting a transfer result.
    func authorizedAccess(for expected: AccountContext) async throws -> AccountAuthorizedAccess {
        guard !boundaryInProgress, !cleanupRequired, operation == nil, state == .signedIn,
              expected == context, let current = grant else { throw AccountError.staleOperation }
        let needsRefresh = current.expiresAt.timeIntervalSinceNow <= 60 || requiresAccountValidation
        let validated = needsRefresh ? try await refresh(current) : current
        try check(expected.generation)
        guard expected == context else { throw AccountError.staleOperation }
        return AccountAuthorizedAccess(context: expected, accessToken: validated.accessToken)
    }

    private func refresh(_ current: AccountGrant) async throws -> AccountGrant {
        if let refreshTask { return try await refreshTask.value }
        let captured = generation, id = UUID()
        let task = Task { @MainActor in
            do {
                self.requiresAccountValidation = true
                var next = current
                if current.expiresAt.timeIntervalSinceNow <= 60 {
                    let response = try await self.transport.refresh(current)
                    self.latestDeviceRefreshToken = response.refreshToken
                    try self.check(captured)
                    guard response.subject == current.identity.subject else { throw AccountError.invalidToken }
                    next = self.rotated(current, response)
                    try await self.credentials.save(next)
                    try self.check(captured)
                    self.grant = next
                }
                let snapshot = try await self.transport.account(accessToken: next.accessToken)
                try snapshot.validate(issuer: current.identity.issuer, subject: current.identity.subject)
                guard snapshot.stableIdentity == current.identity else { throw AccountError.invalidAccount }
                if let org = current.organizationID, let workspace = current.workspaceID,
                   !snapshot.contains(organizationID: org, workspaceID: workspace) { throw AccountError.permissionDenied }
                try self.check(captured)
                self.account = snapshot; self.requiresAccountValidation = false
                return next
            } catch {
                if self.generation == captured {
                    self.presentationError = self.sanitized(error)
                    if [.reauthenticationRequired, .invalidToken, .invalidAccount, .permissionDenied, .credentialsUnavailable].contains(self.presentationError!) {
                        self.state = .reauthenticationRequired
                        do { try self.restoration.inhibit() } catch { self.cleanupRequired = true }
                    }
                }
                throw error
            }
        }
        refreshTask = task; refreshID = id
        do { let result = try await task.value; if refreshID == id { refreshTask = nil; refreshID = nil }; return result }
        catch { if refreshID == id { refreshTask = nil; refreshID = nil }; throw error }
    }

    /// Device logout only. Concurrent callers join the same cleanup. A durable nonsecret marker
    /// prevents a failed Keychain deletion from restoring a deliberately logged-out grant on restart.
    func logout() async {
        if let logoutTask { await logoutTask.value; return }
        boundaryInProgress = true; generation = UUID()
        let task = Task { @MainActor in await self.performLogout() }
        logoutTask = task
        await task.value
        logoutTask = nil; boundaryInProgress = false
    }

    private func performLogout() async {
        let previousContext = context, previousGrant = grant, captured = generation
        presentationError = nil
        var restorationFailed = false
        do { try restoration.inhibit() } catch { restorationFailed = true }
        browser.cancel(); operation?.cancel(); refreshTask?.cancel()
        _ = try? await operation?.value; _ = try? await refreshTask?.value
        operation = nil; operationID = nil; refreshTask = nil
        cleanupRequired = restorationFailed
        if restorationFailed { presentationError = .credentialsUnavailable }
        let persisted = try? await credentials.load()
        let revokeToken = latestDeviceRefreshToken ?? (persisted ?? previousGrant)?.refreshToken
        grant = nil; context = nil; account = nil; requiresAccountValidation = false
        state = configuration == nil ? .unconfigured : .signedOut
        do { try await lifecycle?.transition(from: previousContext, to: nil, generation: captured) }
        catch { cleanupRequired = true; presentationError = sanitized(error) }
        do { try await credentials.clear() }
        catch { cleanupRequired = true; presentationError = .credentialsUnavailable }
        if let revokeToken {
            do { try await transport.revoke(refreshToken: revokeToken) }
            catch { if presentationError == nil { presentationError = .revocationUnavailable } }
        }
        latestDeviceRefreshToken = nil
    }

    /// Termination joins account work and closes only this service's HTTP session. Persisted grant remains.
    func shutdown() async {
        if let logoutTask { await logoutTask.value }
        boundaryInProgress = true
        browser.cancel(); operation?.cancel()
        // A verified refresh response must finish persisting its rotation before termination.
        // Network time is bounded by the owned HTTP session. No new requests are admitted.
        _ = try? await operation?.value; _ = try? await refreshTask?.value
        generation = UUID()
        operation = nil; operationID = nil; refreshTask = nil; refreshID = nil
        try? await lifecycle?.transition(from: context, to: nil, generation: generation)
        await transport.shutdown()
    }

    func isCurrent(_ context: AccountContext) -> Bool {
        !boundaryInProgress && !cleanupRequired && operation == nil && state == .signedIn && self.context == context
    }

    private func failedAdmission(_ error: Error, generation captured: UUID) async {
        let failure = sanitized(error)
        do { try restoration.inhibit() } catch { cleanupRequired = true }
        do { try await lifecycle?.transition(from: context, to: nil, generation: captured) }
        catch { cleanupRequired = true }
        do { try await credentials.clear() } catch { cleanupRequired = true }
        if let token = latestDeviceRefreshToken { try? await transport.revoke(refreshToken: token) }
        guard generation == captured else { return }
        latestDeviceRefreshToken = nil; grant = nil; context = nil; account = nil
        state = .signedOut; presentationError = cleanupRequired ? .credentialsUnavailable : failure
    }
    private func rotated(_ prior: AccountGrant, _ token: AccountTokenResponse) -> AccountGrant {
        AccountGrant(identity: prior.identity, accessToken: token.accessToken, refreshToken: token.refreshToken,
            expiresAt: token.expiresAt, nonce: prior.nonce, organizationID: prior.organizationID, workspaceID: prior.workspaceID)
    }
    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw AccountError.staleOperation }
    }
    private func sanitized(_ error: Error) -> AccountError {
        if error is CancellationError { return .cancelled }
        return error as? AccountError ?? .networkUnavailable
    }
}

/// Explicit logout is durable even when Keychain is locked. Production injects its own scoped
/// defaults; a nil defaults dependency is the in-memory policy used by synthetic service tests.
@MainActor final class AccountRestorationPolicy {
    private let defaults: UserDefaults?
    private let key: String
    private var inhibited = false
    init(defaults: UserDefaults? = nil, scope: String = "") { self.defaults = defaults; self.key = "account.logout." + scope }
    var isAllowed: Bool { !(defaults?.bool(forKey: key) ?? inhibited) }
    func inhibit() throws { try set(true) }
    func permit() throws { try set(false) }
    private func set(_ value: Bool) throws {
        inhibited = value
        if let defaults {
            defaults.set(value, forKey: key)
            guard defaults.synchronize(), defaults.bool(forKey: key) == value else { throw AccountError.credentialsUnavailable }
        }
    }
}
