import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import PichiVoiceMobile

/// The publisher retains a trusted read path. Only local presentation omits
/// encrypted content, while ordinary meetings from before opt-in stay visible.
@MainActor
final class MobileEncryptedPresentationTests: XCTestCase {
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

    func testSharedGuestHistoryRendersInCurrentAccountAcrossAppearances() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic native History windows require an owned simulator")
        #else
        let fixture = try SharedGuestNativeFixture()
        addTeardownBlock { @MainActor in try fixture.cleanup() }
        try await fixture.seed()
        for (name, profile) in [("account-a", fixture.a), ("account-b", fixture.b)] {
            for (appearance, style) in [("light", UIUserInterfaceStyle.light), ("dark", UIUserInterfaceStyle.dark)] {
                let reader = fixture.renewed(profile)
                PrivateProfileStorage.select(reader)
                let host = try SharedGuestHistoryWindow(settings: fixture.settings, store: PrivateProfileMeetingStore(), style: style)
                addTeardownBlock { @MainActor in await host.close() }
                let step = "\(name)-\(appearance)"
                do {
                    try await host.openHistory()
                    try await host.waitForRows(fixture.visibleIDs(for: reader), excluding: fixture.accountIDs.subtracting(fixture.visibleIDs(for: reader)))
                    captureSharedGuestHistory(host, step: step)
                    await host.close()
                } catch {
                    captureSharedGuestHistory(host, step: step + "-failed")
                    await host.close()
                    throw error
                }
            }
        }
        #endif
    }

    private func captureSharedGuestHistory(_ host: SharedGuestHistoryWindow, step: String) {
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "unspecified-revision"
        let attachment = XCTAttachment(image: host.image())
        attachment.name = "shared-guest-history-\(step)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
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

/// Hosts the production root and activates its public accessibility action. No premerged
/// session array, test-only app route, authentication, model, microphone or HTTP is used.
@MainActor private final class SharedGuestHistoryWindow {
    private let services: AppServices
    private let window: UIWindow
    private weak var previous: UIWindow?
    private var closed = false

    init(settings: SettingsStore, store: PrivateProfileMeetingStore, style: UIUserInterfaceStyle) throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive })
        let account = AccountSessionService(configuration: nil, browser: ColdHistoryBrowser(),
            transport: ColdHistoryTransport(), credentials: SharedGuestEmptyCredentials())
        let services = AppServices(store: store, settings: settings, accountSession: account)
        self.services = services
        previous = scene.windows.first { $0.isKeyWindow }
        window = UIWindow(windowScene: scene)
        window.windowLevel = .init(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.overrideUserInterfaceStyle = style
        window.rootViewController = UIHostingController(rootView: AdaptiveAppTheme(accent: .blue) {
            MobileMeetingRoot(coordinator: services.meetingSessionCoordinator, asr: services.asr,
                store: services.meetingStore, privacy: services.transcriptPrivacy, required: services.requiredResources,
                privacyActivation: services.privacyActivation, accountSession: account,
                microphones: { .init(identities: [], defaultCoreAudioUID: nil) })
        })
        window.makeKeyAndVisible(); window.layoutIfNeeded()
    }

    func openHistory() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            if let button = elements().first(where: { object in
                if (object as? UIAccessibilityIdentification)?.accessibilityIdentifier == "navigation.history" { return true }
                return ["History", "История"].contains(object.accessibilityLabel ?? "")
                    && object.accessibilityTraits.contains(.button)
            }), button.accessibilityActivate() { return }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "SharedGuestNativeHistory", code: 1,
                      userInfo: [NSLocalizedDescriptionKey: "The native History accessibility action was not available"])
    }

    func waitForRows(_ expected: Set<UUID>, excluding foreign: Set<UUID>) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while ContinuousClock.now < deadline {
            let identifiers = Set(elements().compactMap { ($0 as? UIAccessibilityIdentification)?.accessibilityIdentifier })
            if expected.allSatisfy({ identifiers.contains("history.session.\($0.uuidString)") }) {
                XCTAssertTrue(foreign.allSatisfy { !identifiers.contains("history.session.\($0.uuidString)") },
                              "The native History must not show another account's meeting")
                return
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        throw NSError(domain: "SharedGuestNativeHistory", code: 2,
                      userInfo: [NSLocalizedDescriptionKey: "The native History did not render the guest and selected-account rows"])
    }

    private func elements() -> [NSObject] {
        var result: [NSObject] = []
        var seen = Set<ObjectIdentifier>()
        var pending: [NSObject] = [window]
        while let object = pending.popLast(), result.count < 5_000, pending.count < 10_000 {
            guard seen.insert(ObjectIdentifier(object)).inserted else { continue }
            result.append(object)
            if let view = object as? UIView { pending.append(contentsOf: view.subviews) }
            pending.append(contentsOf: (object.automationElements ?? []).compactMap { $0 as? NSObject })
            pending.append(contentsOf: (object.accessibilityElements ?? []).compactMap { $0 as? NSObject })
            let count = object.accessibilityElementCount()
            if (1...500).contains(count) {
                for index in 0..<count {
                    if let child = object.accessibilityElement(at: index) as? NSObject { pending.append(child) }
                }
            }
        }
        return result
    }

    func image() -> UIImage {
        window.layoutIfNeeded()
        return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
    }

    func close() async {
        guard !closed else { return }; closed = true
        let restore = window.isKeyWindow && window.windowScene?.activationState == .foregroundActive
        window.isHidden = true; window.rootViewController = nil
        if restore { previous?.makeKeyAndVisible() }
        await services.shutdownForTermination()
    }
}

private actor SharedGuestEmptyCredentials: AccountCredentialStoring {
    func load() -> AccountGrant? { nil }
    func save(_ grant: AccountGrant) { preconditionFailure("No account grant belongs to this native guest fixture") }
    func clear() {}
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
