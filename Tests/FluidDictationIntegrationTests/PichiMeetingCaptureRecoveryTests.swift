import AVFoundation
import CoreMedia
import CryptoKit
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Closed-capture recovery after a crash between publication of the final CAF and the index update.
final class PichiMeetingCaptureRecoveryTests: XCTestCase {
    private let finalPath = "tracks/microphone/000001.caf"
    private let partialPath = "tracks/microphone/000001.recovery.partial.caf"
    private let frames = 480

    func testPublishedFinalFileIsRecoveredEvenWhenPartialPathMetadataIsMalformed() throws {
        let root = try self.makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        try self.publishFinalCapture(in: root)
        let finalURL = root.appendingPathComponent(self.finalPath)
        let before = try Data(contentsOf: finalURL)
        var identity = stat(); XCTAssertEqual(lstat(finalURL.path, &identity), 0)

        for malformed in ["../escape.partial.caf", "/etc/escape.partial.caf", "tracks/../x.partial.caf", "no-extension"] {
            let chunk = self.chunk(partialPath: malformed)
            let recovered = try MeetingAudioFilePCMChunkSink.recoverClosedCapture(chunk, in: root)

            XCTAssertEqual(recovered.relativeFilePath, self.finalPath, malformed)
            XCTAssertEqual(recovered.frameCount, Int64(self.frames), malformed)
            XCTAssertEqual(recovered.byteCount, Int64(before.count), malformed)
            XCTAssertEqual(recovered.sha256, SHA256.hash(data: before).map { String(format: "%02x", $0) }.joined(), malformed)
        }
        var after = stat(); XCTAssertEqual(lstat(finalURL.path, &after), 0)
        XCTAssertEqual(try Data(contentsOf: finalURL), before, "recovery must not rewrite the published recording")
        XCTAssertEqual(after.st_ino, identity.st_ino)
        XCTAssertEqual(after.st_mtimespec.tv_sec, identity.st_mtimespec.tv_sec)
    }

    func testMalformedPartialPathWithoutPublishedFileStillFails() throws {
        let root = try self.makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let chunk = self.chunk(partialPath: "../escape.partial.caf")

        XCTAssertThrowsError(try MeetingAudioFilePCMChunkSink.recoverClosedCapture(chunk, in: root)) { error in
            XCTAssertEqual(error as? MeetingPCMSinkError, .invalidRelativePath("../escape.partial.caf"))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(self.finalPath).path))
    }

    func testADirectoryInPlaceOfThePartialCaptureIsAPermanentRejection() throws {
        let root = try self.makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let partial = root.appendingPathComponent(self.partialPath)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        XCTAssertThrowsError(try MeetingAudioFilePCMChunkSink.recoverClosedCapture(self.chunk(partialPath: self.partialPath), in: root)) { error in
            XCTAssertEqual((error as? MeetingPCMSinkError)?.isPermanentRecoveryRejection, true, "\(error)")
        }
        var info = stat(); XCTAssertEqual(lstat(partial.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR, "Recovery keeps what it rejects")
    }

    func testACaptureInAnotherFormatThanItsExtentIsAPermanentRejection() throws {
        let root = try self.makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let other = "tracks/microphone/other.caf"
        try self.publishFinalCapture(in: root, path: other, sampleRate: 16_000)
        let partial = root.appendingPathComponent(self.partialPath)
        try FileManager.default.moveItem(at: root.appendingPathComponent(other), to: partial)
        let before = try Data(contentsOf: partial)

        XCTAssertThrowsError(try MeetingAudioFilePCMChunkSink.recoverClosedCapture(self.chunk(partialPath: self.partialPath), in: root)) { error in
            XCTAssertEqual((error as? MeetingPCMSinkError)?.isPermanentRecoveryRejection, true, "\(error)")
        }
        XCTAssertEqual(try Data(contentsOf: partial), before, "Recovery keeps what it rejects")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(self.finalPath).path))
    }

    func testAMissingCaptureStaysATransientFailure() throws {
        let root = try self.makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        // A finalizer may be publishing the capture at this moment, so a missing file proves nothing yet.
        XCTAssertThrowsError(try MeetingAudioFilePCMChunkSink.recoverClosedCapture(self.chunk(partialPath: self.partialPath), in: root)) { error in
            XCTAssertEqual((error as? MeetingPCMSinkError)?.isPermanentRecoveryRejection, false, "\(error)")
        }
    }

    func testReloadFailsAChunkWhosePartialCaptureIsADirectoryAndKeepsTheDirectory() async throws {
        let root = try self.makeDirectory(); defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        var session = MeetingSession(
            id: UUID(),
            configuration: MeetingCaptureConfiguration(
                mode: .inRoom, title: "Directory partial",
                microphone: MeetingMicrophoneIdentity(captureDeviceID: "m", displayName: "M")
            ),
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
        )
        var chunk = self.chunk(partialPath: self.partialPath)
        chunk.sequence = 0
        chunk.captureAnalysisAsset?.presence = .partial
        let track = MeetingAudioTrack(
            id: UUID(), kind: .microphone, sourceIdentifier: "m", sourceDisplayName: "M", format: nil,
            timebase: session.timebase, health: .waiting, chunks: [chunk]
        )
        session.audioTracks = [track]
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: session.id)
        let header = directory.appendingPathComponent("tracks/microphone/track.json")
        try FileManager.default.createDirectory(at: header.deletingLastPathComponent(), withIntermediateDirectories: true)
        try JSONEncoder().encode(track).write(to: header)
        let partial = directory.appendingPathComponent(self.partialPath)
        try FileManager.default.createDirectory(at: partial, withIntermediateDirectories: true)

        let loaded = try await store.load(id: session.id)

        XCTAssertEqual(
            loaded?.audioTracks.first?.chunks.first?.finalizationState,
            .failed,
            "No writer can turn a directory into this capture, so it must not stay writing on every reload"
        )
        var info = stat(); XCTAssertEqual(lstat(partial.path, &info), 0)
        XCTAssertEqual(info.st_mode & S_IFMT, S_IFDIR, "Recovery keeps what it rejects")
    }

    private func chunk(partialPath: String) -> MeetingAudioChunk {
        let asset = MeetingAudioAsset(
            role: .captureAnalysis, encoding: .linearPCMFloat32CAFV1, presence: .ready,
            relativeFilePath: partialPath, byteCount: 0, sha256: "", sampleRate: 48_000, channelCount: 1, frameCount: Int64(self.frames)
        )
        return MeetingAudioChunk(
            id: UUID(), sequence: 1, relativeFilePath: self.finalPath,
            presentationStart: MeetingMediaTime(value: 0, timescale: 1000),
            presentationEnd: MeetingMediaTime(value: 10, timescale: 1000),
            discontinuities: [], sha256: "", byteCount: 0, finalizationState: .writing,
            audioSchemaVersion: 2, captureAnalysisAsset: asset
        )
    }

    private func publishFinalCapture(in root: URL, path: String? = nil, sampleRate: Double = 48_000) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: sampleRate, channels: 1, interleaved: true))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: path ?? self.finalPath, format: format)
        _ = try sink.append(self.sampleBuffer(format: format))
        _ = try sink.finalize().get()
    }

    private func sampleBuffer(format: AVAudioFormat) throws -> CMSampleBuffer {
        let bytes = (0..<self.frames).map { Float($0 % 100) / 100 }.withUnsafeBytes { Data($0) }
        var block: CMBlockBuffer?
        XCTAssertEqual(CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault, memoryBlock: nil, blockLength: bytes.count, blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil, offsetToData: 0, dataLength: bytes.count, flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
        ), noErr)
        let blockBuffer = try XCTUnwrap(block)
        XCTAssertEqual(bytes.withUnsafeBytes { raw in
            raw.baseAddress.map { CMBlockBufferReplaceDataBytes(with: $0, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: bytes.count) } ?? -1
        }, noErr)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: CMTimeScale(format.sampleRate)), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault, dataBuffer: blockBuffer, formatDescription: format.formatDescription,
            sampleCount: self.frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
            sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sample
        ), noErr)
        return try XCTUnwrap(sample)
    }

    private func makeDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("PichiCaptureRecovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false, attributes: [.posixPermissions: NSNumber(value: Int16(0o700))])
        return url
    }
}
