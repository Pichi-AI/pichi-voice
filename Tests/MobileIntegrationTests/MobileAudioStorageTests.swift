@preconcurrency import AVFoundation
import CoreMedia
import Foundation
@testable import PichiVoiceMobile
import XCTest

@MainActor
final class MobileAudioStorageTests: XCTestCase {
    func testEphemeralAACPreservesBoundariesAndReleasesItsRecording() async throws {
        let archive = try MeetingMemoryAudioArchive()
        let count = 65 * 16_000 + 317
        let input = (0..<count).map { Float(0.3) * sin(Float($0) * 0.12) }
        for start in stride(from: 0, to: count, by: 1_600) {
            try input.withUnsafeBufferPointer {
                try archive.append(UnsafeBufferPointer(rebasing: $0[start..<min(count, start + 1_600)]))
            }
        }
        XCTAssertLessThanOrEqual(archive.bufferedPCMSampleCount, 480_000)
        try archive.seal()
        XCTAssertEqual(archive.totalSampleCount, count)
        XCTAssertLessThan(archive.retainedEncodedBytes, 1_000_000)
        let range = (29 * 16_000)..<(31 * 16_000)
        let decoded = try await archive.readSamples(in: range)
        XCTAssertEqual(decoded.count, range.count)
        let mse = zip(decoded, input[range]).reduce(Float(0)) { $0 + ($1.0 - $1.1) * ($1.0 - $1.1) } / Float(range.count)
        XCTAssertLessThan(mse, 0.002, "AAC priming must not move the source timeline")
        archive.clear()
        XCTAssertEqual(archive.totalSampleCount, 0)
        XCTAssertEqual(archive.retainedEncodedBytes, 0)
        XCTAssertEqual(archive.bufferedPCMSampleCount, 0)
    }

    func testRetainedPCMUsesOriginalWriterAndExportsProtectedPlayableAudio() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic audio",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture"), audioStorageMode: .retainedFiles)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: configuration, timebase: timebase)
        try await store.create(session)
        let directory = try await store.sessionDirectory(for: session.id)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "fixture",
            sourceDisplayName: "Fixture", format: nil, timebase: timebase, health: .waiting, chunks: [])
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: directory,
            chunkDuration: 1, eventHandler: { _ in })
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000, channels: 1, interleaved: false))
        for ordinal in 0..<2 {
            let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 12_000))
            pcm.frameLength = 12_000
            let channel = try XCTUnwrap(pcm.floatChannelData?[0])
            for frame in 0..<12_000 { channel[frame] = 0.1 * sin(Float(frame) * 0.1) }
            let sample = try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm,
                presentationTime: CMTime(value: Int64(ordinal * 12_000), timescale: 16_000))
            XCTAssertTrue(writer.enqueue(sample))
        }
        let finalized = await writer.stop()
        XCTAssertFalse(finalized.chunks.isEmpty)
        XCTAssertTrue(finalized.chunks.allSatisfy { $0.finalizationState == .finalized && $0.byteCount > 0 })
        session.audioTracks = [finalized]
        session.state = .completed
        session.endedAt = session.startedAt.addingTimeInterval(1.5)
        try await store.save(session)
        XCTAssertTrue(session.hasFinalizedAudio)
        let playback = try XCTUnwrap(MeetingAudioPresentation.firstPlaybackURL(in: session, directory: directory))
        let audio = try AVAudioFile(forReading: playback)
        XCTAssertEqual(audio.processingFormat.sampleRate, 16_000)
        XCTAssertGreaterThan(audio.length, 0)
        XCTAssertEqual(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try assertProtectedFiles(in: directory)

        let payload = try await MeetingSharePayload.audio(session: session, directory: directory)
        defer { payload.cleanup() }
        XCTAssertTrue(payload.includesAudio)
        XCTAssertFalse(payload.items.isEmpty)
        XCTAssertEqual(try payload.directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        try assertProtectedFiles(in: payload.directory)
    }

    private func assertProtectedFiles(in directory: URL) throws {
        let files = try XCTUnwrap(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let file as URL in files {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #if targetEnvironment(simulator)
            // Simulator files live on macOS; this runtime returns no iOS protection class.
            if let actual = attributes[.protectionKey] as? String {
                XCTAssertEqual(actual, FileProtectionType.completeUntilFirstUserAuthentication.rawValue, file.lastPathComponent)
            }
            #else
            XCTAssertEqual(attributes[.protectionKey] as? String,
                FileProtectionType.completeUntilFirstUserAuthentication.rawValue, file.lastPathComponent)
            #endif
        }
    }

    func testFileProtectionClassOnPhysicalDevice() throws {
        #if targetEnvironment(simulator)
        throw XCTSkip("The iOS Simulator does not implement device Data Protection. Verify on a physical iPad or iPhone.")
        #else
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: url) }
        try Data([1]).write(to: url, options: .completeFileProtectionUntilFirstUserAuthentication)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual(attributes[.protectionKey] as? String, FileProtectionType.completeUntilFirstUserAuthentication.rawValue)
        #endif
    }
}
