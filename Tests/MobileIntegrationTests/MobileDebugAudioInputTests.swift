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
            var remaining = Int(seconds * rate)
            while remaining > 0 {
                buffer.frameLength = AVAudioFrameCount(min(remaining, 4096))
                for channel in 0..<2 {
                    for frame in 0..<Int(buffer.frameLength) {
                        buffer.floatChannelData![channel][frame] = sin(Float(frame) * 0.1) * 0.2
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
