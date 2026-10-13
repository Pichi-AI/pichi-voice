import Foundation
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
        defer {
            release.open()
            pending.cancel()
        }

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

        let configuration = try await pending.value
        XCTAssertEqual(configuration.audioStorageMode, .memoryOnly)
        XCTAssertEqual(configuration.speakerLabelsEnabled, false)
        XCTAssertEqual(configuration.piiRedactionEnabled, false)
        XCTAssertEqual(configuration.microphone, microphone)
        XCTAssertEqual(configuration.languageCode, "ru")
        XCTAssertEqual(configuration.mode, .inRoom)
        XCTAssertNil(configuration.application)
        try configuration.validate()
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
