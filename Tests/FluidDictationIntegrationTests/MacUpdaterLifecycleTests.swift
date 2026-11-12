import AppKit
@testable import FluidVoice_Debug
import XCTest

@MainActor
final class MacUpdaterLifecycleTests: XCTestCase {
    func testAbsentAndNonStringInstalledBuildMetadataCannotBecomeBuildZero() async throws {
        let context = try Context()
        defer { context.close() }
        context.updater.currentBuildForTesting = nil
        for information: [String: Any] in [
            ["CFBundleShortVersionString": "0.1.0"],
            ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": 71],
            ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": true],
            ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": NSNull()],
        ] {
            context.updater.currentBundleInformationForTesting = information
            do {
                _ = try await context.updater.checkForUpdate(owner: "Pichi-AI", repo: "pichi-voice")
                XCTFail("Unverified installed metadata must not become build zero")
            } catch {}
        }
        XCTAssertEqual(context.fixture.downloadCount, 0)
        XCTAssertNil(context.updater.availableUpdateVersion)
        await context.cleanup()
    }

    func testUnknownInstalledBuildFailsClosedInsteadOfComparingAsZero() async throws {
        let context = try Context()
        defer { context.close() }
        for build in ["unknown", "71.1", "999999999999999999999999999999"] {
            context.updater.currentBuildForTesting = build
            do {
                _ = try await context.updater.checkForUpdate(owner: "Pichi-AI", repo: "pichi-voice")
                XCTFail("Unsupported installed build must not offer another release")
            } catch {}
        }
        XCTAssertEqual(context.fixture.downloadCount, 0)
        XCTAssertNil(context.updater.availableUpdateVersion)
        await context.cleanup()
    }

    func testSameMarketingVersionComparesEveryOlderEqualAndNewerBuild() async throws {
        let context = try Context()
        defer { context.close() }
        for current in [69, 70, 71] {
            context.updater.currentBuildForTesting = String(current)
            for available in [69, 70, 71] {
                context.fixture.releases = [fixtureRelease(available)]
                let result = try await context.updater.checkForUpdate(owner: "Pichi-AI", repo: "pichi-voice")
                XCTAssertEqual(result.hasUpdate, available > current, "current \(current), available \(available)")
            }
        }
        await context.cleanup()
    }

    func testOlderBuildIsNotOfferedDownloadedOrInstalledAsAnUpdate() async throws {
        let context = try Context()
        defer { context.close() }
        context.updater.currentBuildForTesting = "71"
        context.fixture.releases = [fixtureRelease(69)]
        var installs = 0
        context.updater.installStagedForTesting = { _, _ in installs += 1 }
        context.updater.checkForUpdatesAutomatically()
        try await wait { !context.updater.isCheckingForUpdates }
        XCTAssertNil(context.updater.availableUpdateVersion)
        XCTAssertEqual(context.updater.downloadState, .idle)
        do {
            try await context.updater.checkAndUpdate(owner: "Pichi-AI", repo: "pichi-voice")
            XCTFail("An ordinary update must not install an older build")
        } catch {}
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(context.fixture.downloadCount, 0)
        XCTAssertFalse(context.updater.isUpdateInProgress)
        await context.cleanup()
    }

    func testQuitWaitsForCommittedRelaunchBeforeAllowingTermination() async {
        await self.assertTerminationBarrier(recoveredFailure: false)
    }

    func testQuitWaitsForRecoveryBeforeReleasingTheOperation() async {
        await self.assertTerminationBarrier(recoveredFailure: true)
    }

    private func assertTerminationBarrier(recoveredFailure: Bool) async {
        let gate = UpdateOperationGate()
        XCTAssertTrue(gate.begin())
        XCTAssertTrue(gate.beginCommit())
        let token = UUID().uuidString
        guard let defaults = UserDefaults(suiteName: token) else { return XCTFail("Fixture defaults unavailable") }
        defer { defaults.removePersistentDomain(forName: token) }
        let updater = SimpleUpdater(defaults: defaults, promptPresenter: UpdatePromptPresenter(), operationGate: gate)
        var returned = false
        let quit = Task { @MainActor in
            await updater.shutdownForTermination()
            returned = true
        }
        await Task.yield()
        XCTAssertFalse(returned, "Quit must not abandon the owner while commit/relaunch/recovery is held")
        if recoveredFailure { gate.finish() } else { gate.allowTermination() }
        await quit.value
        XCTAssertTrue(returned)
        XCTAssertEqual(gate.isActive, !recoveredFailure, "Successful relaunch keeps capture admission closed until the old process exits")
        gate.finish()
    }

    func testSelectionUsesBuildAndExcludesDraftRuntimeWrongArtifactAndBeta() async throws {
        let context = try Context()
        defer { context.close() }
        context.fixture.releases = [
            fixtureRelease(69), fixtureRelease(71), fixtureRelease(100, draft: true),
            fixtureRelease(120, tag: "runtime-v0.1.0"), fixtureRelease(130, wrongAsset: true),
            fixtureRelease(140, beta: true), fixtureRelease(150, wrongURL: true),
        ]
        let result = try await context.updater.checkForUpdate(owner: "Pichi-AI", repo: "pichi-voice")
        XCTAssertTrue(result.hasUpdate)
        XCTAssertEqual(result.latestVersion, "0.1.0 (71)")
        let beta = try await context.updater.checkForUpdate(owner: "Pichi-AI", repo: "pichi-voice", includePrerelease: true)
        XCTAssertEqual(beta.latestVersion, "0.1.0 (140)")
        context.updater.currentBuildForTesting = "151"
        let older = try await context.updater.fetchRecentReleaseBuildOptions(owner: "Pichi-AI", repo: "pichi-voice", olderThanCurrent: true)
        XCTAssertEqual(older.map(\.displayVersion), ["0.1.0 (71)", "0.1.0 (69)"])
        await context.cleanup()
    }

    func testAutomaticDownloadDefaultOnDeduplicatesAndInstallReusesVerifiedFile() async throws {
        let context = try Context()
        defer { context.close() }
        var installs = 0
        context.updater.installStagedForTesting = { app, selected in
            XCTAssertTrue(FileManager.default.fileExists(atPath: app.path))
            XCTAssertEqual(selected.tag, "v0.1.0+71-public.1")
            XCTAssertEqual(context.asr.activeExclusiveActivity, .settingsRestore)
            XCTAssertThrowsError(try context.asr.acquireExclusiveActivity(.dictation))
            context.asr.micStatus = .authorized
            await context.asr.startMicrophonePreview()
            XCTAssertFalse(context.asr.isMicrophonePreviewActive)
            installs += 1
        }
        context.updater.checkForUpdatesAutomatically()
        try await wait { context.updater.downloadState == .ready("0.1.0 (71)") }
        context.updater.checkForUpdatesAutomatically()
        try await wait { !context.updater.isCheckingForUpdates }
        XCTAssertEqual(context.fixture.downloadCount, 1)
        XCTAssertEqual(installs, 0, "Automatic download must never install without an explicit approval action")
        XCTAssertFalse(context.updater.isUpdateInProgress)
        // The offer's actual native button routes through SimpleUpdater's approval action.
        context.updater.showAvailableUpdate()
        let offer = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "Update Available" })
        let install = try XCTUnwrap(offer.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Install Now" })
        install.performClick(nil)
        try await wait { installs == 1 && !context.updater.isUpdateInProgress }
        XCTAssertEqual(context.fixture.downloadCount, 1)
        XCTAssertNil(context.asr.activeExclusiveActivity)
        let capture = try context.asr.acquireExclusiveActivity(.dictation)
        context.asr.releaseExclusiveActivity(capture)
        await context.cleanup()
    }

    func testDisabledAutomaticDownloadsDiscoverWithoutTransportAndPreferenceCancels() async throws {
        let context = try Context()
        defer { context.close() }
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.automaticUpdateDownloads)
        context.updater.checkForUpdatesAutomatically()
        try await wait { !context.updater.isCheckingForUpdates }
        XCTAssertEqual(context.updater.availableUpdateVersion, "0.1.0 (71)")
        XCTAssertEqual(context.fixture.downloadCount, 0)
        context.fixture.holdDownloads = true
        context.defaults.set(true, forKey: SettingsStore.UpdateKeys.automaticUpdateDownloads)
        context.updater.automaticDownloadPreferenceDidChange()
        try await wait { context.fixture.downloadCount == 1 }
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.automaticUpdateDownloads)
        context.updater.automaticDownloadPreferenceDidChange()
        await context.updater.cancelPendingUpdate()
        XCTAssertEqual(context.updater.downloadState, .idle)
        XCTAssertGreaterThanOrEqual(context.fixture.cancelCount, 1)
        await context.cleanup()
    }

    func testTerminationJoinsBackgroundDownloadAndReleasesItsWorkspace() async throws {
        let context = try Context()
        defer { context.close() }
        context.fixture.holdDownloads = true
        context.updater.checkForUpdatesAutomatically()
        try await wait { context.fixture.downloadCount == 1 }
        await context.updater.shutdownForTermination()
        XCTAssertGreaterThanOrEqual(context.fixture.cancelCount, 1)
        XCTAssertEqual(context.updater.downloadState, .idle)
        XCTAssertFalse(context.updater.isCheckingForUpdates)
        let contents = try FileManager.default.contentsOfDirectory(at: context.temporaryDirectory, includingPropertiesForKeys: [.isDirectoryKey])
        XCTAssertFalse(try contents.contains { try $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true })
        context.fixture.holdDownloads = false
        context.updater.checkForUpdatesAutomatically()
        try await wait { context.updater.downloadState == .ready("0.1.0 (71)") }
        await context.updater.shutdownForTermination()
        XCTAssertEqual(context.fixture.downloadCount, 2)
        await context.cleanup()
    }

    func testHTTPFailureCanRetryAndChannelMutationJoinsCancelledDownload() async throws {
        let context = try Context()
        defer { context.close() }
        context.fixture.downloadStatus = 503
        context.updater.checkForUpdatesAutomatically()
        try await wait { if case .failed = context.updater.downloadState { return true }; return false }
        XCTAssertFalse(context.updater.isUpdateInProgress)
        context.fixture.downloadStatus = 200
        context.fixture.holdDownloads = true
        context.updater.automaticDownloadPreferenceDidChange()
        try await wait { context.fixture.downloadCount == 2 }
        context.defaults.set(1, forKey: SettingsStore.UpdateKeys.channelPreferenceRevision)
        context.defaults.set(true, forKey: SettingsStore.UpdateKeys.betaReleasesEnabled)
        context.updater.updateChannelDidChange()
        await context.updater.cancelPendingUpdate()
        XCTAssertNil(context.updater.availableUpdateVersion)
        XCTAssertEqual(context.updater.downloadState, .idle)
        XCTAssertGreaterThanOrEqual(context.fixture.cancelCount, 1)
        context.fixture.holdDownloads = false
        context.fixture.releases = [fixtureRelease(72, beta: true)]
        context.updater.checkForUpdatesAutomatically()
        try await wait { context.updater.downloadState == .ready("0.1.0 (72)") }
        XCTAssertEqual(context.updater.availableUpdateVersion, "0.1.0 (72)")
        await context.cleanup()
    }

    func testNativeCancelRoutesToJoinedDownloadCleanupAndCaptureCanResume() async throws {
        let context = try Context()
        defer { context.close() }
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.automaticUpdateDownloads)
        context.fixture.holdDownloads = true
        context.updater.checkForUpdatesManually()
        try await wait { !context.updater.isCheckingForUpdates }
        let offer = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title == "Update Available" })
        try XCTUnwrap(offer.contentView?.subviews.compactMap { $0 as? NSButton }.first { $0.title == "Install Now" }).performClick(nil)
        try await wait { context.fixture.downloadCount == 1 && context.updater.isUpdateInProgress }
        let status = try XCTUnwrap(NSApp.windows.first { $0.isVisible && $0.title.hasPrefix("Installing ") })
        let cancel = try XCTUnwrap(status.contentView?.subviews.compactMap { $0 as? UpdateCancelButton }.first)
        cancel.performClick(nil)
        try await wait { !context.updater.isUpdateInProgress && context.fixture.cancelCount > 0 }
        XCTAssertFalse(status.isVisible)
        XCTAssertEqual(context.updater.downloadState, .idle)
        let capture = try context.asr.acquireExclusiveActivity(.meeting)
        context.asr.releaseExclusiveActivity(capture)
        await context.cleanup()
    }

    func testCaptureAdmissionRejectsEveryExclusiveConsumerAndSurvivesASRFailure() async throws {
        let context = try Context()
        defer { context.close() }
        context.updater.checkForUpdatesAutomatically()
        try await wait { context.updater.downloadState == .ready("0.1.0 (71)") }
        var installs = 0
        context.updater.installStagedForTesting = { _, _ in installs += 1 }
        for activity: ASRExclusiveActivity in [.meeting, .dictation, .fileTranscription, .localAPI, .modelMaintenance] {
            let lease = try context.asr.acquireExclusiveActivity(activity)
            context.asr.isAsrReady = false // Losing ASR readiness never frees a live capture's lease.
            do {
                try await context.updater.checkAndUpdate(owner: "Pichi-AI", repo: "pichi-voice", expectedVersion: "0.1.0 (71)")
                XCTFail("An active consumer must veto replacement")
            } catch {}
            XCTAssertEqual(context.asr.activeExclusiveActivity, activity)
            XCTAssertEqual(installs, 0)
            context.asr.releaseExclusiveActivity(lease)
        }
        context.updater.installStagedForTesting = { _, _ in throw URLError(.cannotOpenFile) }
        do { try await context.updater.checkAndUpdate(owner: "Pichi-AI", repo: "pichi-voice"); XCTFail("Injected swap boundary should fail") } catch {}
        XCTAssertNil(context.asr.activeExclusiveActivity)
        XCTAssertFalse(context.updater.isUpdateInProgress)
        let resumed = try context.asr.acquireExclusiveActivity(.dictation)
        context.asr.releaseExclusiveActivity(resumed)
        await context.cleanup()
    }

    func testDefaultUpdaterAdmissionProtectsTheApplicationCaptureService() async throws {
        let context = try Context(useDefaultAdmission: true)
        defer { context.close() }
        context.updater.checkForUpdatesAutomatically()
        try await wait { context.updater.downloadState == .ready("0.1.0 (71)") }
        var installs = 0
        context.updater.installStagedForTesting = { _, _ in installs += 1 }
        let lease = try context.asr.acquireExclusiveActivity(.meeting)
        defer { context.asr.releaseExclusiveActivity(lease) }
        do {
            try await context.updater.checkAndUpdate(owner: "Pichi-AI", repo: "pichi-voice")
            XCTFail("The default composition must observe the application's capture lease")
        } catch {}
        XCTAssertEqual(installs, 0)
        XCTAssertEqual(context.asr.activeExclusiveActivity, .meeting)
        await context.cleanup()
    }

    func testPendingCaptureFinalizationAndTrainingRejectInstallationWithoutOwningAudio() throws {
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        for state in ["running", "starting", "finalizing", "training", "recovering"] {
            service.isRunning = state == "running"
            service.configureDictationModeSwitchForTesting(ownedLease: nil, starting: state == "starting", finalizing: state == "finalizing", dictionaryTraining: state == "training")
            let finish = state == "recovering" ? service.beginDictationBufferDrainForTesting(recovering: true) : nil
            XCTAssertThrowsError(try SimpleUpdater.reserveInstallation(using: service), "\(state)")
            XCTAssertNil(service.activeExclusiveActivity)
            finish?()
            service.isRunning = false
            service.configureDictationModeSwitchForTesting(ownedLease: nil)
        }
        let release = try SimpleUpdater.reserveInstallation(using: service)
        XCTAssertEqual(service.activeExclusiveActivity, .settingsRestore)
        release()
        XCTAssertNil(service.activeExclusiveActivity)
    }

    func testSameTagAssetMutationRequiresFreshApproval() async throws {
        let context = try Context()
        defer { context.close() }
        context.defaults.set(false, forKey: SettingsStore.UpdateKeys.automaticUpdateDownloads)
        context.updater.checkForUpdatesAutomatically()
        try await wait { !context.updater.isCheckingForUpdates }
        var changed = fixtureRelease(71)
        var assets = changed["assets"] as! [[String: Any]]
        assets[0]["digest"] = "sha256:" + String(repeating: "0", count: 64)
        changed["assets"] = assets
        context.fixture.releases = [changed]
        do {
            try await context.updater.checkAndUpdate(owner: "Pichi-AI", repo: "pichi-voice", expectedVersion: "0.1.0 (71)")
            XCTFail("Same tag with a changed asset is a new selection")
        } catch { XCTAssertEqual(error.localizedDescription, SimpleUpdateError.releaseChanged.localizedDescription) }
        XCTAssertEqual(context.fixture.downloadCount, 0)
        await context.cleanup()
    }

    func testDigestMismatchNeverReachesExtraction() async throws {
        let context = try Context()
        defer { context.close() }
        var changed = fixtureRelease(71)
        var assets = changed["assets"] as! [[String: Any]]
        assets[0]["digest"] = "sha256:" + String(repeating: "0", count: 64)
        changed["assets"] = assets
        context.fixture.releases = [changed]
        context.updater.stageDownloadForTesting = { _, _, _ in XCTFail("Digest mismatch must reject before extraction"); throw URLError(.badServerResponse) }
        context.updater.checkForUpdatesAutomatically()
        try await wait { if case .failed = context.updater.downloadState { return true }; return false }
        XCTAssertEqual(context.fixture.downloadCount, 1)
        await context.cleanup()
    }

    func testBackupMigratesAutomaticDownloadPreferenceWithoutOverwritingLegacyChoice() throws {
        let suite = UUID().uuidString
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let settings = SettingsStore(defaults: defaults, initializeDesktop: false)
        XCTAssertTrue(settings.automaticUpdateDownloads)
        settings.automaticUpdateDownloads = false
        var payload = settings.makeBackupPayload()
        payload.automaticUpdateDownloads = false
        let data = try JSONEncoder().encode(payload)
        XCTAssertEqual(try JSONDecoder().decode(SettingsBackupPayload.self, from: data).automaticUpdateDownloads, false)
        var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        legacy.removeValue(forKey: "automaticUpdateDownloads")
        XCTAssertNil(try JSONDecoder().decode(SettingsBackupPayload.self, from: JSONSerialization.data(withJSONObject: legacy)).automaticUpdateDownloads)
    }

    func testPichiNeverForceRetiresAnOlderInstance() {
        XCTAssertFalse(SupersededInstanceRetirement.permitsLegacyRetirement(owner: "Pichi-AI", repo: "pichi-voice"))
        XCTAssertTrue(SupersededInstanceRetirement.permitsLegacyRetirement(owner: "altic-dev", repo: "FluidVoice"))
    }

    private func wait(_ predicate: @MainActor () -> Bool) async throws {
        for _ in 0..<300 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTFail("Updater fixture timed out")
        throw URLError(.timedOut)
    }
}

private nonisolated func fixtureRelease(_ build: Int, tag: String? = nil, draft: Bool = false, beta: Bool = false, wrongAsset: Bool = false, wrongURL: Bool = false) -> [String: Any] {
    let tag = tag ?? "v0.1.0+\(build)-\(beta ? "beta" : "public").1"
    let asset = "Pichi-Voice-0.1.0-\(build)-macos-arm64.dmg"
    return ["tag_name": tag, "draft": draft, "prerelease": beta, "assets": [[
        "name": wrongAsset ? "runtime.zip" : asset,
        "content_type": "application/x-apple-diskimage",
        "browser_download_url": "https://github.com/\(wrongURL ? "untrusted" : "Pichi-AI")/pichi-voice/releases/download/\(tag)/\(asset)",
    ]]]
}

@MainActor
private final class Context {
    let token = UUID().uuidString
    let defaults: UserDefaults
    let fixture = Transport()
    let session: URLSession
    let presenter = UpdatePromptPresenter()
    let asr: ASRService
    let updater: SimpleUpdater
    let temporaryDirectory = FileManager.default.temporaryDirectory.appendingPathComponent("MacUpdaterLifecycleTests-" + UUID().uuidString)

    init(useDefaultAdmission: Bool = false) throws {
        asr = useDefaultAdmission ? AppServices.shared.asr : ASRService(meetingModelResidency: MeetingModelResidencyCoordinator())
        defaults = try XCTUnwrap(UserDefaults(suiteName: token))
        defaults.set(false, forKey: SettingsStore.UpdateKeys.showUpdatePopups)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TransportProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Mac-Updater-Fixture": token]
        session = URLSession(configuration: configuration)
        TransportProtocol.register(fixture, token: token)
        let service = asr
        if useDefaultAdmission {
            updater = SimpleUpdater(session: session, defaults: defaults, promptPresenter: presenter)
        } else {
            updater = SimpleUpdater(session: session, defaults: defaults, promptPresenter: presenter, installationAdmission: {
                try SimpleUpdater.reserveInstallation(using: service)
            })
        }
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: false)
        updater.downloadTemporaryDirectoryForTesting = temporaryDirectory
        updater.updatesEnabledForTesting = true
        updater.currentVersionForTesting = "0.1.0"
        updater.currentBuildForTesting = "70"
        updater.stageDownloadForTesting = { _, root, _ in
            let app = root.appendingPathComponent("Pichi Voice.app", isDirectory: true)
            try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
            return app
        }
    }

    func cleanup() async {
        await updater.cancelPendingUpdate()
        presenter.dismissAll()
        updater.dismissUpdateInstallStatus()
    }

    func close() {
        session.invalidateAndCancel()
        TransportProtocol.remove(token)
        defaults.removePersistentDomain(forName: token)
        try? FileManager.default.removeItem(at: temporaryDirectory)
        presenter.dismissAll()
        updater.dismissUpdateInstallStatus()
    }
}

private final nonisolated class Transport: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [[String: Any]] = [fixtureRelease(71)]
    private var hold = false
    private var status = 200
    private var downloads = 0
    private var cancelled = 0
    private var pending: [ObjectIdentifier: TransportProtocol] = [:]
    var releases: [[String: Any]] { get { lock.withLock { entries } } set { lock.withLock { entries = newValue } } }
    var holdDownloads: Bool { get { lock.withLock { hold } } set { lock.withLock { hold = newValue } } }
    var downloadStatus: Int { get { lock.withLock { status } } set { lock.withLock { status = newValue } } }
    var downloadCount: Int { lock.withLock { downloads } }
    var cancelCount: Int { lock.withLock { cancelled } }

    func receive(_ request: TransportProtocol) {
        let isDownload = request.request.url!.host == "github.com"
        let reply: (Int, Data, Bool) = lock.withLock {
            if isDownload {
                downloads += 1
                if hold { pending[ObjectIdentifier(request)] = request }
                return (status, Data("synthetic DMG transport bytes".utf8), hold)
            }
            return (200, try! JSONSerialization.data(withJSONObject: entries), false)
        }
        if reply.2 { return }
        let response = HTTPURLResponse(url: request.request.url!, statusCode: reply.0, httpVersion: nil, headerFields: ["Content-Length": String(reply.1.count)])!
        request.client?.urlProtocol(request, didReceive: response, cacheStoragePolicy: .notAllowed)
        request.client?.urlProtocol(request, didLoad: reply.1)
        request.client?.urlProtocolDidFinishLoading(request)
    }
    func cancel(_ request: TransportProtocol) {
        lock.withLock {
            if pending.removeValue(forKey: ObjectIdentifier(request)) != nil { cancelled += 1 }
        }
    }
}

private final nonisolated class TransportProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: Transport] = [:]
    private var owner: Transport?
    static func register(_ fixture: Transport, token: String) { lock.withLock { fixtures[token] = fixture } }
    static func remove(_ token: String) { _ = lock.withLock { fixtures.removeValue(forKey: token) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        guard let token = request.value(forHTTPHeaderField: "X-Mac-Updater-Fixture"),
              let fixture = Self.lock.withLock({ Self.fixtures[token] }) else {
            client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        owner = fixture
        fixture.receive(self)
    }
    override func stopLoading() { owner?.cancel(self) }
}
