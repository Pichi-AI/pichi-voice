import Foundation
@testable import FluidVoice_Debug
import XCTest

/// Admission must happen before any permission, device discovery or audio-file owner is reached.
/// This deliberately passes a nonexistent session directory and a synthetic microphone identity.
@MainActor
final class MeetingCaptureStorageAdmissionTests: XCTestCase {
    func testDesktopRefusesStreamingWithoutConsumerBeforeStorageOrPermissionWork() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic streaming admission",
            languageCode: "ru", microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic microphone"),
            audioStorageMode: .retainedFiles, speakerProcessingMode: .streaming)
        let session = MeetingSession(configuration: configuration,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        let engine = MeetingCaptureEngine()
        do {
            _ = try await engine.start(session: session, configuration: configuration,
                sessionDirectory: root, eventHandler: { _ in }, liveAudioHandler: nil)
            XCTFail("A missing bounded consumer must fail before an audio writer can be made")
        } catch let error as MeetingCaptureError {
            guard case .captureStartFailed = error else { return XCTFail("Unexpected admission error: \(error)") }
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        await engine.shutdownForTermination()
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
