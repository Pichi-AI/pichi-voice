@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import SwiftUI
import UIKit
import XCTest
@testable import PichiVoiceMobile

/// Runs the production kiosk and coordinator with invented audio and an injected recognizer.
/// No microphone, model, user Keychain, shared defaults or production meeting store is used.
@MainActor
final class MobileKioskRecordingTests: XCTestCase {
    func testKioskRendersConfiguredRecordingAndPreservesAudioThroughRepeatedSessions() async throws {
        #if !targetEnvironment(simulator)
        throw XCTSkip("The synthetic kiosk window belongs on a task-owned simulator")
        #else
        let fixture = try Fixture()
        addTeardownBlock { await fixture.cleanup() }
        let host = try KioskWindow(coordinator: fixture.coordinator, required: fixture.required,
            privacy: fixture.privacy, access: fixture.access, audioArbiter: fixture.arbiter)
        defer { host.close() }
        try await settle()
        try capture(host, step: "01-ready")

        for ordinal in 1...2 {
            if ordinal > 1 { try fixture.coordinator.resetForNewMeeting() }
            try await MobileMeetingRecordingActions.start(coordinator: fixture.coordinator,
                required: fixture.required, privacyActivation: fixture.privacy, settings: fixture.settings)
            let recording = try XCTUnwrap(fixture.coordinator.activeSession)
            XCTAssertTrue(fixture.coordinator.isRecording)
            XCTAssertEqual(recording.audioStorageMode, .retainedFiles)
            XCTAssertEqual(recording.languageCode, "ru")
            XCTAssertEqual(recording.selectedMicrophone.captureDeviceID, "synthetic-kiosk-input")
            XCTAssertEqual(recording.speakerLabelsEnabled, false)
            XCTAssertEqual(fixture.settings.selectedSpeechModel, .whisperSmall)
            XCTAssertEqual(fixture.settings.meetingAudioRetentionPolicy, .never)
            XCTAssertTrue(fixture.settings.meetingSaveAudio)
            let measuredPeak = await fixture.capture.measuredPeak
            XCTAssertGreaterThan(measuredPeak, 0.02, "The invented PCM must exceed the ordinary waveform noise threshold")
            try await waitForMicrophoneLevel(fixture.coordinator, expectedPeak: measuredPeak)
            try await Task.sleep(for: .milliseconds(1100))
            XCTAssertGreaterThanOrEqual(fixture.coordinator.elapsedTime, 1)
            try await settle()
            try capture(host, step: "0\(ordinal * 3 - 1)-recording-\(ordinal)")

            // A later administrator preference cannot rewrite an admitted capture's storage.
            fixture.settings.meetingSaveAudio = false
            fixture.processing.hold = true
            let stop = Task { try await fixture.coordinator.stopAndTranscribe() }
            defer { fixture.processing.finish() }
            try await waitForProcessing(fixture.processing)
            XCTAssertTrue(fixture.coordinator.isProcessing)
            try await settle()
            try capture(host, step: "0\(ordinal * 3)-processing-\(ordinal)")
            fixture.processing.finish()
            let finished = try await stop.value
            fixture.settings.meetingSaveAudio = true
            XCTAssertEqual(finished.state, .completed)
            XCTAssertTrue(finished.hasFinalizedAudio)
            XCTAssertEqual(finished.transcriptSegments.map(\.text), [Fixture.secret])
            XCTAssertEqual(finished.audioStorageMode, .retainedFiles)
            XCTAssertTrue(fixture.coordinator.isQuiescent)
            XCTAssertFalse(fixture.arbiter.hasLease)
            try await settle()
            try capture(host, step: "0\(ordinal * 3 + 1)-saved-\(ordinal)")

            let reloadedStore = MeetingSessionStore(rootDirectory: fixture.root.appendingPathComponent("meetings"))
            let loaded = try await reloadedStore.load(id: finished.id)
            let reloaded = try XCTUnwrap(loaded)
            XCTAssertEqual(reloaded.transcriptSegments.map(\.text), [Fixture.secret])
            let directory = try await reloadedStore.sessionDirectory(for: reloaded.id)
            let url = try XCTUnwrap(MeetingAudioPresentation.firstPlaybackURL(in: reloaded, directory: directory))
            let audio = try AVAudioFile(forReading: url)
            XCTAssertEqual(audio.processingFormat.sampleRate, 16_000)
            XCTAssertEqual(audio.length, 24_000)
            let all = try await reloadedStore.loadAll()
            XCTAssertEqual(all.count, ordinal)
        }
        XCTAssertEqual(fixture.arbiter.acquireCount, 2)
        XCTAssertEqual(fixture.arbiter.releaseCount, 2)
        #endif
    }

    func testPreparationFailureDoesNotAcquireCaptureOrChangeAdministratorPreferences() async throws {
        let fixture = try Fixture(failPreparation: true)
        addTeardownBlock { await fixture.cleanup() }
        do {
            try await MobileMeetingRecordingActions.start(coordinator: fixture.coordinator,
                required: fixture.required, privacyActivation: fixture.privacy, settings: fixture.settings)
            XCTFail("A failed preparation must not admit a capture")
        } catch {
            XCTAssertEqual(fixture.arbiter.acquireCount, 0)
            XCTAssertFalse(fixture.coordinator.hasPendingStart)
            XCTAssertTrue(fixture.coordinator.isQuiescent)
            XCTAssertTrue(fixture.settings.meetingSaveAudio)
            XCTAssertEqual(fixture.settings.meetingAudioRetentionPolicy, .never)
            XCTAssertEqual(fixture.settings.selectedSpeechModel, .whisperSmall)
            let all = try await fixture.store.loadAll()
            XCTAssertTrue(all.isEmpty)
        }
    }

    private func waitForProcessing(_ processing: SyntheticProcessing) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !processing.isWaiting, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertTrue(processing.isWaiting, "Stop must reach the injected processing boundary")
        guard processing.isWaiting else { throw SyntheticFailure.preparation }
    }

    private func waitForMicrophoneLevel(_ coordinator: MeetingSessionCoordinator, expectedPeak: Float) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while coordinator.trackHealth[.microphone]?.status != .healthy, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let health = try XCTUnwrap(coordinator.trackHealth[.microphone],
            "The capture event must reach the same microphone meter used by ordinary recording")
        XCTAssertEqual(health.status, .healthy)
        XCTAssertEqual(health.level, expectedPeak, accuracy: 0.0001)
    }

    private func settle() async throws { try await Task.sleep(for: .milliseconds(150)) }

    private func capture(_ host: KioskWindow, step: String) throws {
        let image = host.image()
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "unspecified-revision"
        let name = "kiosk-recording-\(step)-\(revision)"
        let attachment = XCTAttachment(image: image)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let output = ProcessInfo.processInfo.environment["PICHI_KIOSK_EVIDENCE_DIR"] {
            let directory = URL(fileURLWithPath: output, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try XCTUnwrap(image.pngData()).write(to: directory.appendingPathComponent(name + ".png"))
        }
    }

    private nonisolated enum SyntheticFailure: Error { case preparation }

    private final class Fixture {
        static let secret = "Synthetic hidden transcript Ёё 4829"
        let suite = "MobileKioskRecordingTests.\(UUID().uuidString)"
        let root: URL
        let defaults: UserDefaults
        let settings: SettingsStore
        let store: MeetingSessionStore
        let capture = SyntheticCapture()
        let processing = SyntheticProcessing()
        let arbiter = SyntheticArbiter()
        let coordinator: MeetingSessionCoordinator
        let required: MobileRequiredResources
        let privacy: MobilePrivacyActivation
        let access = MobileKioskAccess(storage: MemoryCredentialStore())

        init(failPreparation: Bool = false) throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
            defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
            settings = SettingsStore(defaults: defaults)
            settings.fluidMeetEnabled = true
            settings.selectedSpeechModel = .whisperSmall
            settings.meetingSaveAudio = true
            settings.meetingAudioRetentionPolicy = .never
            settings.meetingSpeakerLabelsEnabled = false
            settings.meetingPIIRedactionRequested = false
            settings.meetingPIIRedactionEnabled = false
            store = MeetingSessionStore(rootDirectory: root.appendingPathComponent("meetings"))
            let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: Self.secret,
                languageCode: "ru", microphone: .init(captureDeviceID: "synthetic-kiosk-input",
                    displayName: "Synthetic input"), audioStorageMode: .retainedFiles,
                speakerLabelsEnabled: false, transcriptionBackendID: MeetingBackendID.legacyCompatibility.rawValue)
            coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: processing,
                audioArbiter: arbiter, settings: settings,
                defaultConfigurationResolver: { _, _ in configuration }, processingLogger: { _ in })
            let artifact = MeetingNemotronModelArtifact(packageURL: root.appendingPathComponent("invented-artifact"),
                totalByteCount: 1, fileCount: 1, manifestSHA256: "synthetic", entryMetadataSHA256: "synthetic")
            let speakerStore = MeetingDiarizationModelStore(supportsOwnerVoiceVerification: false,
                validate: { artifact }, install: { _ in throw SyntheticFailure.preparation })
            required = MobileRequiredResources(prepareSpeech: {
                if failPreparation { throw SyntheticFailure.preparation }
            }, speakerStore: { _ in speakerStore })
            privacy = MobilePrivacyActivation(settings: settings, prepare: { _ in
                XCTFail("Privacy was disabled by the administrator")
                throw SyntheticFailure.preparation
            })
        }

        func cleanup() async {
            processing.finish()
            await coordinator.shutdownForTermination()
            await capture.shutdownForTermination()
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
    }

    private nonisolated final class MemoryCredentialStore: MobileKioskCredentialStoring, @unchecked Sendable {
        func read() throws -> Data? { nil }
        func write(_ data: Data) throws { throw SyntheticFailure.preparation }
    }

    private actor SyntheticCapture: MeetingCaptureControlling {
        private var writer: MeetingAudioChunkWriter?
        private var startedAt = Date()
        private(set) var measuredPeak: Float = 0

        func preflightPermissions() async throws {}

        func start(session: MeetingSession, configuration: MeetingCaptureConfiguration,
                   sessionDirectory: URL, eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
                   liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) async throws -> MeetingCaptureStartResult {
            startedAt = session.startedAt
            let track = MeetingAudioTrack(id: UUID(), kind: .microphone,
                sourceIdentifier: configuration.microphone.captureDeviceID,
                sourceDisplayName: configuration.microphone.displayName,
                format: nil, timebase: session.timebase, health: .waiting, chunks: [])
            let output = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory,
                chunkDuration: 60, eventHandler: eventHandler)
            writer = output
            let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                sampleRate: 16_000, channels: 1, interleaved: false))
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
            pcm.frameLength = 24_000
            let samples = try XCTUnwrap(pcm.floatChannelData?[0])
            measuredPeak = 0
            for frame in 0..<24_000 {
                let value = 0.1 * sin(Float(frame) * 0.1)
                samples[frame] = value
                measuredPeak = max(measuredPeak, abs(value))
            }
            let sample = try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm, presentationTime: .zero)
            guard output.enqueue(sample) else { throw SyntheticFailure.preparation }
            // The production iOS capture reports the accepted PCM's peak through this event.
            // Keep the returned track waiting so the test verifies that event-to-meter path.
            eventHandler(.trackHealth(trackID: track.id, health: .init(status: .healthy,
                lastPresentationTime: .init(value: 0, timescale: 16_000), lastSampleAt: Date(),
                level: min(1, measuredPeak), droppedSampleCount: 0, detail: nil, silentForSeconds: 0)))
            return .init(tracks: [track], firstPresentationTime: .init(value: 0, timescale: 16_000))
        }

        func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
            guard let writer else { throw SyntheticFailure.preparation }
            self.writer = nil
            return .init(tracks: [await writer.stop()], stoppedAt: startedAt.addingTimeInterval(1.5))
        }

        func shutdownForTermination() async {
            if let writer { self.writer = nil; _ = await writer.stop() }
        }
    }

    private final class SyntheticProcessing: MeetingProcessingControlling {
        var hold = false
        private(set) var isWaiting = false
        private var continuation: CheckedContinuation<Void, Never>?

        func process(session: MeetingSession, sessionDirectory: URL,
                     progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingProcessingResult {
            progress(.transcribing)
            if hold {
                isWaiting = true
                await withCheckedContinuation { continuation = $0 }
                isWaiting = false
            }
            let track = try XCTUnwrap(session.audioTracks.first)
            return .init(speakers: [], segments: [.init(id: UUID(), start: .init(value: 0, timescale: 16_000),
                end: .init(value: 24_000, timescale: 16_000), sourceTrackID: track.id, speakerID: nil,
                text: Fixture.secret, revision: 0, status: .final, overlap: .none, completeness: .complete)],
                attempt: .init(id: UUID(), startedAt: Date(), completedAt: Date(), stage: .completed,
                    pipelineVersion: MeetingProcessingPipeline.pipelineVersion, asrProvider: "synthetic",
                    asrModel: "synthetic", diarizationModel: nil, lastCompletedTrackID: track.id, errorCode: nil))
        }

        func finish() {
            hold = false
            let pending = continuation
            continuation = nil
            pending?.resume()
        }
    }

    private final class SyntheticArbiter: MeetingAudioActivityArbitrating {
        private(set) var acquireCount = 0
        private(set) var releaseCount = 0
        private(set) var hasLease = false
        func acquireMeetingCapture() async throws -> MeetingAudioActivityLease {
            XCTAssertFalse(hasLease)
            hasLease = true
            acquireCount += 1
            return .init(id: UUID())
        }
        func release(_ lease: MeetingAudioActivityLease) async {
            XCTAssertTrue(hasLease)
            hasLease = false
            releaseCount += 1
        }
    }

    private final class KioskWindow {
        let window: UIWindow
        weak var previous: UIWindow?

        init(coordinator: MeetingSessionCoordinator, required: MobileRequiredResources,
             privacy: MobilePrivacyActivation, access: MobileKioskAccess,
             audioArbiter: any MeetingAudioActivityArbitrating) throws {
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
                .first { $0.activationState == .foregroundActive })
            previous = scene.windows.first { $0.isKeyWindow }
            window = UIWindow(windowScene: scene)
            window.windowLevel = .init(rawValue: UIWindow.Level.normal.rawValue + 1)
            window.rootViewController = UIHostingController(rootView: AdaptiveAppTheme(accent: .blue) {
                MobileKioskRoot(coordinator: coordinator, required: required,
                    privacyActivation: privacy, access: access, audioArbiter: audioArbiter)
            })
            window.makeKeyAndVisible()
            window.layoutIfNeeded()
        }

        func close() {
            window.isHidden = true
            window.rootViewController = nil
            previous?.makeKeyAndVisible()
        }

        // Hosted SwiftUI does not expose an XCUI accessibility snapshot in this process.
        // These native frames are visually reviewed; MobileKioskUITests owns AX assertions.
        func image() -> UIImage {
            window.layoutIfNeeded()
            return UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
                window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
            }
        }
    }
}
