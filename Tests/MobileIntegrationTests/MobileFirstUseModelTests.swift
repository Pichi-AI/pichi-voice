import CoreMedia
import Foundation
@testable import PichiVoiceMobile
import XCTest

/// The actual mobile composition and ASR operation run here. Only provider transport and
/// microphone permission are controlled, so these tests never download weights or record audio.
@MainActor
final class MobileFirstUseModelTests: XCTestCase {
    private func settings() throws -> (SettingsStore, UserDefaults, String) {
        let name = "MobileFirstUseModelTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: name))
        self.addTeardownBlock { defaults.removePersistentDomain(forName: name) }
        return (SettingsStore(defaults: defaults), defaults, name)
    }

    private func services(settings: SettingsStore, capture: FirstUsePermissionProbe,
                          root: URL) -> AppServices {
        AppServices(store: MeetingSessionStore(rootDirectory: root), capture: capture, settings: settings,
                    microphoneResolver: { _ in .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone") })
    }

    private func configuration(_ services: AppServices) async throws -> MeetingCaptureConfiguration {
        var result = try await services.meetingSessionCoordinator.defaultConfiguration(mode: .inRoom, title: "Synthetic first meeting")
        result.speakerLabelsEnabled = false
        result.piiRedactionEnabled = false
        return result
    }

    private func assertCapture(_ capture: FirstUsePermissionProbe, permissions: Int = 0,
                               file: StaticString = #filePath, line: UInt = #line) async {
        let permissionCount = await capture.permissionCount
        let captureCount = await capture.captureCount
        XCTAssertEqual(permissionCount, permissions, file: file, line: line)
        XCTAssertEqual(captureCount, 0, file: file, line: line)
    }

    func testFreshRussianProductDefaultsToGigaAMAndKeepsChoiceAcrossInterfaceChanges() throws {
        let (settings, defaults, _) = try self.settings()
        XCTAssertEqual(settings.interfaceLanguage, .russian)
        XCTAssertEqual(settings.selectedSpeechModel, .gigaam)
        settings.interfaceLanguage = .english
        XCTAssertEqual(settings.selectedSpeechModel, .gigaam)
        XCTAssertEqual(SettingsStore(defaults: defaults).selectedSpeechModel, .gigaam)
        for model: SettingsStore.SpeechModel in [.whisperTiny, .parakeetTDT] {
            settings.selectedSpeechModel = model
            settings.interfaceLanguage = .russian
            XCTAssertEqual(settings.selectedSpeechModel, model)
            settings.interfaceLanguage = .english
            XCTAssertEqual(SettingsStore(defaults: defaults).selectedSpeechModel, model)
        }
        XCTAssertEqual(PichiMeetingProviderFactory.registeredLanguageCodes(for: SettingsStore.SpeechModel.gigaam.rawValue), ["ru"])
    }

    func testModelChangeDuringConfigurationLookupDoesNotPrepareEitherModel() async throws {
        let (settings, _, name) = try self.settings()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let entered = FirstUsePreparationSignal()
        let release = FirstUsePreparationSignal()
        let original = FirstUseProvider()
        let replacement = FirstUseProvider()
        let capture = FirstUsePermissionProbe()
        let services = AppServices(store: MeetingSessionStore(rootDirectory: root), capture: capture, settings: settings,
            microphoneResolver: { _ in entered.open(); try await release.wait(); return .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone") })
        services.asr.modelProvidersForTesting[.gigaam] = original
        services.asr.modelProvidersForTesting[.whisperTiny] = replacement
        let configuration = Task { try await services.meetingSessionCoordinator.defaultConfiguration(mode: .inRoom, title: "Synthetic") }
        do {
            try await entered.wait()
            settings.selectedSpeechModel = .whisperTiny
            release.open()
            do { _ = try await configuration.value; XCTFail("The model used for the draft language must stay fixed") } catch is CancellationError { }
        } catch { release.open(); configuration.cancel(); _ = try? await configuration.value; throw error }
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
        XCTAssertEqual(original.prepareCount, 0)
        XCTAssertEqual(replacement.prepareCount, 0)
        await self.assertCapture(capture)
    }

    func testFirstRecordingInstallsAndPreparesDefaultBeforePermissionOrCapture() async throws {
        let (settings, _, name) = try self.settings()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FirstUseProvider()
        let capture = FirstUsePermissionProbe {
            XCTAssertEqual(provider.installCount, 1)
            XCTAssertEqual(provider.prepareCount, 1)
            XCTAssertTrue(provider.installed)
            XCTAssertFalse(provider.isReady, "Prepared ASR residency must be released before capture admission")
            XCTAssertEqual(provider.releaseCount, 1)
        }
        let services = self.services(settings: settings, capture: capture, root: root)
        services.asr.modelProvidersForTesting[.gigaam] = provider
        let configuration = try await self.configuration(services)
        XCTAssertEqual(configuration.languageCode, "ru")
        do { _ = try await services.meetingSessionCoordinator.startRecording(configuration: configuration); XCTFail("Permission probe must end the test before microphone capture") }
        catch is FirstUsePermissionProbe.PermissionReached { }
        await self.assertCapture(capture, permissions: 1)
        XCTAssertNil(services.asr.activeExclusiveActivity)
        XCTAssertFalse(services.asr.hasActiveModelPreparation)
        let sessions = try await services.meetingStore.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(services.meetingSessionCoordinator.isQuiescent)
    }

    func testInstalledExplicitModelIsPreparedWithoutInstallingOrChangingChoice() async throws {
        let (settings, _, name) = try self.settings()
        settings.selectedSpeechModel = .whisperTiny
        settings.interfaceLanguage = .russian
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FirstUseProvider(installed: true)
        let capture = FirstUsePermissionProbe {
            XCTAssertEqual(provider.installCount, 0)
            XCTAssertEqual(provider.prepareCount, 1)
        }
        let services = self.services(settings: settings, capture: capture, root: root)
        services.asr.modelProvidersForTesting[.whisperTiny] = provider
        let configuration = try await self.configuration(services)
        do { _ = try await services.meetingSessionCoordinator.startRecording(configuration: configuration); XCTFail("Expected permission probe") }
        catch is FirstUsePermissionProbe.PermissionReached { }
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
        XCTAssertEqual(provider.releaseCount, 1)
        await self.assertCapture(capture, permissions: 1)
    }

    func testCancelledInstallationJoinsProviderCleanupBeforeAllowingNewModelOperation() async throws {
        let (settings, _, name) = try self.settings()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FirstUseProvider(blocked: true)
        let capture = FirstUsePermissionProbe()
        let services = self.services(settings: settings, capture: capture, root: root)
        services.asr.modelProvidersForTesting[.gigaam] = provider
        let configuration = try await self.configuration(services)
        let start = Task { try await services.meetingSessionCoordinator.startRecording(configuration: configuration) }
        do {
            try await provider.entered.wait()
            start.cancel()
            XCTAssertNotNil(services.asr.activeExclusiveActivity)
            XCTAssertTrue(services.asr.hasActiveModelPreparation)
            XCTAssertEqual(provider.releaseCount, 0)
            do { try await services.asr.downloadModel(.gigaam); XCTFail("Cancelled provider still owns preparation until joined") } catch { }
            provider.release.open()
            do { _ = try await start.value; XCTFail("Cancelled start cannot continue to permissions") } catch is CancellationError { }
        } catch { provider.release.open(); start.cancel(); _ = try? await start.value; throw error }
        XCTAssertEqual(provider.prepareCount, 1)
        XCTAssertEqual(provider.releaseCount, 1)
        XCTAssertFalse(provider.isReady)
        await self.assertCapture(capture)
        XCTAssertNil(services.asr.activeExclusiveActivity)
        XCTAssertFalse(services.asr.hasActiveModelPreparation)
        let sessions = try await services.meetingStore.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(services.meetingSessionCoordinator.isQuiescent)
    }

    func testSelectionChangedDuringInstallationDoesNotPrepareReplacementOrAdmitCapture() async throws {
        let (settings, _, name) = try self.settings()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let original = FirstUseProvider(blocked: true)
        let replacement = FirstUseProvider()
        let capture = FirstUsePermissionProbe()
        let services = self.services(settings: settings, capture: capture, root: root)
        services.asr.modelProvidersForTesting[.gigaam] = original
        services.asr.modelProvidersForTesting[.whisperTiny] = replacement
        let configuration = try await self.configuration(services)
        let start = Task { try await services.meetingSessionCoordinator.startRecording(configuration: configuration) }
        do {
            try await original.entered.wait()
            settings.selectedSpeechModel = .whisperTiny
            original.release.open()
            do { _ = try await start.value; XCTFail("Prepared model cannot be replaced by mutable settings") } catch is CancellationError { }
        } catch { original.release.open(); start.cancel(); _ = try? await start.value; throw error }
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
        XCTAssertEqual(original.prepareCount, 1)
        XCTAssertEqual(original.releaseCount, 1)
        XCTAssertEqual(replacement.prepareCount, 0)
        await self.assertCapture(capture)
        XCTAssertNil(services.asr.activeExclusiveActivity)
        let sessions = try await services.meetingStore.loadAll()
        XCTAssertTrue(sessions.isEmpty)
    }

    func testActivatingInstalledModelPersistsSelectionAndBackendAcrossInterfaceChange() async throws {
        let (settings, defaults, _) = try self.settings()
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator(), settings: settings)
        let provider = FirstUseProvider(installed: true)
        service.modelProvidersForTesting[.whisperTiny] = provider
        try await service.activateModel(.whisperTiny)
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
        XCTAssertEqual(settings.meetingTranscriptionBackendID, .whisperTiny)
        settings.interfaceLanguage = .english
        XCTAssertEqual(SettingsStore(defaults: defaults).selectedSpeechModel, .whisperTiny)
        XCTAssertFalse(service.isAsrReady, "Activation selects the model; recording preparation owns readiness")
        XCTAssertEqual(provider.prepareCount, 0)
        XCTAssertNil(service.activeExclusiveActivity)
        await service.shutdownForTermination()
    }

    func testCancelledActivationJoinsPreviousUnloadWithoutPublishingNewSelection() async throws {
        let (settings, _, _) = try self.settings()
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator(), settings: settings)
        let original = FirstUseProvider(installed: true)
        let replacement = FirstUseProvider(installed: true)
        service.modelProvidersForTesting[.gigaam] = original
        service.modelProvidersForTesting[.whisperTiny] = replacement
        try await service.ensureAsrReady()
        XCTAssertTrue(service.isAsrReady)
        original.blocksUnload = true
        let activation = Task { try await service.activateModel(.whisperTiny) }
        do {
            try await original.unloadEntered.wait()
            activation.cancel()
            XCTAssertEqual(settings.selectedSpeechModel, .gigaam)
            XCTAssertFalse(service.isAsrReady)
            XCTAssertNotNil(service.activeExclusiveActivity)
            original.unloadRelease.open()
            do { try await activation.value; XCTFail("Cancelled activation cannot publish another model") } catch is CancellationError { }
        } catch { original.unloadRelease.open(); activation.cancel(); _ = try? await activation.value; throw error }
        XCTAssertEqual(settings.selectedSpeechModel, .gigaam)
        XCTAssertEqual(original.releaseCount, 1)
        XCTAssertEqual(replacement.prepareCount, 0)
        XCTAssertNil(service.activeExclusiveActivity)
        await service.shutdownForTermination()
    }

    func testEnsureReadyInstallsOnceAndTerminationJoinsItsResidentCleanup() async throws {
        let (settings, _, _) = try self.settings()
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator(), settings: settings)
        let provider = FirstUseProvider()
        service.modelProvidersForTesting[.gigaam] = provider
        try await service.ensureAsrReady()
        XCTAssertEqual(provider.installCount, 1)
        XCTAssertEqual(provider.prepareCount, 1)
        XCTAssertTrue(service.isAsrReady)
        XCTAssertTrue(service.fileTranscriptionProvider.isReady)
        XCTAssertNil(service.activeExclusiveActivity)
        await service.shutdownForTermination()
        XCTAssertEqual(provider.releaseCount, 1)
        XCTAssertFalse(service.isAsrReady)
        do { try await service.ensureAsrReady(); XCTFail("Termination closes further model preparation") }
        catch { XCTAssertEqual(error as? MeetingModelResidencyError, .terminating) }
    }

    func testReadinessCannotPublishAProviderAfterSelectionChangesDuringPreparation() async throws {
        let (settings, _, _) = try self.settings()
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator(), settings: settings)
        let provider = FirstUseProvider(blocked: true)
        service.modelProvidersForTesting[.gigaam] = provider
        let readiness = Task { try await service.ensureAsrReady() }
        do {
            try await provider.entered.wait()
            settings.selectedSpeechModel = .whisperTiny
            provider.release.open()
            do { try await readiness.value; XCTFail("Readiness must match its frozen selection") } catch is CancellationError { }
        } catch { provider.release.open(); readiness.cancel(); _ = try? await readiness.value; throw error }
        XCTAssertEqual(provider.prepareCount, 1)
        XCTAssertEqual(provider.releaseCount, 1)
        XCTAssertFalse(service.isAsrReady)
        XCTAssertEqual(settings.selectedSpeechModel, .whisperTiny)
        XCTAssertNil(service.activeExclusiveActivity)
        await service.shutdownForTermination()
    }

    func testReadinessRestoresThroughTheExistingExactMeetingGrant() async throws {
        let (settings, _, _) = try self.settings()
        let service = ASRService(meetingModelResidency: MeetingModelResidencyCoordinator(), settings: settings)
        let provider = FirstUseProvider(installed: true)
        service.modelProvidersForTesting[.gigaam] = provider
        try await service.ensureAsrReady()
        let lease = try service.acquireExclusiveActivity(.meeting)
        try await service.withMeetingModelResidency(attemptID: UUID()) {
            XCTAssertFalse(service.isAsrReady)
        }
        XCTAssertTrue(service.isAsrReady)
        XCTAssertEqual(provider.prepareCount, 2)
        XCTAssertEqual(provider.installCount, 0)
        XCTAssertEqual(provider.releaseCount, 1)
        XCTAssertEqual(service.activeExclusiveActivity, .meeting)
        await service.completeMeetingAudioHandback(lease)
        await service.shutdownForTermination()
    }

    func testInstallationFailureLeavesNoCaptureAndReleasesPreparation() async throws {
        let (settings, _, name) = try self.settings()
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        defer { try? FileManager.default.removeItem(at: root) }
        let provider = FirstUseProvider(failing: true)
        let capture = FirstUsePermissionProbe()
        let services = self.services(settings: settings, capture: capture, root: root)
        services.asr.modelProvidersForTesting[.gigaam] = provider
        let configuration = try await self.configuration(services)
        do { _ = try await services.meetingSessionCoordinator.startRecording(configuration: configuration); XCTFail("Expected provider failure") }
        catch is FirstUseProvider.TransportFailure { }
        XCTAssertEqual(provider.releaseCount, 1)
        await self.assertCapture(capture)
        XCTAssertNil(services.asr.activeExclusiveActivity)
        XCTAssertFalse(services.asr.hasActiveModelPreparation)
        let sessions = try await services.meetingStore.loadAll()
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(services.meetingSessionCoordinator.isQuiescent)
    }
}

@MainActor
private final class FirstUseProvider: TranscriptionProvider {
    struct TransportFailure: Error {}
    let name = "Synthetic first-use provider"
    var isAvailable: Bool { true }
    private(set) var isReady = false
    private(set) var installed: Bool
    private(set) var installCount = 0
    private(set) var prepareCount = 0
    private(set) var releaseCount = 0
    let entered = FirstUsePreparationSignal()
    let release = FirstUsePreparationSignal()
    let unloadEntered = FirstUsePreparationSignal()
    let unloadRelease = FirstUsePreparationSignal()
    var blocksUnload = false
    private let blocked: Bool
    private let failing: Bool
    init(installed: Bool = false, blocked: Bool = false, failing: Bool = false) {
        self.installed = installed; self.blocked = blocked; self.failing = failing
    }
    func prepare(progressHandler: ((ModelPreparationProgress) -> Void)?) async throws {
        prepareCount += 1
        entered.open()
        progressHandler?(.preparingDownload)
        if blocked { try await release.wait() }
        if failing { throw TransportFailure() }
        if !installed { installCount += 1; installed = true; progressHandler?(.downloading(1)) }
        isReady = true
        progressHandler?(.loading)
    }
    func modelsExistOnDisk() -> Bool { installed }
    func releaseResidency() async {
        releaseCount += 1
        unloadEntered.open()
        if blocksUnload { try? await unloadRelease.wait() }
        isReady = false
    }
    func clearCache() async throws { installed = false; isReady = false }
    func transcribe(_ samples: [Float]) async throws -> ASRTranscriptionResult { XCTFail("No audio inference in first-use admission tests"); throw TransportFailure() }
}

private actor FirstUsePermissionProbe: MeetingCaptureControlling {
    struct PermissionReached: Error {}
    private(set) var permissionCount = 0
    private(set) var captureCount = 0
    private let onPermission: @MainActor @Sendable () -> Void
    init(onPermission: @escaping @MainActor @Sendable () -> Void = {}) { self.onPermission = onPermission }
    func preflightPermissions() async throws { permissionCount += 1; await onPermission(); throw PermissionReached() }
    func start(session: MeetingSession, configuration: MeetingCaptureConfiguration, sessionDirectory: URL,
               eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
               liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) async throws -> MeetingCaptureStartResult {
        captureCount += 1
        throw PermissionReached()
    }
    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult { throw PermissionReached() }
    func shutdownForTermination() async {}
}

@MainActor
private final class FirstUsePreparationSignal {
    private var opened = false
    private var waiter: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?
    func wait() async throws {
        if opened { return }
        try await withCheckedThrowingContinuation { continuation in
            waiter = continuation
            deadline = Task { @MainActor [weak self] in
                do { try await Task.sleep(for: .seconds(4)) } catch { return }
                self?.finish(.failure(FirstUseProvider.TransportFailure()))
            }
        }
    }
    func open() { opened = true; finish(.success(())) }
    private func finish(_ result: Result<Void, Error>) {
        let continuation = waiter; waiter = nil
        deadline?.cancel(); deadline = nil
        continuation?.resume(with: result)
    }
}
