import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import PichiVoiceMobile

/// Shared device guest history stays visible. Account-protected presentation and
/// trusted publication retain their existing per-record boundaries.
@MainActor
final class MobileEncryptedPresentationTests: XCTestCase {
    func testEncryptedGuestHistoryIsVisibleWhileAccountProtectionStaysConcealed() async {
        var guest = session(title: "Encrypted device guest", concealed: true)
        guest.profileOwnership = .guest
        var account = session(title: "Protected account recording", concealed: true)
        account.profileOwnership = .init(profileID: "synthetic-account", issuer: "https://identity.invalid",
            subject: "synthetic", internalUserID: "synthetic", organizationID: "org", workspaceID: "workspace")
        let values = [guest, account]
        let history = MeetingHistorySnapshot { values }
        await history.refresh()
        XCTAssertEqual(history.sessions.map(\.id), [guest.id])
        XCTAssertTrue(guest.requiresEncryptedPersistence == true)
        XCTAssertFalse(guest.isLocalContentConcealed)
        XCTAssertTrue(account.isLocalContentConcealed)
    }

    func testSharedGuestHistorySurvivesAccountChangesAndFreshSnapshots() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic profile history regression requires an owned simulator")
        #else
        let fixture = try SharedGuestNativeFixture()
        addTeardownBlock { @MainActor in try fixture.cleanup() }
        try await fixture.seed()
        let originalGuestBytes = try Data(contentsOf: fixture.manifest(profile: fixture.guest, id: fixture.guestID))
        for profile in [fixture.guest, fixture.a, fixture.b, fixture.guest, fixture.renewed(fixture.a)] {
            PrivateProfileStorage.select(profile)
            let store = PrivateProfileMeetingStore()
            let history = MeetingHistorySnapshot { try await store.loadHistory() }
            await history.refresh()
            XCTAssertTrue(history.hasLoaded)
            XCTAssertNil(history.errorMessage)
            XCTAssertEqual(Set(history.sessions.map(\.id)), fixture.visibleIDs(for: profile),
                           "Every fresh history owner must combine device-guest and current-account records only")
            let guest = try await store.loadTranscript(id: fixture.guestID)
            XCTAssertEqual(guest?.title, "Гостевая встреча Ёж")
            if !profile.isGuest {
                XCTAssertTrue(guest?.profileOwnership?.matches(fixture.guest) == true,
                              "An account reads the guest source without adopting it")
                XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.manifest(profile: profile, id: fixture.guestID).path))
            }
            for foreignID in fixture.accountIDs.subtracting(fixture.visibleIDs(for: profile)) {
                let foreign = try await store.loadTranscript(id: foreignID)
                let directory = try await store.existingSessionDirectory(for: foreignID)
                XCTAssertNil(foreign, "A known foreign account UUID must remain unreadable")
                XCTAssertNil(directory, "A known foreign account UUID must not expose its files")
            }
            await store.finishProfileTransition()
        }
        XCTAssertEqual(try Data(contentsOf: fixture.manifest(profile: fixture.guest, id: fixture.guestID)), originalGuestBytes,
                       "Profile changes and cold history reads must preserve the legacy guest manifest bytes")
        #endif
    }

    func testColdGuestHistoryWaitsForInitialPrivateAdmission() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic launch regression requires an owned simulator")
        #else
        let name = "ColdGuestHistory.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        let previousProfile = PrivateProfileStorage.current
        let profile = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(profile)
        addTeardownBlock { @MainActor in
            PrivateProfileStorage.select(previousProfile)
            defaults.removePersistentDomain(forName: name)
            try? FileManager.default.removeItem(at: root)
        }
        let store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("Meetings"))
        let saved = session(title: "Saved before restart")
        try await store.create(saved)
        let started = expectation(description: "Initial credentials restoration is held")
        let credentials = ColdHistoryCredentials(started: started)
        let account = AccountSessionService(configuration: .init(issuer: URL(string: "https://identity.example")!,
            apiBaseURL: URL(string: "https://api.example")!, clientID: "synthetic",
            apiAudience: "synthetic", bundleIdentifier: "ai.example.voice"),
            browser: ColdHistoryBrowser(), transport: ColdHistoryTransport(), credentials: credentials)
        let services = AppServices(store: store, settings: SettingsStore(defaults: defaults), accountSession: account)
        let captureID = UUID()
        addTeardownBlock { @MainActor in
            await credentials.release()
            services.privateProfiles.clearCaptureStopHandler(id: captureID)
            await services.shutdownForTermination()
        }
        // Mirror production cold startup without using the global store or Keychain.
        PrivateProfileStorage.closeAdmission()
        let sourceRevision = services.privateProfiles.sourceRevision
        let history = MeetingHistorySnapshot { try await store.loadHistory() }
        let read = expectation(description: "Saved history loaded after admission")
        let lifetime = ColdHistoryLifetime()
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previousWindow = scene.windows.first { $0.isKeyWindow }
        let window = UIWindow(windowScene: scene)
        window.rootViewController = UIHostingController(rootView: AdaptiveAppTheme(accent: .blue) {
            PrivateProfileRoot(services: services, profiles: services.privateProfiles) {
                Text("Saved history probe")
                    .onAppear { lifetime.mounts += 1 }
                    .onDisappear { lifetime.unmounts += 1 }
                    .task {
                        lifetime.tasks += 1
                        guard PrivateProfileStorage.acceptsNewWork else { return }
                        await history.refresh()
                        read.fulfill()
                    }
            }
        })
        window.makeKeyAndVisible()
        defer {
            window.isHidden = true; window.rootViewController = nil
            previousWindow?.makeKeyAndVisible()
        }
        await fulfillment(of: [started], timeout: 5)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertFalse(services.hasRestoredAccount)
        XCTAssertEqual(lifetime.mounts, 0, "Opacity must not start private readers before restoration")
        XCTAssertEqual(lifetime.tasks, 0)
        await credentials.release()
        await fulfillment(of: [read], timeout: 5)
        XCTAssertTrue(services.hasRestoredAccount)
        XCTAssertEqual(services.privateProfiles.sourceRevision, sourceRevision, "Guest startup performs no profile switch")
        XCTAssertEqual(history.sessions.map(\.id), [saved.id], "The first admitted load reads saved meetings without user refresh")
        XCTAssertEqual(lifetime.tasks, 1)
        // Busy logout conceals private pixels while retaining an admitted capture owner.
        XCTAssertTrue(services.privateProfiles.installCaptureStopHandler(id: captureID, stop: {}))
        do { try await services.privateProfiles.transition(from: nil, to: nil, generation: UUID()) }
        catch AccountError.busy {}
        XCTAssertFalse(services.privateProfiles.isPrivateDataVisible)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(lifetime.unmounts, 0, "Later concealment must retain the mounted capture controller")
        #endif
    }

    private func session(title: String, concealed: Bool = false) -> MeetingSession {
        var value = MeetingSession(configuration: .init(mode: .inRoom, title: title,
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1,
                            machTimebaseDenominator: 1, firstPresentationTime: nil))
        value.requiresEncryptedPersistence = concealed
        return value
    }

    func testHistoryKeepsOrdinaryMeetingsAndOmitsEncryptedTitles() async {
        let ordinary = session(title: "Earlier ordinary meeting")
        let encrypted = session(title: "Synthetic confidential name", concealed: true)
        let trustedSource = [ordinary, encrypted]
        let history = MeetingHistorySnapshot { trustedSource }
        await history.refresh()
        XCTAssertEqual(history.sessions.map(\.id), [ordinary.id])
        XCTAssertFalse(history.sessions.contains { $0.title == encrypted.title })
        XCTAssertEqual(trustedSource.count, 2, "Presentation must not mutate the trusted delivery source")
        XCTAssertTrue(history.hasLoaded)
        XCTAssertNil(history.errorMessage)
    }

    func testConcealedCommitDoesNotAppendOrRetainACachedHistoryRow() async {
        let ordinary = session(title: "Ordinary")
        let encrypted = session(title: "Synthetic confidential row", concealed: true)
        let history = MeetingHistorySnapshot { [ordinary] }
        await history.refresh()
        history.applyCommitted(encrypted)
        XCTAssertEqual(history.sessions.map(\.id), [ordinary.id])
        // Evict an older presentation if a committed source is now protected.
        var stale = encrypted
        stale.requiresEncryptedPersistence = false
        history.applyCommitted(stale)
        XCTAssertTrue(history.sessions.contains { $0.id == encrypted.id })
        history.applyCommitted(encrypted)
        XCTAssertFalse(history.sessions.contains { $0.id == encrypted.id })
        XCTAssertTrue(history.sessions.contains { $0.id == ordinary.id })
    }
}

/// Invented records in disposable roots; account selection here exercises storage scope,
/// while the existing account lifecycle regressions own authentication and transition joins.
@MainActor private final class SharedGuestNativeFixture {
    let root: URL
    let guest: PrivateProfileSnapshot
    let a: PrivateProfileSnapshot
    let b: PrivateProfileSnapshot
    let guestID = UUID()
    let aID = UUID()
    let bID = UUID()
    let settings: SettingsStore
    private let suite: String
    private let defaults: UserDefaults
    private let previous = PrivateProfileStorage.current
    private let previouslyAdmitted = PrivateProfileStorage.acceptsNewWork

    var accountIDs: Set<UUID> { [aID, bID] }

    init() throws {
        let suite = "SharedGuestNativeHistory.\(UUID().uuidString)"
        self.suite = suite
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        self.defaults = defaults
        let settings = SettingsStore(defaults: defaults, initializeDesktop: false)
        settings.meetingAudioRetentionPolicy = .never
        self.settings = settings
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        self.root = root
        guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        func account(_ subject: String) throws -> PrivateProfileSnapshot {
            let context = AccountContext(identity: .init(issuer: "https://identity.invalid/shared-guest",
                subject: subject, internalUserID: "synthetic-" + subject), organizationID: "synthetic-org",
                workspaceID: "synthetic-workspace", generation: UUID())
            return try PrivateProfileStorage.proposed(context: context, generation: UUID(), legacyRootDirectory: root)
        }
        a = try account("a"); b = try account("b")
    }

    func renewed(_ profile: PrivateProfileSnapshot) -> PrivateProfileSnapshot {
        .init(id: profile.id, context: profile.context, generation: UUID(), rootDirectory: profile.rootDirectory,
              legacyRootDirectory: profile.legacyRootDirectory, isReadable: true)
    }

    func visibleIDs(for profile: PrivateProfileSnapshot) -> Set<UUID> {
        profile.isGuest ? [guestID] : [guestID, profile.id == a.id ? aID : bID]
    }

    func manifest(profile: PrivateProfileSnapshot, id: UUID) -> URL {
        profile.directory("Meetings").appendingPathComponent(id.uuidString).appendingPathComponent("session.json")
    }

    func seed() async throws {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        for (profile, id, title, offset) in [(guest, guestID, "Гостевая встреча Ёж", 0.0),
                                             (a, aID, "Встреча аккаунта А", 60.0), (b, bID, "Встреча аккаунта Б", 120.0)] {
            var record = MeetingSession(id: id, configuration: .init(mode: .inRoom, title: title,
                microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone")),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000 + offset), timebase: timebase)
            record.profileOwnership = profile.isGuest ? nil : .init(profile: profile)
            record.state = .completed; record.endedAt = record.startedAt.addingTimeInterval(30)
            record.audioStorageMode = .memoryOnly; record.transcriptTimeDomain = .meetingRelative
            record.audioTracks = [.init(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
                sourceDisplayName: "Synthetic microphone", format: nil, timebase: timebase, health: .waiting, chunks: [])]
            if profile.isGuest {
                record.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1),
                    end: .init(value: 2, timescale: 1), sourceTrackID: record.audioTracks[0].id, speakerID: nil,
                    text: "Синтетический текст гостевой встречи.", revision: 0, status: .final,
                    overlap: .none, completeness: .complete, attributionState: .unassigned)]
            }
            try await MeetingSessionStore(rootDirectory: profile.directory("Meetings")).create(record)
        }
    }

    func cleanup() throws {
        PrivateProfileStorage.select(previous)
        if !previouslyAdmitted { PrivateProfileStorage.closeAdmission() }
        defaults.removePersistentDomain(forName: suite)
        if FileManager.default.fileExists(atPath: root.path) { try FileManager.default.removeItem(at: root) }
    }
}

@MainActor private final class ColdHistoryLifetime {
    var mounts = 0
    var unmounts = 0
    var tasks = 0
}

private actor ColdHistoryCredentials: AccountCredentialStoring {
    let started: XCTestExpectation
    private var gate: CheckedContinuation<Void, Never>?
    private var released = false
    init(started: XCTestExpectation) { self.started = started }
    func load() async -> AccountGrant? {
        guard !released else { return nil }
        await withCheckedContinuation { gate = $0; started.fulfill() }
        return nil
    }
    func release() { released = true; gate?.resume(); gate = nil }
    func save(_ grant: AccountGrant) { preconditionFailure("No grant belongs to the guest regression") }
    func clear() {}
}

@MainActor private final class ColdHistoryBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw AccountError.unconfigured }
    func authenticate(url: URL, callbackScheme: String, requiresExplicitIdentity: Bool) async throws -> URL { throw AccountError.unconfigured }
    func cancel() {}
}

private struct ColdHistoryTransport: AccountTransporting {
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL { throw AccountError.unconfigured }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func account(accessToken: String) async throws -> AccountSnapshot { throw AccountError.unconfigured }
    func revoke(refreshToken: String) async throws { throw AccountError.unconfigured }
}
