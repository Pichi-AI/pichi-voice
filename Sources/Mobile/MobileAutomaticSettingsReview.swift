#if DEBUG && targetEnvironment(simulator)
import Combine
import Foundation
import SwiftUI

/// Actual native settings over disposable synthetic service inputs, never a production
/// account or readiness override. No recording, HTTP transport, Keychain or model is used.
struct MobileAutomaticSettingsReview: View {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["PICHI_UI_AUTOMATIC_SETTINGS_REVIEW"] == "1" }
    @StateObject private var state = AutomaticSettingsReviewState()
    @State private var showsDataCleanup = false
    var body: some View {
        NavigationStack {
            if let fixture = state.fixture {
                VStack(spacing: 0) {
                    MobileAccountSettings(session: fixture.account, interaction: fixture.accountUI,
                        cloudPublication: fixture.cloud, cloudInteraction: fixture.cloudUI)
                }.accessibilityElement(children: .contain).accessibilityIdentifier("automatic.review.ready")
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Button { showsDataCleanup = true } label: { Image(systemName: "lock.shield") }
                                .accessibilityLabel(PichiLocalization.text("Data cleanup"))
                                .accessibilityIdentifier("automatic.review.openPrivacy")
                        }
                        ToolbarItem(placement: .confirmationAction) {
                            Button(PichiLocalization.text("Close")) { state.close() }.accessibilityIdentifier("automatic.review.close")
                        }
                    }
                    .sheet(isPresented: $showsDataCleanup) {
                        NavigationStack {
                            Form {
                                Section(PichiLocalization.text("recording.protection.section")) {
                                    MobileRecordingDataControls(session: fixture.account, service: fixture.cloud,
                                        interaction: fixture.cloudUI, settings: fixture.settings, profiles: fixture.profiles)
                                }
                            }.navigationTitle(PichiLocalization.text("Data cleanup"))
                                .accessibilityIdentifier("automatic.review.privacy")
                                .toolbar { ToolbarItem(placement: .confirmationAction) {
                                    Button(PichiLocalization.text("Close")) { showsDataCleanup = false }
                                        .accessibilityIdentifier("automatic.review.closePrivacy")
                                } }
                        }
                    }
            } else if state.closed {
                Text(PichiLocalization.text("Done")).accessibilityIdentifier("automatic.review.closed")
            } else if state.failed {
                Text(PichiLocalization.text("Unavailable")).accessibilityIdentifier("automatic.review.failed")
                    .toolbar { ToolbarItem(placement: .confirmationAction) {
                        Button(PichiLocalization.text("Close")) { state.close() }.accessibilityIdentifier("automatic.review.close")
                    } }
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
        let settings: SettingsStore
        let profiles: PrivateProfileService
    }
    @Published private(set) var fixture: Fixture?
    @Published private(set) var closed = false
    @Published private(set) var failed = false
    private var setup: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var failurePending = false
    private var settingsSuite: String?
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
                let suite = "AutomaticSettingsReview." + UUID().uuidString
                guard let defaults = UserDefaults(suiteName: suite) else { throw AccountError.invalidConfiguration }
                settingsSuite = suite
                let settings = SettingsStore(defaults: defaults, initializeDesktop: false)
                fixture = Fixture(account: account, accountUI: MobileAccountInteraction(session: account,
                    requireTransitionAdmission: { [profiles] in try profiles.requireTransitionAdmission() }), cloud: cloud, cloudUI: cloudUI, settings: settings, profiles: profiles)
            } catch {
                failurePending = true
                close() // Cleanup joins this setup task after it returns, without a self-await.
            }
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
            do { try await cloudUI?.prepareForPrivateProfileTransition() }
            catch { failurePending = true }
            await cloud?.shutdown(); await account?.shutdown(); await meetings.finishProfileTransition()
            cloudUI = nil; cloud = nil; account = nil
            if let settingsSuite { UserDefaults.standard.removePersistentDomain(forName: settingsSuite) }
            settingsSuite = nil
            if let previous { PrivateProfileStorage.select(previous); if !wasAdmitted { PrivateProfileStorage.closeAdmission() } }
            do { if let root { try FileManager.default.removeItem(at: root) }; root = nil; previous = nil; closed = !failurePending; failed = failurePending }
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

/// Real meeting screens over a disposable device-guest/account library. This route exists
/// only in a simulator Debug build and never starts recording, authentication or models.
struct MobileSharedGuestHistoryReview: View {
    static var isRequested: Bool { ProcessInfo.processInfo.environment["PICHI_UI_SHARED_GUEST_HISTORY_REVIEW"] == "1" }
    @StateObject private var state = SharedGuestHistoryReviewState()

    var body: some View {
        Group {
            if let services = state.services {
                MobileMeetingRoot(coordinator: services.meetingSessionCoordinator, asr: services.asr,
                    store: services.meetingStore, privacy: services.transcriptPrivacy,
                    required: services.requiredResources, privacyActivation: services.privacyActivation,
                    accountSession: services.accountSession,
                    microphones: { .init(identities: [], defaultCoreAudioUID: nil) })
            } else if state.failed {
                Text(PichiLocalization.text("Unavailable")).accessibilityIdentifier("shared.history.review.failed")
            } else if state.closed {
                Text(PichiLocalization.text("Done")).accessibilityIdentifier("shared.history.review.closed")
            } else {
                ProgressView().accessibilityIdentifier("shared.history.review.preparing")
            }
        }.task { await state.start() }.onDisappear { state.close() }
    }
}

@MainActor private final class SharedGuestHistoryReviewState: ObservableObject {
    @Published private(set) var services: AppServices?
    @Published private(set) var failed = false
    @Published private(set) var closed = false
    private var setup: Task<Void, Never>?
    private var cleanup: Task<Void, Never>?
    private var failurePending = false
    private var root: URL?
    private var previous: PrivateProfileSnapshot?
    private var wasAdmitted = false
    private var settingsSuite: String?
    private var meetings: PrivateProfileMeetingStore?

    func start() async {
        guard setup == nil, root == nil, services == nil, cleanup == nil, !closed else { return }
        let task = Task { @MainActor in
            do {
                let selected = ProcessInfo.processInfo.environment["PICHI_UI_SHARED_GUEST_HISTORY_PROFILE"] ?? "a"
                guard ["a", "b", "guest"].contains(selected) else { throw AccountError.invalidConfiguration }
                // Stable only inside the explicitly owned simulator app container. Reuse the
                // invented manifests across process relaunches; parent deletion of the owned
                // simulator releases this disposable library after evidence preservation.
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("SharedGuestHistoryReview-v1", isDirectory: true)
                try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                    attributes: [.posixPermissions: 0o700])
                self.root = root
                previous = PrivateProfileStorage.current; wasAdmitted = PrivateProfileStorage.acceptsNewWork
                let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
                func account(_ subject: String) throws -> PrivateProfileSnapshot {
                    let context = AccountContext(identity: .init(issuer: "https://identity.invalid/shared-guest-review",
                        subject: subject, internalUserID: "synthetic-" + subject), organizationID: "synthetic-org",
                        workspaceID: "synthetic-workspace", generation: UUID())
                    return try PrivateProfileStorage.proposed(context: context, generation: UUID(), legacyRootDirectory: root)
                }
                let a = try account("a"), b = try account("b")
                let fixtures = [
                    (guest, "E0000000-0000-4000-8000-000000000001", "Гостевая встреча Ёж", 0.0),
                    (a, "E0000000-0000-4000-8000-000000000002", "Встреча аккаунта А", 60.0),
                    (b, "E0000000-0000-4000-8000-000000000003", "Встреча аккаунта Б", 120.0)
                ]
                for (profile, rawID, title, offset) in fixtures {
                    guard let id = UUID(uuidString: rawID) else { throw AccountError.invalidConfiguration }
                    let file = profile.directory("Meetings").appendingPathComponent(rawID).appendingPathComponent("session.json")
                    guard !FileManager.default.fileExists(atPath: file.path) else { continue }
                    let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
                        machTimebaseDenominator: 1, firstPresentationTime: nil)
                    var record = MeetingSession(id: id, configuration: .init(mode: .inRoom, title: title,
                        microphone: .init(captureDeviceID: "synthetic-history-review", displayName: "Synthetic microphone")),
                        startedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset), timebase: timebase)
                    record.profileOwnership = profile.isGuest ? nil : .init(profile: profile)
                    record.state = .completed; record.endedAt = record.startedAt.addingTimeInterval(30)
                    record.audioStorageMode = .memoryOnly; record.transcriptTimeDomain = .meetingRelative
                    let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
                        sourceDisplayName: "Synthetic microphone", format: nil, timebase: timebase, health: .waiting, chunks: [])
                    record.audioTracks = [track]
                    if profile.isGuest {
                        record.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1),
                            end: .init(value: 2, timescale: 1), sourceTrackID: track.id, speakerID: nil,
                            text: "Синтетический текст гостевой встречи.", revision: 0, status: .final,
                            overlap: .none, completeness: .complete, attributionState: .unassigned)]
                    }
                    try await MeetingSessionStore(rootDirectory: profile.directory("Meetings")).create(record)
                    try Task.checkCancellation()
                }
                try Task.checkCancellation()
                PrivateProfileStorage.select(selected == "a" ? a : selected == "b" ? b : guest)
                let suite = "SharedGuestHistoryReview.v1"
                guard let defaults = UserDefaults(suiteName: suite) else { throw AccountError.invalidConfiguration }
                settingsSuite = suite
                let settings = SettingsStore(defaults: defaults, initializeDesktop: false)
                settings.meetingAudioRetentionPolicy = .never
                let accountSession = AccountSessionService(configuration: nil, browser: SettingsReviewBrowser(),
                    transport: SettingsReviewOIDC(), credentials: SettingsReviewCredentials())
                let meetings = PrivateProfileMeetingStore()
                self.meetings = meetings
                services = AppServices(store: meetings, settings: settings, accountSession: accountSession)
            } catch {
                failurePending = true
                close()
            }
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
            let services = self.services; self.services = nil
            await services?.shutdownForTermination()
            await meetings?.finishProfileTransition(); meetings = nil
            if let settingsSuite { UserDefaults.standard.removePersistentDomain(forName: settingsSuite) }
            settingsSuite = nil
            if let previous {
                PrivateProfileStorage.select(previous)
                if !wasAdmitted { PrivateProfileStorage.closeAdmission() }
            }
            // The fixed synthetic root is deliberately retained for the next app launch.
            // It contains no audio, weights, personal data or account credentials.
            root = nil; previous = nil; closed = !failurePending; failed = failurePending
            cleanup = nil
        }
    }
}
#endif
