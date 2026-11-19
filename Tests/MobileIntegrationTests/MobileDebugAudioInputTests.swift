@preconcurrency import AVFoundation
import CoreMedia
import Darwin
import Foundation
@testable import PichiVoiceMobile
import XCTest

private final nonisolated class DebugAudioPCMProbe: MeetingMemoryAudioConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    private var largest = 0
    private let collectSamples: Bool
    private var capturedSamples: [Float] = []
    init(collectSamples: Bool = false) { self.collectSamples = collectSamples }
    var samples: [Float] { self.lock.withLock { self.capturedSamples } }
    private var expectedPTS: Double?
    private var continuous = true
    var snapshot: (frames: Int, largest: Int, continuous: Bool) {
        self.lock.withLock { (self.count, self.largest, self.continuous) }
    }
    var rejectionReason: String? { nil }
    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        self.lock.withLock {
            let frames = CMSampleBufferGetNumSamples(sampleBuffer)
            let pts = CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer))
            if let expectedPTS, abs(expectedPTS - pts) > 0.0001 { self.continuous = false }
            self.expectedPTS = pts + Double(frames) / 16_000
            if self.collectSamples, let buffer = MeetingLiveSampleCopy.copy(sampleBuffer)?.buffer,
               let values = buffer.floatChannelData?[0] {
                self.capturedSamples.append(contentsOf: UnsafeBufferPointer(start: values, count: Int(buffer.frameLength)))
            }
            self.count += frames; self.largest = max(self.largest, frames)
        }
        return true
    }
    func finish() async throws { }
}

@MainActor
final class MobileDebugAudioInputTests: XCTestCase {
    private func withInput(seconds: Double, rate: Double = 48_000,
                           body: (IOSMeetingDebugFileInput) async throws -> Void) async throws {
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = support.appendingPathComponent("DebugAudioInput", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let url = root.appendingPathComponent("synthetic.caf")
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
            sampleRate: rate, channels: 2, interleaved: false))
        try autoreleasepool {
            let file = try AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatLinearPCM,
                AVSampleRateKey: rate, AVNumberOfChannelsKey: 2, AVLinearPCMBitDepthKey: 32,
                AVLinearPCMIsFloatKey: true, AVLinearPCMIsNonInterleaved: false],
                commonFormat: .pcmFormatFloat32, interleaved: false)
            let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4096))
            let total = Int(seconds * rate)
            var remaining = total
            while remaining > 0 {
                buffer.frameLength = AVAudioFrameCount(min(remaining, 4096))
                for channel in 0..<2 {
                    let data = try XCTUnwrap(buffer.floatChannelData?[channel])
                    for frame in 0..<Int(buffer.frameLength) {
                        let index = total - remaining + frame
                        let frequency: Float = index < total / 2 ? 0.1 : 0.16
                        data[frame] = sin(Float(index) * frequency) * 0.2
                    }
                }
                try file.write(from: buffer)
                remaining -= Int(buffer.frameLength)
            }
        }
        let input = try XCTUnwrap(IOSMeetingDebugFileInput.requested(environment: [
            "PICHI_DEBUG_AUDIO_INPUT": "1", "PICHI_DEBUG_AUDIO_FILE": "synthetic.caf",
            "PICHI_DEBUG_AUDIO_SPEED": "32"], applicationSupport: support))
        try await body(input)
    }

    func testDebugInputRequiresExplicitFlagAndConfinesFixturePath() throws {
        XCTAssertNil(try IOSMeetingDebugFileInput.requested(environment: [:]))
        for path in ["", "/tmp/audio.wav", "../audio.wav", "nested/../audio.wav", "./audio.wav", "nested//audio.wav"] {
            XCTAssertThrowsError(try IOSMeetingDebugFileInput.requested(environment: [
                "PICHI_DEBUG_AUDIO_INPUT": "1", "PICHI_DEBUG_AUDIO_FILE": path]))
        }
        for speed in ["0", "nan", "inf", "33", "-1"] {
            XCTAssertThrowsError(try IOSMeetingDebugFileInput.requested(environment: [
                "PICHI_DEBUG_AUDIO_INPUT": "1", "PICHI_DEBUG_AUDIO_FILE": "audio.wav",
                "PICHI_DEBUG_AUDIO_SPEED": speed]))
        }
        let support = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let root = support.appendingPathComponent("DebugAudioInput")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: support) }
        let outside = support.appendingPathComponent("outside.wav")
        try Data([0]).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.wav"), withDestinationURL: outside)
        let input = try XCTUnwrap(IOSMeetingDebugFileInput.requested(environment: [
            "PICHI_DEBUG_AUDIO_INPUT": "1", "PICHI_DEBUG_AUDIO_FILE": "escape.wav"], applicationSupport: support))
        XCTAssertThrowsError(try input.validateFile())
    }

    func testDebugInputResamplesIncrementallyAndStopJoinsProducer() async throws {
        try await self.withInput(seconds: 0.2) { input in
            let probe = DebugAudioPCMProbe()
            let runtime = try IOSMeetingDebugFileRuntime(input: input, trackID: UUID(),
                originHostTime: mach_absolute_time(), writer: nil, memoryConsumer: probe,
                eventHandler: { _ in }, liveAudioHandler: nil)
            try await runtime.start()
            for _ in 0..<100 where probe.snapshot.frames < 3200 {
                try await Task.sleep(for: .milliseconds(10))
            }
            try await runtime.stop()
            XCTAssertEqual(probe.snapshot.frames, 3200)
            XCTAssertLessThanOrEqual(probe.snapshot.largest, 4096)
            XCTAssertTrue(probe.snapshot.continuous)
            let stopped = probe.snapshot.frames
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(probe.snapshot.frames, stopped)
            XCTAssertEqual(runtime.healthSnapshot().status, .stopped)
        }
    }

    func testVoiceMaskAppliesToBothTurnsBeforeStorageWhileRecognizerReceivesOriginalPCM() async throws {
        try await self.withInput(seconds: 0.4) { input in
            let original = try await self.capture(input, storage: .retainedFiles, masked: false)
            let masked = try await self.capture(input, storage: .retainedFiles, masked: true)
            let ephemeral = try await self.capture(input, storage: .memoryOnly, masked: true)
            XCTAssertEqual(original.live.count, 6400)
            XCTAssertTrue(original.saved == original.live)
            XCTAssertTrue(masked.live == original.live)
            XCTAssertTrue(ephemeral.live == original.live)
            XCTAssertTrue(ephemeral.saved.isEmpty)
            let saved = masked.saved
            XCTAssertEqual(saved.count, original.live.count)
            guard saved.count == 6400 && original.live.count == saved.count else { return }
            for range in [0..<3200, 3200..<6400] {
                let differences = zip(saved[range], original.live[range]).map { abs($0 - $1) }
                XCTAssertGreaterThan(differences.reduce(0, +) / Float(range.count), 0.015)
                XCTAssertTrue(saved[range].contains { abs($0) > 0.01 })
            }
        }
    }

    private func capture(_ input: IOSMeetingDebugFileInput, storage: MeetingAudioStorageMode, masked: Bool)
        async throws -> (live: [Float], saved: [Float]) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let probe = DebugAudioPCMProbe(collectSamples: true)
        let capture = IOSMeetingCaptureEngine(debugFileInput: input, memoryConsumerFactory: { _, _, _, _ in probe })
        var configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic turns",
            microphone: IOSMeetingDebugFileInput.identity, audioStorageMode: storage, speakerProcessingMode: .streaming)
        configuration.maskSavedVoices = masked
        let timebase = MeetingTimebaseMetadata(startedHostTime: mach_absolute_time(), machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        let session = MeetingSession(configuration: configuration, timebase: timebase)
        _ = try await capture.start(session: session, configuration: configuration,
            sessionDirectory: dir, eventHandler: { _ in })
        for _ in 0..<250 where probe.snapshot.frames < 6400 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let stopped = try await capture.stop(sessionID: session.id)
        if storage == .memoryOnly {
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: dir.path).isEmpty)
            return (probe.samples, [])
        }
        let track = try XCTUnwrap(stopped.tracks.first)
        XCTAssertEqual(track.chunks.count, 1)
        let chunk = try XCTUnwrap(track.chunks.first)
        XCTAssertEqual(chunk.finalizationState, .finalized)
        let file = try AVAudioFile(forReading: dir.appendingPathComponent(chunk.relativeFilePath))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat,
            frameCapacity: AVAudioFrameCount(file.length)))
        try file.read(into: buffer)
        let values = try XCTUnwrap(buffer.floatChannelData?[0])
        return (probe.samples, Array(UnsafeBufferPointer(start: values, count: Int(buffer.frameLength))))
    }

    func testDebugInputEarlyStopDoesNotContinueReadingLongFixture() async throws {
        try await self.withInput(seconds: 10) { input in
            let probe = DebugAudioPCMProbe()
            let runtime = try IOSMeetingDebugFileRuntime(input: input, trackID: UUID(),
                originHostTime: mach_absolute_time(), writer: nil, memoryConsumer: probe,
                eventHandler: { _ in }, liveAudioHandler: nil)
            try await runtime.start()
            while probe.snapshot.frames < 1600 { try await Task.sleep(for: .milliseconds(1)) }
            try await runtime.stop()
            let stopped = probe.snapshot.frames
            XCTAssertLessThan(stopped, 160_000)
            XCTAssertTrue(probe.snapshot.continuous)
            try await Task.sleep(for: .milliseconds(30))
            XCTAssertEqual(probe.snapshot.frames, stopped)
        }
    }
}
