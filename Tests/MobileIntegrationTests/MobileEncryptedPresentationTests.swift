import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import PichiVoiceMobile

/// The publisher retains a trusted read path. Only local presentation omits
/// encrypted content, while ordinary meetings from before opt-in stay visible.
@MainActor
final class MobileEncryptedPresentationTests: XCTestCase {
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
        defer {
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
        let captureID = UUID()
        XCTAssertTrue(services.privateProfiles.installCaptureStopHandler(id: captureID, stop: {}))
        do { try await services.privateProfiles.transition(from: nil, to: nil, generation: UUID()) }
        catch AccountError.busy {}
        XCTAssertFalse(services.privateProfiles.isPrivateDataVisible)
        try await Task.sleep(for: .milliseconds(150))
        XCTAssertEqual(lifetime.unmounts, 0, "Later concealment must retain the mounted capture controller")
        services.privateProfiles.clearCaptureStopHandler(id: captureID)
        await services.shutdownForTermination()
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

@MainActor private final class ColdHistoryLifetime {
    var mounts = 0
    var unmounts = 0
    var tasks = 0
}

private actor ColdHistoryCredentials: AccountCredentialStoring {
    let started: XCTestExpectation
    private var gate: CheckedContinuation<Void, Never>?
    init(started: XCTestExpectation) { self.started = started }
    func load() async -> AccountGrant? {
        await withCheckedContinuation { gate = $0; started.fulfill() }
        return nil
    }
    func release() { gate?.resume(); gate = nil }
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
