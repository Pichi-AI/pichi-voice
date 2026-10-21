import XCTest
@testable import PichiVoiceMobile

@MainActor
final class MobileSetupTransactionTests: XCTestCase {
    private func settings() throws -> SettingsStore {
        let name = "MobileSetupTransactionTests.\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return SettingsStore(defaults: defaults)
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
        XCTAssertEqual(value.meetingSpeakerProcessingMode(for: .onlineCall), .afterRecording)
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
        let (started, startSignal) = AsyncStream<Void>.makeStream()
        let (release, releaseSignal) = AsyncStream<Void>.makeStream()
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
            startSignal.yield(())
            for await _ in release { break }
            voice.finish()
        })
        var speechChecks = 0
        let resources = MobileRequiredResources(prepareSpeech: { speechChecks += 1 }, voiceStore: canonical, speakerStore: { _ in selected })
        let background = Task { try await resources.prepare(modelID: "synthetic") }
        var events = started.makeAsyncIterator()
        _ = await events.next()
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
        startSignal.finish(); releaseSignal.finish()
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
