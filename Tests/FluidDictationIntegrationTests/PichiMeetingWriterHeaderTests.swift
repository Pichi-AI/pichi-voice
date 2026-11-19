import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The track header of a capture writer is on disk when its initializer returns. The upstream writer
/// guaranteed this; the coalescing journal wrote the first header from a background queue instead, and
/// an upstream test that removes the track directory right after creating a writer raced that write
/// (NSCocoaErrorDomain 513 from removeItem on CI run 44330654476).
final class PichiMeetingWriterHeaderTests: XCTestCase {
    private final class JournalGate: @unchecked Sendable {
        let release = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var held = false
        /// Parks only the first manifest operation; later ones must not wait for the release again.
        func hold(_ operation: MeetingAudioRecordingJournal.Operation) throws {
            guard case .manifest = operation else { return }
            let first = self.lock.withLock { let value = !self.held; self.held = true; return value }
            if first {
                _ = self.release.wait(timeout: .now() + 10)
            }
        }
    }

    private func makeTrack() -> MeetingAudioTrack {
        MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "test-mic", sourceDisplayName: "Test Microphone", format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            ),
            health: .waiting, chunks: []
        )
    }

    private func makeSessionDirectory() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("PichiWriterHeader-\(UUID().uuidString)", isDirectory: true)
    }

    private func headerURL(_ session: URL) -> URL {
        session.appendingPathComponent("tracks/microphone/track.json")
    }

    private func inode(_ url: URL) -> UInt64? {
        var info = stat()
        return lstat(url.path, &info) == 0 ? UInt64(info.st_ino) : nil
    }

    func testHeaderIsOnDiskWhenInitReturnsEvenWhileTheJournalIsHeld() async throws {
        let session = self.makeSessionDirectory(); defer { try? FileManager.default.removeItem(at: session) }
        let gate = JournalGate(); defer { gate.release.signal() }
        let track = self.makeTrack()
        let writer = try MeetingAudioChunkWriter(
            track: track, sessionDirectory: session, chunkDuration: 60, eventHandler: { _ in }, persistenceHook: gate.hold
        )

        // The journal queue is parked in its first manifest operation, so only init itself can have written this.
        let data = try Data(contentsOf: self.headerURL(session))
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        XCTAssertEqual(try decoder.decode(MeetingAudioTrack.self, from: data).id, track.id)
        var info = stat(); XCTAssertEqual(lstat(self.headerURL(session).path, &info), 0)
        XCTAssertEqual(info.st_mode & 0o777, 0o600)

        gate.release.signal()
        _ = await writer.stop()
    }

    func testRemovingTheTrackDirectoryRightAfterInitNeverRacesAJournalWrite() async throws {
        for _ in 0..<200 {
            let session = self.makeSessionDirectory(); defer { try? FileManager.default.removeItem(at: session) }
            let writer = try MeetingAudioChunkWriter(
                track: self.makeTrack(), sessionDirectory: session, chunkDuration: 60, eventHandler: { _ in }
            )
            try FileManager.default.removeItem(at: session.appendingPathComponent("tracks/microphone", isDirectory: true))
            _ = await writer.stop()
        }
    }

    func testAnIdenticalHeaderIsNotRewrittenButAChangedOneIs() async throws {
        let session = self.makeSessionDirectory(); defer { try? FileManager.default.removeItem(at: session) }
        let writer = try MeetingAudioChunkWriter(
            track: self.makeTrack(), sessionDirectory: session, chunkDuration: 60, eventHandler: { _ in }
        )
        let initial = try XCTUnwrap(self.inode(self.headerURL(session)))

        // updateTrackMetadata returns after the journal has handled its snapshot.
        try await writer.updateTrackMetadata { _ in }
        XCTAssertEqual(self.inode(self.headerURL(session)), initial, "an unchanged header must not be written again")

        try await writer.updateTrackMetadata { $0.captureMethod = .avCaptureSession }
        XCTAssertNotEqual(self.inode(self.headerURL(session)), initial, "a changed header must reach the disk")
        let saved = try String(contentsOf: self.headerURL(session), encoding: .utf8)
        XCTAssertTrue(saved.contains("avCaptureSession"), saved)
        _ = await writer.stop()
    }

    func testAFailedInitialHeaderWriteDoesNotFailTheWriter() async throws {
        let session = self.makeSessionDirectory(); defer { try? FileManager.default.removeItem(at: session) }
        // A directory in the place of the header makes the write fail for as long as it stays.
        try FileManager.default.createDirectory(
            at: self.headerURL(session), withIntermediateDirectories: true, attributes: nil
        )
        let track = self.makeTrack()
        let writer = try MeetingAudioChunkWriter(
            track: track, sessionDirectory: session, chunkDuration: 60, eventHandler: { _ in }
        )
        let stopped = await writer.stop()
        XCTAssertEqual(stopped.id, track.id)
    }
}
