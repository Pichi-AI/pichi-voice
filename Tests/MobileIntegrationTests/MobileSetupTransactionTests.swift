import XCTest
import SwiftUI
import UIKit
@testable import PichiVoiceMobile

@MainActor
final class MobileSetupTransactionTests: XCTestCase {
    private func settings() throws -> SettingsStore {
        let name = "MobileSetupTransactionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return SettingsStore(defaults: defaults)
    }

    private func profileScopedSettings() throws -> (settings: SettingsStore,
                                                    guest: PrivateProfileSnapshot,
                                                    account: PrivateProfileSnapshot) {
        let original = PrivateProfileStorage.current
        let originalAdmission = PrivateProfileStorage.acceptsNewWork
        let identifier = UUID().uuidString
        let guestName = "MobileSetupTransactionTests.guest.\(identifier)"
        let guestDefaults = try XCTUnwrap(UserDefaults(suiteName: guestName))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(identifier)
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(),
            legacyRootDirectory: root)
        let account = try PrivateProfileStorage.proposed(context: .init(identity: .init(
            issuer: "https://synthetic.invalid", subject: identifier, internalUserID: identifier),
            organizationID: "synthetic-org", workspaceID: "synthetic-workspace", generation: UUID()),
            generation: UUID(), legacyRootDirectory: root)
        let domains = [guestName, AppBrand.storageNamespace + ".private-profile." + account.id]
        addTeardownBlock {
            await MainActor.run {
                PrivateProfileStorage.select(original)
                if !originalAdmission { PrivateProfileStorage.closeAdmission() }
            }
            for name in domains {
                UserDefaults(suiteName: name)?.removePersistentDomain(forName: name)
            }
        }
        PrivateProfileStorage.select(guest)
        return (SettingsStore(defaults: PrivateProfileDefaults(guestDefaults: guestDefaults),
            initializeDesktop: false), guest, account)
    }

    func testLocationConsentDefaultsOffAndPersistsWithoutReopeningSetup() throws {
        let value = try settings()
        value.migrateMobileSetup()
        XCTAssertFalse(value.meetingLocationEnabled)
        value.mobileSetupCompleted = true
        value.meetingLocationEnabled = true
        value.migrateMobileSetup()
        XCTAssertTrue(value.meetingLocationEnabled)
        XCTAssertTrue(value.mobileSetupCompleted)
        value.mobileSetupStep = 6
        XCTAssertEqual(value.mobileSetupStep, 6)
        value.meetingLocationEnabled = false
        value.migrateMobileSetup()
        XCTAssertFalse(value.meetingLocationEnabled)
        XCTAssertTrue(value.mobileSetupCompleted)
    }

    func testReplayReturnsToTheFirstPageAndKeepsChoices() throws {
        let value = try settings()
        value.migrateMobileSetup()
        value.mobileSetupSelectedModel = .whisperTiny
        value.meetingLocationEnabled = true
        value.mobileSetupStep = 6
        value.mobileSetupCompleted = true
        XCTAssertFalse(value.isReplayingMobileSetup)
        value.resetMobileSetupProgress()
        XCTAssertFalse(value.mobileSetupCompleted)
        XCTAssertEqual(value.mobileSetupStep, 0)
        XCTAssertNil(value.mobileSetupSelectedModel, "Replay preselects the current model, not the first setup's choice")
        XCTAssertTrue(value.isReplayingMobileSetup)
        XCTAssertTrue(value.meetingLocationEnabled)
        value.mobileSetupCompleted = true
        XCTAssertFalse(value.isReplayingMobileSetup)
    }

    func testCleanInstallAndInterruptedSetupKeepPrivacyOffAndResumeSelection() throws {
        let value = try settings()
        value.migrateMobileSetup()
        XCTAssertFalse(value.mobileSetupCompleted)
        XCTAssertFalse(value.meetingPIIRedactionRequested)
        XCTAssertFalse(value.meetingPIIRedactionEnabled)
        XCTAssertTrue(value.meetingSpeakerLabelsEnabled)
        value.mobileSetupStep = 2
        value.mobileSetupSelectedModel = .whisperTiny
        value.migrateMobileSetup()
        XCTAssertEqual(value.mobileSetupStep, 2)
        XCTAssertEqual(value.mobileSetupSelectedModel, .whisperTiny)
        XCTAssertFalse(value.mobileSetupCompleted)
    }

    func testOldInstallKeepsExplicitPrivacyAudioModelAndRetiresLegacySpeakerControls() throws {
        let value = try settings()
        value.selectedSpeechModel = .parakeetTDT
        value.meetingPIIRedactionEnabled = true
        value.meetingSaveAudio = false
        value.meetingSpeakerLabelsEnabled = false
        value.meetingSpeakerProcessingMode = .afterRecording
        value.migrateMobileSetup()
        XCTAssertTrue(value.mobileSetupCompleted)
        XCTAssertTrue(value.meetingPIIRedactionRequested)
        XCTAssertTrue(value.meetingPIIRedactionEnabled)
        XCTAssertFalse(value.meetingSaveAudio)
        XCTAssertEqual(value.selectedSpeechModel, .parakeetTDT)
        XCTAssertTrue(value.meetingSpeakerLabelsEnabled)
        XCTAssertEqual(value.meetingSpeakerProcessingMode(for: .inRoom), .streaming)
        XCTAssertEqual(value.meetingSpeakerProcessingMode(for: .onlineCall), .streaming,
                       "Retired implicit controls use the registered multi-track streaming capability")
    }

    func testRequiredSetupSharesOneJobAndCancellationDetachesOnlyItsWaiter() async throws {
        var speechCalls = 0
        var speechContinuation: CheckedContinuation<Void, Never>?
        let store = MeetingDiarizationModelStore(supportsOwnerVoiceVerification: false,
            validate: { throw URLError(.notConnectedToInternet) },
            install: { _ in throw URLError(.notConnectedToInternet) })
        let resources = MobileRequiredResources(prepareSpeech: {
            speechCalls += 1
            await withCheckedContinuation { speechContinuation = $0 }
        }, speakerStore: { _ in store })
        let background = Task { try await resources.prepare(modelID: "synthetic") }
        for _ in 0..<1_000 where speechContinuation == nil { await Task.yield() }
        let loader = try XCTUnwrap(speechContinuation)
        let detached = Task { try await resources.prepare(modelID: "synthetic") }
        for _ in 0..<10 { await Task.yield() }
        detached.cancel()
        do { try await detached.value; XCTFail("Expected cancellation") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertTrue(resources.isPreparing)
        XCTAssertEqual(speechCalls, 1)
        loader.resume()
        do { try await background.value; XCTFail("A failed resource check must fail setup") }
        catch { }
        XCTAssertFalse(resources.isPreparing)
        if case .failed = resources.phase {} else { XCTFail("Expected resource failure") }
    }

    func testBackgroundAndEnrollmentJoinTheCanonicalVoiceInstallation() async throws {
        let voice = SetupVoiceResourceProbe()
        let started = expectation(description: "Canonical voice installation has started")
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
        defer { releaseSignal.finish() }
        let artifact = MeetingNemotronModelArtifact(packageURL: URL(fileURLWithPath: "/synthetic-unused"),
            totalByteCount: 1, fileCount: 1, manifestSHA256: "synthetic", entryMetadataSHA256: "synthetic",
            profile: .experimentalFast128FP16CPU)
        let selected = MeetingDiarizationModelStore(validate: { artifact },
            validateVoice: { throw URLError(.unsupportedURL) },
            installVoice: { _ in throw URLError(.unsupportedURL) })
        let canonical = MeetingDiarizationModelStore(validate: { artifact }, validateVoice: {
            if !voice.isReady { throw URLError(.fileDoesNotExist) }
        }, installVoice: { _ in
            voice.begin()
            started.fulfill()
            for await _ in release { break }
            voice.finish()
        })
        var speechChecks = 0
        let resources = MobileRequiredResources(prepareSpeech: { speechChecks += 1 }, voiceStore: canonical, speakerStore: { _ in selected })
        let background = Task { try await resources.prepare(modelID: "synthetic") }
        await fulfillment(of: [started], timeout: 5)
        guard voice.starts == 1 else {
            releaseSignal.finish()
            do { try await background.value }
            catch { XCTFail("Canonical voice preparation ended before installation began: \(error)") }
            return
        }
        let enrollment = Task { try await canonical.prepare(dependencies: [.voiceMatching]) }
        for _ in 0..<10 { await Task.yield() }
        releaseSignal.yield(())
        try await background.value
        try await enrollment.value
        XCTAssertEqual(resources.phase, .ready)
        try await resources.prepare(modelID: "synthetic")
        XCTAssertEqual(speechChecks, 1, "Onboarding and Start must reuse the completed job without retiring idle warmup")
        XCTAssertTrue(canonical.voiceMatchingReady)
        XCTAssertEqual(voice.starts, 1)
        XCTAssertFalse(selected.voiceMatchingReady, "Profile-specific installation must not own the shared encoder")
    }

    func testPrivacyActivationCommitsOnlyAfterActualPreparationAndJoinsRepeatedEnable() async throws {
        let settings = try settings()
        var continuation: CheckedContinuation<Void, Error>?
        var starts = 0
        let activation = MobilePrivacyActivation(settings: settings) { progress in
            starts += 1
            progress(0.25)
            try await withCheckedThrowingContinuation { continuation = $0 }
        }
        activation.setEnabled(true)
        activation.setEnabled(true)
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        _ = try XCTUnwrap(continuation)
        XCTAssertEqual(starts, 1)
        XCTAssertEqual(activation.state, .enabling)
        XCTAssertTrue(settings.meetingPIIRedactionRequested)
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
        continuation?.resume()
        try await activation.waitUntilReadyIfRequested()
        XCTAssertTrue(settings.meetingPIIRedactionEnabled)
        XCTAssertEqual(activation.state, .active)
    }

    func testPrivacyFailureRemainsRequestedAndInactiveUntilRetryOrExplicitOff() async throws {
        let settings = try settings()
        var calls = 0
        let activation = MobilePrivacyActivation(settings: settings) { _ in
            calls += 1
            if calls == 1 { throw URLError(.notConnectedToInternet) }
        }
        activation.setEnabled(true)
        do { try await activation.waitUntilReadyIfRequested(); XCTFail("An unprepared request must fail closed") }
        catch { }
        XCTAssertTrue(settings.meetingPIIRedactionRequested)
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
        if case .failed = activation.state {} else { XCTFail("Expected failed state") }
        activation.setEnabled(true)
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(activation.state, .active)
        activation.setEnabled(false)
        XCTAssertFalse(settings.meetingPIIRedactionRequested)
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
        XCTAssertEqual(activation.state, .off)
    }

    func testPrivacyRestoreClearsPreviousProfileActiveStateAndCanEnableNewProfile() async throws {
        let fixture = try profileScopedSettings()
        let settings = fixture.settings
        var preparedProfiles: [String] = []
        let activation = MobilePrivacyActivation(settings: settings) { _ in
            preparedProfiles.append(PrivateProfileStorage.current.id)
        }
        activation.setEnabled(true)
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(activation.state, .active)
        XCTAssertEqual(preparedProfiles, [fixture.guest.id])

        PrivateProfileStorage.select(fixture.account)
        XCTAssertFalse(settings.meetingPIIRedactionRequested,
            "A new account must not inherit the guest's privacy choice")
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
        activation.restore()

        XCTAssertEqual(activation.state, .off,
            "An active footer from the previous profile must not survive an off preference")
        XCTAssertFalse(activation.isRequested)
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
        XCTAssertEqual(preparedProfiles, [fixture.guest.id],
            "Restoring an off preference must not download or activate anything")
        try await captureNativePrivacyControls(activation, name: "profile-cleanup-off")

        activation.setEnabled(true)
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(preparedProfiles, [fixture.guest.id, fixture.account.id])
        XCTAssertTrue(activation.isRequested)
        XCTAssertTrue(settings.meetingPIIRedactionEnabled)
        XCTAssertEqual(activation.state, .active)
        try await captureNativePrivacyControls(activation, name: "profile-cleanup-on")
    }

    func testPrivacyProfileTransitionJoinsOldPreparationAndCancelsWaiters() async throws {
        let fixture = try profileScopedSettings()
        let settings = fixture.settings
        var loader: CheckedContinuation<Void, Never>?
        var calls = 0
        let activation = MobilePrivacyActivation(settings: settings) { _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { loader = $0 } }
        }
        activation.setEnabled(true)
        for _ in 0..<1_000 where loader == nil { await Task.yield() }
        let oldLoader = try XCTUnwrap(loader)
        let waiter = Task { try await activation.waitUntilReadyIfRequested() }
        for _ in 0..<10 { await Task.yield() }
        var firstJoined = false
        var secondJoined = false
        let first = Task {
            await activation.prepareForPrivateProfileTransition()
            firstJoined = true
        }
        for _ in 0..<1_000 where activation.state != .off { await Task.yield() }
        let second = Task {
            await activation.prepareForPrivateProfileTransition()
            secondJoined = true
        }
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(firstJoined)
        XCTAssertFalse(secondJoined, "Repeated transition preparation must join the same draining work")
        XCTAssertTrue(settings.meetingPIIRedactionRequested, "Concealing must preserve the source choice")
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
        activation.setEnabled(false)
        XCTAssertTrue(settings.meetingPIIRedactionRequested, "UI input cannot rewrite a transitioning profile")
        do { try await waiter.value; XCTFail("The old profile waiter must be cancelled") }
        catch { XCTAssertTrue(error is CancellationError) }
        do { try await activation.waitUntilReadyIfRequested(); XCTFail("No readiness during transition") }
        catch { XCTAssertTrue(error is CancellationError) }
        oldLoader.resume()
        await first.value
        await second.value
        XCTAssertTrue(firstJoined && secondJoined)
        XCTAssertEqual(activation.state, .off)

        PrivateProfileStorage.select(fixture.account)
        activation.restore()
        XCTAssertFalse(settings.meetingPIIRedactionRequested)
        XCTAssertFalse(settings.meetingPIIRedactionEnabled, "Late old completion must not commit to the target")
        activation.setEnabled(true)
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(activation.state, .active)
    }

    func testPrivacyRestoreCannotReopenConcealedProfile() async throws {
        let fixture = try profileScopedSettings()
        let activation = MobilePrivacyActivation(settings: fixture.settings) { _ in }
        activation.setEnabled(true)
        try await activation.waitUntilReadyIfRequested()
        await activation.prepareForPrivateProfileTransition()
        PrivateProfileStorage.conceal(generation: UUID())
        activation.restore()
        XCTAssertEqual(activation.state, .off)

        // A delayed startup restore must not release the transition guard. Only
        // a restore after the selected profile is readable can accept UI input.
        PrivateProfileStorage.select(fixture.guest)
        activation.setEnabled(false)
        XCTAssertTrue(fixture.settings.meetingPIIRedactionRequested)
        activation.restore()
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(activation.state, .active)
    }

    func testRepeatedPrivacyRestoreKeepsSameProfilePreparationAndItsWaiter() async throws {
        let fixture = try profileScopedSettings()
        var loader: CheckedContinuation<Void, Never>?
        var calls = 0
        var canPrepare = true
        let activation = MobilePrivacyActivation(settings: fixture.settings, canPrepare: { canPrepare }) { _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { loader = $0 } }
        }
        activation.setEnabled(true)
        for _ in 0..<1_000 where loader == nil { await Task.yield() }
        let preparation = try XCTUnwrap(loader)
        let waiter = Task { () -> Bool in
            do { try await activation.waitUntilReadyIfRequested(); return true }
            catch { return false }
        }
        for _ in 0..<10 { await Task.yield() }
        activation.restore()
        activation.restore()
        XCTAssertEqual(activation.state, .enabling)
        XCTAssertEqual(calls, 1)
        preparation.resume()
        let waiterSucceeded = await waiter.value
        XCTAssertTrue(waiterSucceeded, "A late startup restore must not cancel the first recording's waiter")
        XCTAssertEqual(calls, 1)
        XCTAssertEqual(activation.state, .active)

        canPrepare = false // Recording now owns the model resources.
        activation.restore()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertEqual(activation.state, .active)
        XCTAssertTrue(fixture.settings.meetingPIIRedactionEnabled)
        XCTAssertEqual(calls, 1, "Same-profile restore must not prepare again during capture")
    }

    func testPrivacyEnableRepairsActivePhaseWithAnOffSavedRequest() async throws {
        let settings = try settings()
        var calls = 0
        let activation = MobilePrivacyActivation(settings: settings) { _ in calls += 1 }
        activation.setEnabled(true)
        try await activation.waitUntilReadyIfRequested()
        settings.meetingPIIRedactionRequested = false
        settings.meetingPIIRedactionEnabled = false
        activation.setEnabled(true)
        try await activation.waitUntilReadyIfRequested()
        XCTAssertTrue(activation.isRequested)
        XCTAssertTrue(settings.meetingPIIRedactionEnabled)
        XCTAssertEqual(activation.state, .active)
        XCTAssertEqual(calls, 2)
    }

    private func captureNativePrivacyControls(_ activation: MobilePrivacyActivation, name: String) async throws {
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        defer { window.isHidden = true; previous?.makeKey() }
        for (suffix, style, scheme) in [("light", UIUserInterfaceStyle.light, ColorScheme.light),
                                       ("dark", UIUserInterfaceStyle.dark, ColorScheme.dark)] {
            window.overrideUserInterfaceStyle = style
            window.rootViewController = UIHostingController(rootView:
                NavigationStack {
                    Form { MobilePrivacyActivationControls(activation: activation, asFormRows: true) }
                        .navigationTitle(PichiLocalization.text("Privacy"))
                }.preferredColorScheme(scheme))
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
            try await Task.sleep(for: .seconds(2))
            let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
            let attachment = XCTAttachment(image: image)
            attachment.name = "\(name)-\(suffix)"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testPrivacyRestorePreparesRequestedTargetProfileInsteadOfTrustingPreviousActiveState() async throws {
        let fixture = try profileScopedSettings()
        let settings = fixture.settings
        var preparedProfiles: [String] = []
        var targetPreparation: CheckedContinuation<Void, Never>?
        let activation = MobilePrivacyActivation(settings: settings) { _ in
            preparedProfiles.append(PrivateProfileStorage.current.id)
            if preparedProfiles.count == 2 {
                await withCheckedContinuation { targetPreparation = $0 }
            }
        }
        activation.setEnabled(true)
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(activation.state, .active)

        PrivateProfileStorage.select(fixture.account)
        settings.meetingPIIRedactionRequested = true
        settings.meetingPIIRedactionEnabled = true
        activation.restore()
        for _ in 0..<1_000 where targetPreparation == nil { await Task.yield() }

        XCTAssertEqual(activation.state, .enabling,
            "A saved enabled flag is not current-profile model readiness")
        XCTAssertTrue(activation.isRequested)
        XCTAssertFalse(settings.meetingPIIRedactionEnabled,
            "Target protection must not commit before its own preparation completes")
        XCTAssertEqual(preparedProfiles, [fixture.guest.id, fixture.account.id])
        let preparation = try XCTUnwrap(targetPreparation)
        preparation.resume()
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(activation.state, .active)
        XCTAssertTrue(settings.meetingPIIRedactionEnabled)
    }

    func testCancellingFinalSetupWaitDoesNotWaitForOrCancelSharedPrivacyLoader() async throws {
        let settings = try settings()
        settings.meetingPIIRedactionRequested = true
        settings.mobileSetupStep = 5
        var continuation: CheckedContinuation<Void, Never>?
        let activation = MobilePrivacyActivation(settings: settings) { _ in
            await withCheckedContinuation { continuation = $0 }
        }
        activation.restore()
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        let loader = try XCTUnwrap(continuation)
        let foreground = Task { try await activation.waitUntilReadyIfRequested() }
        for _ in 0..<10 { await Task.yield() }
        foreground.cancel()
        do { try await foreground.value; XCTFail("A cancelled final-page waiter must detach immediately") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(activation.state, .enabling)
        XCTAssertTrue(settings.meetingPIIRedactionRequested)
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
        loader.resume()
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(activation.state, .active)
    }

    func testBusyCaptureDoesNotStartUnrelatedPrivacyLoading() async throws {
        let settings = try settings()
        var calls = 0
        let activation = MobilePrivacyActivation(settings: settings, canPrepare: { false }) { _ in calls += 1 }
        activation.setEnabled(true)
        do { try await activation.waitUntilReadyIfRequested(); XCTFail("Busy setup must stay inactive") }
        catch { }
        XCTAssertEqual(calls, 0)
        XCTAssertTrue(settings.meetingPIIRedactionRequested)
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
    }

    func testLatestOnIntentSurvivesOffWhilePreviousPreparationIsDraining() async throws {
        let settings = try settings()
        var continuation: CheckedContinuation<Void, Never>?
        var calls = 0
        let activation = MobilePrivacyActivation(settings: settings) { _ in
            calls += 1
            if calls == 1 { await withCheckedContinuation { continuation = $0 } }
        }
        activation.setEnabled(true)
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        let first = try XCTUnwrap(continuation)
        activation.setEnabled(false)
        activation.setEnabled(true)
        XCTAssertTrue(settings.meetingPIIRedactionRequested)
        first.resume()
        try await activation.waitUntilReadyIfRequested()
        XCTAssertEqual(calls, 2)
        XCTAssertEqual(activation.state, .active)
        XCTAssertTrue(settings.meetingPIIRedactionEnabled)
    }

    func testCancelledEnableCannotCommitAfterLateLoaderCompletionAndRestartRestoresRequest() async throws {
        let settings = try settings()
        var continuation: CheckedContinuation<Void, Never>?
        let activation = MobilePrivacyActivation(settings: settings) { _ in
            await withCheckedContinuation { continuation = $0 }
        }
        activation.setEnabled(true)
        for _ in 0..<1_000 where continuation == nil { await Task.yield() }
        _ = try XCTUnwrap(continuation)
        activation.setEnabled(false)
        continuation?.resume()
        for _ in 0..<10 { await Task.yield() }
        XCTAssertFalse(settings.meetingPIIRedactionEnabled)
        XCTAssertFalse(settings.meetingPIIRedactionRequested)
        XCTAssertEqual(activation.state, .off)
        settings.meetingPIIRedactionRequested = true
        let restored = MobilePrivacyActivation(settings: settings, prepare: { _ in })
        restored.restore()
        try await restored.waitUntilReadyIfRequested()
        XCTAssertEqual(restored.state, .active)
        XCTAssertTrue(settings.meetingPIIRedactionEnabled)
    }
}

private final nonisolated class SetupVoiceResourceProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var ready = false
    var starts: Int { lock.withLock { count } }
    var isReady: Bool { lock.withLock { ready } }
    func begin() { lock.withLock { count += 1 } }
    func finish() { lock.withLock { ready = true } }
}
