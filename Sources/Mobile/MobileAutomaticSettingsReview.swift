#if DEBUG && targetEnvironment(simulator)
import Combine
import Foundation
import SwiftUI

/// Actual native settings over disposable synthetic service inputs, never a production
/// account or readiness override. No recording, HTTP transport, Keychain or model is used.
struct MobileAutomaticSettingsReview: View {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["PICHI_UI_AUTOMATIC_SETTINGS_REVIEW"] == "1" }
    @StateObject private var state = AutomaticSettingsReviewState()
    var body: some View {
        NavigationStack {
            if let fixture = state.fixture {
                VStack(spacing: 0) {
                    MobileAccountSettings(session: fixture.account, interaction: fixture.accountUI,
                        cloudPublication: fixture.cloud, cloudInteraction: fixture.cloudUI)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("automatic.review.ready")
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button(PichiLocalization.text("Close")) { state.close() }.accessibilityIdentifier("automatic.review.close")
                    } }
            } else if state.closed {
                Text(PichiLocalization.text("Done")).accessibilityIdentifier("automatic.review.closed")
            } else if state.failed {
                Text(PichiLocalization.text("Unavailable")).accessibilityIdentifier("automatic.review.failed")
            } else { ProgressView().accessibilityIdentifier("automatic.review.preparing") }
        }.task { await state.start() }.onDisappear { state.close() }
    }
}

@MainActor private final class AutomaticSettingsReviewState: ObservableObject {
    struct Fixture {
        let account: AccountSessionService
        let accountUI: MobileAccountInteraction
        let cloud: PichiCloudPublicationService
        let cloudUI: MobileCloudInteraction
    }
    @Published private(set) var fixture: Fixture?
    @Published private(set) var closed = false
    @Published private(set) var failed = false
    private var setup: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var root: URL?
    private var previous: PrivateProfileSnapshot?
    private var wasAdmitted = false
    private var account: AccountSessionService?
    private var cloud: PichiCloudPublicationService?
    private var cloudUI: MobileCloudInteraction?
    private let profiles = PrivateProfileService()
    private let meetings = PrivateProfileMeetingStore()

    func start() async {
        guard setup == nil, root == nil, cleanup == nil, !closed else { return }
        let task = Task { @MainActor in
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("automatic-settings-review-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                self.root = root; previous = PrivateProfileStorage.current; wasAdmitted = PrivateProfileStorage.acceptsNewWork
                PrivateProfileStorage.select(try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root))
                // Only the owned store and facade participate here. These hooks make
                // no assertion about the production application's source inventory.
                try profiles.configure(isBusy: { false }, prepare: { [meetings] in await meetings.finishProfileTransition() }, activate: { _ in })
                let config = LegacyAccountConfiguration(apiBaseURL: URL(string: "https://automatic-settings.example")!, bundleIdentifier: "ai.synthetic.voice")
                let account = AccountSessionService(configuration: nil, browser: SettingsReviewBrowser(), transport: SettingsReviewOIDC(),
                    credentials: SettingsReviewCredentials(), lifecycle: profiles,
                    legacyConfiguration: config, legacyTransport: SettingsReviewLegacy(configuration: config))
                self.account = account
                let cloud = PichiCloudPublicationService(account: account, meetings: meetings, profiles: profiles,
                    recordingCipher: { try MeetingRecordingCipher(profileID: $0.id, key: Data(repeating: 0x52, count: 32)) })
                self.cloud = cloud
                try await cloud.install()
                await account.signIn(email: "synthetic@example.invalid", password: "synthetic-only")
                try Task.checkCancellation()
                try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
                try await cloud.refresh(); try Task.checkCancellation()
                guard let context = account.context, account.isCurrent(context), context.workspaceID == "9",
                      PrivateProfileStorage.current.context == context, cloud.snapshot.items.isEmpty,
                      !cloud.snapshot.cloudSyncEnabled else { throw AccountError.invalidAccount }
                let cloudUI = MobileCloudInteraction(session: account, profiles: profiles)
                self.cloudUI = cloudUI
                fixture = Fixture(account: account, accountUI: MobileAccountInteraction(session: account,
                    requireTransitionAdmission: { [profiles] in try profiles.requireTransitionAdmission() }), cloud: cloud, cloudUI: cloudUI)
            } catch { failed = true }
        }
        setup = task
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        setup = nil
    }

    func close() {
        guard cleanup == nil, !closed else { return }
        let pending = setup; pending?.cancel()
        cleanup = Task { @MainActor in
            await pending?.value
            fixture = nil
            await cloudUI?.prepareForPrivateProfileTransition()
            await cloud?.shutdown(); await account?.shutdown(); await meetings.finishProfileTransition()
            cloudUI = nil; cloud = nil; account = nil
            if let previous { PrivateProfileStorage.select(previous); if !wasAdmitted { PrivateProfileStorage.closeAdmission() } }
            do { if let root { try FileManager.default.removeItem(at: root) }; root = nil; previous = nil; closed = true }
            catch { failed = true }
            cleanup = nil
        }
    }
}

@MainActor private final class SettingsReviewBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw AccountError.unconfigured }
    func cancel() {}
}
private actor SettingsReviewCredentials: AccountCredentialStoring {
    func load() async throws -> AccountGrant? { nil }
    func save(_ grant: AccountGrant) async throws { throw AccountError.invalidState }
    func clear() async throws {}
}
private actor SettingsReviewOIDC: AccountTransporting {
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL { throw AccountError.unconfigured }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func account(accessToken: String) async throws -> AccountSnapshot { throw AccountError.unconfigured }
    func revoke(refreshToken: String) async throws {}
}
private actor SettingsReviewLegacy: LegacyAccountTransporting {
    let configuration: LegacyAccountConfiguration
    init(configuration: LegacyAccountConfiguration) { self.configuration = configuration }
    func login(email: String, password: String, captchaToken: String?) async throws -> AccountSnapshot { try await account() }
    func account() async throws -> AccountSnapshot {
        .init(schemaVersion: 1, account: .init(id: "123", displayName: "Synthetic account Ёё", email: "synthetic@example.invalid"),
            identity: .init(issuer: "", subject: "", legacyOrigin: configuration.apiBaseURL.absoluteString),
            organizations: [.init(id: "17", name: "Synthetic organization Ёё",
                workspaces: [.init(id: "9", name: "Synthetic workspace Ёё", capabilities: ["recordings:import"])])], activeOrganizationID: "17")
    }
    func switchOrganization(_ organizationID: String) async throws -> AccountSnapshot { try await account() }
    func perform(_ request: URLRequest) async throws -> LegacyAccountHTTPResponse { throw AccountError.invalidConfiguration }
    func logout() async throws {}
    func clearSession() async {}
    func shutdown() async {}
}
#endif
