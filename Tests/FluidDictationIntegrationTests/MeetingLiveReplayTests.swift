import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import XCTest
#if arch(arm64)
import FluidAudio
#endif

/// Opt-in replay harness: drives the REAL `MeetingLiveTranscriptionCoordinator` with a real,
/// previously-recorded Zoom meeting's decoded microphone/application-audio WAVs, to see what the
/// live-transcription pipeline actually produces. Gated behind an env var so the normal suite
/// stays deterministic - this test downloads/loads real CoreML models and takes real wall time.
///
/// Set `FLUIDVOICE_LIVE_REPLAY=1`, explicit `FLUIDVOICE_LIVE_REPLAY_MIC_WAV` /
/// `FLUIDVOICE_LIVE_REPLAY_APP_WAV` paths and distinct expected phrases in
/// `FLUIDVOICE_LIVE_REPLAY_MIC_EXPECTED_TEXT` / `FLUIDVOICE_LIVE_REPLAY_APP_EXPECTED_TEXT`.
/// Choose approved fixtures where each expected phrase belongs to only its source track.
final class MeetingLiveReplayTests: XCTestCase {
    private static let chunkFrames = 320 // 20ms @ 16kHz
    private static let sampleRate: Double = 16_000
    private static let trailingSilenceSeconds: Double = 3

    func testReplayBufferUsesPerFrameTiming() throws {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(Self.makeBuffer(format: format, samples: [Float](repeating: 0, count: Self.chunkFrames)[...]))
        let description = try XCTUnwrap(Self.makeFormatDescription(format: format))
        let sample = try XCTUnwrap(Self.makeSampleBuffer(pcm: pcm, formatDescription: description, pts: CMTime(seconds: 7, preferredTimescale: 16_000)))
        XCTAssertEqual(CMSampleBufferGetDuration(sample).seconds, 0.02, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, 7, accuracy: 0.000_001)
        XCTAssertEqual(CMSampleBufferGetNumSamples(sample), Self.chunkFrames)
    }

    func testReplayRealMeetingThroughLiveCoordinator() async throws {
        let env = ProcessInfo.processInfo.environment
        guard env["FLUIDVOICE_LIVE_REPLAY"] == "1" else {
            throw XCTSkip("Set FLUIDVOICE_LIVE_REPLAY=1 to run the live-transcription replay harness.")
        }

        let fixture = try ReplayFixture(environment: env)

        let micSamples = try Self.load16kMonoFloatSamples(path: fixture.microphonePath)
        let appSamples = try Self.load16kMonoFloatSamples(path: fixture.applicationPath)
        XCTAssertFalse(micSamples.isEmpty)
        XCTAssertFalse(appSamples.isEmpty)
        print(
            "[replay] mic samples=\(micSamples.count) (\(Double(micSamples.count) / Self.sampleRate)s), app samples=\(appSamples.count) (\(Double(appSamples.count) / Self.sampleRate)s)"
        )

        guard let pcmFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let formatDescription = Self.makeFormatDescription(format: pcmFormat)
        else {
            XCTFail("Could not build the 16kHz mono Float32 format used to feed the coordinator.")
            return
        }

        // Interleave both tracks' 20ms chunks in true time order. Both files share a clock and
        // (empirically) an identical sample count, so ties are broken mic-first - matching the
        // typical ordering of the real capture tee.
        var events: [(kind: MeetingAudioTrackKind, samples: ArraySlice<Float>, ptsSamples: Int)] = []
        events.reserveCapacity(((micSamples.count + appSamples.count) / Self.chunkFrames) + 4)
        Self.appendChunks(&events, kind: .microphone, samples: micSamples)
        Self.appendChunks(&events, kind: .applicationAudio, samples: appSamples)
        // Trailing silence on both tracks so any in-flight utterance at end-of-file can still hit
        // its 1280ms EOU silence debounce and finalize, instead of being lost to `stop()`'s reset.
        let silenceFrames = Int(Self.trailingSilenceSeconds * Self.sampleRate)
        let silence = [Float](repeating: 0, count: silenceFrames)
        let micTailStart = micSamples.count
        let appTailStart = appSamples.count
        Self.appendChunks(&events, kind: .microphone, samples: silence, ptsBaseSamples: micTailStart)
        Self.appendChunks(&events, kind: .applicationAudio, samples: silence, ptsBaseSamples: appTailStart)
        events.sort { lhs, rhs in
            if lhs.ptsSamples != rhs.ptsSamples { return lhs.ptsSamples < rhs.ptsSamples }
            return lhs.kind == .microphone && rhs.kind != .microphone
        }
        print("[replay] total chunks to feed: \(events.count)")

        final class SnapshotBox: @unchecked Sendable {
            let lock = NSLock()
            var latest: MeetingLiveTranscriptSnapshot = .empty
            var log: [(elapsed: TimeInterval, snapshot: MeetingLiveTranscriptSnapshot)] = []
            let start = Date()
            func record(_ snapshot: MeetingLiveTranscriptSnapshot) {
                self.lock.lock()
                defer { self.lock.unlock() }
                self.latest = snapshot
                self.log.append((Date().timeIntervalSince(self.start), snapshot))
            }
        }
        let box = SnapshotBox()
        let coordinator = MeetingLiveTranscriptionCoordinator { snapshot in
            box.record(snapshot)
        }

        let harnessStart = Date()
        coordinator.start(mode: .onlineCall)

        do {
            // Wait for the pipeline to report ready before hammering it with non-real-time audio: a
            // capacity-24 (~480ms) bounded queue means feeding faster than real time before the model
            // is loaded would just drop nearly everything, which would test harness pacing, not the
            // pipeline's actual transcription/echo-suppression behavior.
            let readyTimeout: TimeInterval = 300
            let readyDeadline = Date().addingTimeInterval(readyTimeout)
            while Date() < readyDeadline {
                let available = box.lock.withLock { box.latest.availability == .available }
                if available { break }
                try await Task.sleep(nanoseconds: 200_000_000)
            }
            let firstAvailableElapsed = Date().timeIntervalSince(harnessStart)
            let becameAvailable = box.lock.withLock { box.latest.availability == .available }
            print("[replay] first-track-ready after \(String(format: "%.1f", firstAvailableElapsed))s (available=\(becameAvailable))")
            guard becameAvailable else {
                XCTFail("Live captions never became available within \(readyTimeout)s - model load likely failed.")
                await coordinator.stop()
                return
            }
            // Both engines load their own model instance in parallel; give the slower one a grace
            // window since the snapshot only reports "available" on the FIRST track's readiness.
            try await Task.sleep(nanoseconds: 5_000_000_000)

            // The bounded queue holds only ~480ms per track (capacity 24 * 20ms). Blasting all ~19.5k
            // chunks in a tight loop (sub-second) overwhelms it before the drain loop can ever get
            // scheduled, which would test harness timing, not the pipeline. Cap the feed rate at
            // `accelerationFactor`x real time instead - still far from a real 192s sleep, but paced
            // enough for the actor's drain loop to keep up with genuine ASR inference.
            let accelerationFactor = 1.5
            let feedStart = Date()
            var bufferFailures = 0
            var sampleBufferFailures = 0
            var offeredCount = 0
            var totalWaitSeconds: Double = 0
            for (index, event) in events.enumerated() {
                try Task.checkCancellation()
                guard let buffer = Self.makeBuffer(format: pcmFormat, samples: event.samples) else {
                    bufferFailures += 1
                    continue
                }
                let pts = CMTime(value: CMTimeValue(event.ptsSamples), timescale: CMTimeScale(Self.sampleRate))
                guard let sampleBuffer = Self.makeSampleBuffer(pcm: buffer, formatDescription: formatDescription, pts: pts) else {
                    sampleBufferFailures += 1
                    continue
                }
                coordinator.offer(kind: event.kind, sampleBuffer: sampleBuffer)
                offeredCount += 1
                let ptsSeconds = Double(event.ptsSamples) / Self.sampleRate
                let targetElapsed = ptsSeconds / accelerationFactor
                let actualElapsed = Date().timeIntervalSince(feedStart)
                let waitSeconds = targetElapsed - actualElapsed
                if waitSeconds > 0.001 {
                    totalWaitSeconds += waitSeconds
                    try await Task.sleep(nanoseconds: UInt64(waitSeconds * 1_000_000_000))
                } else if index % 8 == 0 {
                    await Task.yield()
                }
            }
            let feedElapsed = Date().timeIntervalSince(feedStart)
            print(
                // Keep the exact fixture text or diagnostic output together for comparison.
                // swiftlint:disable:next line_length
                "[replay] fed \(events.count) chunks in \(String(format: "%.2f", feedElapsed))s (offered=\(offeredCount), bufferFailures=\(bufferFailures), sampleBufferFailures=\(sampleBufferFailures), totalWaitSeconds=\(String(format: "%.2f", totalWaitSeconds)))"
            )

            // Let the drain loops work through whatever is still queued, until the transcript stops
            // changing.
            var lastSnapshot = box.lock.withLock { box.latest }
            var stableCount = 0
            let settleDeadline = Date().addingTimeInterval(60)
            while Date() < settleDeadline, stableCount < 10 {
                try await Task.sleep(nanoseconds: 300_000_000)
                let current = box.lock.withLock { box.latest }
                if current == lastSnapshot {
                    stableCount += 1
                } else {
                    stableCount = 0
                    lastSnapshot = current
                }
            }

            await coordinator.stop()
            // stop() may itself publish nothing further, but give any last async callback a moment.
            try await Task.sleep(nanoseconds: 300_000_000)
            let final = box.lock.withLock { box.latest }

            // ---- Report ----
            print("=== LIVE REPLAY TRANSCRIPT (\(final.utterances.count) utterances) ===")
            for utterance in final.utterances {
                let speaker = utterance.speaker == .you ? "You " : "Them"
                print(String(format: "[%7.2f - %7.2f] %@: %@", utterance.start, utterance.end, speaker, utterance.text))
            }
            if !final.partials.isEmpty {
                print("--- Leftover partials at end ---")
                for (speaker, text) in final.partials {
                    print("  \(speaker): \(text)")
                }
            }
            print("Final availability: \(final.availability)")

            let degradedTransitions = box.lock.withLock {
                box.log.filter { if case .degraded = $0.snapshot.availability { return true } else { return false } }
            }
            print("Degraded-availability updates observed: \(degradedTransitions.count)")
            for transition in degradedTransitions.prefix(20) {
                print("  t+\(String(format: "%.1f", transition.elapsed))s: \(transition.snapshot.availability)")
            }

            let youUtterances = final.utterances.filter { $0.speaker == .you }
            let themUtterances = final.utterances.filter { $0.speaker == .them }
            print("You utterances: \(youUtterances.count), Them utterances: \(themUtterances.count)")

            XCTAssertEqual(bufferFailures, 0)
            XCTAssertEqual(sampleBufferFailures, 0)
            XCTAssertEqual(offeredCount, events.count)
            let issues = Self.validationIssues(final, fixture: fixture, durations: (
                microphone: Double(micSamples.count) / Self.sampleRate + Self.trailingSilenceSeconds,
                application: Double(appSamples.count) / Self.sampleRate + Self.trailingSilenceSeconds
            ))
            XCTAssertTrue(issues.isEmpty, issues.joined(separator: "\n"))
        } catch {
            await coordinator.stop()
            throw error
        }
    }

    // MARK: - Helpers

    private struct ReplayFixture {
        let microphonePath: String
        let applicationPath: String
        let microphoneText: String
        let applicationText: String

        init(environment: [String: String]) throws {
            func required(_ key: String) throws -> String {
                guard let value = environment[key], !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    throw NSError(domain: "MeetingLiveReplayTests", code: 6,
                                  userInfo: [NSLocalizedDescriptionKey: "Explicit replay input required: \(key)"])
                }
                return value
            }
            self.microphonePath = try required("FLUIDVOICE_LIVE_REPLAY_MIC_WAV")
            self.applicationPath = try required("FLUIDVOICE_LIVE_REPLAY_APP_WAV")
            self.microphoneText = Self.normalize(try required("FLUIDVOICE_LIVE_REPLAY_MIC_EXPECTED_TEXT"))
            self.applicationText = Self.normalize(try required("FLUIDVOICE_LIVE_REPLAY_APP_EXPECTED_TEXT"))
            guard NSString(string: self.microphonePath).isAbsolutePath,
                  NSString(string: self.applicationPath).isAbsolutePath,
                  !self.microphoneText.isEmpty, !self.applicationText.isEmpty,
                  !self.microphoneText.contains(self.applicationText),
                  !self.applicationText.contains(self.microphoneText) else {
                throw NSError(domain: "MeetingLiveReplayTests", code: 7,
                              userInfo: [NSLocalizedDescriptionKey: "Replay requires absolute audio paths and distinct source-specific phrases."])
            }
        }

        static func normalize(_ text: String) -> String {
            text.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
                .filter { !$0.isEmpty }.joined(separator: " ")
        }
    }

    private static func validationIssues(
        _ snapshot: MeetingLiveTranscriptSnapshot,
        fixture: ReplayFixture,
        durations: (microphone: TimeInterval, application: TimeInterval)
    ) -> [String] {
        var issues: [String] = []
        let microphoneText = ReplayFixture.normalize(snapshot.utterances.filter { $0.speaker == .you }.map(\.text).joined(separator: " "))
        let applicationText = ReplayFixture.normalize(snapshot.utterances.filter { $0.speaker == .them }.map(\.text).joined(separator: " "))
        if !microphoneText.contains(fixture.microphoneText) { issues.append("Microphone captions missed the expected phrase.") }
        if !applicationText.contains(fixture.applicationText) { issues.append("Application captions missed the expected phrase.") }
        if microphoneText.contains(fixture.applicationText) { issues.append("Application phrase leaked into microphone captions.") }
        if applicationText.contains(fixture.microphoneText) { issues.append("Microphone phrase leaked into application captions.") }
        if Set(snapshot.utterances.map(\.id)).count != snapshot.utterances.count { issues.append("Duplicate finalized turn IDs.") }
        var previousStart: TimeInterval = 0
        for utterance in snapshot.utterances {
            let duration = utterance.speaker == .you ? durations.microphone : durations.application
            if ReplayFixture.normalize(utterance.text).isEmpty { issues.append("Empty finalized caption.") }
            if !utterance.start.isFinite || !utterance.end.isFinite || utterance.start < 0
                || utterance.end < utterance.start || utterance.end > duration + 0.1
            { issues.append("Finalized caption has invalid source timing.") }
            if utterance.start < previousStart { issues.append("Finalized captions are not ordered by source time.") }
            previousStart = utterance.start
        }
        return issues
    }

    func testReplayRequiresExplicitFixturesAndDistinctExpectedPhrases() throws {
        let environment = Self.syntheticReplayEnvironment
        for key in environment.keys {
            var missing = environment
            missing.removeValue(forKey: key)
            XCTAssertThrowsError(try ReplayFixture(environment: missing))
        }
        var relative = environment
        relative["FLUIDVOICE_LIVE_REPLAY_MIC_WAV"] = "microphone.wav"
        XCTAssertThrowsError(try ReplayFixture(environment: relative))
        var identical = environment
        identical["FLUIDVOICE_LIVE_REPLAY_APP_EXPECTED_TEXT"] = "MICROPHONE, ONLY."
        XCTAssertThrowsError(try ReplayFixture(environment: identical))
        _ = try ReplayFixture(environment: environment)
    }

    func testReplayValidationRejectsEmptySwappedEchoedAndInvalidCaptions() throws {
        let fixture = try ReplayFixture(environment: Self.syntheticReplayEnvironment)
        let durations = (microphone: 5.0, application: 5.0)
        var valid = MeetingLiveTranscriptSnapshot.empty
        valid.utterances = [
            .init(id: UUID(), speaker: .you, text: "Microphone, only!", start: 0, end: 1),
            .init(id: UUID(), speaker: .them, text: "Application only.", start: 2, end: 3),
        ]
        XCTAssertTrue(Self.validationIssues(valid, fixture: fixture, durations: durations).isEmpty)
        XCTAssertFalse(Self.validationIssues(.empty, fixture: fixture, durations: durations).isEmpty)
        var swapped = valid
        swapped.utterances[0].speaker = .them
        swapped.utterances[1].speaker = .you
        XCTAssertFalse(Self.validationIssues(swapped, fixture: fixture, durations: durations).isEmpty)
        var echo = valid
        echo.utterances.append(.init(id: UUID(), speaker: .you, text: "Application only", start: 3, end: 4))
        XCTAssertFalse(Self.validationIssues(echo, fixture: fixture, durations: durations).isEmpty)
        for end in [TimeInterval.nan, -1, 20] {
            var invalid = valid
            invalid.utterances[0].end = end
            XCTAssertFalse(Self.validationIssues(invalid, fixture: fixture, durations: durations).isEmpty)
        }
    }

    private static var syntheticReplayEnvironment: [String: String] { [
        "FLUIDVOICE_LIVE_REPLAY_MIC_WAV": "/synthetic/microphone.wav",
        "FLUIDVOICE_LIVE_REPLAY_APP_WAV": "/synthetic/application.wav",
        "FLUIDVOICE_LIVE_REPLAY_MIC_EXPECTED_TEXT": "microphone only",
        "FLUIDVOICE_LIVE_REPLAY_APP_EXPECTED_TEXT": "application only",
    ] }

    private static func appendChunks(
        _ events: inout [(kind: MeetingAudioTrackKind, samples: ArraySlice<Float>, ptsSamples: Int)],
        kind: MeetingAudioTrackKind,
        samples: [Float],
        ptsBaseSamples: Int = 0
    ) {
        var offset = 0
        while offset < samples.count {
            let end = min(offset + self.chunkFrames, samples.count)
            events.append((kind: kind, samples: samples[offset..<end], ptsSamples: ptsBaseSamples + offset))
            offset = end
        }
    }

    private static func load16kMonoFloatSamples(path: String) throws -> [Float] {
        let url = URL(fileURLWithPath: path)
        guard FileManager.default.fileExists(atPath: path) else {
            throw NSError(domain: "MeetingLiveReplayTests", code: 1, userInfo: [NSLocalizedDescriptionKey: "Fixture not found at \(path)"])
        }
        let inputFile = try AVAudioFile(forReading: url)
        let inputFormat = inputFile.processingFormat
        guard let desiredFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: self.sampleRate, channels: 1, interleaved: false) else {
            throw NSError(domain: "MeetingLiveReplayTests", code: 2, userInfo: [NSLocalizedDescriptionKey: "Could not build target format"])
        }

        let inputBuffer: AVAudioPCMBuffer = try {
            let frameCount = AVAudioFrameCount(inputFile.length)
            guard let buffer = AVAudioPCMBuffer(pcmFormat: inputFormat, frameCapacity: max(frameCount, 1)) else {
                throw NSError(domain: "MeetingLiveReplayTests", code: 3, userInfo: [NSLocalizedDescriptionKey: "Could not allocate input buffer"])
            }
            try inputFile.read(into: buffer)
            return buffer
        }()

        if inputFormat.sampleRate == desiredFormat.sampleRate,
           inputFormat.channelCount == desiredFormat.channelCount,
           inputFormat.commonFormat == desiredFormat.commonFormat
        {
            return Self.extractSamples(inputBuffer)
        }

        guard let converter = AVAudioConverter(from: inputFormat, to: desiredFormat) else {
            throw NSError(domain: "MeetingLiveReplayTests", code: 4, userInfo: [NSLocalizedDescriptionKey: "Could not build converter"])
        }
        let ratio = desiredFormat.sampleRate / inputFormat.sampleRate
        let estimatedFrames = max(1, AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio) + 1)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: desiredFormat, frameCapacity: estimatedFrames) else {
            throw NSError(domain: "MeetingLiveReplayTests", code: 5, userInfo: [NSLocalizedDescriptionKey: "Could not allocate output buffer"])
        }
        var providedInput = false
        var conversionError: NSError?
        converter.convert(to: outputBuffer, error: &conversionError) { _, outStatus in
            if providedInput {
                outStatus.pointee = .endOfStream
                return nil
            }
            providedInput = true
            outStatus.pointee = .haveData
            return inputBuffer
        }
        if let conversionError { throw conversionError }
        return Self.extractSamples(outputBuffer)
    }

    private static func extractSamples(_ buffer: AVAudioPCMBuffer) -> [Float] {
        guard let channelData = buffer.floatChannelData else { return [] }
        return Array(UnsafeBufferPointer(start: channelData[0], count: Int(buffer.frameLength)))
    }

    private static func makeBuffer(format: AVAudioFormat, samples: ArraySlice<Float>) -> AVAudioPCMBuffer? {
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples.count)),
              let channelData = buffer.floatChannelData
        else { return nil }
        buffer.frameLength = AVAudioFrameCount(samples.count)
        for (index, sample) in samples.enumerated() {
            channelData[0][index] = sample
        }
        return buffer
    }

    private static func makeFormatDescription(format: AVAudioFormat) -> CMAudioFormatDescription? {
        var formatDescription: CMAudioFormatDescription?
        var asbd = format.streamDescription.pointee
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &asbd,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &formatDescription
        )
        guard status == noErr else { return nil }
        return formatDescription
    }

    /// Builds a `dataReady` sample buffer directly from a copy of the PCM buffer's bytes, rather
    /// than via `CMSampleBufferSetDataBufferFromAudioBufferList` (which reliably returned
    /// `kCMSampleBufferError_RequiredParameterMissing` for this mono/non-interleaved Float32 case
    /// in practice, despite matching Apple's documented parameters).
    private static func makeSampleBuffer(pcm: AVAudioPCMBuffer, formatDescription: CMAudioFormatDescription, pts: CMTime) -> CMSampleBuffer? {
        let frameCount = Int(pcm.frameLength)
        guard frameCount > 0, let channelData = pcm.floatChannelData else { return nil }
        let bytesPerFrame = Int(pcm.format.streamDescription.pointee.mBytesPerFrame)
        let dataLength = frameCount * bytesPerFrame

        var blockBuffer: CMBlockBuffer?
        let blockStatus = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: dataLength,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: dataLength,
            flags: 0,
            blockBufferOut: &blockBuffer
        )
        guard blockStatus == kCMBlockBufferNoErr, let blockBuffer else { return nil }
        let copyStatus = channelData[0].withMemoryRebound(to: UInt8.self, capacity: dataLength) { bytes in
            CMBlockBufferReplaceDataBytes(with: bytes, blockBuffer: blockBuffer, offsetIntoDestination: 0, dataLength: dataLength)
        }
        guard copyStatus == kCMBlockBufferNoErr else { return nil }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: CMTimeScale(self.sampleRate)),
            presentationTimeStamp: pts,
            decodeTimeStamp: .invalid
        )
        var sampleSize = bytesPerFrame
        var sampleBuffer: CMSampleBuffer?
        let createStatus = CMSampleBufferCreate(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            dataReady: true,
            makeDataReadyCallback: nil,
            refcon: nil,
            formatDescription: formatDescription,
            sampleCount: frameCount,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &sampleSize,
            sampleBufferOut: &sampleBuffer
        )
        guard createStatus == noErr, let sampleBuffer else { return nil }
        return sampleBuffer
    }
}
