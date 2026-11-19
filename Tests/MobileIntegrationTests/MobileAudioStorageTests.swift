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

    func testVoiceMaskProtectsSealedPartialBeforeFinalPublication() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let (pcm, sample) = try self.syntheticSample(rate: 16_000)
        let sink = MeetingAudioFilePCMChunkSink(sessionDirectory: root, voiceMask: MeetingVoiceMask())
        try sink.begin(relativeFilePath: "track.caf", format: pcm.format)
        let receipt = try sink.append(sample)
        XCTAssertEqual(receipt.framesWritten, Int64(pcm.frameLength))
        try sink.sealForRecovery()
        let partial = root.appendingPathComponent(try XCTUnwrap(sink.partialRelativeFilePath))
        let file = try AVAudioFile(forReading: partial)
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: pcm.frameLength))
        try file.read(into: buffer)
        XCTAssertEqual(buffer.frameLength, pcm.frameLength)
        let stored = try XCTUnwrap(buffer.floatChannelData?[0])
        let original = try XCTUnwrap(pcm.floatChannelData?[0])
        let frames = 0..<Int(buffer.frameLength)
        XCTAssertTrue(frames.contains { abs(stored[$0] - original[$0]) > 0.05 })
        XCTAssertTrue(frames.contains { abs(stored[$0]) > 0.01 })
        let stage = try Data(contentsOf: partial)
        let final = try sink.finalize().get()
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent(final.relativeFilePath)), stage)
    }

    func testMaskedWriterRejectsUnsupportedFormatAndRecoversOnNextCanonicalInput() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "fixture",
            sourceDisplayName: "Fixture", format: nil, timebase: .init(startedHostTime: 0,
                machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [])
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: root, chunkDuration: 60,
            eventHandler: { _ in }, maskSavedVoices: true)
        let (_, unsupported) = try self.syntheticSample(rate: 48_000)
        XCTAssertTrue(writer.enqueue(unsupported))
        let rejected = await writer.snapshot()
        XCTAssertGreaterThan(rejected.health.droppedSampleCount, 0)
        let files = try FileManager.default.subpathsOfDirectory(atPath: root.path)
        XCTAssertFalse(files.contains { $0.hasSuffix(".caf") })
        let (canonical, supported) = try self.syntheticSample(rate: 16_000)
        XCTAssertTrue(writer.enqueue(supported))
        let finalized = await writer.stop()
        XCTAssertEqual(finalized.chunks.count, 1)
        let asset = try XCTUnwrap(finalized.chunks.first?.captureAnalysisAsset)
        XCTAssertEqual(asset.frameCount, Int64(canonical.frameLength))
        XCTAssertEqual(asset.sampleRate, 16_000)
        XCTAssertEqual(finalized.chunks.first?.finalizationState, .finalized)
    }

    func testMaskedCaptionsWithSpeakerLabelsOffKeepOriginalPCMInBoundedMemory() async throws {
        var configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Fixture",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture"),
            audioStorageMode: .retainedFiles, speakerLabelsEnabled: false)
        configuration.maskSavedVoices = true
        let selected = try XCTUnwrap(MeetingSessionCoordinator.legacyCaptionStorage(for: configuration, speechDeferred: false))
        XCTAssertEqual(selected, .memoryOnly)
        // No writable spool directory is available. Falling back to disk would fail this read.
        let absentDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let fifo = MeetingLiveAudioFIFO(temporaryDirectory: absentDirectory, storage: selected)
        addTeardownBlock { await fifo.close() }
        let (_, original) = try self.syntheticSample(rate: 16_000)
        let input = try XCTUnwrap(MeetingLiveSampleCopy.copy(original))
        XCTAssertTrue(fifo.enqueue(.init(sample: input, epoch: 7)))
        let waiting = await fifo.testingState()
        XCTAssertGreaterThan(waiting.memoryBacklogBytes, 0)
        XCTAssertEqual(waiting.diskBytes, 0)
        XCTAssertEqual(waiting.permissions, 0)
        let batch = try await fifo.drainBatch()
        let restored = try XCTUnwrap(batch.first)
        XCTAssertEqual(restored.epoch, 7)
        XCTAssertEqual(restored.sample.buffer.frameLength, input.buffer.frameLength)
        let left = try XCTUnwrap(restored.sample.buffer.floatChannelData?[0])
        let right = try XCTUnwrap(input.buffer.floatChannelData?[0])
        let frames = Int(input.buffer.frameLength)
        XCTAssertTrue(UnsafeBufferPointer(start: left, count: frames).elementsEqual(UnsafeBufferPointer(start: right, count: frames)))
        let drained = await fifo.testingState()
        XCTAssertEqual(drained.memoryBacklogBytes, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: absentDirectory.path))

        XCTAssertNil(MeetingSessionCoordinator.legacyCaptionStorage(for: configuration, speechDeferred: true))
        configuration.audioStorageMode = .memoryOnly
        XCTAssertNil(MeetingSessionCoordinator.legacyCaptionStorage(for: configuration, speechDeferred: false))
        configuration.audioStorageMode = .retainedFiles
        configuration.speakerLabelsEnabled = true
        configuration.speakerProcessingMode = .streaming
        XCTAssertNil(MeetingSessionCoordinator.legacyCaptionStorage(for: configuration, speechDeferred: false))
        configuration.speakerProcessingMode = .afterRecording
        XCTAssertEqual(MeetingSessionCoordinator.legacyCaptionStorage(for: configuration, speechDeferred: false), .memoryOnly)
        configuration.maskSavedVoices = nil
        XCTAssertEqual(MeetingSessionCoordinator.legacyCaptionStorage(for: configuration, speechDeferred: false), .anonymousFile)
    }

    func testFullMaskedCaptionBacklogReportsOverflowAndClosesWithoutDiskFallback() async throws {
        let (_, original) = try self.syntheticSample(rate: 16_000)
        let input = try XCTUnwrap(MeetingLiveSampleCopy.copy(original))
        var limits = MeetingLiveAudioFIFO.Limits()
        limits.maximumPendingBytes = 20_000 // Holds one serialized 3200-frame packet.
        let fifo = MeetingLiveAudioFIFO(limits: limits, storage: .memoryOnly)
        addTeardownBlock { await fifo.close() }
        XCTAssertTrue(fifo.enqueue(.init(sample: input, epoch: 1)))
        _ = await fifo.testingState()
        XCTAssertTrue(fifo.enqueue(.init(sample: input, epoch: 2)))
        let full = await fifo.testingState()
        XCTAssertGreaterThan(full.memoryBacklogBytes, 0)
        XCTAssertLessThanOrEqual(full.memoryBacklogBytes, limits.maximumPendingBytes)
        XCTAssertEqual(full.diskBytes, 0)
        XCTAssertEqual(full.permissions, 0)
        do { _ = try await fifo.drainBatch(); XCTFail("Capacity exhaustion must pause live captions.") }
        catch { XCTAssertEqual(error as? MeetingLiveAudioFIFO.Failure, .pendingCapacity) }
        XCTAssertFalse(fifo.enqueue(.init(sample: input, epoch: 3)))
        await fifo.close()
        let closed = await fifo.testingState()
        XCTAssertEqual(closed.memoryBacklogBytes, 0)
        XCTAssertEqual(closed.diskBytes, 0)
    }

    private func syntheticSample(rate: Double) throws -> (AVAudioPCMBuffer, CMSampleBuffer) {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: rate, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3200))
        pcm.frameLength = pcm.frameCapacity
        let data = try XCTUnwrap(pcm.floatChannelData?[0])
        for frame in 0..<Int(pcm.frameLength) { data[frame] = 0.2 * sin(Float(frame) * 0.1) }
        let sample = try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm, presentationTime: .zero, sampleRate: rate)
        return (pcm, sample)
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
