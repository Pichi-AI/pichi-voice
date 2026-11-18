import AVFoundation
import CoreMedia
import CryptoKit
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Closed-capture recovery after a crash between publication of the final CAF and the index update.
final class PichiMeetingCaptureRecoveryTests: XCTestCase {
    private let finalPath = "tracks/microphone/000001.caf"
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
            XCTAssertEqual(recovered.frameCount, self.frames, malformed)
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

    private func publishFinalCapture(in root: URL) throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: true))
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root)
        try sink.begin(relativeFilePath: self.finalPath, format: format)
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
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
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
