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
