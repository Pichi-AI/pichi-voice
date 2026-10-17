import Foundation
import CoreMedia
import XCTest
@testable import PichiVoiceMobile

/// Hosted tests exercise the actual iOS service composition. Only the platform
/// microphone lookup is controlled; the settings, coordinator, pipeline and store are real.
@MainActor
final class MobileConfigurationSnapshotTests: XCTestCase {
    func testPreferencesAreFrozenBeforeAwaitedMicrophoneLookup() async throws {
        let suiteName = "MobileConfigurationSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        settings.meetingSaveAudio = false
        settings.meetingSpeakerLabelsEnabled = false
        settings.meetingPIIRedactionEnabled = false
        settings.meetingRecordingDefaults = MeetingRecordingDefaults(
            isConfigured: true,
            mode: .inRoom,
            applicationBundleIdentifier: nil,
            microphoneCaptureDeviceID: "initial-microphone",
            microphoneCoreAudioUID: "initial-microphone",
            microphoneRole: .unknown,
            languageCode: "ru"
        )

        let entered = BoundedConfigurationSignal()
        let release = BoundedConfigurationSignal()
        let microphone = MeetingMicrophoneIdentity(
            captureDeviceID: "initial-microphone",
            coreAudioUID: "initial-microphone",
            displayName: "Synthetic microphone"
        )
        var requestedUID: String?
        let services = AppServices(
            store: MeetingSessionStore(rootDirectory: root.appendingPathComponent("meetings", isDirectory: true)),
            settings: settings,
            privacy: PichiTranscriptPrivacyService(modelStore: .init(directory: root.appendingPathComponent("privacy", isDirectory: true))),
            microphoneResolver: { preferredUID in
                requestedUID = preferredUID
                entered.open()
                try await release.wait()
                return microphone
            }
        )
        let pending = Task { @MainActor in
            try await services.meetingSessionCoordinator.defaultConfiguration(
                mode: .inRoom, title: "Synthetic offline meeting"
            )
        }
        let configuration: MeetingCaptureConfiguration
        do {
            try await entered.wait()
            XCTAssertEqual(requestedUID, "initial-microphone")
            settings.meetingSaveAudio = true
            settings.meetingSpeakerLabelsEnabled = true
            settings.meetingPIIRedactionEnabled = true
            var changedDefaults = settings.meetingRecordingDefaults
            changedDefaults.microphoneCaptureDeviceID = "replacement-microphone"
            changedDefaults.microphoneCoreAudioUID = "replacement-microphone"
            changedDefaults.languageCode = "en"
            settings.meetingRecordingDefaults = changedDefaults
            release.open()
            configuration = try await pending.value
        } catch {
            release.open()
            pending.cancel()
            _ = try? await pending.value
            throw error
        }
        XCTAssertEqual(configuration.audioStorageMode, .memoryOnly)
        XCTAssertEqual(configuration.speakerLabelsEnabled, false)
        XCTAssertEqual(configuration.piiRedactionEnabled, false)
        XCTAssertEqual(configuration.microphone, microphone)
        XCTAssertEqual(configuration.languageCode, "ru")
        XCTAssertEqual(configuration.mode, .inRoom)
        XCTAssertNil(configuration.application)
        try configuration.validate()
    }

    func testStreamingModeIsFrozenBeforeAwaitedMicrophoneLookup() async throws {
        let suite = "StreamingConfigurationSnapshot.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .gigaam
        settings.meetingSaveAudio = true
        settings.meetingSpeakerLabelsEnabled = true
        settings.meetingSpeakerProcessingMode = .streaming
        settings.meetingPIIRedactionEnabled = false
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "synthetic", displayName: "Synthetic microphone")
        let services = AppServices(store: MeetingSessionStore(rootDirectory: root), settings: settings,
            microphoneResolver: { _ in
                // Simulates a preference change during asynchronous source discovery.
                await Task.yield()
                settings.meetingSpeakerProcessingMode = .afterRecording
                settings.meetingSaveAudio = false
                return microphone
            })
        let configuration = try await services.meetingSessionCoordinator.defaultConfiguration(mode: .inRoom, title: "Synthetic stream")
        XCTAssertEqual(configuration.effectiveSpeakerProcessingMode, .streaming)
        XCTAssertEqual(configuration.audioStorageMode, .retainedFiles)
        XCTAssertEqual(settings.meetingSpeakerProcessingMode, .afterRecording)
        XCTAssertFalse(settings.meetingSaveAudio)
        let session = MeetingSession(configuration: configuration,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        XCTAssertEqual(session.effectiveSpeakerProcessingMode, .streaming)
        XCTAssertEqual(session.audioStorageMode, .retainedFiles)
    }

    func testSelectedSpeechModelDoesNotPromoteAmbientBackendToRequestOverride() async throws {
        let suite = "MobileAmbientBackend.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        defer { defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let settings = SettingsStore(defaults: defaults)
        settings.meetingSaveAudio = false
        settings.meetingSpeakerLabelsEnabled = false
        let microphone = MeetingMicrophoneIdentity(captureDeviceID: "synthetic", displayName: "Synthetic microphone")
        let services = AppServices(store: MeetingSessionStore(rootDirectory: root), settings: settings,
            microphoneResolver: { _ in microphone })
        let unknown = MeetingBackendID(rawValue: "ambient-future-backend")
        for (model, backend) in [(SettingsStore.SpeechModel.whisperTiny, MeetingBackendID.whisperTiny), (.gigaam, .gigaam)] {
            settings.selectedSpeechModel = model
            for saved in [MeetingBackendID.legacyCompatibility, unknown] {
                settings.meetingTranscriptionBackendID = saved
                let configuration = try await services.meetingSessionCoordinator.defaultConfiguration(mode: .inRoom, title: "Synthetic meeting")
                XCTAssertNil(configuration.transcriptionBackendID)
                XCTAssertEqual(PichiMeetingProviderFactory.selectedBackendID(languageCode: configuration.languageCode,
                    selectedModelID: model.rawValue, savedBackendID: saved), backend)
                XCTAssertEqual(settings.selectedSpeechModel, model)
                XCTAssertEqual(settings.meetingTranscriptionBackendID, saved)
            }
        }
    }

    func testFreshSettingsRetainAudioAndSpeakerLabelsWithoutPIIRedaction() async throws {
        let suiteName = "MobileConfigurationSnapshotTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent(suiteName, isDirectory: true)
        defer {
            defaults.removePersistentDomain(forName: suiteName)
            try? FileManager.default.removeItem(at: root)
        }

        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .whisperTiny
        let microphone = MeetingMicrophoneIdentity(
            captureDeviceID: "default-microphone",
            coreAudioUID: "default-microphone",
            displayName: "Synthetic microphone"
        )
        let services = AppServices(
            store: MeetingSessionStore(rootDirectory: root.appendingPathComponent("meetings", isDirectory: true)),
            settings: settings,
            privacy: PichiTranscriptPrivacyService(modelStore: .init(directory: root.appendingPathComponent("privacy", isDirectory: true))),
            microphoneResolver: { preferredUID in
                XCTAssertNil(preferredUID)
                return microphone
            }
        )

        let configuration = try await services.meetingSessionCoordinator.defaultConfiguration(
            mode: .inRoom, title: "Synthetic offline meeting"
        )

        XCTAssertEqual(configuration.audioStorageMode, .retainedFiles)
        XCTAssertEqual(configuration.speakerLabelsEnabled, true)
        XCTAssertEqual(configuration.piiRedactionEnabled, false)
        XCTAssertEqual(configuration.microphone, microphone)
        XCTAssertEqual(configuration.languageCode, "auto")
        XCTAssertEqual(configuration.mode, .inRoom)
        XCTAssertNil(configuration.application)
        try configuration.validate()
    }
}

/// Each signal has one waiter and a deadline, so a configuration regression
/// fails the test instead of leaving the hosted process blocked indefinitely.
@MainActor
private final class BoundedConfigurationSignal {
    private enum SignalError: Error {
        case timedOut
        case duplicateWaiter
    }

    private var isOpen = false
    private var continuation: CheckedContinuation<Void, Error>?
    private var deadline: Task<Void, Never>?

    func wait() async throws {
        try Task.checkCancellation()
        if isOpen { return }
        guard continuation == nil else { throw SignalError.duplicateWaiter }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                self.deadline = Task { @MainActor [weak self] in
                    do { try await Task.sleep(for: .seconds(3)) }
                    catch { return }
                    self?.finish(.failure(SignalError.timedOut))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    func open() {
        isOpen = true
        finish(.success(()))
    }

    private func finish(_ result: Result<Void, Error>) {
        let pending = continuation
        continuation = nil
        deadline?.cancel()
        deadline = nil
        pending?.resume(with: result)
    }
}

/// Metadata-only admission checks: no speech model, microphone or player is started.
@MainActor
final class MobilePCMAdmissionTests: XCTestCase {
    private struct RuntimeReached: Error {}
    private final class Probe {
        var asr = 0
        var dependencies = 0
        var runtime = 0
    }

    private actor CaptureProbe: MeetingCaptureControlling {
        private(set) var permissions = 0
        private(set) var starts = 0
        func preflightPermissions() async throws { permissions += 1 }
        func start(session: MeetingSession, configuration: MeetingCaptureConfiguration, sessionDirectory: URL,
                   eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
                   liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) async throws -> MeetingCaptureStartResult {
            starts += 1
            throw RuntimeReached()
        }
        func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult { throw RuntimeReached() }
        func shutdownForTermination() async {}
    }

    private func descriptor() throws -> MeetingBackendDescriptor {
        try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: SettingsStore.SpeechModel.gigaam.rawValue))
    }

    private func context(pii: Bool = true) -> MeetingPCMAdmissionContext {
        .init(physicalDeviceModel: "iPad7,1", operatingSystemVersion: "17.7.10", piiRedactionEnabled: pii)
    }

    private func captureConfiguration() -> MeetingCaptureConfiguration {
        .init(mode: .inRoom, title: "Synthetic admission", languageCode: "ru",
              microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone"),
              audioStorageMode: .memoryOnly, speakerLabelsEnabled: true, piiRedactionEnabled: true)
    }

    func testPCMRequestAdmitsSavedAudioOnlyWithTheRegisteredStreamingMode() throws {
        let descriptor = try self.descriptor()
        for storage: MeetingAudioStorageMode in [.memoryOnly, .retainedFiles] {
            for mode: MeetingSpeakerProcessingMode in [.afterRecording, .streaming] {
                var capture = self.captureConfiguration()
                capture.audioStorageMode = storage
                capture.speakerProcessingMode = mode
                let session = MeetingSession(configuration: capture,
                    timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1,
                        machTimebaseDenominator: 1, firstPresentationTime: nil))
                let configuration = PichiMeetingProviderFactory.validationConfiguration(backendID: descriptor.id,
                    languageCode: "ru", diarizationEnabled: true, speakerProcessingMode: mode)
                let request = MeetingBackendRequest(attemptID: UUID(), session: session,
                    sessionDirectory: FileManager.default.temporaryDirectory,
                    configuration: configuration)
                if storage == .retainedFiles && mode == .afterRecording {
                    XCTAssertThrowsError(try descriptor.validatePCMInput(request, admissionContext: self.context()))
                } else {
                    XCTAssertNoThrow(try descriptor.validatePCMInput(request, admissionContext: self.context()))
                }
            }
        }
    }

    func testDeferredSpeakerAnalysisDoesNotInheritTheLiveCombinedWorkloadBan() throws {
        for model: SettingsStore.SpeechModel in [.gigaam, .whisperTiny, .parakeetTDT] {
            let descriptor = try XCTUnwrap(PichiMeetingProviderFactory.registeredBackendDescriptor(for: model.rawValue))
            XCTAssertTrue(descriptor.pcmAdmissionRestrictions.isEmpty)
            for speakers in [false, true] {
                for pii in [false, true] {
                    XCTAssertNoThrow(try descriptor.validatePCMInput(configuration: .init(asrModel: model.rawValue,
                        languageCode: model == .gigaam ? "ru" : "auto", speakerLabelsEnabled: speakers),
                        mode: .inRoom, admissionContext: self.context(pii: pii)))
                }
            }
        }
    }

    func testFrozenRouteReachesItsRegisteredRuntimeAfterDependencyPreparation() async throws {
        let descriptor = try self.descriptor()
        let probe = Probe()
        let pipeline = MeetingProcessingPipeline(asrServiceProvider: {
            probe.asr += 1; XCTFail("The injected runtime refuses before ASR preparation"); return ASRService()
        }, managesModelResidency: false, pcmAdmissionContextProvider: { pii in self.context(pii: pii) },
           backendRegistry: .makeDefault(), meetingRuntimeFactory: { _ in
            probe.runtime += 1; throw RuntimeReached()
        }, prepareDiarizationDependencies: { _ in probe.dependencies += 1 })
        var session = MeetingSession(configuration: self.captureConfiguration(),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        session.recordingBackendID = descriptor.id.rawValue
        session.recordingASRArtifactFingerprint = "synthetic-frozen-public-export"
        session.piiRedactionEnabled = false // This test injects a runtime refusal, not a privacy model.
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("UncreatedAdmission.\(UUID().uuidString)")
        do {
            try await pipeline.prepareMemoryAudio(session: session, sessionDirectory: directory,
                checkpoint: { _ in XCTFail("An unprepared runtime cannot publish a checkpoint") })
            XCTFail("The injected factory must refuse before starting capture")
        } catch { XCTAssertTrue(error is RuntimeReached) }
        XCTAssertEqual(probe.asr, 0)
        XCTAssertEqual(probe.dependencies, 1)
        XCTAssertEqual(probe.runtime, 1)
        XCTAssertTrue(pipeline.memoryAttempts.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path))
    }

    func testPhysicalInstalledExportHasNoObsoleteCombinedLiveWorkloadRestriction() async throws {
        let context = MeetingPCMAdmissionContext.current(piiRedactionEnabled: true)
        guard context.physicalDeviceModel == "iPad7,1", context.operatingSystemVersion == "17.7.10" else {
            throw XCTSkip("Requires the physical deployment; Simulator is separate evidence")
        }
        let descriptor = try self.descriptor()
        let installed = try PichiGigaAMModelStore.shared.installedModel()
        XCTAssertTrue(descriptor.pcmAdmissionRestrictions.isEmpty)
        XCTAssertNoThrow(try descriptor.validatePCMInput(configuration: .init(asrModel: SettingsStore.SpeechModel.gigaam.rawValue,
            asrArtifactFingerprint: installed.descriptor.fingerprint, languageCode: "ru", speakerLabelsEnabled: true),
            mode: .inRoom, admissionContext: context))
    }

    func testCancelledStartNeverReachesPreparationOrPermissions() async throws {
        let suiteName = "CancelledAdmission.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suiteName)
        defer { defaults.removePersistentDomain(forName: suiteName); try? FileManager.default.removeItem(at: directory) }
        let settings = SettingsStore(defaults: defaults)
        settings.selectedSpeechModel = .gigaam
        let capture = CaptureProbe()
        let services = AppServices(store: MeetingSessionStore(rootDirectory: directory), capture: capture, settings: settings)
        let pending = Task { @MainActor in
            try await services.meetingSessionCoordinator.startRecording(configuration: self.captureConfiguration())
        }
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Cancelled start cannot open admission") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let permissions = await capture.permissions
        let starts = await capture.starts
        XCTAssertEqual(permissions, 0)
        XCTAssertEqual(starts, 0)
        XCTAssertFalse(services.asr.hasActiveModelPreparation)
        XCTAssertNil(services.asr.activeExclusiveActivity)
        XCTAssertFalse(services.meetingSessionCoordinator.hasPendingStart)
    }
}
