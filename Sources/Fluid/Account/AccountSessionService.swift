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
    let legacyConfiguration: LegacyAccountConfiguration?
    private let legacyTransport: (any LegacyAccountTransporting)?
    private let legacyCredentials: (any LegacyAccountSessionStoring)?
    private var legacyStoredSession: LegacyAccountStoredSession?
    private var pendingLegacySession: LegacyAccountStoredSession?
    private var legacyProtectedRollbackRequired = false
    @Published private(set) var isAwaitingProtectedData = false
    @Published private(set) var isAwaitingLegacyServerValidation = false
    private var legacySessionActive = false
    // A wake is only a hint. All account validation paths share this server floor.
    private var legacyValidationRetryNotBefore: (generation: UUID, date: Date)?
    private var legacyRemoteRevocationRequested = false
    var isConfigured: Bool { configuration != nil || legacyConfiguration != nil }
    var isLegacySession: Bool { legacyConfiguration != nil }
    var legacyLogoutRevokesAllSessions: Bool { isLegacySession }
    var publicationConfiguration: AccountPublicationConfiguration? {
        if let legacyConfiguration { return .legacy(legacyConfiguration) }
        return configuration.map(AccountPublicationConfiguration.oidc)
    }
    private let browser: any AccountBrowserAuthenticating
    private let transport: any AccountTransporting
    private let credentials: any AccountCredentialStoring
    private let restoration: AccountRestorationPolicy
    private var lifecycle: (any AccountSessionLifecycle)?
    private var grant: AccountGrant?
    private enum OperationKind { case admission, restoration, workspace }
    private struct OwnedOperation {
        let id: UUID
        let kind: OperationKind
        let task: Task<Void, Error>
    }
    private var ownedOperation: OwnedOperation? { didSet { objectWillChange.send() } }
    /// Owns the complete user command, including any pre-admission logout. It is
    /// deliberately outside ownedOperation because the logout boundary joins that slot.
    private struct AuthenticationCommand {
        let id: UUID
        let task: Task<Void, Never>
    }
    private var authenticationCommand: AuthenticationCommand? { didSet { objectWillChange.send() } }
    private var isShuttingDown = false
    private var refreshTask: Task<AccountGrant, Error>?
    private var refreshID: UUID?
    private var logoutTask: Task<Void, Never>?
    // Availability (isSignInAvailable, isCurrent) is read by views that stay open across a sign-in or
    // workspace boundary; these flags redraw them when the boundary settles.
    private var boundaryInProgress = false { didSet { objectWillChange.send() } }
    private var cleanupRequired = false { didSet { objectWillChange.send() } }
    private var requiresAccountValidation = false
    private var latestDeviceRefreshToken: String?

    private var canAdmitSignIn: Bool {
        isConfigured && lifecycle?.isAccountIsolationReady == true
            && !boundaryInProgress && !cleanupRequired && !isShuttingDown
    }
    var isSignInAvailable: Bool { canAdmitSignIn && authenticationCommand == nil }

    init(configuration: AccountConfiguration?, browser: any AccountBrowserAuthenticating,
         transport: any AccountTransporting, credentials: any AccountCredentialStoring,
         lifecycle: (any AccountSessionLifecycle)? = nil, restoration: AccountRestorationPolicy? = nil,
         legacyConfiguration: LegacyAccountConfiguration? = nil, legacyTransport: (any LegacyAccountTransporting)? = nil,
         legacyCredentials: (any LegacyAccountSessionStoring)? = nil) {
        self.configuration = configuration; self.browser = browser; self.transport = transport
        self.legacyConfiguration = legacyConfiguration; self.legacyTransport = legacyTransport
        self.legacyCredentials = legacyCredentials
        self.credentials = credentials; self.lifecycle = lifecycle; self.restoration = restoration ?? AccountRestorationPolicy()
        self.state = configuration == nil && legacyConfiguration == nil ? .unconfigured : .signedOut
    }

    /// Composition-only handoff. UI must never manufacture an isolation participant.
    func installLifecycle(_ lifecycle: any AccountSessionLifecycle) throws {
        guard self.lifecycle == nil, authenticationCommand == nil, ownedOperation == nil,
              refreshTask == nil, grant == nil, !boundaryInProgress, !isShuttingDown else { throw AccountError.busy }
        self.lifecycle = lifecycle
    }

    func signIn() async {
        if isLegacySession { presentationError = .reauthenticationRequired; return }
        let reauthentication = state == .reauthenticationRequired
        await runAuthenticationCommand(logoutFirst: reauthentication,
            requiresExplicitIdentity: reauthentication, excluding: nil)
    }

    /// Explicit person switch requests a fresh browser interaction and rejects the prior
    /// verified identity if a federated provider nevertheless returns it without a choice.
    func switchPerson() async {
        if isLegacySession { await retireLegacySession(); return }
        let previousIdentity = context?.identity ?? grant?.identity
        await runAuthenticationCommand(logoutFirst: true,
            requiresExplicitIdentity: true, excluding: previousIdentity)
    }

    private func runAuthenticationCommand(logoutFirst: Bool, requiresExplicitIdentity: Bool,
                                          excluding previousIdentity: AccountIdentity?) async {
        guard !Task.isCancelled else { return }
        guard authenticationCommand == nil, !isShuttingDown else { presentationError = .busy; return }
        let id = UUID()
        let task = Task { @MainActor in
            guard !Task.isCancelled else { return }
            // Internal cleanup never joins this encompassing command, avoiding a self-cycle.
            if logoutFirst { await self.logoutSession() }
            guard !Task.isCancelled, self.authenticationCommand?.id == id else { return }
            await self.beginSignIn(requiresExplicitIdentity: requiresExplicitIdentity, excluding: previousIdentity)
            if Task.isCancelled { await self.logoutSession() }
        }
        authenticationCommand = AuthenticationCommand(id: id, task: task)
        // Cancellation must reach the concrete task synchronously. A queued actor callback
        // could otherwise run after this command has admitted or a replacement has started.
        await withTaskCancellationHandler {
            await task.value
        } onCancel: { task.cancel() }
        if authenticationCommand?.id == id { authenticationCommand = nil }
    }

    private func beginSignIn(requiresExplicitIdentity: Bool, excluding previousIdentity: AccountIdentity?) async {
        guard !Task.isCancelled else { return }
        guard let configuration else { presentationError = .unconfigured; return }
        guard canAdmitSignIn else { presentationError = cleanupRequired ? .credentialsUnavailable : .isolationRequired; return }
        guard ownedOperation == nil, grant == nil else { presentationError = .busy; return }
        presentationError = nil; state = .signingIn; generation = UUID()
        let captured = generation, id = UUID()
        let task = Task { @MainActor in
            do {
                try self.check(captured)
                let attempt = try AccountAuthorizationAttempt(redirectURI: configuration.redirectURI)
                var url = try await self.transport.authorizationURL(state: attempt.state, nonce: attempt.nonce, challenge: attempt.challenge)
                if requiresExplicitIdentity {
                    guard var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { throw AccountError.invalidConfiguration }
                    components.queryItems = (components.queryItems ?? []).filter { $0.name != "prompt" }
                        + [URLQueryItem(name: "prompt", value: "login")]
                    guard let explicitURL = components.url else { throw AccountError.invalidConfiguration }
                    url = explicitURL
                }
                try self.check(captured)
                let callback = try await self.browser.authenticate(url: url, callbackScheme: configuration.bundleIdentifier,
                    requiresExplicitIdentity: requiresExplicitIdentity)
                try self.check(captured)
                let token = try await self.transport.exchange(code: attempt.code(from: callback), verifier: attempt.verifier, nonce: attempt.nonce)
                self.latestDeviceRefreshToken = token.refreshToken
                try self.check(captured)
                let snapshot = try await self.transport.account(accessToken: token.accessToken)
                try snapshot.validate(issuer: configuration.issuer.absoluteString, subject: token.subject)
                if let previousIdentity, snapshot.identity.issuer == previousIdentity.issuer,
                   snapshot.identity.subject == previousIdentity.subject { throw AccountError.previousAccountReturned }
                try self.check(captured)
                let workspace = self.initialWorkspace(in: snapshot)
                let next = AccountGrant(identity: snapshot.stableIdentity, accessToken: token.accessToken,
                    refreshToken: token.refreshToken, expiresAt: token.expiresAt, nonce: attempt.nonce,
                    organizationID: workspace?.organizationID, workspaceID: workspace?.workspaceID)
                try await self.credentials.save(next)
                try self.check(captured)
                let nextContext = AccountContext(identity: next.identity, organizationID: next.organizationID,
                    workspaceID: next.workspaceID, generation: captured)
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
        ownedOperation = OwnedOperation(id: id, kind: .admission, task: task)
        await withTaskCancellationHandler {
            _ = try? await task.value
        } onCancel: { task.cancel() }
        if ownedOperation?.id == id { ownedOperation = nil }
    }

    /// Explicit startup operation, only after N2 has installed the safe profile boundary.
    func restore() async {
        if isLegacySession { await restoreLegacySession(); return }
        guard let configuration, isSignInAvailable, restoration.isAllowed, ownedOperation == nil, grant == nil else { return }
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
        ownedOperation = OwnedOperation(id: id, kind: .restoration, task: task)
        _ = try? await task.value
        if ownedOperation?.id == id { ownedOperation = nil }
    }

    func cancelSignIn() async {
        guard authenticationCommand != nil || state == .signingIn else { return }
        if isLegacySession { await retireLegacySession() } else { await logout() }
        if !cleanupRequired { presentationError = nil }
    }

    func selectWorkspace(organizationID: String, workspaceID: String) async throws {
        if isLegacySession { try await selectLegacyWorkspace(organizationID: organizationID, workspaceID: workspaceID); return }
        guard !isShuttingDown, authenticationCommand == nil, !boundaryInProgress,
              !cleanupRequired, ownedOperation == nil, state == .signedIn,
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
        ownedOperation = OwnedOperation(id: id, kind: .workspace, task: task)
        do { try await task.value }
        catch { if ownedOperation?.id == id { ownedOperation = nil }; throw error }
        if ownedOperation?.id == id { ownedOperation = nil }
    }

    /// N2 checks this immutable context again before accepting a transfer result.
    func authorizedAccess(for expected: AccountContext) async throws -> AccountAuthorizedAccess {
        guard !isLegacySession else { throw AccountError.invalidState }
        guard !isShuttingDown, authenticationCommand == nil, !boundaryInProgress,
              !cleanupRequired, ownedOperation == nil, state == .signedIn,
              expected == context, let current = grant else { throw AccountError.staleOperation }
        let needsRefresh = current.expiresAt.timeIntervalSinceNow <= 60 || requiresAccountValidation
        let validated = needsRefresh ? try await refresh(current) : current
        try check(expected.generation)
        guard !isShuttingDown, authenticationCommand == nil, expected == context else { throw AccountError.staleOperation }
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
    func logout() async { await retireSession(revokeLegacyRemote: true) }

    /// Disconnect this device without invoking the server endpoint that revokes all
    /// devices. Used by reconnect, cancellation and the explicit guest continuation.
    func retireLegacySession() async {
        guard isLegacySession else { return }
        await retireSession(revokeLegacyRemote: false)
    }

    private func retireSession(revokeLegacyRemote: Bool) async {
        let command = authenticationCommand
        command?.task.cancel()
        await logoutSession(revokeLegacyRemote: revokeLegacyRemote)
        await command?.task.value
        if let command, authenticationCommand?.id == command.id { authenticationCommand = nil }
    }

    /// Joined profile/credential cleanup only. This must never await authenticationCommand:
    /// that command may itself be suspended on this logout task during its preflight.
    private func logoutSession(revokeLegacyRemote: Bool = true) async {
        if revokeLegacyRemote { legacyRemoteRevocationRequested = true }
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
        browser.cancel(); ownedOperation?.task.cancel(); refreshTask?.cancel()
        _ = try? await ownedOperation?.task.value; _ = try? await refreshTask?.value
        ownedOperation = nil; refreshTask = nil
        cleanupRequired = restorationFailed
        if restorationFailed { presentationError = .credentialsUnavailable }
        let persisted = try? await credentials.load()
        let revokeToken = latestDeviceRefreshToken ?? (persisted ?? previousGrant)?.refreshToken
        grant = nil; context = nil; account = nil; requiresAccountValidation = false
        legacyStoredSession = nil; pendingLegacySession = nil; isAwaitingLegacyServerValidation = false
        legacyValidationRetryNotBefore = nil
        isAwaitingProtectedData = false; legacyProtectedRollbackRequired = false
        state = isConfigured ? .signedOut : .unconfigured
        do { try await lifecycle?.transition(from: previousContext, to: nil, generation: captured) }
        catch { cleanupRequired = true; presentationError = sanitized(error) }
        do { try await credentials.clear() }
        catch { cleanupRequired = true; presentationError = .credentialsUnavailable }
        if let revokeToken {
            do { try await transport.revoke(refreshToken: revokeToken) }
            catch { if presentationError == nil { presentationError = .revocationUnavailable } }
        }
        latestDeviceRefreshToken = nil
        if let legacyCredentials {
            do { try await legacyCredentials.clear() }
            catch { cleanupRequired = true; presentationError = .credentialsUnavailable }
        }
        if let legacyTransport {
            let hadActiveLegacySession = legacySessionActive
            let attemptedRemoteRevocation = legacyRemoteRevocationRequested
            if hadActiveLegacySession && attemptedRemoteRevocation {
                do { try await legacyTransport.logout() }
                catch { if presentationError == nil { presentationError = .revocationUnavailable } }
            }
            await legacyTransport.clearSession()
            // A late explicit logout can join after local retirement discarded its
            // cookie. Do not report all-device revocation without server evidence.
            if hadActiveLegacySession && legacyRemoteRevocationRequested && !attemptedRemoteRevocation && presentationError == nil {
                presentationError = .revocationUnavailable
            }
            legacySessionActive = false
            legacyRemoteRevocationRequested = false
        }
    }

    /// Termination joins account work and closes only this service's HTTP session. Persisted grant remains.
    func shutdown() async {
        isShuttingDown = true
        let command = authenticationCommand
        command?.task.cancel()
        await command?.task.value
        if let command, authenticationCommand?.id == command.id { authenticationCommand = nil }
        if let logoutTask { await logoutTask.value }
        boundaryInProgress = true
        browser.cancel()
        // Restore can also own a rotating refresh. Join it through persistence just like
        // refreshTask; canceling it after a verified response could lose the replacement.
        if ownedOperation?.kind != .restoration { ownedOperation?.task.cancel() }
        // A verified refresh response must finish persisting its rotation before termination.
        // Network time is bounded by the owned HTTP session. No new requests are admitted.
        _ = try? await ownedOperation?.task.value; _ = try? await refreshTask?.value
        generation = UUID()
        ownedOperation = nil; refreshTask = nil; refreshID = nil
        try? await lifecycle?.transition(from: context, to: nil, generation: generation)
        await transport.shutdown()
        await legacyTransport?.shutdown()
        legacySessionActive = false
    }

    func isCurrent(_ context: AccountContext) -> Bool {
        !isShuttingDown && authenticationCommand == nil && !boundaryInProgress
            && !cleanupRequired && ownedOperation == nil && state == .signedIn && self.context == context
    }

    private func failedAdmission(_ error: Error, generation captured: UUID) async {
        let failure = sanitized(error)
        legacyValidationRetryNotBefore = nil
        await legacyTransport?.clearSession()
        legacySessionActive = false; legacyStoredSession = nil; pendingLegacySession = nil; isAwaitingLegacyServerValidation = false
        isAwaitingProtectedData = false; legacyProtectedRollbackRequired = false
        do { try await legacyCredentials?.clear() } catch { cleanupRequired = true }
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
    /// Fresh sign-in starts in the first destination from the verified catalog, before
    /// activating its private profile. Legacy workspaces belong to the server's active
    /// organization; choosing another organization remains an explicit server command.
    /// Restoration and later workspace changes retain their own validated selection.
    private func initialWorkspace(in snapshot: AccountSnapshot) -> (organizationID: String, workspaceID: String)? {
        let organization = isLegacySession
            ? snapshot.organizations.first { $0.id == snapshot.activeOrganizationID }
            : snapshot.organizations.first { !$0.workspaces.isEmpty }
        guard let organization, let workspace = organization.workspaces.first else { return nil }
        return (organization.id, workspace.id)
    }
    private func check(_ expected: UUID) throws {
        try Task.checkCancellation()
        guard generation == expected else { throw AccountError.staleOperation }
    }
    private func sanitized(_ error: Error) -> AccountError {
        if error is CancellationError { return .cancelled }
        if let temporary = error as? LegacyAccountConnectivityFailure {
            if case .rateLimited = temporary { return .rateLimited }
            return .networkUnavailable
        }
        return error as? AccountError ?? .networkUnavailable
    }
}

extension AccountSessionService {
    /// Password lifetime is limited to this joined command. A production legacy cookie
    /// has its separate device-only store, never the OIDC grant or provider API-key store.
    func signIn(email: String, password: String, captchaToken: String? = nil) async {
        guard !Task.isCancelled else { return }
        guard let legacyConfiguration, let legacyTransport else { presentationError = .unconfigured; return }
        guard authenticationCommand == nil, !isShuttingDown else { presentationError = .busy; return }
        let commandID = UUID()
        let task = Task { @MainActor in
            if self.state == .reauthenticationRequired { await self.logoutSession(revokeLegacyRemote: false) }
            guard !Task.isCancelled, self.authenticationCommand?.id == commandID else { return }
            guard self.canAdmitSignIn, self.ownedOperation == nil, self.context == nil else {
                self.presentationError = self.cleanupRequired ? .credentialsUnavailable : .isolationRequired; return
            }
            self.presentationError = nil; self.state = .signingIn; self.generation = UUID()
            let captured = self.generation, operationID = UUID()
            let operation = Task { @MainActor in
                do {
                    try legacyConfiguration.validate()
                    guard self.configuration == nil else { throw AccountError.invalidConfiguration }
                    try self.restoration.inhibit()
                    self.pendingLegacySession = nil
                    let snapshot = try await legacyTransport.login(email: email, password: password, captchaToken: captchaToken)
                    try snapshot.validateLegacy(origin: legacyConfiguration.apiBaseURL)
                    try self.check(captured)
                    let workspace = self.initialWorkspace(in: snapshot)
                    let next = AccountContext(identity: snapshot.stableIdentity, organizationID: workspace?.organizationID,
                        workspaceID: workspace?.workspaceID, generation: captured)
                    self.pendingLegacySession = try await self.legacySessionEnvelope(snapshot: snapshot, context: next)
                    try await self.transitionLegacyProfile(from: nil, to: next, generation: captured)
                    try self.check(captured)
                    self.legacySessionActive = true
                    self.account = snapshot; self.context = next; self.state = .signedIn
                    self.isAwaitingLegacyServerValidation = false
                    try await self.persistLegacySession(snapshot: snapshot, context: next)
                } catch {
                    if self.generation == captured {
                        if error is ProtectedDataAccessError { await self.handleTemporaryLegacyFailure(generation: captured) }
                        else { await self.failedAdmission(error, generation: captured) }
                    }
                    throw error
                }
            }
            self.ownedOperation = OwnedOperation(id: operationID, kind: .admission, task: operation)
            await withTaskCancellationHandler { _ = try? await operation.value } onCancel: { operation.cancel() }
            if self.ownedOperation?.id == operationID { self.ownedOperation = nil }
            if Task.isCancelled { await self.logoutSession(revokeLegacyRemote: false) }
        }
        authenticationCommand = AuthenticationCommand(id: commandID, task: task)
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        if authenticationCommand?.id == commandID { authenticationCommand = nil }
    }

    private func freshLegacySnapshot(for expected: AccountContext? = nil) async throws -> AccountSnapshot {
        guard let legacyTransport else { throw AccountError.unconfigured }
        let captured = generation
        if let floor = legacyValidationRetryNotBefore, floor.generation == captured, floor.date > Date() {
            let remaining = ceil(floor.date.timeIntervalSinceNow)
            throw LegacyAccountConnectivityFailure.rateLimited(retryAfter: String(format: "%.0f", remaining))
        }
        do {
            // Refresh cannot revive an expired session or change the server TTL.
            if let cookie = try await legacyTransport.sessionCookie(), cookie.expiresAt.timeIntervalSinceNow <= 60 {
                try await legacyTransport.refreshSession()
            }
            let snapshot = try await legacyTransport.account()
            if let expected {
                try check(expected.generation)
                guard context == expected else { throw AccountError.staleOperation }
                guard snapshot.stableIdentity == expected.identity else { throw AccountError.invalidAccount }
                if let organization = expected.organizationID, let workspace = expected.workspaceID {
                    guard snapshot.activeOrganizationID == organization,
                          snapshot.contains(organizationID: organization, workspaceID: workspace) else { throw AccountError.permissionDenied }
                }
            }
            if generation == captured { legacyValidationRetryNotBefore = nil }
            return snapshot
        } catch {
            if generation == captured, case let LegacyAccountConnectivityFailure.rateLimited(header) = error,
               let date = Self.legacyValidationRetryDate(header, now: Date()) {
                legacyValidationRetryNotBefore = (captured, date)
            }
            if let expected, context == expected, generation == expected.generation {
                let failure = sanitized(error)
                if [.reauthenticationRequired, .invalidAccount, .permissionDenied].contains(failure) {
                    await invalidateLegacyRestoration(for: expected, failure: failure)
                } else if error is LegacyAccountConnectivityFailure || failure == .rateLimited { isAwaitingLegacyServerValidation = true }
            }
            throw error
        }
    }

    /// Account validation also runs outside publication, so retain its own scoped floor
    /// before any cookie refresh or ACL request. No timer or independent retry is created.
    private static func legacyValidationRetryDate(_ header: String?, now: Date) -> Date? {
        guard let header, !header.isEmpty else { return nil }
        guard header.utf8.count <= 128 else { return .distantFuture }
        let value = header.trimmingCharacters(in: .whitespaces)
        if !value.isEmpty && value.utf8.allSatisfy({ (48...57).contains($0) }) {
            guard let seconds = Double(value), seconds.isFinite else { return .distantFuture }
            return min(.distantFuture, now.addingTimeInterval(seconds))
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss 'GMT'"
        formatter.isLenient = false
        guard let date = formatter.date(from: value), formatter.string(from: date) == value else { return nil }
        return max(now, date)
    }

    private func persistLegacySession(snapshot: AccountSnapshot, context expected: AccountContext) async throws {
        guard let legacyCredentials else { return }
        try check(expected.generation)
        guard context == expected, state == .signedIn else { throw AccountError.staleOperation }
        guard let saved = try await legacySessionEnvelope(snapshot: snapshot, context: expected) else { throw AccountError.credentialsUnavailable }
        pendingLegacySession = saved
        try await legacyCredentials.save(saved)
        try check(expected.generation)
        guard context == expected else { throw AccountError.staleOperation }
        try restoration.permit()
        legacyStoredSession = saved; pendingLegacySession = nil; isAwaitingProtectedData = false
    }

    private func legacySessionEnvelope(snapshot: AccountSnapshot, context expected: AccountContext) async throws -> LegacyAccountStoredSession? {
        guard legacyCredentials != nil, let legacyConfiguration, let legacyTransport else { return nil }
        guard let cookie = try await legacyTransport.sessionCookie() else { throw AccountError.credentialsUnavailable }
        try check(expected.generation)
        let saved = LegacyAccountStoredSession(schemaVersion: 1, configuration: legacyConfiguration,
            cookie: cookie, snapshot: snapshot, verifiedAt: Date(),
            organizationID: expected.organizationID, workspaceID: expected.workspaceID)
        try saved.validate(configuration: legacyConfiguration)
        return saved
    }

    private func transitionLegacyProfile(from: AccountContext?, to: AccountContext?, generation: UUID) async throws {
        legacyProtectedRollbackRequired = true
        try await lifecycle?.transition(from: from, to: to, generation: generation)
        legacyProtectedRollbackRequired = false
    }

    private func validateLegacySelection(_ snapshot: AccountSnapshot, saved: LegacyAccountStoredSession) throws {
        try snapshot.validateLegacy(origin: saved.configuration.apiBaseURL)
        guard snapshot.stableIdentity == saved.snapshot.stableIdentity,
              snapshot.activeOrganizationID == saved.snapshot.activeOrganizationID else { throw AccountError.invalidAccount }
        if let organization = saved.organizationID, let workspace = saved.workspaceID {
            guard snapshot.activeOrganizationID == organization,
                  snapshot.contains(organizationID: organization, workspaceID: workspace) else { throw AccountError.permissionDenied }
        }
    }

    private func restoreLegacySession() async {
        guard let configuration = legacyConfiguration, let legacyTransport, let legacyCredentials,
              isSignInAvailable, (restoration.isAllowed || pendingLegacySession != nil), ownedOperation == nil, context == nil else { return }
        generation = UUID()
        let captured = generation, id = UUID()
        let task = Task { @MainActor in
            do {
                let wasPending = self.pendingLegacySession != nil
                let candidate: LegacyAccountStoredSession?
                if let pending = self.pendingLegacySession { candidate = pending }
                else { candidate = try await legacyCredentials.load() }
                guard let saved = candidate else { return }
                try saved.validate(configuration: configuration)
                try self.check(captured)
                try await legacyTransport.restoreSession(saved.cookie)
                try self.check(captured)
                var snapshot = saved.snapshot
                var awaitingServer = true
                do {
                    let fresh = try await self.freshLegacySnapshot()
                    try self.validateLegacySelection(fresh, saved: saved)
                    snapshot = fresh; awaitingServer = false
                } catch where error is LegacyAccountConnectivityFailure || (error as? AccountError) == .rateLimited {
                    // Cached identity is solely a local recovery admission. Remote requests
                    // still require fresh identity and editable-workspace evidence.
                }
                try self.check(captured)
                let next = AccountContext(identity: saved.snapshot.stableIdentity,
                    organizationID: saved.organizationID, workspaceID: saved.workspaceID, generation: captured)
                self.pendingLegacySession = saved
                try await self.transitionLegacyProfile(from: nil, to: next, generation: captured)
                try self.check(captured)
                self.legacySessionActive = true; self.legacyStoredSession = saved
                self.account = snapshot; self.context = next; self.state = .signedIn
                self.isAwaitingLegacyServerValidation = awaitingServer; self.presentationError = nil
                if !awaitingServer { try await self.persistLegacySession(snapshot: snapshot, context: next) }
                else if wasPending {
                    // Preserve the original verification time when a fresh pre-lock
                    // envelope is saved after unlock while connectivity is still absent.
                    try await legacyCredentials.save(saved)
                    try self.check(captured)
                    try self.restoration.permit()
                    self.pendingLegacySession = nil; self.isAwaitingProtectedData = false
                } else { self.pendingLegacySession = nil; self.isAwaitingProtectedData = false }
            } catch {
                if self.generation == captured {
                    if error is CancellationError {
                        await legacyTransport.clearSession()
                        try? await self.lifecycle?.transition(from: self.context, to: nil, generation: captured)
                        if self.generation == captured {
                            self.context = nil; self.account = nil; self.legacyStoredSession = nil
                            self.legacySessionActive = false; self.isAwaitingLegacyServerValidation = false
                            self.state = .signedOut; self.presentationError = .cancelled
                        }
                    } else if error is ProtectedDataAccessError {
                        await self.handleTemporaryLegacyFailure(generation: captured)
                    } else {
                        await self.failedAdmission(error, generation: captured)
                        if self.generation == captured { self.state = .reauthenticationRequired }
                    }
                }
                throw error
            }
        }
        ownedOperation = OwnedOperation(id: id, kind: .restoration, task: task)
        await withTaskCancellationHandler { _ = try? await task.value } onCancel: { task.cancel() }
        if ownedOperation?.id == id { ownedOperation = nil }
    }

    /// A transient keystore lock never revokes a credential. Only a failed profile
    /// activation needs joined guest rollback; an already committed safe owner stays.
    private func handleTemporaryLegacyFailure(generation captured: UUID) async {
        guard generation == captured else { return }
        isAwaitingProtectedData = true; isAwaitingLegacyServerValidation = true
        presentationError = nil
        guard legacyProtectedRollbackRequired else { return }
        let old = context
        context = nil; account = nil; state = .signedOut
        do {
            try await lifecycle?.transition(from: old, to: nil, generation: captured)
            if generation == captured { legacyProtectedRollbackRequired = false }
        } catch is ProtectedDataAccessError {
            // The guest's protected sources may also be locked. Keep the failed
            // account concealed and retry this exact cleanup after unlock.
        } catch {
            if generation == captured { cleanupRequired = true; presentationError = sanitized(error) }
        }
    }

    /// Bounded retry for the OS protected-data notification or foreground wake.
    /// This joins the same operation slot and never changes logout/restoration intent.
    func restoreAfterProtectedDataAvailable() async {
        guard isLegacySession, isAwaitingProtectedData, !isShuttingDown, !boundaryInProgress,
              !cleanupRequired, authenticationCommand == nil, ownedOperation == nil,
              restoration.isAllowed || pendingLegacySession != nil else { return }
        let captured = generation, id = UUID()
        let task = Task<Void, Error> { @MainActor in
            do {
                if self.legacyProtectedRollbackRequired {
                    try await self.lifecycle?.transition(from: self.context, to: nil, generation: captured)
                    try self.check(captured)
                    self.legacyProtectedRollbackRequired = false
                }
                // A pending envelope is previously server-verified. Saving its exact
                // bytes after unlock does not assert another fresh server validation.
                if let expected = self.context, let pending = self.pendingLegacySession,
                   let credentials = self.legacyCredentials, let configuration = self.legacyConfiguration {
                    try pending.validate(configuration: configuration)
                    guard pending.snapshot.stableIdentity == expected.identity,
                          pending.organizationID == expected.organizationID,
                          pending.workspaceID == expected.workspaceID else { throw AccountError.invalidAccount }
                    try await credentials.save(pending)
                    try self.check(captured)
                    guard self.context == expected else { throw AccountError.staleOperation }
                    try self.restoration.permit()
                    self.legacyStoredSession = pending; self.pendingLegacySession = nil
                }
                try self.check(captured)
                self.isAwaitingProtectedData = false
            } catch is ProtectedDataAccessError {
                await self.handleTemporaryLegacyFailure(generation: captured)
            } catch is CancellationError {
                // The owner of logout/shutdown joins this attempt before clearing.
            } catch {
                if self.generation == captured { await self.failedAdmission(error, generation: captured) }
            }
        }
        ownedOperation = OwnedOperation(id: id, kind: .restoration, task: task)
        await withTaskCancellationHandler { _ = try? await task.value } onCancel: { task.cancel() }
        if ownedOperation?.id == id { ownedOperation = nil }
        guard !Task.isCancelled, !isShuttingDown, generation == captured, !isAwaitingProtectedData else { return }
        if context == nil { await restoreLegacySession() }
        else { await restoreAfterConnectivity() }
    }

    /// One connectivity event, one bounded validation. It never switches an identity
    /// or retries a password, and it leaves the existing offline capture owner intact.
    func restoreAfterConnectivity() async {
        guard isLegacySession else { return }
        if isAwaitingProtectedData { await restoreAfterProtectedDataAvailable(); return }
        if context == nil { await restoreLegacySession(); return }
        guard isAwaitingLegacyServerValidation, isSignInAvailable, ownedOperation == nil,
              let expected = context, state == .signedIn, let saved = pendingLegacySession ?? legacyStoredSession else { return }
        let id = UUID(), captured = expected.generation
        let task = Task<Void, Error> { @MainActor in
            do {
                try saved.validate(configuration: saved.configuration)
                let snapshot = try await self.freshLegacySnapshot()
                try self.check(captured)
                guard self.context == expected else { throw AccountError.staleOperation }
                try self.validateLegacySelection(snapshot, saved: saved)
                self.account = snapshot
                try await self.persistLegacySession(snapshot: snapshot, context: expected)
                try self.check(captured)
                self.isAwaitingLegacyServerValidation = false; self.presentationError = nil
            } catch is ProtectedDataAccessError {
                await self.handleTemporaryLegacyFailure(generation: captured)
            } catch where error is LegacyAccountConnectivityFailure || (error as? AccountError) == .rateLimited {
                // Still offline. Keep only the already admitted local profile.
            } catch is CancellationError {
                // Cancellation of one connectivity check does not erase local capture.
            } catch {
                if self.generation == captured {
                    await self.failedAdmission(error, generation: captured)
                    if self.generation == captured { self.state = .reauthenticationRequired }
                }
            }
        }
        ownedOperation = OwnedOperation(id: id, kind: .restoration, task: task)
        await withTaskCancellationHandler { _ = try? await task.value } onCancel: { task.cancel() }
        if ownedOperation?.id == id { ownedOperation = nil }
    }

    private func selectLegacyWorkspace(organizationID: String, workspaceID: String) async throws {
        guard legacyTransport != nil, let configuration = legacyConfiguration,
              !isShuttingDown, authenticationCommand == nil, !boundaryInProgress, !cleanupRequired,
              ownedOperation == nil, state == .signedIn, let old = context else { throw AccountError.busy }
        let id = UUID()
        let task = Task { @MainActor in
            let snapshot = try await self.freshLegacySnapshot(for: old)
            try snapshot.validateLegacy(origin: configuration.apiBaseURL)
            try self.check(old.generation)
            guard snapshot.stableIdentity == old.identity,
                  snapshot.activeOrganizationID == organizationID,
                  snapshot.contains(organizationID: organizationID, workspaceID: workspaceID) else { throw AccountError.workspaceUnavailable }
            self.generation = UUID()
            let next = AccountContext(identity: old.identity, organizationID: organizationID, workspaceID: workspaceID, generation: self.generation)
            do {
                self.pendingLegacySession = try await self.legacySessionEnvelope(snapshot: snapshot, context: next)
                try await self.transitionLegacyProfile(from: old, to: next, generation: next.generation)
                try self.check(next.generation)
                self.account = snapshot; self.context = next
                self.isAwaitingLegacyServerValidation = false
                try await self.persistLegacySession(snapshot: snapshot, context: next)
            } catch {
                if self.generation == next.generation {
                    if error is ProtectedDataAccessError { await self.handleTemporaryLegacyFailure(generation: next.generation) }
                    else { await self.failedAdmission(error, generation: next.generation) }
                }
                throw error
            }
        }
        ownedOperation = OwnedOperation(id: id, kind: .workspace, task: task)
        defer { if ownedOperation?.id == id { ownedOperation = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Organization switching replaces the server cookie and retires the previous local
    /// profile before admitting the response. A workspace must then be selected explicitly.
    func selectLegacyOrganization(_ organizationID: String) async throws {
        guard let legacyTransport, let configuration = legacyConfiguration,
              !isShuttingDown, authenticationCommand == nil, !boundaryInProgress, !cleanupRequired,
              ownedOperation == nil, state == .signedIn, let old = context,
              account?.organizations.contains(where: { $0.id == organizationID }) == true else { throw AccountError.busy }
        generation = UUID()
        let captured = generation, id = UUID()
        let task = Task { @MainActor in
            do {
                try await self.transitionLegacyProfile(from: old, to: nil, generation: captured)
                try self.check(captured)
                let snapshot = try await legacyTransport.switchOrganization(organizationID)
                try snapshot.validateLegacy(origin: configuration.apiBaseURL)
                try self.check(captured)
                guard snapshot.stableIdentity == old.identity, snapshot.activeOrganizationID == organizationID else { throw AccountError.invalidAccount }
                let next = AccountContext(identity: old.identity, organizationID: nil, workspaceID: nil, generation: captured)
                self.pendingLegacySession = try await self.legacySessionEnvelope(snapshot: snapshot, context: next)
                try await self.transitionLegacyProfile(from: nil, to: next, generation: captured)
                try self.check(captured)
                self.account = snapshot; self.context = next
                self.isAwaitingLegacyServerValidation = false
                try await self.persistLegacySession(snapshot: snapshot, context: next)
            } catch {
                if self.generation == captured {
                    if error is ProtectedDataAccessError { await self.handleTemporaryLegacyFailure(generation: captured) }
                    else { await self.failedAdmission(error, generation: captured) }
                }
                throw error
            }
        }
        ownedOperation = OwnedOperation(id: id, kind: .workspace, task: task)
        defer { if ownedOperation?.id == id { ownedOperation = nil } }
        try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Fresh identity and editable-workspace evidence precede every protected operation.
    /// The publication service remains the single owner of transfer/retry/outbox work.
    func performAuthorizedLegacyRequest(for expected: AccountContext, request: URLRequest,
        responseFailure: (@Sendable (Int, String?) -> (any Error)?)? = nil) async throws -> LegacyAccountHTTPResponse {
        guard let legacyTransport, let configuration = legacyConfiguration, isCurrent(expected),
              let workspace = expected.workspaceID, let organization = expected.organizationID else { throw AccountError.staleOperation }
        guard Self.isLegacyPublicationRequest(request, workspace: workspace, origin: configuration.apiBaseURL) else {
            throw AccountError.invalidConfiguration
        }
        do {
            let snapshot = try await self.freshLegacySnapshot(for: expected)
            try snapshot.validateLegacy(origin: configuration.apiBaseURL)
            guard isCurrent(expected) else { throw AccountError.staleOperation }
            guard snapshot.stableIdentity == expected.identity, snapshot.activeOrganizationID == organization,
                  snapshot.contains(organizationID: organization, workspaceID: workspace) else { throw AccountError.permissionDenied }
            account = snapshot; isAwaitingLegacyServerValidation = false
            try await persistLegacySession(snapshot: snapshot, context: expected)
            guard isCurrent(expected) else { throw AccountError.staleOperation }
            let response = try await legacyTransport.perform(request)
            // The caller may retain safe failure metadata from its already admitted
            // request before a racing validation closes current-owner admission.
            // Success data still requires all ordinary checks below.
            if let failure = responseFailure?(response.status, response.retryAfter) { throw failure }
            try Task.checkCancellation()
            guard isCurrent(expected) else { throw AccountError.staleOperation }
            if response.status == 401 || response.status == 403 {
                await invalidateLegacyRestoration(for: expected,
                    failure: response.status == 403 ? .permissionDenied : .reauthenticationRequired)
            }
            return response
        } catch {
            if error is ProtectedDataAccessError {
                await handleTemporaryLegacyFailure(generation: expected.generation)
                throw error
            }
            let failure = sanitized(error)
            if (error is LegacyAccountConnectivityFailure || failure == .rateLimited), isCurrent(expected) { isAwaitingLegacyServerValidation = true }
            if isCurrent(expected), [.reauthenticationRequired, .invalidAccount, .permissionDenied].contains(failure) {
                await invalidateLegacyRestoration(for: expected, failure: failure)
            }
            throw error
        }
    }

    /// A known revocation cannot later become an offline cached admission. This
    /// performs no profile lifecycle transition from inside a publication request,
    /// whose caller already owns that joined work; it closes new network admission.
    private func invalidateLegacyRestoration(for expected: AccountContext, failure: AccountError) async {
        guard context == expected, generation == expected.generation else { return }
        state = .reauthenticationRequired; presentationError = failure
        isAwaitingLegacyServerValidation = false; legacyStoredSession = nil; pendingLegacySession = nil
        isAwaitingProtectedData = false; legacyProtectedRollbackRequired = false
        do { try restoration.inhibit() } catch { cleanupRequired = true; presentationError = .credentialsUnavailable }
        do { try await legacyCredentials?.clear() }
        catch { cleanupRequired = true; presentationError = .credentialsUnavailable }
    }

    private static func isLegacyPublicationRequest(_ request: URLRequest, workspace: String, origin: URL) -> Bool {
        guard let url = request.url, url.scheme == "https", url.host == origin.host, url.port == origin.port,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              request.value(forHTTPHeaderField: "Authorization") == nil, request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Origin") == nil, request.value(forHTTPHeaderField: "Referer") == nil else { return false }
        let method = request.httpMethod ?? "GET", path = url.path
        if method == "POST" { return path == "/api/recordings/transcript" }
        guard method == "GET", request.httpBody == nil else { return false }
        if path == "/api/workspaces/" + workspace + "/users" || path == "/api/evaluation-criteria/names" { return true }
        let prefix = "/api/recordings/"
        guard path.hasPrefix(prefix), let id = Int(path.dropFirst(prefix.count)), id > 0, id <= 2_147_483_647 else { return false }
        return path == prefix + String(id)
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
