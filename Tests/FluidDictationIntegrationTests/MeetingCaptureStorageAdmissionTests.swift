import Foundation
@testable import FluidVoice_Debug
import XCTest

/// Admission must happen before any permission, device discovery or audio-file owner is reached.
/// This deliberately passes a nonexistent session directory and a synthetic microphone identity.
@MainActor
final class MeetingCaptureStorageAdmissionTests: XCTestCase {
    /// Recording reliability contract (AGENTS.md, #157): file-backed recording never stops because a
    /// live transcription consumer is missing. Audio keeps being retained and transcription is
    /// deferred. Only the strict no-file policy refuses, and it must not silently downgrade.
    func testStreamingWithoutConsumerDefersTranscriptionForFilesAndRefusesStrictMemoryOnly() async throws {
        for storage in [MeetingAudioStorageMode.retainedFiles, .memoryOnly] {
            let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic streaming admission",
                languageCode: "ru", microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone"),
                audioStorageMode: storage, speakerProcessingMode: .streaming)
            let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil)
            let session = MeetingSession(configuration: configuration, timebase: timebase)
            let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
                sourceDisplayName: "Synthetic microphone", format: nil, timebase: timebase, health: .waiting, chunks: [])
            let events = AdmissionEventRecorder()
            var deferred: MeetingMultiTrackCaptureTee?
            var failure: Error?
            do {
                deferred = try await MeetingMultiTrackCaptureTee.prepare(
                    session: session, configuration: configuration, tracks: [track], consumerFactory: nil,
                    eventHandler: events.record, liveAudioHandler: nil, privacyGate: nil, clockContexts: [:])
            } catch {
                failure = error
            }
            let deferrals = events.snapshot().filter {
                if case .interrupted(.liveTranscriptionDeferred, nil, _) = $0 { return true }
                return false
            }
            switch storage {
            case .retainedFiles:
                XCTAssertNil(failure, "File-backed recording must not stop for a missing consumer")
                XCTAssertNil(deferred, "No consumer means no streaming tee, so the files remain the only owner")
                XCTAssertEqual(deferrals.count, 1, "The deferral is reported once so retained audio can be transcribed later")
            case .memoryOnly:
                XCTAssertEqual(failure as? MeetingCapturePCMError, .transcriptionStopped)
                XCTAssertNil(deferred)
                XCTAssertTrue(deferrals.isEmpty, "A strict no-file recording must not be downgraded to deferral")
            }
        }
    }

    func testDesktopRefusesMemoryOnlyBeforeAnyAudioFilesOrDirectoriesAreCreated() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let sessionDirectory = scratch.appendingPathComponent("session-not-created", isDirectory: true)
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic privacy admission",
                                                        languageCode: "en",
                                                        microphone: MeetingMicrophoneIdentity(captureDeviceID: "synthetic-mic",
                                                                                              displayName: "Synthetic microphone"),
                                                        audioStorageMode: .memoryOnly)
        let session = MeetingSession(configuration: configuration,
                                     timebase: MeetingTimebaseMetadata(startedHostTime: 0,
                                                                       machTimebaseNumerator: 1,
                                                                       machTimebaseDenominator: 1,
                                                                       firstPresentationTime: nil))
        let engine = MeetingCaptureEngine()
        do {
            _ = try await engine.start(session: session, configuration: configuration,
                                       sessionDirectory: sessionDirectory, eventHandler: { _ in }, liveAudioHandler: nil)
            XCTFail("Desktop capture must not advertise a memory-only path while it only supports file writers.")
        } catch let error as MeetingCaptureError {
            guard case .captureStartFailed = error else {
                XCTFail("Strict admission must precede permission/storage/device work: \(error)")
                return
            }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: sessionDirectory.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: scratch.path), [])
        await engine.shutdownForTermination()
    }
}

private final class AdmissionEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [MeetingCaptureEvent] = []
    func record(_ event: MeetingCaptureEvent) { self.lock.withLock { self.events.append(event) } }
    func snapshot() -> [MeetingCaptureEvent] { self.lock.withLock { self.events } }
}
