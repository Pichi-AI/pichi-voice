import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Hardware-free: everything here runs on CI. The opt-in real-hardware probe
/// (`FLUIDVOICE_MIC_PHASE1`) lives in `MeetingMicrophonePhase1Probe` and is not exercised here.
final class MeetingMicrophoneCaptureTests: XCTestCase {
    private static let identityTimebase = mach_timebase_info_data_t(numer: 1, denom: 1)

    private func makeClock() -> MeetingMicrophonePTSClock {
        MeetingMicrophonePTSClock(timebase: Self.identityTimebase)
    }

    private func hostTime(seconds: Double) -> UInt64 {
        UInt64(seconds * 1_000_000_000)
    }

    // MARK: - PTS clock

    func testValidStampsMapHostTimeToCMTimeExactly() {
        var clock = self.makeClock()
        let outcome = clock.stamp(hostTime: self.hostTime(seconds: 2.5), frameCount: 4800)
        guard case let .emitted(pts, synthesized, corrected, resynced) = outcome else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertEqual(pts.seconds, 2.5, accuracy: 1.0 / 48_000)
        XCTAssertFalse(synthesized)
        XCTAssertFalse(corrected)
        XCTAssertFalse(resynced)
    }

    func testValidStampsAreContinuousAcrossBuffers() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4800)
        let second = clock.stamp(hostTime: self.hostTime(seconds: 0.1), frameCount: 4800)
        guard case let .emitted(pts, _, corrected, _) = second else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertEqual(pts.seconds, 0.1, accuracy: 1.0 / 48_000)
        XCTAssertFalse(corrected, "hostTime landed exactly on the anchor+framesEmitted domain")
    }

    /// Real-hardware Phase 1 gate; skips unless FLUIDVOICE_MIC_PHASE1=<minutes> is set.
    func testPhase1HardwareGate() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let result = try await MeetingMicrophonePhase1Probe.run(sessionDirectory: temp) else {
            throw XCTSkip("FLUIDVOICE_MIC_PHASE1 not set")
        }
        let stats = result.stats
        let validRate = stats.buffersEmitted > 0 ? Double(stats.validHostTimeCount) / Double(stats.buffersEmitted) : 0
        print("""
        [phase1] minutes=\(result.minutes) outcome=\(result.outcome)
        [phase1] settled=\(String(describing: result.settled))
        [phase1] delivered=\(result.deliveredSourceFormat) buffers=\(stats.buffersEmitted) validHostTime=\(String(format: "%.4f", validRate)) \
        synthesized=\(stats.synthesizedCount) anchorCorrections=\(stats.anchorCorrectionCount) sequenceBreaks=\(stats.sequenceContinuityViolations)
        [phase1] chunks=\(result.writerRotationCount) discontinuities=\(result.writerDiscontinuities) \
        backpressure=\(result.writerBackpressureEvents) health=\(result.finalHealthStatus) liveCopyNils=\(result.liveCopyNilCount)
        """)
        if let readback = result.voiceProcessingReadback {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // JSONEncoder fixture bytes are UTF-8; retain nonoptional decoding for assertions.
            // swiftlint:disable:next optional_data_string_conversion
            let json = try String(decoding: encoder.encode(readback), as: UTF8.self)
            print("[phase1] voice-processing-readback=\n\(json)")
        } else {
            XCTFail("running VPIO capture did not produce a read-back snapshot")
        }
        #if DEBUG
        if let acoustic = result.acousticTrialB {
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            // JSONEncoder fixture bytes are UTF-8; retain nonoptional decoding for assertions.
            // swiftlint:disable:next optional_data_string_conversion
            let json = try String(decoding: encoder.encode(acoustic), as: UTF8.self)
            print("[phase0-trial-b] numeric-sidecar=\n\(json)")
            XCTAssertEqual(acoustic.schemaVersion, MeetingVPIOAcousticTrialBReport.currentSchemaVersion)
            XCTAssertFalse(acoustic.runs.isEmpty)
            XCTAssertTrue(acoustic.stimulus.withinSafetyBounds)
        }
        #endif
        XCTAssertGreaterThanOrEqual(validRate, 0.99)
        XCTAssertEqual(result.writerDiscontinuities, 0)
        XCTAssertEqual(result.writerBackpressureEvents, 0)
        XCTAssertEqual(result.liveCopyNilCount, 0)
        XCTAssertEqual(stats.conversionFailures, 0)
        XCTAssertGreaterThan(result.peakAmplitude, 0, "a live microphone never captures digital silence")
        let expectedChunks = Int((result.minutes * 60 / 60).rounded(.up))
        XCTAssertLessThanOrEqual(abs(result.writerRotationCount - expectedChunks), 1, "rotation cadence ≈ chunkDuration")
    }

    /// Without any anchor there is no meaningful acquisition PTS: a zero anchor would park the mic
    /// track at epoch 0 against SCStream's mach-domain stamps.
    func testInvalidStampsBeforeFirstAnchorAreDropped() {
        var clock = self.makeClock()
        XCTAssertEqual(clock.stamp(hostTime: nil, frameCount: 480), .droppedPostCap)
        XCTAssertEqual(clock.stamp(hostTime: nil, frameCount: 480), .droppedPostCap)
        let first = clock.stamp(hostTime: self.hostTime(seconds: 7), frameCount: 480)
        guard case let .emitted(pts, synthesized, _, _) = first else {
            return XCTFail("expected the first valid stamp to anchor and emit")
        }
        XCTAssertEqual(pts.seconds, 7.0, accuracy: 1.0 / 48_000)
        XCTAssertFalse(synthesized)
    }

    func testInvalidStampsExtrapolateFromLastValid() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4800) // anchor at t=0, 100ms
        let outcome = clock.stamp(hostTime: nil, frameCount: 4800) // extrapolated 100ms window
        guard case let .emitted(pts, synthesized, _, _) = outcome else {
            return XCTFail("expected an emitted (synthesized) stamp")
        }
        XCTAssertEqual(pts.seconds, 0.1, accuracy: 1.0 / 48_000)
        XCTAssertTrue(synthesized)
    }

    func testInvalidRunExtrapolatesForUpToHalfASecondThenDrops() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 480) // 10ms anchor

        var emittedSynthesizedCount = 0
        var sawDrop = false
        for _ in 0..<60 { // 60 * 10ms = 600ms of invalid stamps
            let outcome = clock.stamp(hostTime: nil, frameCount: 480)
            switch outcome {
            case let .emitted(_, synthesized, _, _):
                XCTAssertTrue(synthesized)
                XCTAssertFalse(sawDrop, "no emission should follow a drop without a valid resync")
                emittedSynthesizedCount += 1
            case .droppedPostCap:
                sawDrop = true
            }
        }
        XCTAssertTrue(sawDrop, "600ms of invalid stamps must exceed the 500ms cap")
        // 50 * 10ms = 500ms is within the cap and must still be emitted.
        XCTAssertEqual(emittedSynthesizedCount, 50)
    }

    func testValidStampAfterADropResyncsAndCorrectsTheAnchor() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 480)
        for _ in 0..<60 {
            _ = clock.stamp(hostTime: nil, frameCount: 480)
        }

        let resync = clock.stamp(hostTime: self.hostTime(seconds: 1.2), frameCount: 480)
        guard case let .emitted(pts, synthesized, corrected, resynced) = resync else {
            return XCTFail("expected an emitted stamp resuming from the drop")
        }
        XCTAssertEqual(pts.seconds, 1.2, accuracy: 1.0 / 48_000)
        XCTAssertFalse(synthesized)
        XCTAssertTrue(corrected)
        XCTAssertTrue(resynced)

        // Post-resync, valid stamps track the corrected anchor without further correction.
        let next = clock.stamp(hostTime: self.hostTime(seconds: 1.21), frameCount: 480)
        guard case let .emitted(_, _, nextCorrected, _) = next else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertFalse(nextCorrected)
    }

    func testSmallDivergenceDoesNotCorrectTheAnchor() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4800)
        // 1/96000s divergence is half a frame at 48kHz — below the one-frame correction threshold.
        let outcome = clock.stamp(hostTime: self.hostTime(seconds: 0.1 + 1.0 / 96_000), frameCount: 4800)
        guard case let .emitted(_, _, corrected, _) = outcome else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertFalse(corrected)
    }

    func testLargeDivergenceCorrectsTheAnchorWithoutASynthesizedFlag() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4800)
        let outcome = clock.stamp(hostTime: self.hostTime(seconds: 0.15), frameCount: 4800) // 50ms off
        guard case let .emitted(pts, synthesized, corrected, resynced) = outcome else {
            return XCTFail("expected an emitted stamp")
        }
        XCTAssertEqual(pts.seconds, 0.1, accuracy: 1.0 / 48_000, "this buffer's pts stays on the old, continuous domain")
        XCTAssertFalse(synthesized)
        XCTAssertTrue(corrected)
        XCTAssertFalse(resynced, "a mid-stream correction is not a post-drop resync")
    }

    // MARK: - CMSampleBuffer synthesis round-trip

    private func makeMonoBuffer(frameCount: Int, fill: (Int) -> Float) -> AVAudioPCMBuffer {
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let channel = buffer.floatChannelData![0]
        for index in 0..<frameCount {
            channel[index] = fill(index)
        }
        return buffer
    }

    func testSynthesizedSampleBufferRoundTripsThroughLiveSampleCopy() throws {
        let frameCount = 480
        let source = self.makeMonoBuffer(frameCount: frameCount) { Float($0) / 1000 }
        let pts = CMTime(value: 123, timescale: 48_000)

        let sampleBuffer = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(from: source, presentationTime: pts))
        XCTAssertEqual(CMSampleBufferGetNumSamples(sampleBuffer), frameCount)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sampleBuffer), pts)
        XCTAssertEqual(CMTimeGetSeconds(CMSampleBufferGetDuration(sampleBuffer)), Double(frameCount) / 48_000, accuracy: 1e-9)

        let copy = try XCTUnwrap(MeetingLiveSampleCopy.copy(sampleBuffer))
        XCTAssertEqual(copy.buffer.frameLength, AVAudioFrameCount(frameCount))
        XCTAssertEqual(copy.buffer.format.commonFormat, .pcmFormatFloat32)
        XCTAssertEqual(copy.buffer.format.sampleRate, 48_000)
        XCTAssertEqual(copy.buffer.format.channelCount, 1)
        XCTAssertEqual(copy.pts, pts)
        for index in 0..<frameCount {
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            XCTAssertEqual(copy.buffer.floatChannelData![0][index], Float(index) / 1000)
        }
    }

    func testSynthesizedSampleBufferIsImmutableAgainstSourceMutation() throws {
        let frameCount = 240
        let source = self.makeMonoBuffer(frameCount: frameCount) { _ in 1.0 }
        let sampleBuffer = try XCTUnwrap(
            meetingMicrophoneSynthesizeSampleBuffer(from: source, presentationTime: CMTime(value: 0, timescale: 48_000))
        )

        let before = try XCTUnwrap(MeetingLiveSampleCopy.copy(sampleBuffer))
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let beforeValues = (0..<frameCount).map { before.buffer.floatChannelData![0][$0] }

        // Mutate the source AFTER synthesis — the synthesized buffer must not see this.
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let channel = source.floatChannelData![0]
        for index in 0..<frameCount {
            channel[index] = -99
        }

        let after = try XCTUnwrap(MeetingLiveSampleCopy.copy(sampleBuffer))
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let afterValues = (0..<frameCount).map { after.buffer.floatChannelData![0][$0] }

        XCTAssertEqual(beforeValues, afterValues)
        XCTAssertEqual(afterValues, Array(repeating: Float(1.0), count: frameCount))
    }

    // MARK: - Binding decision table

    func testBindingDecisionSucceedsOnVerifiedReadBack() {
        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: noErr,
            readBackDeviceID: 42,
            requestedDeviceID: 42,
            defaultInputUID: nil,
            requestedUID: "uid-a"
        )
        XCTAssertEqual(outcome, .boundVerified(42))
    }

    func testBindingDecisionMismatchFallsBackToUnavailableWhenDefaultDoesNotMatch() {
        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: noErr,
            readBackDeviceID: 7,
            requestedDeviceID: 42,
            defaultInputUID: "uid-other",
            requestedUID: "uid-a"
        )
        guard case .unavailable = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
    }

    func testBindingDecisionReadBackErrorFallsBackToEscapeHatchWhenDefaultMatches() {
        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: -10_851,
            readBackDeviceID: nil,
            requestedDeviceID: 42,
            defaultInputUID: "uid-a",
            requestedUID: "uid-a"
        )
        XCTAssertEqual(outcome, .defaultMatchesRequested)
    }

    func testBindingDecisionAggregateDeviceStatusIsUnavailableWithoutEscapeHatch() {
        let outcome = MeetingMicrophoneBindDecision.outcome(
            bindStatus: -10_851,
            readBackDeviceID: nil,
            requestedDeviceID: 42,
            defaultInputUID: "uid-other",
            requestedUID: "uid-a"
        )
        guard case let .unavailable(reason) = outcome else { return XCTFail("expected unavailable, got \(outcome)") }
        XCTAssertTrue(reason.contains("10851"))
    }

    func testBindingDecisionReadBackMismatchIsDistinctFromReadBackError() {
        let mismatch = MeetingMicrophoneBindDecision.outcome(
            bindStatus: noErr,
            readBackDeviceID: 99,
            requestedDeviceID: 42,
            defaultInputUID: nil,
            requestedUID: "uid-a"
        )
        let readBackError = MeetingMicrophoneBindDecision.outcome(
            bindStatus: noErr,
            readBackDeviceID: nil,
            requestedDeviceID: 42,
            defaultInputUID: nil,
            requestedUID: "uid-a"
        )
        guard case let .unavailable(mismatchReason) = mismatch,
              case let .unavailable(errorReason) = readBackError
        else { return XCTFail("expected both to be unavailable") }
        XCTAssertNotEqual(mismatchReason, errorReason)
    }

    // MARK: - Writer-coupled synthetic stamp-sequence test

    private func makeWriter() throws -> (writer: MeetingAudioChunkWriter, sessionDirectory: URL) {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "test-mic",
            sourceDisplayName: "Test Microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: []
        )
        let writer = try MeetingAudioChunkWriter(
            track: track, sessionDirectory: sessionDirectory, chunkDuration: 60
        ) { _ in }
        return (writer, sessionDirectory)
    }

    private func pushBuffer(
        _ writer: MeetingAudioChunkWriter,
        ptsSeconds: Double,
        frameCount: Int = 480,
        producerEpoch: UInt64 = 0,
        timescale: CMTimeScale = 48_000
    ) {
        let buffer = self.makeMonoBuffer(frameCount: frameCount) { _ in 0.1 }
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: timescale)
        guard let sampleBuffer = meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts) else {
            return XCTFail("failed to synthesize a sample buffer")
        }
        writer.enqueue(sampleBuffer, producerEpoch: producerEpoch)
    }

    func testSteadySequenceProducesOneChunkWithNoDiscontinuities() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        for tick in 0..<20 {
            self.pushBuffer(writer, ptsSeconds: Double(tick) * 0.01)
        }
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 1)
        XCTAssertEqual(track.chunks.first?.discontinuities ?? [], [])
    }

    func testNanosecondClockRoundingDoesNotFragmentApplicationAudio() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        for tick in 0..<100 {
            self.pushBuffer(
                writer,
                ptsSeconds: 188_092.2_630_985 + Double(tick) * 0.01 - Double(tick) * 0.000_000_042,
                timescale: 1_000_000_000
            )
            if tick.isMultiple(of: 10) { _ = await writer.snapshot() }
        }
        let track = await writer.stop()
        XCTAssertEqual(track.chunks.count, 1)
        XCTAssertEqual(track.chunks.first?.discontinuities ?? [], [])
        XCTAssertEqual(track.chunks.first?.captureAnalysisAsset?.frameCount, 48_000)
    }

    func testWriterPublishesPCMCAFMetadataAndReadyLedgerTerminal() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0, frameCount: 480)
        let track = await writer.stop()

        let chunk = try XCTUnwrap(track.chunks.first)
        XCTAssertEqual(track.format, MeetingAudioFormat(codec: "lpcm-f32", sampleRate: 48_000, channelCount: 1, bitRate: nil))
        XCTAssertTrue(chunk.relativeFilePath.hasSuffix(".caf"))
        XCTAssertFalse(chunk.relativeFilePath.hasSuffix(".m4a"))
        XCTAssertEqual(chunk.finalizationState, .finalized)
        XCTAssertEqual(chunk.audioSchemaVersion, 2)
        let asset = try XCTUnwrap(chunk.captureAnalysisAsset)
        XCTAssertEqual(asset.encoding, .linearPCMFloat32CAFV1)
        XCTAssertEqual(asset.presence, .ready)
        XCTAssertEqual(asset.frameCount, 480)
        XCTAssertNil(chunk.playbackArchiveAsset)
        XCTAssertTrue(FileManager.default.fileExists(atPath: sessionDirectory.appendingPathComponent(chunk.relativeFilePath).path))
        let audioFiles = try FileManager.default.subpathsOfDirectory(atPath: sessionDirectory.path)
            .filter { $0.hasSuffix(".m4a") }
        XCTAssertTrue(audioFiles.isEmpty)

        let ledger = MeetingAudioChunkLedgerStore(sessionDirectory: sessionDirectory)
        XCTAssertEqual(try ledger.readTerminal(for: chunk.id)?.status, .ready)
        XCTAssertEqual(try ledger.readCheckpoint(for: chunk.id)?.writtenFrames, 480)
    }

    func testOneTickOverlapTriggersClockDiscontinuityAndRotation() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        for tick in 0..<10 {
            self.pushBuffer(writer, ptsSeconds: Double(tick) * 0.01)
        }
        // One tick (1/48000s) before the running end — a backwards stamp.
        self.pushBuffer(writer, ptsSeconds: 0.1 - 1.0 / 48_000)
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertEqual(track.chunks.first?.discontinuities.map(\.kind), [.clockDiscontinuity])
    }

    func testLargeBackwardJumpIsRetimedAndNeverProducesInvalidChunkBounds() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 100, producerEpoch: 1)
        self.pushBuffer(writer, ptsSeconds: 1, producerEpoch: 1)
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertTrue(track.chunks.allSatisfy { $0.presentationEnd.seconds >= $0.presentationStart.seconds })
        XCTAssertEqual(track.chunks[1].presentationStart.seconds, 100.01, accuracy: 1.0 / 48_000)
        XCTAssertEqual(track.chunks[0].discontinuities.map(\.kind), [.clockDiscontinuity])
    }

    func testNewProducerEpochCreatesMonotonicBoundaryAcrossClockReset() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 42, producerEpoch: 7)
        self.pushBuffer(writer, ptsSeconds: 0, producerEpoch: 8)
        self.pushBuffer(writer, ptsSeconds: 0.01, producerEpoch: 8)
        self.pushBuffer(writer, ptsSeconds: 0.02, producerEpoch: 8)
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertTrue(track.chunks.allSatisfy { $0.presentationEnd.seconds >= $0.presentationStart.seconds })
        XCTAssertEqual(track.chunks[1].presentationStart.seconds, 42.01, accuracy: 1.0 / 48_000)
        XCTAssertEqual(track.chunks[1].presentationEnd.seconds, 42.04, accuracy: 1.0 / 48_000)
        XCTAssertEqual(track.chunks[0].discontinuities.first?.detail, "Capture producer epoch changed.")
    }

    func testRetiredProducerEpochIsDroppedInsteadOfRetimedAsDuplicateAudio() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 10, producerEpoch: 1)
        self.pushBuffer(writer, ptsSeconds: 0, producerEpoch: 2)
        self.pushBuffer(writer, ptsSeconds: 20, producerEpoch: 1)
        let track = await writer.stop()

        XCTAssertEqual(track.health.droppedSampleCount, 1)
        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertLessThan(track.chunks.last?.presentationEnd.seconds ?? .infinity, 11)
        XCTAssertTrue(track.chunks.allSatisfy { $0.presentationEnd.seconds >= $0.presentationStart.seconds })
    }

    func testFortyNineMillisecondGapDoesNotRotate() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0, frameCount: 480) // ends at 0.01s
        self.pushBuffer(writer, ptsSeconds: 0.01 + 0.49) // 0.49s gap, at/under the 0.5s threshold
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 1)
        XCTAssertEqual(track.chunks.first?.discontinuities ?? [], [])
    }

    func testFiftyOneMillisecondGapTriggersSourceLostAndRotation() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0, frameCount: 480) // ends at 0.01s
        self.pushBuffer(writer, ptsSeconds: 0.01 + 0.51) // 0.51s gap, over the 0.5s threshold
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertEqual(track.chunks.first?.discontinuities.map(\.kind), [.sourceLost])
    }

    /// Drives the PTS clock through a 500ms synthesized run followed by a 600ms dropped run, feeding
    /// only what the clock says to emit into a real writer — the only test that exercises the risky
    /// cap/drop/resync path end to end.
    func testSixHundredMillisecondInvalidRunProducesSourceLostAfterResync() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        var clock = self.makeClock()
        func emit(_ outcome: MeetingMicrophonePTSClock.Outcome, frameCount: Int) {
            guard case let .emitted(pts, _, _, _) = outcome else { return }
            let buffer = self.makeMonoBuffer(frameCount: frameCount) { _ in 0.1 }
            guard let sampleBuffer = meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts) else {
                return XCTFail("failed to synthesize a sample buffer")
            }
            writer.enqueue(sampleBuffer)
        }

        emit(clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 480), frameCount: 480)
        for _ in 0..<50 { // up to and including the 500ms cap boundary, all still emitted and contiguous
            emit(clock.stamp(hostTime: nil, frameCount: 480), frameCount: 480)
        }
        var droppedCount = 0
        for _ in 0..<60 { // 600ms dropped — nothing pushed to the writer for these
            if case .droppedPostCap = clock.stamp(hostTime: nil, frameCount: 480) { droppedCount += 1 }
        }
        XCTAssertEqual(droppedCount, 60, "the entire 600ms run must be past the cap and dropped")

        let resync = clock.stamp(hostTime: self.hostTime(seconds: 1.1), frameCount: 480)
        emit(resync, frameCount: 480)

        let track = await writer.stop()
        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertEqual(track.chunks.first?.discontinuities.map(\.kind), [.sourceLost])
    }
}

// MARK: - Phase 2: correction latch, step detector, resync clamp

extension MeetingMicrophoneCaptureTests {
    /// The Phase 1 field data (corrections on ~97% of buffers) was a latch: the correction
    /// re-baselined one full window off, so every subsequent stamp re-corrected forever.
    func testCorrectionDoesNotLatchAcrossSubsequentStamps() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4800)
        // Force one genuine correction with a 5ms excursion…
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0.105), frameCount: 4800)
        // …then five contiguous jitter-free stamps on the shifted timeline: zero further corrections.
        for i in 2...6 {
            let outcome = clock.stamp(hostTime: self.hostTime(seconds: 0.005 + Double(i) * 0.1), frameCount: 4800)
            guard case let .emitted(_, _, corrected, _) = outcome else { return XCTFail("expected emission") }
            XCTAssertFalse(corrected, "stamp \(i) re-corrected: the latch is back")
        }
    }

    /// A correction is a no-op on output: the next buffer's PTS continues exactly from the
    /// previous end.
    func testCorrectionLeavesEmittedPTSContinuous() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4800)
        guard case let .emitted(before, _, corrected1, _) = clock.stamp(hostTime: self.hostTime(seconds: 0.108), frameCount: 4800) else {
            return XCTFail("expected emission")
        }
        XCTAssertTrue(corrected1)
        guard case let .emitted(after, _, _, _) = clock.stamp(hostTime: self.hostTime(seconds: 0.208), frameCount: 4800) else {
            return XCTFail("expected emission")
        }
        XCTAssertEqual(after.seconds - before.seconds, 0.1, accuracy: 1.0 / 48_000)
    }

    /// Drift must never fire the step detector: 6.4 ppm over a simulated two hours.
    func testSlowDriftNeverFiresTheStepDetector() {
        var clock = self.makeClock()
        let windows = 72_000 // 2h of 100ms windows
        for i in 0..<windows {
            let actual = Double(i) * 0.1 * (1 + 6.4e-6)
            _ = clock.stamp(hostTime: self.hostTime(seconds: actual), frameCount: 4800)
        }
        XCTAssertEqual(clock.divergenceStepEventCount, 0)
        XCTAssertGreaterThan(clock.cumulativeAbsorbedCorrectionSeconds, 0, "drift shows up as absorbed corrections")
    }

    func testSingleJumpFiresExactlyOneStepEvent() {
        var clock = self.makeClock()
        for i in 0..<10 {
            _ = clock.stamp(hostTime: self.hostTime(seconds: Double(i) * 0.1), frameCount: 4800)
        }
        _ = clock.stamp(hostTime: self.hostTime(seconds: 1.0 + 0.050), frameCount: 4800) // 50ms step
        for i in 11..<20 {
            _ = clock.stamp(hostTime: self.hostTime(seconds: 0.050 + Double(i) * 0.1), frameCount: 4800)
        }
        XCTAssertEqual(clock.divergenceStepEventCount, 1)
        XCTAssertEqual(clock.maxDivergenceStepSeconds, 0.050, accuracy: 0.001)
    }

    /// A backlogged invalid burst can synthesize more timeline than elapsed host time; the resync
    /// anchor clamps forward so PTS never steps behind emitted audio.
    func testResyncNeverStepsBehindEmittedAudio() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 0), frameCount: 4800)
        // 500ms of synthesized emission (cap-inclusive), delivered as a burst…
        for _ in 0..<5 {
            _ = clock.stamp(hostTime: nil, frameCount: 4800)
        }
        _ = clock.stamp(hostTime: nil, frameCount: 4800) // over cap → dropping
        // …then a valid stamp whose host time is EARLIER than the emitted end (0.6s emitted, 0.3s wall).
        guard case let .emitted(pts, _, _, resynced) = clock.stamp(hostTime: self.hostTime(seconds: 0.3), frameCount: 4800) else {
            return XCTFail("expected resync emission")
        }
        XCTAssertTrue(resynced)
        XCTAssertGreaterThanOrEqual(pts.seconds, 0.6 - 1.0 / 48_000, "resync anchored behind already-emitted audio")
        XCTAssertEqual(clock.resyncClampCount, 1)
    }

    // MARK: - Phase 3: valid-host-seconds bounds for the de-drift elapsed term

    func testValidHostSecondsBoundsTrackFirstAndLastValidStamp() throws {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 5), frameCount: 4800)
        _ = clock.stamp(hostTime: nil, frameCount: 4800) // synthesized: must not move the bounds
        _ = clock.stamp(hostTime: self.hostTime(seconds: 5.3), frameCount: 4800)
        XCTAssertEqual(try XCTUnwrap(clock.firstValidHostSeconds), 5.0, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(clock.lastValidHostSeconds), 5.3, accuracy: 1e-9)
    }

    func testValidHostSecondsAreNilBeforeAnyValidStamp() {
        let clock = self.makeClock()
        XCTAssertNil(clock.firstValidHostSeconds)
        XCTAssertNil(clock.lastValidHostSeconds)
    }

    func testTimelineResetReanchorsOnNextValidStamp() {
        var clock = self.makeClock()
        _ = clock.stamp(hostTime: self.hostTime(seconds: 5), frameCount: 4800)
        clock.requestTimelineReset()
        guard case let .emitted(pts, _, _, _) = clock.stamp(hostTime: self.hostTime(seconds: 9), frameCount: 4800) else {
            return XCTFail("expected emission after reset")
        }
        XCTAssertEqual(pts.seconds, 9.0, accuracy: 1.0 / 48_000)
    }

    func testPrivacyTimingChecksEveryTapInsideAccumulationWindow() {
        let start = Self.privacyHostTime(1_000)
        XCTAssertTrue(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: start,
            windowHostTime: nil, accumulatedFrameCount: 0))
        XCTAssertTrue(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: Self.privacyHostTime(1_000.010),
            windowHostTime: start, accumulatedFrameCount: 480))
        XCTAssertTrue(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: Self.privacyHostTime(1_000.011),
            windowHostTime: start, accumulatedFrameCount: 480), "Normal one-millisecond jitter stays usable")
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: Self.privacyHostTime(1_003.010),
            windowHostTime: start, accumulatedFrameCount: 480), "A gap inside one accumulated block must retire its earlier PCM")
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: Self.privacyHostTime(999.010),
            windowHostTime: start, accumulatedFrameCount: 480), "A backwards acquisition clock also retires the window")
        XCTAssertTrue(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: Self.privacyHostTime(1_003.010),
            windowHostTime: nil, accumulatedFrameCount: 0), "A valid discontinuous tap may begin a new window after reset")
    }

    func testPrivacyTimingRejectsInvalidHostTimeAtWindowStartAndInsideWindow() {
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: nil, windowHostTime: nil, accumulatedFrameCount: 0))
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: nil,
            windowHostTime: Self.privacyHostTime(1_000), accumulatedFrameCount: 480))
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsTap(hostTime: Self.privacyHostTime(1_000.01),
            windowHostTime: nil, accumulatedFrameCount: 480))
    }

    func testPrivacyTimingRejectsOldCanonicalPTSAndAllowsRealReset() {
        var clock = MeetingMicrophonePTSClock()
        _ = clock.stamp(hostTime: Self.privacyHostTime(1_000), frameCount: 4_800)
        let actualAcquisition = Self.privacyHostTime(1_003)
        let stale = clock.stamp(hostTime: actualAcquisition, frameCount: 4_800)
        guard case let .emitted(pts, synthesized, _, _) = stale else { return XCTFail("Expected the canonical clock's normal output") }
        XCTAssertEqual(pts.seconds, 1_000.1, accuracy: 1.0 / 48_000)
        XCTAssertFalse(synthesized, "A valid input timestamp alone does not prove canonical PTS equals acquisition")
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsEmission(stale, acquisitionHostTime: actualAcquisition))
        clock.requestTimelineReset()
        let fresh = clock.stamp(hostTime: actualAcquisition, frameCount: 4_800)
        XCTAssertTrue(MeetingMicrophonePrivacyTiming.acceptsEmission(fresh, acquisitionHostTime: actualAcquisition))
    }

    func testPrivacyTimingNeverApprovesSynthesizedOrUnprovenEmission() {
        let host = Self.privacyHostTime(1_000)
        let actual = CMClockMakeHostTimeFromSystemUnits(host)
        let normal = MeetingMicrophonePTSClock.Outcome.emitted(pts: actual + CMTime(seconds: 0.019, preferredTimescale: 48_000),
            synthesized: false, anchorCorrected: false, resynced: false)
        XCTAssertTrue(MeetingMicrophonePrivacyTiming.acceptsEmission(normal, acquisitionHostTime: host))
        let divergent = MeetingMicrophonePTSClock.Outcome.emitted(pts: actual + CMTime(seconds: 0.021, preferredTimescale: 48_000),
            synthesized: false, anchorCorrected: false, resynced: false)
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsEmission(divergent, acquisitionHostTime: host))
        let synthesized = MeetingMicrophonePTSClock.Outcome.emitted(pts: actual, synthesized: true, anchorCorrected: false, resynced: false)
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsEmission(synthesized, acquisitionHostTime: host))
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsEmission(normal, acquisitionHostTime: nil))
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsEmission(.droppedPostCap, acquisitionHostTime: host))
    }

    func testPrivacyAcquisitionProofExcludesFreshPrivateMarkerWithOldCanonicalPTS() throws {
        let hostClock = PrivacyHostClock()
        let gate = MeetingMicrophonePrivacyGate(hostTime: { hostClock.now() }, automaticWatchdog: false)
        defer { gate.close() }
        gate.setAdmitted(true, observedAtHostTime: hostClock.now())
        var ptsClock = MeetingMicrophonePTSClock()
        _ = ptsClock.stamp(hostTime: Self.privacyHostTime(1_000), frameCount: 4_800)
        for step in 1...6 {
            hostClock.set(1_000 + Double(step) * 0.5)
            gate.setAdmitted(true, observedAtHostTime: hostClock.now())
        }
        let actualAcquisition = hostClock.now()
        let outcome = ptsClock.stamp(hostTime: actualAcquisition, frameCount: 480)
        guard case let .emitted(oldPTS, _, _, _) = outcome else { return XCTFail("Expected canonical output after the host gap") }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        pcm.frameLength = 480
        try XCTUnwrap(pcm.floatChannelData?[0]).initialize(repeating: -0.75, count: 480)
        let privateMarker = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(from: pcm, presentationTime: oldPTS))
        XCTAssertTrue(gate.permitsReleasedSample(privateMarker), "Reproduce the old-PTS hazard: sink freshness alone cannot know acquisition time")
        XCTAssertFalse(MeetingMicrophonePrivacyTiming.acceptsEmission(outcome, acquisitionHostTime: actualAcquisition),
            "The production tap's independent acquisition proof rejects the fresh private marker before quarantine")
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
        XCTAssertEqual(gate.statistics.deliveredBuffers, 0)
    }

    func testAcquisitionClockKeepsFortyFiveMinuteDriftingMicrophoneContinuous() async throws {
        let host = PrivacyHostClock()
        let gate = MeetingMicrophonePrivacyGate(configuration: .init(admissionPolicy: .latchedTransitions),
            hostTime: { host.now() }, automaticWatchdog: false)
        defer { gate.close() }
        gate.setAdmitted(true, observedAtHostTime: host.now())
        let sink = AcquisitionSink()
        var clock = MeetingMicrophonePTSClock()
        let carrier = try self.acquisitionSample(at: CMTime(seconds: 1_000, preferredTimescale: 48_000), frames: 4_800)
        let count = 27_000
        for index in 0..<count {
            let acquisition = 1_000 + Double(index) * 0.1 * (1 - 5e-6)
            let acquiredAt = Self.privacyHostTime(acquisition)
            guard case let .emitted(pts, _, _, _) = clock.stamp(hostTime: acquiredAt, frameCount: 4_800) else {
                return XCTFail("A valid hardware clock unexpectedly stopped")
            }
            // A realistic variable handoff delay becomes shorter than accumulated canonical lead.
            host.set(acquisition + 0.100 + Double(index % 13) * 0.0005 + 0.001)
            let sample = try self.acquisitionCopy(carrier, at: pts)
            XCTAssertTrue(gate.submit(sample, acquisitionHostTime: acquiredAt,
                                      deliveryQueue: sink.queue, delivery: sink.receive))
            gate.checkFreshnessAndDrain()
            if index % 10 == 0 { sink.join() }
        }
        host.set(3_702)
        gate.checkFreshnessAndDrain(); sink.join()
        await gate.stop()
        XCTAssertEqual(sink.count, count, "Host-clock drift must not turn continuous allowed capture into tiny islands")
        XCTAssertEqual(sink.frames, count * 4_800)
        XCTAssertTrue(sink.contiguous, "Privacy checks preserve the source's exact sample-count PTS")
        XCTAssertEqual(gate.statistics.rejectedBuffers, 0)
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
    }

    func testVerifiedAcquisitionRecoversAcrossNinetyMinuteDriftThresholdWithoutBackwardsPCM() async throws {
        let host = PrivacyHostClock(), sink = AcquisitionSink()
        let gate = MeetingMicrophonePrivacyGate(configuration: .init(admissionPolicy: .latchedTransitions),
            hostTime: { host.now() }, automaticWatchdog: false)
        defer { gate.close() }
        gate.setAdmitted(true, observedAtHostTime: host.now())
        var clock = MeetingMicrophonePTSClock()
        let carrier = try self.acquisitionSample(at: CMTime(seconds: 1_000, preferredTimescale: 48_000), frames: 4_800)
        let count = 54_000
        var discarded = 0, consecutiveDiscards = 0, maximumConsecutiveDiscards = 0
        var lastPublishedEnd: CMTime?
        for index in 0..<count {
            let acquisition = 1_000 + Double(index) * 0.1 * (1 - 5e-6)
            let acquiredAt = Self.privacyHostTime(acquisition)
            host.set(acquisition + 0.102 + Double(index % 13) * 0.0005)
            // This is the same verified stamping and rollback transition used by the native tap.
            guard let outcome = clock.stampVerifiedAcquisition(hostTime: acquiredAt, frameCount: 4_800) else {
                discarded += 1; consecutiveDiscards += 1
                maximumConsecutiveDiscards = max(maximumConsecutiveDiscards, consecutiveDiscards)
                continue
            }
            consecutiveDiscards = 0
            guard case let .emitted(pts, _, _, _) = outcome else { return XCTFail("Verified capture returned a non-emitting result") }
            if let lastPublishedEnd {
                XCTAssertGreaterThanOrEqual(CMTimeCompare(pts, lastPublishedEnd), 0,
                    "Re-anchoring must preserve every genuinely published end")
            }
            lastPublishedEnd = pts + CMTime(value: 4_800, timescale: 48_000)
            let sample = try self.acquisitionCopy(carrier, at: pts)
            XCTAssertTrue(gate.submit(sample, acquisitionHostTime: acquiredAt,
                                      deliveryQueue: sink.queue, delivery: sink.receive))
            gate.checkFreshnessAndDrain()
            if index % 10 == 0 { sink.join() }
        }
        host.set(6_402); gate.checkFreshnessAndDrain(); sink.join()
        await gate.stop()
        XCTAssertGreaterThan(discarded, 0, "The run must cross the native 20 ms acquisition-proof boundary")
        XCTAssertLessThanOrEqual(discarded, 2, "A drift reset must retire only a bounded unpublished tail")
        XCTAssertLessThanOrEqual(maximumConsecutiveDiscards, 1, "The next valid acquisition must recover promptly")
        XCTAssertEqual(sink.count, count - discarded, "No accepted PCM may disappear after clock recovery")
        XCTAssertEqual(sink.frames, (count - discarded) * 4_800)
        XCTAssertEqual(gate.statistics.rejectedBuffers, 0)
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
    }

    func testVerifiedAcquisitionRepeatedRejectionsCannotAdvanceThePublishedBoundary() {
        var clock = MeetingMicrophonePTSClock()
        XCTAssertNotNil(clock.stampVerifiedAcquisition(hostTime: Self.privacyHostTime(1_000), frameCount: 4_800))
        XCTAssertNil(clock.stampVerifiedAcquisition(hostTime: Self.privacyHostTime(1_000.070), frameCount: 4_800))
        XCTAssertNil(clock.stampVerifiedAcquisition(hostTime: Self.privacyHostTime(1_000.075), frameCount: 4_800))
        let recovered = clock.stampVerifiedAcquisition(hostTime: Self.privacyHostTime(1_000.180), frameCount: 4_800)
        guard case let .emitted(pts, _, _, _)? = recovered else { return XCTFail("An unpublished future end blocked recovery") }
        XCTAssertEqual(pts.seconds, 1_000.180, accuracy: 1.0 / 48_000)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(pts, CMTime(seconds: 1_000.1, preferredTimescale: 48_000)), 0)
        guard case let .emitted(next, _, _, _)? = clock.stampVerifiedAcquisition(
            hostTime: Self.privacyHostTime(1_000.280), frameCount: 4_800) else { return XCTFail("The recovered acquisition stopped again") }
        XCTAssertEqual(next.seconds, pts.seconds + 0.1, accuracy: 1.0 / 48_000)
    }

    func testVerifiedAcquisitionInvalidAndBackwardsHostTimesPreserveAcceptedPCM() {
        var clock = MeetingMicrophonePTSClock()
        XCTAssertNil(clock.stampVerifiedAcquisition(hostTime: nil, frameCount: 4_800))
        XCTAssertNil(clock.stampVerifiedAcquisition(hostTime: nil, frameCount: 4_800), "A non-emitting rejection must be idempotent")
        guard case let .emitted(first, _, _, _)? = clock.stampVerifiedAcquisition(
            hostTime: Self.privacyHostTime(1_000), frameCount: 4_800) else { return XCTFail("The first valid acquisition did not start") }
        XCTAssertEqual(first.seconds, 1_000, accuracy: 1.0 / 48_000)
        XCTAssertNil(clock.stampVerifiedAcquisition(hostTime: nil, frameCount: 4_800), "Synthesized acquisition remains unproved")
        XCTAssertNil(clock.stampVerifiedAcquisition(hostTime: Self.privacyHostTime(999.8), frameCount: 4_800))
        XCTAssertNil(clock.stampVerifiedAcquisition(hostTime: Self.privacyHostTime(999.9), frameCount: 4_800))
        guard case let .emitted(recovered, _, _, _)? = clock.stampVerifiedAcquisition(
            hostTime: Self.privacyHostTime(1_000.2), frameCount: 4_800) else { return XCTFail("Valid time did not recover after backwards acquisition") }
        XCTAssertEqual(recovered.seconds, 1_000.2, accuracy: 1.0 / 48_000)
        XCTAssertGreaterThanOrEqual(CMTimeCompare(recovered, first + CMTime(value: 4_800, timescale: 48_000)), 0)
        clock.requestTimelineReset()
        guard case let .emitted(clamped, _, _, _) = clock.stamp(
            hostTime: Self.privacyHostTime(999.9), frameCount: 4_800) else { return XCTFail("Ordinary capture did not preserve its existing clamp") }
        XCTAssertEqual(clamped.seconds, recovered.seconds + 0.1, accuracy: 1.0 / 48_000,
                       "The non-privacy reset still clamps against genuinely emitted PCM")
    }

    func testOnlyVerifiedAcquisitionCanQuarantineCanonicalFuturePCM() async throws {
        let host = PrivacyHostClock(), sink = AcquisitionSink()
        let gate = MeetingMicrophonePrivacyGate(configuration: .init(admissionPolicy: .latchedTransitions),
            hostTime: { host.now() }, automaticWatchdog: false)
        defer { gate.close() }
        gate.setAdmitted(true, observedAtHostTime: host.now())
        let sample = try self.acquisitionSample(at: CMTime(seconds: 1_000.110, preferredTimescale: 48_000), frames: 4_800)
        host.set(1_000.205)
        XCTAssertFalse(gate.submit(sample, deliveryQueue: sink.queue, delivery: sink.receive),
                       "Unproven ScreenCaptureKit/AVCapture PCM retains strict future rejection")
        XCTAssertFalse(gate.submit(sample, acquisitionHostTime: Self.privacyHostTime(1_000.080),
                                  deliveryQueue: sink.queue, delivery: sink.receive), "An out-of-contract acquisition clock is rejected")
        let actualFuture = try self.acquisitionSample(at: CMTime(seconds: 1_000.220, preferredTimescale: 48_000))
        XCTAssertFalse(gate.submit(actualFuture, acquisitionHostTime: Self.privacyHostTime(1_000.210),
                                  deliveryQueue: sink.queue, delivery: sink.receive), "Verified acquisition still cannot be in the future")
        XCTAssertTrue(gate.submit(sample, acquisitionHostTime: Self.privacyHostTime(1_000.100),
                                 deliveryQueue: sink.queue, delivery: sink.receive))
        host.set(1_001.215); gate.checkFreshnessAndDrain(); sink.join()
        XCTAssertEqual(sink.count, 0, "A verified clock does not bypass full quarantine on either timeline")
        host.set(1_001.240); gate.checkFreshnessAndDrain(); sink.join()
        XCTAssertEqual(sink.count, 1)
        let owned = try XCTUnwrap(sink.last)
        XCTAssertTrue(gate.permitsReleasedSample(owned))
        var copied: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopy(allocator: kCFAllocatorDefault, sampleBuffer: owned,
                                             sampleBufferOut: &copied), noErr)
        XCTAssertTrue(gate.permitsReleasedSample(try XCTUnwrap(copied)), "A native copy preserves gate-owned acquisition proof")
        let transformed = try self.acquisitionSample(at: CMSampleBufferGetPresentationTimeStamp(owned), frames: 4_800)
        XCTAssertTrue(gate.permitsReleasedSample(transformed),
                      "A downstream resampler's canonical output is already conservatively mature when ingress releases it")
        let other = MeetingMicrophonePrivacyGate(configuration: .init(admissionPolicy: .latchedTransitions),
            hostTime: { host.now() }, automaticWatchdog: false)
        defer { other.close() }
        other.setAdmitted(true, observedAtHostTime: host.now())
        XCTAssertFalse(other.permitsReleasedSample(owned), "Acquisition proof belongs to one capture gate")
    }

    func testAcquisitionProofUsesRealUnmuteAndMuteBoundariesForCopiedAndTransformedPCM() async throws {
        let host = PrivacyHostClock(), sink = AcquisitionSink()
        let gate = MeetingMicrophonePrivacyGate(configuration: .init(admissionPolicy: .latchedTransitions),
            hostTime: { host.now() }, automaticWatchdog: false)
        defer { gate.close() }
        gate.setAdmitted(true, observedAtHostTime: host.now())
        host.set(1_000.3); gate.setAdmitted(false, observedAtHostTime: host.now())
        host.set(1_000.5); gate.setAdmitted(true, observedAtHostTime: host.now())
        host.set(1_000.6)
        let beforeUnmute = try self.acquisitionSample(at: CMTime(seconds: 1_000.509, preferredTimescale: 48_000))
        XCTAssertFalse(gate.submit(beforeUnmute, acquisitionHostTime: Self.privacyHostTime(1_000.490),
                                  deliveryQueue: sink.queue, delivery: sink.receive), "Canonical lead cannot admit pre-unmute acquisition")
        let allowed = try self.acquisitionSample(at: CMTime(seconds: 1_000.540, preferredTimescale: 48_000))
        XCTAssertTrue(gate.submit(allowed, acquisitionHostTime: Self.privacyHostTime(1_000.521),
                                 deliveryQueue: sink.queue, delivery: sink.receive))
        host.set(1_001.7); gate.checkFreshnessAndDrain(); sink.join()
        let owned = try XCTUnwrap(sink.last)
        XCTAssertTrue(gate.permitsReleasedSample(owned))
        XCTAssertFalse(gate.permitsReleasedSample(beforeUnmute), "An attachment-free converted buffer has a conservative reopen edge")
        XCTAssertTrue(gate.permitsReleasedSample(allowed), "Canonical resampler output after the safe reopen edge remains usable")
        let closeTail = try self.acquisitionSample(at: CMTime(seconds: 1_001.979, preferredTimescale: 48_000))
        host.set(1_001.990)
        XCTAssertTrue(gate.submit(closeTail, acquisitionHostTime: Self.privacyHostTime(1_001.960),
                                 deliveryQueue: sink.queue, delivery: sink.receive))
        host.set(1_002); gate.setAdmitted(false, observedAtHostTime: host.now())
        host.set(1_003.2); gate.checkFreshnessAndDrain(); sink.join()
        XCTAssertEqual(sink.count, 1, "Close still removes the quarantined unsafe tail")
        XCTAssertFalse(gate.permitsReleasedSample(closeTail))
        XCTAssertTrue(gate.permitsReleasedSample(owned), "A confirmed copied prefix survives ordinary Stop")
        await gate.stop()
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
        gate.close()
        XCTAssertFalse(gate.permitsReleasedSample(owned), "Abort revokes the gate-owned attachment too")
    }

    func testAcquisitionAbortDropsPendingCopiesAndJoinsWithoutLateDelivery() async throws {
        let host = PrivacyHostClock(), sink = AcquisitionSink()
        let gate = MeetingMicrophonePrivacyGate(configuration: .init(admissionPolicy: .latchedTransitions),
            hostTime: { host.now() }, automaticWatchdog: false)
        gate.setAdmitted(true, observedAtHostTime: host.now())
        host.set(1_000.205)
        let sample = try self.acquisitionSample(at: CMTime(seconds: 1_000.110, preferredTimescale: 48_000), frames: 4_800)
        XCTAssertTrue(gate.submit(sample, acquisitionHostTime: Self.privacyHostTime(1_000.100),
                                 deliveryQueue: sink.queue, delivery: sink.receive))
        gate.close()
        host.set(1_002)
        gate.checkFreshnessAndDrain()
        await gate.stop(); sink.join()
        XCTAssertEqual(sink.count, 0)
        XCTAssertEqual(gate.statistics.retainedBuffers, 0)
        XCTAssertEqual(gate.statistics.retainedBytes, 0)
    }

    func testNativeMasterTapKeepsNinetyMinuteDriftOnMeasuredHostClockWithoutPeriodicDiscard() async throws {
        for drift in [-5e-6, 7e-6] {
            let fixture = try self.masterTapFixture()
            let frames: AVAudioFrameCount = 4_800
            let raw = try self.masterRawPCM(rate: 48_000, frames: frames, channels: 1)
            let count = 54_000
            for index in 0..<count {
                let seconds = 1_000 + Double(index) * 0.1 * (1 + drift)
                let time = AVAudioTime(hostTime: Self.privacyHostTime(seconds), sampleTime: Int64(index) * Int64(frames), atRate: 48_000)
                fixture.tap.handle(buffer: raw, time: time)
                // Virtual producers run faster than capture. Join every packet rather than
                // deliberately saturating the same eight-slot queue that bounds native capture.
                await fixture.tap.drainClockHandoff()
            }
            await fixture.tap.finishClockInput()
            XCTAssertEqual(fixture.sink.frames, count * Int(frames))
            XCTAssertEqual(fixture.sink.firstHost, 1_000, accuracy: 1e-9)
            XCTAssertEqual(fixture.sink.lastHost, 1_000 + Double(count - 1) * 0.1 * (1 + drift) + 0.1, accuracy: 2e-9)
            XCTAssertEqual(fixture.sink.discontinuities, 1, "Only the first producer epoch is a boundary")
            XCTAssertTrue(fixture.sink.consistentContext)
            XCTAssertEqual(fixture.stats.snapshot().conversionFailures, 0)
            await fixture.tap.stopPrivacyDelivery()
        }
    }

    func testNativeMasterTapResamplesNineChannelPCMAt441And48kWithoutLosingAcquisitionCoverage() async throws {
        for rate in [44_100.0, 48_000.0] {
            for interleaved in [false, true] {
                let fixture = try self.masterTapFixture()
                let frames = AVAudioFrameCount(rate / 100)
                let raw = try self.masterRawPCM(rate: rate, frames: frames, channels: 9, interleaved: interleaved)
                for index in 0..<200 {
                    fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(1_000 + Double(index) * 0.01),
                        sampleTime: Int64(index) * Int64(frames), atRate: rate))
                    await fixture.tap.drainClockHandoff()
                }
                await fixture.tap.finishClockInput()
                XCTAssertEqual(fixture.sink.frames, 96_000)
                XCTAssertEqual(fixture.sink.lastHost, 1_002, accuracy: 2e-9)
                XCTAssertTrue(fixture.sink.samplesValid)
                XCTAssertEqual(fixture.stats.snapshot().conversionFailures, 0)
                await fixture.tap.stopPrivacyDelivery()
            }
        }
    }

    func testNativeMasterTapPreservesRealGapAndRetiresRawHandoffAtStop() async throws {
        let fixture = try self.masterTapFixture()
        let raw = try self.masterRawPCM(rate: 48_000, frames: 4_800, channels: 1)
        for (frame, host) in [(0, 1_000.0), (4_800, 1_000.1), (9_600, 1_000.2),
                              (120_000, 1_002.5), (124_800, 1_002.6)] {
            fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(host), sampleTime: Int64(frame), atRate: 48_000))
            await fixture.tap.drainClockHandoff()
        }
        await fixture.tap.finishClockInput()
        XCTAssertEqual(fixture.sink.frames, 24_000)
        XCTAssertEqual(fixture.sink.discontinuities, 2)
        XCTAssertTrue(fixture.sink.observedGap)
        XCTAssertEqual(fixture.stats.snapshot().conversionFailures, 0)
        await fixture.tap.stopPrivacyDelivery()
        let count = fixture.sink.frames
        fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(1_003), sampleTime: 144_000, atRate: 48_000))
        await fixture.tap.drainClockHandoff()
        XCTAssertEqual(fixture.sink.frames, count, "A retired tap cannot publish delayed raw PCM")
    }

    func testNativeMasterTapSplitsLargeNativeBlocksIntoBoundedMappedPrivacyPackets() async throws {
        let fixture = try self.masterTapFixture()
        let raw = try self.masterRawPCM(rate: 48_000, frames: 48_000, channels: 1)
        for index in 0..<3 {
            fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(1_000 + Double(index)),
                sampleTime: Int64(index) * 48_000, atRate: 48_000))
            await fixture.tap.drainClockHandoff()
        }
        await fixture.tap.finishClockInput()
        XCTAssertEqual(fixture.sink.frames, 144_000)
        XCTAssertLessThanOrEqual(fixture.sink.maximumPacketFrames, 4_800,
            "A supported large native block cannot exceed privacy intake's duration budget")
        XCTAssertEqual(fixture.sink.lastHost, 1_003, accuracy: 1e-9)
        XCTAssertEqual(fixture.stats.snapshot().conversionFailures, 0)
        await fixture.tap.stopPrivacyDelivery()
    }

    func testNativeMasterTapExplicitRouteResetStartsNewEpochWithoutDiscardingOwnedPCM() async throws {
        let fixture = try self.masterTapFixture()
        let raw = try self.masterRawPCM(rate: 48_000, frames: 4_800, channels: 1)
        for index in 0..<4 {
            if index == 2 { fixture.tap.requestTimelineReset() }
            fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(1_000 + Double(index) * 0.1),
                sampleTime: Int64(index) * 4_800, atRate: 48_000))
            await fixture.tap.drainClockHandoff()
        }
        await fixture.tap.finishClockInput()
        XCTAssertEqual(fixture.sink.frames, 19_200)
        XCTAssertEqual(fixture.sink.discontinuities, 2)
        XCTAssertEqual(fixture.sink.producerEpochs.count, 2)
        XCTAssertEqual(fixture.stats.snapshot().conversionFailures, 0)
        await fixture.tap.stopPrivacyDelivery()
    }

    func testNativeMasterTapRejectsUnprovenClockOnceAndJoinsWithoutPublishingLaterPCM() async throws {
        let failure = MasterClockFailureCounter()
        let fixture = try self.masterTapFixture(onFailure: failure.record)
        let raw = try self.masterRawPCM(rate: 48_000, frames: 4_800, channels: 1)
        fixture.tap.handle(buffer: raw, time: AVAudioTime(sampleTime: 0, atRate: 48_000))
        for index in 0..<5 {
            fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(1_000 + Double(index) * 0.1),
                sampleTime: Int64(index) * 4_800, atRate: 48_000))
        }
        await fixture.tap.drainClockHandoff()
        await fixture.tap.finishClockInput()
        await fixture.tap.stopPrivacyDelivery()
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(fixture.sink.frames, 0)
        XCTAssertEqual(fixture.stats.snapshot().conversionFailures, 1)
    }

    func testNativeMasterTapBackwardsAcquisitionRetiresPendingPCMAndReportsOnlyOnce() async throws {
        let failure = MasterClockFailureCounter()
        let fixture = try self.masterTapFixture(onFailure: failure.record)
        let raw = try self.masterRawPCM(rate: 48_000, frames: 4_800, channels: 1)
        fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(1_000.1), sampleTime: 0, atRate: 48_000))
        await fixture.tap.drainClockHandoff()
        fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(1_000), sampleTime: 4_800, atRate: 48_000))
        await fixture.tap.drainClockHandoff()
        fixture.tap.handle(buffer: raw, time: AVAudioTime(hostTime: Self.privacyHostTime(1_000.2), sampleTime: 9_600, atRate: 48_000))
        await fixture.tap.drainClockHandoff()
        await fixture.tap.finishClockInput()
        await fixture.tap.stopPrivacyDelivery()
        XCTAssertEqual(failure.count, 1)
        XCTAssertEqual(fixture.sink.frames, 0, "Unproved pending acquisition cannot be rescued by later valid input")
        XCTAssertEqual(fixture.stats.snapshot().conversionFailures, 1)
    }

    private final nonisolated class MasterClockFailureCounter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        var count: Int { self.lock.withLock { self.value } }
        func record() { self.lock.withLock { self.value += 1 } }
    }

    private struct MasterTapFixture {
        let tap: MeetingMicrophoneTapState
        let stats: MeetingMicrophoneCaptureStats
        let sink: MasterTapSink
    }
    private func masterTapFixture(onFailure: @escaping @Sendable () -> Void = {}) throws -> MasterTapFixture {
        var timebase = mach_timebase_info_data_t(); mach_timebase_info(&timebase)
        let clock = try MeetingRecordingClock(timebase: .init(startedHostTime: Self.privacyHostTime(999),
            machTimebaseNumerator: timebase.numer, machTimebaseDenominator: timebase.denom, firstPresentationTime: nil))
        let context = clock.source(UUID())
        let sink = MasterTapSink(context: context), stats = MeetingMicrophoneCaptureStats()
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let tap = MeetingMicrophoneTapState(statsBox: stats, canonicalFormat: format, clockContext: context,
            onClockFailure: onFailure, onSample: sink.receive)
        return MasterTapFixture(tap: tap, stats: stats, sink: sink)
    }
    private func masterRawPCM(rate: Double, frames: AVAudioFrameCount, channels: AVAudioChannelCount,
                              interleaved: Bool = false) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: channels, interleaved: interleaved))
        let raw = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)); raw.frameLength = frames
        let data = try XCTUnwrap(raw.floatChannelData)
        if interleaved { data[0].initialize(repeating: 0.25, count: Int(frames * channels)) }
        else { for channel in 0..<Int(channels) { data[channel].initialize(repeating: 0.25, count: Int(frames)) } }
        return raw
    }
    private final nonisolated class MasterTapSink: @unchecked Sendable {
        let context: MeetingRecordingClockContext
        private(set) var frames = 0
        private(set) var maximumPacketFrames = 0
        private(set) var firstHost = Double.nan
        private(set) var lastHost = Double.nan
        private(set) var discontinuities = 0
        private(set) var observedGap = false
        private(set) var consistentContext = true
        private(set) var producerEpochs: Set<UInt64> = []
        private(set) var samplesValid = true
        init(context: MeetingRecordingClockContext) { self.context = context }
        func receive(_ sample: CMSampleBuffer) {
            guard let packet = MeetingCaptureClockMetadata.read(from: sample) else { self.consistentContext = false; return }
            self.consistentContext = self.consistentContext && self.context.accepts(packet)
            self.producerEpochs.insert(packet.producerEpoch)
            if let first = packet.mapping.spans.first {
                if self.firstHost.isNaN { self.firstHost = first.hostStart.seconds }
                if first.discontinuityBefore {
                    self.discontinuities += 1
                    if self.lastHost.isFinite && first.hostStart.seconds > self.lastHost + 0.1 { self.observedGap = true }
                }
            }
            self.lastHost = packet.mapping.spans.last?.hostEnd.seconds ?? .nan
            self.frames += CMSampleBufferGetNumSamples(sample)
            self.maximumPacketFrames = max(self.maximumPacketFrames, CMSampleBufferGetNumSamples(sample))
            if let block = CMSampleBufferGetDataBuffer(sample) {
                var marker: Float = 0
                let status = withUnsafeMutableBytes(of: &marker) {
                    CMBlockBufferCopyDataBytes(block, atOffset: CMBlockBufferGetDataLength(block) - 4,
                        dataLength: 4, destination: $0.baseAddress!)
                }
                // Check the steady constant marker after any finite resampling startup transient.
                self.samplesValid = self.samplesValid && status == noErr && marker.isFinite && abs(marker - 0.25) < 0.01
            } else { self.samplesValid = false }
        }
    }

    private func acquisitionSample(at pts: CMTime, frames: AVAudioFrameCount = 480) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        try XCTUnwrap(pcm.floatChannelData?[0]).initialize(repeating: 0.25, count: Int(frames))
        return try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(from: pcm, presentationTime: pts))
    }

    private func acquisitionCopy(_ sample: CMSampleBuffer, at pts: CMTime) throws -> CMSampleBuffer {
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
                                       presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var copy: CMSampleBuffer?
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: sample,
            sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleBufferOut: &copy), noErr)
        return try XCTUnwrap(copy)
    }

    private final nonisolated class AcquisitionSink: @unchecked Sendable {
        let queue = DispatchQueue(label: "meeting.acquisition-clock.tests")
        private var previousEnd: CMTime?
        private(set) var count = 0
        private(set) var frames = 0
        private(set) var contiguous = true
        private(set) var last: CMSampleBuffer?
        func receive(_ sample: CMSampleBuffer) {
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            if let previousEnd, abs((pts - previousEnd).seconds) > 1.0 / 48_000 { self.contiguous = false }
            let frames = CMSampleBufferGetNumSamples(sample)
            self.previousEnd = pts + CMTime(value: Int64(frames), timescale: 48_000)
            self.count += 1; self.frames += frames; self.last = sample
        }
        func join() { self.queue.sync {} }
    }

    private final nonisolated class PrivacyHostClock: @unchecked Sendable {
        private let lock = NSLock()
        private var hostTime = CMClockConvertHostTimeToSystemUnits(CMTime(seconds: 1_000, preferredTimescale: 1_000_000_000))
        func now() -> UInt64 { self.lock.withLock { self.hostTime } }
        func set(_ seconds: Double) {
            self.lock.withLock {
                self.hostTime = CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
            }
        }
    }

    private static func privacyHostTime(_ seconds: Double) -> UInt64 {
        CMClockConvertHostTimeToSystemUnits(CMTime(seconds: seconds, preferredTimescale: 1_000_000_000))
    }
}

// MARK: - Bidirectional route-following mic: capture-side unit tests (no real engines/sessions)

extension MeetingMicrophoneCaptureTests {
    // MARK: - MeetingEraAcceptanceFence

    func testFenceBeginSampleAfterQuiesceReturnsFalse() async {
        let fence = MeetingEraAcceptanceFence()
        await fence.quiesce()
        XCTAssertFalse(fence.beginSample())
    }

    func testFenceQuiesceAwaitsInFlightZero() async {
        let fence = MeetingEraAcceptanceFence()
        XCTAssertTrue(fence.beginSample())
        XCTAssertTrue(fence.beginSample())

        let quiesced = Task { await fence.quiesce() }
        try? await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertFalse(quiesced.isCancelled, "quiesce must still be awaiting drain with 2 in-flight samples")

        fence.endSample()
        try? await Task.sleep(nanoseconds: 100_000_000)
        // Still one in-flight: a concurrent beginSample must be rejected once quiesce() starts.
        XCTAssertFalse(fence.beginSample())

        fence.endSample()
        await quiesced.value
    }

    func testFenceReuseAfterQuiesceStaysClosed() async {
        let fence = MeetingEraAcceptanceFence()
        await fence.quiesce()
        XCTAssertFalse(fence.beginSample())
        XCTAssertFalse(fence.beginSample())
    }

    func testAckResumeBeforeWaitReturnsImmediately() async {
        let ack = MeetingCaptureMethodChangeAck()
        ack.resume()
        let start = Date()
        await ack.wait(timeoutSeconds: 2.0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testAckWaitThenResume() async {
        let ack = MeetingCaptureMethodChangeAck()
        let waiter = Task { await ack.wait(timeoutSeconds: 2.0) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        ack.resume()
        let start = Date()
        await waiter.value
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    func testAckBoundedTimeoutFiresWhenNeverResumed() async {
        let ack = MeetingCaptureMethodChangeAck()
        let start = Date()
        await ack.wait(timeoutSeconds: 2.0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.5)
    }

    func testAckDoubleResumeHarmless() async {
        let ack = MeetingCaptureMethodChangeAck()
        ack.resume()
        ack.resume()
        let start = Date()
        await ack.wait(timeoutSeconds: 2.0)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    // MARK: - Writer beginSplice

    func testBeginSpliceReturnsFinalizedChunkPresentationEnd() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        for tick in 0..<5 {
            self.pushBuffer(writer, ptsSeconds: Double(tick) * 0.01)
        }
        try? await Task.sleep(nanoseconds: 50_000_000) // let enqueue's async consume land

        let boundary = await writer.beginSplice()
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 1)
        let finalized = try XCTUnwrap(track.chunks.first)
        XCTAssertEqual(finalized.finalizationState, .finalized)
        XCTAssertFalse(finalized.sha256.isEmpty)
        XCTAssertEqual(try XCTUnwrap(boundary).seconds, finalized.presentationEnd.seconds, accuracy: 1e-9)
    }

    func testBeginSpliceThenEnqueueOpensNewChunk() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0)
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = await writer.beginSplice()

        self.pushBuffer(writer, ptsSeconds: 5)
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertTrue(track.chunks.allSatisfy { $0.finalizationState == .finalized })
    }

    /// Once `.accepting` is false, `beginSplice` no-ops and returns the last finalized boundary.
    func testBeginSpliceOnStoppedWriterNoOps() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        _ = await writer.stop() // stopped with zero chunks: nothing was ever finalized
        let boundary = await writer.beginSplice()
        XCTAssertNil(boundary)
    }

    /// Same no-op, but with existing chunks: returns the last finalized boundary.
    func testBeginSpliceOnStoppedWriterReturnsLastFinalizedBoundary() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0)
        let stoppedTrack = await writer.stop()
        let lastEnd = try XCTUnwrap(stoppedTrack.chunks.last?.presentationEnd)

        let rawBoundary = await writer.beginSplice()
        let boundary = try XCTUnwrap(rawBoundary)
        XCTAssertEqual(boundary.seconds, lastEnd.seconds, accuracy: 1e-9)

        let trackAfter = await writer.snapshot()
        XCTAssertEqual(trackAfter.chunks.count, stoppedTrack.chunks.count)
    }

    func testPostSpliceSubHalfSecondGapDoesNotMergeIntoOldChunk() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        self.pushBuffer(writer, ptsSeconds: 0) // ends at 0.01s
        try? await Task.sleep(nanoseconds: 50_000_000)
        _ = await writer.beginSplice()

        // Under the merge threshold, but the splice already forced rotation into a new chunk.
        self.pushBuffer(writer, ptsSeconds: 0.21)
        let track = await writer.stop()

        XCTAssertEqual(track.chunks.count, 2)
        XCTAssertEqual(track.chunks[1].discontinuities, [])
        XCTAssertEqual(track.chunks[1].presentationStart.seconds, 0.21, accuracy: 1e-6)
    }

    // MARK: - Writer format-mismatch guard

    private func makeStereoBuffer(frameCount: Int, fill: (Int) -> Float) -> AVAudioPCMBuffer {
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 2, interleaved: false)!
        // Fixed test fixture: missing required audio storage or evidence is a setup failure.
        // swiftlint:disable:next force_unwrapping
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frameCount))!
        buffer.frameLength = AVAudioFrameCount(frameCount)
        for channel in 0..<2 {
            // Fixed test fixture: missing required audio storage or evidence is a setup failure.
            // swiftlint:disable:next force_unwrapping
            let data = buffer.floatChannelData![channel]
            for index in 0..<frameCount {
                data[index] = fill(index)
            }
        }
        return buffer
    }

    private func pushStereoBuffer(_ writer: MeetingAudioChunkWriter, ptsSeconds: Double, frameCount: Int = 480) {
        let buffer = self.makeStereoBuffer(frameCount: frameCount) { _ in 0.1 }
        let pts = CMTime(seconds: ptsSeconds, preferredTimescale: 48_000)
        guard let sampleBuffer = meetingMicrophoneSynthesizeSampleBuffer(from: buffer, presentationTime: pts) else {
            return XCTFail("failed to synthesize a stereo sample buffer")
        }
        writer.enqueue(sampleBuffer)
    }

    func testFormatMismatchWithGapProducesTwoChunksZeroWriterFailures() async throws {
        let sessionDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "test-mic",
            sourceDisplayName: "Test Microphone",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        var events: [MeetingCaptureEvent] = []
        let lock = NSLock()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: sessionDirectory, chunkDuration: 60) { event in
            lock.withLock { events.append(event) }
        }

        self.pushBuffer(writer, ptsSeconds: 0) // mono, ends at 0.01s
        try? await Task.sleep(nanoseconds: 50_000_000)
        self.pushStereoBuffer(writer, ptsSeconds: 0.21) // stereo, 0.2s gap
        let finalTrack = await writer.stop()

        XCTAssertEqual(finalTrack.chunks.count, 2)
        XCTAssertTrue(finalTrack.chunks.allSatisfy { $0.finalizationState == .finalized })

        let writerFailures = lock.withLock { events }.compactMap { event -> MeetingInterruptionKind? in
            guard case let .interrupted(kind, _, _) = event else { return nil }
            return kind
        }.filter { $0 == .writerFailure }
        XCTAssertEqual(writerFailures.count, 0)

        let finalizedFormats = lock.withLock { events }.compactMap { event -> MeetingAudioFormat? in
            guard case let .chunkFinalized(_, _, format) = event else { return nil }
            return format
        }
        XCTAssertEqual(finalizedFormats.count, 2)
        XCTAssertEqual(finalizedFormats[0].channelCount, 1)
        XCTAssertEqual(finalizedFormats[1].channelCount, 2)
    }

    // MARK: - Transactional updateTrackMetadata

    func testUpdateTrackMetadataPersistsSuccessfully() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        try await writer.updateTrackMetadata { track in
            track.captureMethod = .avCaptureSession
        }
        let track = await writer.stop()
        XCTAssertEqual(track.captureMethod, .avCaptureSession)
    }

    func testUpdateTrackMetadataThrowOnPersistFailureLeavesInMemoryUnchanged() async throws {
        let (writer, sessionDirectory) = try self.makeWriter()
        defer { try? FileManager.default.removeItem(at: sessionDirectory) }

        // Remove the track directory the manifest is persisted under so the write fails.
        let trackDirectory = sessionDirectory.appendingPathComponent("tracks", isDirectory: true)
            .appendingPathComponent(MeetingAudioTrackKind.microphone.rawValue, isDirectory: true)
        try FileManager.default.removeItem(at: trackDirectory)

        do {
            try await writer.updateTrackMetadata { track in
                track.captureMethod = .avCaptureSession
            }
            XCTFail("expected the persist failure to propagate")
        } catch {}

        let track = await writer.snapshot()
        XCTAssertNil(track.captureMethod, "a failed persist must leave the in-memory track untouched")
    }

    // MARK: - MeetingCaptureDeviceElection

    private func micIdentity(id: String, uid: String?, name: String, role: MeetingMicrophoneRole = .unknown) -> MeetingMicrophoneIdentity {
        MeetingMicrophoneIdentity(captureDeviceID: id, coreAudioUID: uid, displayName: name, role: role)
    }

    func testElectionSameDevicePreservesIdentityAndNeutralizesRole() {
        let original = self.micIdentity(id: "dev-1", uid: "uid-1", name: "MacBook Mic", role: .personal)
        let catalog = [original]
        let elected = MeetingCaptureDeviceElection.decide(original: original, catalog: catalog, defaultInputUID: "uid-1")
        var expected = original
        expected.role = .unknown
        XCTAssertEqual(elected.identity, expected)
        XCTAssertEqual(elected.identity.captureDeviceID, "dev-1")
        XCTAssertEqual(elected.identity.coreAudioUID, "uid-1")
        XCTAssertEqual(elected.identity.role, .unknown)
        XCTAssertEqual(elected.role, .unknown)
        XCTAssertNotEqual(elected.role, .personal)
        XCTAssertNotEqual(elected.role, .shared)
    }

    func testElectionDifferentDeviceReturnsUnknown() {
        let original = self.micIdentity(id: "dev-1", uid: "uid-1", name: "MacBook Mic", role: .personal)
        let other = self.micIdentity(id: "dev-2", uid: "uid-2", name: "AirPods", role: .unknown)
        let catalog = [original, other]
        let elected = MeetingCaptureDeviceElection.decide(original: original, catalog: catalog, defaultInputUID: "uid-2")
        XCTAssertEqual(elected.identity.captureDeviceID, "dev-2")
        XCTAssertEqual(elected.role, .unknown)
    }

    func testDeviceTransitionDistinguishesUnchangedChangedAndUnavailable() {
        let builtIn = self.micIdentity(id: "dev-1", uid: "uid-1", name: "MacBook Mic")
        let headset = self.micIdentity(id: "dev-2", uid: "uid-2", name: "Headset Mic")

        XCTAssertEqual(
            MeetingCaptureDeviceElection.decideTransition(
                from: builtIn, catalog: [builtIn, headset], defaultInputUID: "uid-1"
            ),
            .unchanged(MeetingCaptureDeviceElection(identity: builtIn, role: .unknown))
        )
        XCTAssertEqual(
            MeetingCaptureDeviceElection.decideTransition(
                from: builtIn, catalog: [builtIn, headset], defaultInputUID: "uid-2"
            ),
            .changed(MeetingCaptureDeviceElection(identity: headset, role: .unknown))
        )
        XCTAssertEqual(
            MeetingCaptureDeviceElection.decideTransition(
                from: builtIn, catalog: [builtIn], defaultInputUID: nil
            ),
            .unavailable
        )
        XCTAssertEqual(
            MeetingCaptureDeviceElection.decideTransition(
                from: builtIn, catalog: [builtIn], defaultInputUID: "stale-default"
            ),
            .unavailable
        )
    }

    func testElectionFallsBackToOriginalIdentityWithUnknownRoleWhenNoSystemDefault() {
        let original = self.micIdentity(id: "dev-1", uid: "uid-1", name: "MacBook Mic", role: .personal)
        let elected = MeetingCaptureDeviceElection.decide(original: original, catalog: [original], defaultInputUID: nil)
        var expected = original
        expected.role = .unknown
        XCTAssertEqual(elected.identity, expected)
        XCTAssertEqual(elected.identity.captureDeviceID, "dev-1")
        XCTAssertEqual(elected.identity.coreAudioUID, "uid-1")
        XCTAssertEqual(elected.identity.role, .unknown)
        XCTAssertEqual(elected.role, .unknown)
        XCTAssertNotEqual(elected.role, .personal)
        XCTAssertNotEqual(elected.role, .shared)
    }

    func testElectionAndPreselectionNeverEmitLegacyPersonalOrSharedRoles() {
        for legacyRole in [MeetingMicrophoneRole.personal, .shared] {
            let original = self.micIdentity(id: "dev-1", uid: "uid-1", name: "MacBook Mic", role: legacyRole)
            let sameDevice = MeetingCaptureDeviceElection.decide(
                original: original, catalog: [original], defaultInputUID: "uid-1"
            )
            XCTAssertEqual(sameDevice.identity.captureDeviceID, "dev-1")
            XCTAssertEqual(sameDevice.identity.coreAudioUID, "uid-1")
            XCTAssertEqual(sameDevice.identity.role, .unknown)
            XCTAssertEqual(sameDevice.role, .unknown)
            XCTAssertNotEqual(sameDevice.role, .personal)
            XCTAssertNotEqual(sameDevice.role, .shared)

            let unmatchedDefault = MeetingCaptureDeviceElection.decide(
                original: original, catalog: [original], defaultInputUID: "missing-uid"
            )
            var expectedFallback = original
            expectedFallback.role = .unknown
            XCTAssertEqual(unmatchedDefault.identity, expectedFallback)
            XCTAssertEqual(unmatchedDefault.identity.captureDeviceID, "dev-1")
            XCTAssertEqual(unmatchedDefault.identity.coreAudioUID, "uid-1")
            XCTAssertEqual(unmatchedDefault.role, .unknown)

            let selection = MeetingMicrophonePreselection.select(
                identities: [original],
                savedDeviceID: "dev-1",
                savedRole: legacyRole,
                systemDefaultUID: "uid-1",
                preferredInputUID: nil,
                systemDefaultCaptureID: nil
            )
            XCTAssertEqual(selection.deviceID, "dev-1")
            XCTAssertEqual(selection.role, .unknown)
            XCTAssertNotEqual(selection.role, .personal)
            XCTAssertNotEqual(selection.role, .shared)
        }
    }

    // MARK: - Codable: captureEras

    private func sampleEra(method: MeetingAudioTrackCaptureMethod, start: Double) -> MeetingCaptureEra {
        MeetingCaptureEra(
            method: method,
            deviceUID: "uid-1",
            deviceName: "MacBook Mic",
            roleAtElection: .personal,
            startSeconds: start
        )
    }

    func testMultiEraCaptureErasRoundTrip() throws {
        var track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        track.captureMethod = .avCaptureSession
        track.captureEras = [
            self.sampleEra(method: .voiceProcessing, start: 0),
            self.sampleEra(method: .avCaptureSession, start: 120),
        ]
        let encoder = JSONEncoder()
        let data = try encoder.encode(track)
        let decoded = try JSONDecoder().decode(MeetingAudioTrack.self, from: data)
        XCTAssertEqual(decoded.captureEras?.count, 2)
        XCTAssertEqual(decoded.captureEras?[0].method, .voiceProcessing)
        XCTAssertEqual(decoded.captureEras?[1].method, .avCaptureSession)
        XCTAssertEqual(decoded.captureEras?[1].startSeconds, 120)
    }

    func testLegacyJSONWithoutCaptureErasDecodesNil() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "kind": "microphone",
            "sourceIdentifier": "mic",
            "sourceDisplayName": "Mic",
            "timebase": {"startedHostTime": 0, "machTimebaseNumerator": 1, "machTimebaseDenominator": 1},
            "health": {"status": "waiting", "level": 0, "droppedSampleCount": 0},
            "chunks": []
        }
        """
        let decoded = try JSONDecoder().decode(MeetingAudioTrack.self, from: Data(json.utf8))
        XCTAssertNil(decoded.captureEras)
        XCTAssertNil(decoded.captureMethod)
    }

    /// An unknown middle era must fail the complete track closed; skipping it would extend a
    /// neighbouring protected era across audio whose capture safety is unknowable.
    func testUnknownEraMethodFailsCompleteTrackClosed() throws {
        let json = """
        {
            "id": "\(UUID().uuidString)",
            "kind": "microphone",
            "sourceIdentifier": "mic",
            "sourceDisplayName": "Mic",
            "timebase": {"startedHostTime": 0, "machTimebaseNumerator": 1, "machTimebaseDenominator": 1},
            "health": {"status": "waiting", "level": 0, "droppedSampleCount": 0},
            "chunks": [],
            "captureEras": [
                {"method": "bluetoothHFP", "roleAtElection": "unknown", "startSeconds": 0},
                {"method": "avCaptureSession", "roleAtElection": "unknown", "startSeconds": 30}
            ]
        }
        """
        let decoded = try JSONDecoder().decode(MeetingAudioTrack.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.captureEras?.count, 1)
        XCTAssertEqual(decoded.captureEras?.first?.method, .avCaptureSession)
        XCTAssertEqual(decoded.captureEras?.first?.echoProtection, .unprotected)
    }

    func testMultiEraTrackCaptureMethodIsAvCaptureSession() {
        // Multi-era tracks write the conservative track-level captureMethod for legacy readers.
        var track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: "mic",
            sourceDisplayName: "Mic",
            format: nil,
            timebase: MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting,
            chunks: []
        )
        track.captureEras = [
            self.sampleEra(method: .voiceProcessing, start: 0),
            self.sampleEra(method: .avCaptureSession, start: 90),
        ]
        track.captureMethod = .avCaptureSession
        XCTAssertEqual(track.captureMethod, .avCaptureSession)
        XCTAssertEqual(track.captureEras?.first?.method, .voiceProcessing)
    }

    // MARK: - Gate re-use per era

    func testFreshGatePerEraPassesBufferingFlushPassthroughWhilePreviousEraGateStaysTerminal() throws {
        let firstEraGate = MeetingVoiceProcessingCommitGate()
        let buffer = self.makeMonoBuffer(frameCount: 480) { _ in 0.1 }
        let sample = try XCTUnwrap(meetingMicrophoneSynthesizeSampleBuffer(
            from: buffer, presentationTime: CMTime(value: 0, timescale: 48_000)
        ))

        XCTAssertEqual(firstEraGate.offer(sample), .buffered)
        let flushed = try XCTUnwrap(firstEraGate.beginCommitFlush())
        XCTAssertEqual(flushed.count, 1)
        XCTAssertNil(firstEraGate.continueCommitFlush())
        XCTAssertTrue(firstEraGate.isCommitted)
        XCTAssertEqual(firstEraGate.offer(sample), .passthrough)

        let secondEraGate = MeetingVoiceProcessingCommitGate()
        XCTAssertEqual(secondEraGate.offer(sample), .buffered)
        XCTAssertFalse(secondEraGate.isCommitted)
        _ = secondEraGate.beginCommitFlush()
        XCTAssertNil(secondEraGate.continueCommitFlush())
        XCTAssertTrue(secondEraGate.isCommitted)

        XCTAssertTrue(firstEraGate.isCommitted, "unaffected by the second era's gate lifecycle")
    }

    // MARK: - MeetingSupervisedTimeout wall-clock bound

    /// A non-cooperative 3s sleep must not block `run` past the supervision deadline.
    func testSupervisedTimeoutReturnsNilByDeadlineEvenWhenTheOperationIsNonCooperative() async {
        let start = Date()
        let result = await MeetingSupervisedTimeout.run(seconds: 0.2) { () -> Bool in
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        XCTAssertNil(result)
        XCTAssertLessThan(Date().timeIntervalSince(start), 0.5)
    }

    // MARK: - HAL callback isolation

    func testMeetingEventWorkStartsOnlyAfterHALDeliveryCallbackReturns() {
        let callbackReturned = expectation(description: "HAL callback returned")
        let eventHandled = expectation(description: "meeting event handled")
        let state = MeetingMicrophoneCallbackOrderingState()

        // Model the body of a property-listener callback on the exact serial queue passed to HAL.
        AudioTopologyListenerExecution.deliveryQueue.async {
            MeetingMicrophoneEventExecution.afterHALCallback {
                XCTAssertTrue(state.callbackHasReturned)
                eventHandled.fulfill()
            }
            state.markCallbackReturned()
            callbackReturned.fulfill()
        }

        wait(for: [callbackReturned, eventHandled], timeout: 1, enforceOrder: true)
    }

    // MARK: - Not covered here: phase-machine transitions (file-private, hardware-driven —

    // needs the Phase1 probe) and writer finalizationSlots saturation (no test seam exposed).
    func testPreselectionBuiltInMicDefaultsToUnknownRole() {
        let builtIn = MeetingMicrophoneIdentity(captureDeviceID: "built-in", coreAudioUID: "BuiltInMicrophoneDevice", displayName: "MacBook Pro Microphone")
        let selection = MeetingMicrophonePreselection.select(
            identities: [builtIn],
            savedDeviceID: "other-device",
            savedRole: .personal,
            systemDefaultUID: "BuiltInMicrophoneDevice",
            preferredInputUID: nil,
            systemDefaultCaptureID: nil
        )
        XCTAssertEqual(selection.deviceID, "built-in")
        XCTAssertEqual(selection.role, .unknown)
        XCTAssertNotEqual(selection.role, .personal)
        XCTAssertNotEqual(selection.role, .shared)
    }

    func testElectionBuiltInMicDefaultsToUnknownRole() {
        let original = MeetingMicrophoneIdentity(captureDeviceID: "airpods", coreAudioUID: "EC:input", displayName: "AirPods", role: .personal)
        let builtIn = MeetingMicrophoneIdentity(captureDeviceID: "built-in", coreAudioUID: "BuiltInMicrophoneDevice", displayName: "MacBook Pro Microphone")
        let elected = MeetingCaptureDeviceElection.decide(original: original, catalog: [builtIn], defaultInputUID: "BuiltInMicrophoneDevice")
        XCTAssertEqual(elected.identity.captureDeviceID, "built-in")
        XCTAssertEqual(elected.identity.coreAudioUID, "BuiltInMicrophoneDevice")
        XCTAssertEqual(elected.identity.displayName, "MacBook Pro Microphone")
        XCTAssertEqual(elected.identity.role, .unknown)
        XCTAssertEqual(elected.role, .unknown)
        XCTAssertNotEqual(elected.role, .personal)
        XCTAssertNotEqual(elected.role, .shared)
    }
}

private final class MeetingMicrophoneCallbackOrderingState: @unchecked Sendable {
    private let lock = NSLock()
    private var returned = false

    var callbackHasReturned: Bool {
        self.lock.lock()
        defer { self.lock.unlock() }
        return self.returned
    }

    func markCallbackReturned() {
        self.lock.lock()
        self.returned = true
        self.lock.unlock()
    }
}
