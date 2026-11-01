import Combine
import Foundation

@main struct PichiPublicationCompositionTests {
    @MainActor static func main() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previous = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(previous); try? manager.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        var waitIndex = 0
        func wait(_ condition: @MainActor () async -> Bool) async throws {
            waitIndex += 1
            let index = waitIndex
            let deadline = ContinuousClock.now.advanced(by: .seconds(8))
            while !(await condition()) {
                guard ContinuousClock.now < deadline else {
                    FileHandle.standardError.write(Data("Composition wait \(index) timed out\n".utf8))
                    throw CompositionFailure.timeout
                }
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        let configuration = AccountConfiguration(issuer: URL(string: "https://identity.example/realms/pichi")!,
            apiBaseURL: URL(string: "https://api.example")!, clientID: "synthetic-native",
            apiAudience: "synthetic-api", bundleIdentifier: "ai.synthetic.voice")
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        // Composition owns its observer. A store must not keep a discarded facade alive.
        for iteration in 0..<16 {
            let lifetimeProfiles = PrivateProfileService()
            let lifetimeAccount = AccountSessionService(configuration: nil, browser: CompositionBrowser(),
                transport: CompositionIdentity(configuration: configuration, http: CompositionHTTP()),
                credentials: CompositionCredentials(), lifecycle: lifetimeProfiles)
            let lifetimeStore = PrivateProfileMeetingStore()
            var facade: PichiCloudPublicationService? = PichiCloudPublicationService(
                account: lifetimeAccount, meetings: lifetimeStore, profiles: lifetimeProfiles)
            weak let releasedFacade = facade
            try await facade!.install()
            if iteration.isMultiple(of: 2) { await facade!.shutdown() }
            facade = nil
            await Task.yield()
            guard releasedFacade == nil else {
                print("FAIL: Recording observer retains a discarded publication facade")
                exit(1)
            }
            check(releasedFacade == nil, "A retired publication facade must be released")
            do {
                _ = try await lifetimeStore.prepareCapturePersistencePolicy()
                check(false, "A missing installed observer must not default to unprotected capture")
            } catch let failure as AccountError {
                check(failure == .isolationRequired, "Missing composition must fail closed")
            }
            do {
                _ = try await lifetimeStore.captureOwnership(for: UUID())
                check(false, "An abandoned composition must not admit a capture")
            } catch let failure as AccountError {
                check(failure == .isolationRequired, "Missing capture policy owner must fail closed")
            }
            let replacement = PichiCloudPublicationService(
                account: lifetimeAccount, meetings: lifetimeStore, profiles: lifetimeProfiles)
            try await replacement.install()
            await replacement.shutdown()
            await lifetimeAccount.shutdown()
        }
        let heldStore = PrivateProfileMeetingStore(), observerGate = CompositionSourceGate()
        var heldObserver: CompositionHeldObserver? = CompositionHeldObserver(gate: observerGate)
        weak let releasedObserver = heldObserver
        try await heldStore.installRecordingObserver(heldObserver!)
        let heldID = UUID()
        let captureAdmission = Task { try await heldStore.captureOwnership(for: heldID) }
        try await wait { observerGate.isHeld }
        heldObserver = nil
        check(releasedObserver != nil, "Admitted preflight must retain its exact policy observer while suspended")
        observerGate.release()
        _ = try await captureAdmission.value
        await Task.yield()
        check(releasedObserver == nil, "Completed preflight must release its temporary observer ownership")
        await heldStore.cancelCaptureAdmission(for: heldID)
        let profiles = PrivateProfileService(), browser = CompositionBrowser(), http = CompositionHTTP()
        let credentials = CompositionCredentials(), identity = CompositionIdentity(configuration: configuration, http: http)
        let account = AccountSessionService(configuration: configuration, browser: browser,
            transport: identity, credentials: credentials, lifecycle: profiles)
        let meetings = PrivateProfileMeetingStore()
        let service = PichiCloudPublicationService(account: account, meetings: meetings, profiles: profiles, http: http)
        let owner = PichiCloudPublicationActivation(service: service, account: account, profiles: profiles)
        let sourceGate = CompositionSourceGate()
        var busyCapture = false
        try profiles.configure(isBusy: { !owner.isInstalled || busyCapture }, prepare: {}, activate: { _ in
            if sourceGate.shouldHold { await sourceGate.wait() }
        })
        check(!owner.isInstalled && !account.isSignInAvailable, "Observer installation is a production admission prerequisite")
        await account.signIn()
        check(browser.calls == 0 && account.context == nil, "An early sign-in cannot run before observer installation")
        async let firstInstall: Void = owner.install()
        async let secondInstall: Void = owner.install()
        try await firstInstall; try await secondInstall
        try await owner.install()
        check(owner.isInstalled && account.isSignInAvailable, "Concurrent/repeated composition installation is coalesced")
        do { try await service.install(); check(false, "Facade install may only happen once") }
        catch let failure as AccountError { check(failure == .busy, "Composition does not duplicate the observer") }
        await owner.activateAfterAccountCommand()
        check(service.snapshot.availability == .signedOut && !service.snapshot.cloudSyncEnabled,
              "Signed-out refresh clears unavailable presentation without requesting a token")
        var earlyContextNotifications = 0
        var contextEvents = Set<AnyCancellable>()
        account.$context.sink { context in
            if let context, !account.isCurrent(context) { earlyContextNotifications += 1 }
        }.store(in: &contextEvents)
        await account.signIn()
        try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        try await wait { service.snapshot.availability == .paused }
        let a = PrivateProfileStorage.current
        check(earlyContextNotifications >= 2, "Real frozen N1 publishes before its command/operation is current")
        check(account.context?.workspaceID == "9" && account.isCurrent(account.context!), "N1's concrete command has fully joined")
        check(!service.snapshot.cloudSyncEnabled && service.snapshot.items.isEmpty,
              "Automatic common composition activates the committed workspace with consent off")
        check(manager.fileExists(atPath: a.directory("CloudPublication/Consent").path),
              "Activation opens only the committed readable account source")
        check(await http.count() == 0, "Sign-in and activation with default-off consent create no requests")
        // A source revision publishes while selectWorkspace still owns N1's slot. Hold the
        // real N2 activation hook to exercise queued activation against closed admission.
        sourceGate.shouldHold = true
        let workspace = Task { try await account.selectWorkspace(organizationID: "17", workspaceID: "10") }
        try await wait { sourceGate.isHeld }
        check(profiles.isTransitioning && !PrivateProfileStorage.acceptsNewWork,
              "Workspace source replacement keeps admission closed during its concrete hook")
        await owner.activateAfterAccountCommand()
        check(service.snapshot.availability == .profileUnavailable && service.snapshot.items.isEmpty,
              "A queued activation never reopens concealed or partly activated sources")
        check(!manager.fileExists(atPath: PrivateProfileStorage.current.directory("CloudPublication/Consent").path),
              "A selected but unreadable source is not opened by activation")
        sourceGate.release(); try await workspace.value
        try await wait { service.snapshot.availability == .paused }
        let b = PrivateProfileStorage.current
        check(b.id != a.id && b.context?.workspaceID == "10" && account.isCurrent(b.context!),
              "The later context notification activates the new workspace after its owned slot clears")
        check(manager.fileExists(atPath: b.directory("CloudPublication/Consent").path),
              "Only the committed new workspace receives scoped publication state")
        check(await http.count() == 0, "Replacing a workspace does not enable cloud sync")
        try await service.setCloudSyncEnabled(true)
        check(service.snapshot.availability == .ready, "The same facade can report ready after explicit opt-in with no pending sources")
        await identity.failRefresh(.reauthenticationRequired)
        do { _ = try await account.authorizedAccess(for: account.context!); check(false, "Synthetic validation must require reauthentication") }
        catch let failure as AccountError { check(failure == .reauthenticationRequired, "Actual N1 classifies the expired grant") }
        try await wait { service.snapshot.availability == .paused }
        check(account.state == .reauthenticationRequired && account.context == b.context,
              "A durable non-signed-in state refreshes ready publication to paused while retaining the scope")
        await identity.failRefresh(nil)
        // Logout while an admitted recorder exists must conceal, pause and preserve ownership.
        busyCapture = true
        await account.logout()
        await owner.activateAfterAccountCommand()
        check(!PrivateProfileStorage.current.isReadable && service.snapshot.items.isEmpty,
              "Busy logout hides publication without replacing the recorder's local root")
        check(PrivateProfileStorage.current.id == b.id && service.snapshot.availability == .profileUnavailable,
              "Late activation cannot reopen a concealed former workspace after logout")
        busyCapture = false
        await account.logout()
        await owner.activateAfterAccountCommand()
        check(PrivateProfileStorage.current.isGuest && PrivateProfileStorage.acceptsNewWork
              && service.snapshot.items.isEmpty && !service.snapshot.cloudSyncEnabled,
              "Joined cleanup retry restores guest admission with no previous publication projection")
        await account.signIn(); try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        try await wait { service.snapshot.availability == .paused }
        await owner.shutdown()
        check(await http.isClosed() && service.snapshot.availability == .profileUnavailable,
              "Composition shutdown joins activation and closes the one publication transport")
        try await account.selectWorkspace(organizationID: "17", workspaceID: "10")
        try await Task.sleep(for: .milliseconds(60))
        check(service.snapshot.availability == .profileUnavailable && service.snapshot.items.isEmpty,
              "Removed observers cannot reactivate a shut-down facade after later account changes")
        await account.shutdown()
        check(await identity.shutdownAfterHTTP(), "Publication transport shuts down before the N1 account transport")
        check(await http.count() == 0, "The entire composition fixture uses no live or synthetic publication requests")
        contextEvents.removeAll()

        // Restore uses the actual persisted in-memory N1 grant from the preceding
        // account instance. Install first, await restore, then await activation.
        let restoredProfiles = PrivateProfileService(), restoredHTTP = CompositionHTTP()
        let restoredIdentity = CompositionIdentity(configuration: configuration, http: restoredHTTP)
        let restoredAccount = AccountSessionService(configuration: configuration, browser: CompositionBrowser(),
            transport: restoredIdentity, credentials: credentials, lifecycle: restoredProfiles)
        let restoredService = PichiCloudPublicationService(account: restoredAccount, meetings: .init(),
            profiles: restoredProfiles, http: restoredHTTP)
        let restoredOwner = PichiCloudPublicationActivation(service: restoredService, account: restoredAccount,
            profiles: restoredProfiles)
        try restoredProfiles.configure(isBusy: { !restoredOwner.isInstalled }, prepare: {}, activate: { _ in })
        check(!restoredAccount.isSignInAvailable, "A new host cannot restore before the observer is installed")
        try await restoredOwner.install()
        await restoredAccount.restore()
        await restoredOwner.activateAfterAccountCommand()
        check(restoredAccount.context?.workspaceID == "10" && restoredAccount.isCurrent(restoredAccount.context!),
              "Initial restore validates and joins the same account's workspace before activation")
        check(restoredService.snapshot.cloudSyncEnabled && restoredService.snapshot.items.isEmpty,
              "Restoring an opted-in workspace preserves only its existing consent without claiming history")
        check(await restoredHTTP.count() == 0, "An empty restored queue needs no publication request")
        await restoredOwner.shutdown(); await restoredAccount.shutdown()
        check(await restoredIdentity.shutdownAfterHTTP(), "Restored composition uses the same publication-before-account shutdown order")

        // Failure to acquire the exact observer leaves account admission unavailable.
        PrivateProfileStorage.select(guest)
        let failedProfiles = PrivateProfileService(), occupiedStore = PrivateProfileMeetingStore()
        let occupiedObserver = CompositionNoopObserver()
        defer { withExtendedLifetime(occupiedObserver) {} }
        try await occupiedStore.installRecordingObserver(occupiedObserver)
        let failedAccount = AccountSessionService(configuration: configuration, browser: CompositionBrowser(),
            transport: identity, credentials: CompositionCredentials(), lifecycle: failedProfiles)
        let failedService = PichiCloudPublicationService(account: failedAccount, meetings: occupiedStore, profiles: failedProfiles)
        let failedOwner = PichiCloudPublicationActivation(service: failedService, account: failedAccount, profiles: failedProfiles)
        try failedProfiles.configure(isBusy: { !failedOwner.isInstalled }, prepare: {}, activate: { _ in })
        do { try await failedOwner.install(); check(false, "An occupied observer must not be replaced") }
        catch { check(!failedOwner.isInstalled && !failedAccount.isSignInAvailable,
                      "Failed installation keeps authentication isolation unavailable") }
        await failedOwner.shutdown(); await failedAccount.shutdown()

        // Missing trusted configuration remains an installed local-only composition.
        PrivateProfileStorage.select(guest)
        let localProfiles = PrivateProfileService()
        let localAccount = AccountSessionService(configuration: nil, browser: CompositionBrowser(),
            transport: identity, credentials: CompositionCredentials(), lifecycle: localProfiles)
        let localService = PichiCloudPublicationService(account: localAccount, meetings: .init(), profiles: localProfiles)
        let localOwner = PichiCloudPublicationActivation(service: localService, account: localAccount, profiles: localProfiles)
        try localProfiles.configure(isBusy: { !localOwner.isInstalled }, prepare: {}, activate: { _ in })
        try await localOwner.install(); await localAccount.restore(); await localOwner.activateAfterAccountCommand()
        check(localService.snapshot.availability == .unconfigured && !localService.snapshot.cloudSyncEnabled,
              "No trusted configuration preserves guest/local-only behavior without HTTP")
        await localOwner.shutdown(); await localAccount.shutdown()
        print("Pichi publication composition: \(checks) synthetic checks passed; frozen N1/N5, no network or app UI")
    }
}
private enum CompositionFailure: Error { case timeout }
@MainActor private final class CompositionSourceGate {
    var shouldHold = false
    private var continuation: CheckedContinuation<Void, Never>?
    var isHeld: Bool { continuation != nil }
    func wait() async { await withCheckedContinuation { continuation = $0 } }
    func release() { shouldHold = false; let old = continuation; continuation = nil; old?.resume() }
}
@MainActor private final class CompositionBrowser: AccountBrowserAuthenticating {
    var calls = 0
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        calls += 1
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(string: callbackScheme + ":/oauth/callback")!
        callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "synthetic")]
        return callback.url!
    }
    func cancel() {}
}
private actor CompositionCredentials: AccountCredentialStoring {
    var grant: AccountGrant?
    func load() async throws -> AccountGrant? { grant }
    func save(_ grant: AccountGrant) async throws { self.grant = grant }
    func clear() async throws { grant = nil }
}
private actor CompositionIdentity: AccountTransporting {
    let configuration: AccountConfiguration, http: CompositionHTTP
    var closedAfterHTTP = false
    var refreshFailure: AccountError?
    func failRefresh(_ value: AccountError?) { refreshFailure = value }
    init(configuration: AccountConfiguration, http: CompositionHTTP) { self.configuration = configuration; self.http = http }
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL {
        var url = URLComponents(string: "https://identity.example/authorize")!
        url.queryItems = [.init(name: "state", value: state)]; return url.url!
    }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse {
        .init(accessToken: "synthetic-access", refreshToken: "synthetic-refresh",
            expiresAt: Date().addingTimeInterval(30), subject: "synthetic-subject")
    }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse {
        if let refreshFailure { throw refreshFailure }
        return try await exchange(code: "", verifier: "", nonce: "")
    }
    func account(accessToken: String) async throws -> AccountSnapshot {
        .init(schemaVersion: 1, account: .init(id: "synthetic-user", displayName: "Synthetic", email: nil),
            identity: .init(issuer: configuration.issuer.absoluteString, subject: "synthetic-subject"),
            organizations: [.init(id: "17", name: "Synthetic", workspaces: [
                .init(id: "9", name: "Synthetic A", capabilities: []), .init(id: "10", name: "Synthetic B", capabilities: [])])])
    }
    func revoke(refreshToken: String) async throws {}
    func shutdown() async { closedAfterHTTP = await http.isClosed() }
    func shutdownAfterHTTP() -> Bool { closedAfterHTTP }
}
private actor CompositionHTTP: PichiPublicationHTTPPerforming {
    var requests = 0, closed = false
    func perform(_ request: URLRequest) async throws -> PichiPublicationHTTPResponse {
        requests += 1; throw PichiPublicationNetworkFailure.unavailable
    }
    func count() -> Int { requests }
    func shutdown() async { closed = true }
    func isClosed() -> Bool { closed }
}
private final class CompositionNoopObserver: PrivateProfileRecordingObserver {
    func captureAdmitted(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async {}
    func sourceDidPersist(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async {}
}
@MainActor private final class CompositionHeldObserver: PrivateProfileRecordingObserver {
    let gate: CompositionSourceGate
    init(gate: CompositionSourceGate) { self.gate = gate }
    func captureAdmitted(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async { await gate.wait() }
    func sourceDidPersist(id: MeetingSessionID, admission: MeetingPrivateProfileAdmission) async {}
}
