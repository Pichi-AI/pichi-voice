import AudioToolbox
import AVFoundation
import CoreMedia
@testable import FluidVoice_Debug
import Foundation
import ScreenCaptureKit
import XCTest

/// Phase 2 gate: do the two capture paths' clocks stay in step? Runs `MeetingMicrophoneCapture`
/// (VPIO, built-in mic) and an SCStream audio capture simultaneously, regressing each path's
/// emitted PTS against mach wall time.
///
/// Gate: |slope_mic − slope_app| + CI_Δ < 6.9 ppm — derived from the ±50 ms ordering budget over a
/// 2-hour meeting (50 ms / 7200 s), NOT from Phase 0's 20 ppm domain check, which answered a
/// different question. Absolute cross-path offset is not measurable acoustically (AEC removes the
/// stimulus at ~33 dB); the deterministic latency components are printed instead as the Phase 3
/// estimate. Preconditions: foreground session, unlocked display, speakers (not Bluetooth — VPIO
/// delivers nothing on a BT render route), VPIO ducking audible during the run.
///
/// Run with FLUIDVOICE_DRIFT_PROBE=<minutes>.
final class MeetingTimelineDriftProbeTests: XCTestCase {
    private static let gatePPM = 6.9
    private static let ciBudgetPPM = 1.4 // 20% of the gate; wider means "extend the run", not "pass"

    func testCrossPathClockDrift() async throws {
        guard let minutesString = ProcessInfo.processInfo.environment["FLUIDVOICE_DRIFT_PROBE"],
              let minutes = Double(minutesString), minutes > 0
        else { throw XCTSkip("FLUIDVOICE_DRIFT_PROBE not set") }

        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        guard let display = content.displays.first else { throw XCTSkip("no display") }
        let filter = SCContentFilter(display: display, excludingApplications: [], exceptingWindows: [])
        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.queueDepth = 3
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 2
        configuration.excludesCurrentProcessAudio = true

        let appRecorder = ClockPairRecorder()
        let appOutput = DriftStreamOutput(recorder: appRecorder)
        let stream = SCStream(filter: filter, configuration: configuration, delegate: nil)
        try stream.addStreamOutput(appOutput, type: .audio, sampleHandlerQueue: DispatchQueue(label: "drift.app"))
        try await stream.startCapture()
        defer { Task { try? await stream.stopCapture() } }

        let temp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temp) }

        let microphone = try await MeetingCaptureSourceCatalog.defaultMicrophone(preferredCoreAudioUID: "BuiltInMicrophoneDevice")
        var writerDiscontinuities = 0
        let track = MeetingAudioTrack(
            id: UUID(),
            kind: .microphone,
            sourceIdentifier: microphone.captureDeviceID,
            sourceDisplayName: microphone.displayName,
            format: nil,
            timebase: MeetingTimebaseMetadata(
                startedHostTime: mach_absolute_time(),
                machTimebaseNumerator: Self.timebase.numer,
                machTimebaseDenominator: Self.timebase.denom,
                firstPresentationTime: nil
            ),
            health: .waiting,
            chunks: []
        )
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: temp, chunkDuration: 60) { _ in }

        let micRecorder = ClockPairRecorder()
        let capture = MeetingMicrophoneCapture()
        let outcome = try await capture.start(microphone: microphone) { sampleBuffer in
            // Mach sampled synchronously on the tap thread, before the writer hop.
            let mach = Double(mach_absolute_time()) * Self.timebaseSeconds
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            if pts.isValid {
                Task { await micRecorder.record(mach: mach, pts: pts.seconds) }
            }
            writer.enqueue(sampleBuffer)
        }
        guard case .boundVerified = outcome else {
            throw XCTSkip("mic not bindable in this environment: \(outcome)")
        }
        Self.printLatencyEstimate(capture: await capture.settledConfiguration())

        let seconds = minutes * 60
        var elapsed = 0.0
        while elapsed < seconds {
            let step = min(60.0, seconds - elapsed)
            try await Task.sleep(nanoseconds: UInt64(step * 1_000_000_000))
            elapsed += step
            if elapsed >= 30, await micRecorder.count() == 0 {
                XCTFail("no mic buffers after 30s — Bluetooth render route or dead capture")
                await capture.stop()
                return
            }
            let mic = await micRecorder.regression()
            let app = await appRecorder.regression()
            print(String(
                format: "[drift] t=%4.0fs mic n=%5d slope=%+7.3f ppm | app n=%6d slope=%+7.3f ppm",
                elapsed,
                mic?.count ?? 0,
                mic?.slopePPM ?? .nan,
                app?.count ?? 0,
                app?.slopePPM ?? .nan
            ))
        }

        await capture.stop()
        let finishedTrack = await writer.stop()
        writerDiscontinuities = finishedTrack.chunks.reduce(0) { $0 + $1.discontinuities.count }
        let stats = await capture.statistics()

        guard let mic = await micRecorder.regression(), let app = await appRecorder.regression() else {
            return XCTFail("insufficient samples for regression")
        }
        let delta = abs(mic.slopePPM - app.slopePPM)
        let ciDelta = (mic.slopeCI95PPM * mic.slopeCI95PPM + app.slopeCI95PPM * app.slopeCI95PPM).squareRoot()
        let micHalves = await micRecorder.halfSplitSlopesPPM()

        print(String(format: "\n[drift] mic  slope=%+.3f ppm (CI ±%.3f)  residual=%.2f ms  n=%d", mic.slopePPM, mic.slopeCI95PPM, mic.residualStdMs, mic.count))
        print(String(format: "[drift] app  slope=%+.3f ppm (CI ±%.3f)  residual=%.2f ms  n=%d", app.slopePPM, app.slopeCI95PPM, app.residualStdMs, app.count))
        print(String(format: "[drift] Δ=%.3f ppm  CI_Δ=%.3f  →  projected skew %.1f ms/hour", delta, ciDelta, (delta + ciDelta) * 3.6))
        if let halves = micHalves {
            print(String(format: "[drift] mic half-split: %+.3f / %+.3f ppm (Δ=%.3f)", halves.first, halves.second, abs(halves.first - halves.second)))
        }
        print(
            // Keep the exact fixture text or diagnostic output together for comparison.
            // swiftlint:disable:next line_length
            "[drift] guards: seqViolations=\(stats.sequenceContinuityViolations) convFail=\(stats.conversionFailures) droppedPostCap=\(stats.droppedPostCapCount) resyncs=\(stats.resyncCount) writerDisc=\(writerDiscontinuities) configChanges=\(stats.configurationChangeEvents) corrections=\(stats.anchorCorrectionCount) absorbed=\(String(format: "%.3f", stats.cumulativeAbsorbedCorrectionSeconds * 1000))ms stepEvents=\(stats.divergenceStepEventCount)"
        )
        print("[drift] NOTE: absolute cross-path offset is unmeasured here (AEC removes acoustic stimuli); Phase 3 validates it on a real call.")

        if stats.configurationChangeEvents > 0 {
            throw XCTSkip("configuration changed mid-run — probe artifact, re-run")
        }
        XCTAssertEqual(stats.sequenceContinuityViolations, 0)
        XCTAssertEqual(stats.conversionFailures, 0)
        XCTAssertEqual(stats.droppedPostCapCount, 0)
        XCTAssertEqual(stats.resyncCount, 0)
        XCTAssertEqual(writerDiscontinuities, 0)
        XCTAssertLessThanOrEqual(ciDelta, Self.ciBudgetPPM, "CI too wide — extend the run rather than trusting the point estimate")
        XCTAssertLessThan(delta + ciDelta, Self.gatePPM, "cross-path drift violates the ±50ms/2h ordering budget")
    }

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    private static let timebaseSeconds = Double(timebase.numer) / Double(timebase.denom) / 1_000_000_000

    /// The deterministic latency components — the Phase 3 absolute-offset estimate.
    private static func printLatencyEstimate(capture settled: MeetingMicrophoneSettledConfig?) {
        guard let settled else { return }
        print(
            "[drift] settled: input=\(settled.settledInputDeviceUID ?? "?") output=\(settled.settledOutputDeviceUID ?? "?") source=\(settled.sourceSampleRate)Hz/\(settled.sourceChannelCount)ch"
        )
    }
}

private final class DriftStreamOutput: NSObject, SCStreamOutput {
    private let recorder: ClockPairRecorder
    private static let timebaseSeconds: Double = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return Double(info.numer) / Double(info.denom) / 1_000_000_000
    }()

    init(recorder: ClockPairRecorder) { self.recorder = recorder }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .audio else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        guard pts.isValid else { return }
        let mach = Double(mach_absolute_time()) * Self.timebaseSeconds
        Task { [recorder] in await recorder.record(mach: mach, pts: pts.seconds) }
    }
}

/// Model-free checks of the same frame mapping, attachment and converter used by native capture.
final class MeetingRecordingClockCoreTests: XCTestCase {
    private let clockID = UUID(), sourceID = UUID()
    private func time(_ seconds: Double) -> MeetingMediaTime { MeetingAudioClockMapping.mediaTime(seconds) }
    private func mapping(frames: Int64, start: Double, end: Double, boundary: Bool = false) -> MeetingAudioClockMapping {
        .init(frameCount: frames, spans: [.init(frameStart: 0, frameEnd: Double(frames),
            hostStart: time(start), hostEnd: time(end), discontinuityBefore: boundary)])
    }
    private func packet(_ mapping: MeetingAudioClockMapping, source: UUID? = nil,
                        epoch: UInt64 = 0) -> MeetingCaptureClockMetadata.Packet {
        .init(mapping: mapping, clockID: clockID, sourceID: source ?? sourceID, producerEpoch: epoch)
    }
    private func pcm(rate: Double, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: rate, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        pcm.frameLength = frames
        try XCTUnwrap(pcm.floatChannelData?[0]).initialize(repeating: 0.25, count: Int(frames))
        return pcm
    }
    private func sample(rate: Double = 16_000, frames: AVAudioFrameCount = 160,
                        at seconds: Double = 1_000) throws -> CMSampleBuffer {
        try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm(rate: rate, frames: frames),
            presentationTime: CMTime(seconds: seconds, preferredTimescale: 1_000_000_000), sampleRate: rate)
    }

    private final class ActivityEvidence: @unchecked Sendable {
        private let lock = NSLock()
        private var resets = 0
        private var values: [(Double, Double, MeetingSpeechActivity)] = []
        func reset() { lock.withLock { resets += 1 } }
        func append(_ start: Double, _ end: Double, _ activity: MeetingSpeechActivity) {
            lock.withLock { values.append((start, end, activity)) }
        }
        var snapshot: (Int, [(Double, Double, MeetingSpeechActivity)]) { lock.withLock { (resets, values) } }
    }
    private struct QuietModel: MeetingSpeechActivityFrameModel {
        let evidence: ActivityEvidence
        mutating func probability(samples: [Float], reset: Bool) throws -> Float {
            if reset { evidence.reset() }
            return 0.01
        }
    }

    func testSpeechActivityUsesMappedFrameEndsWithoutResettingForDriftOrScoringMuteGaps() async throws {
        let evidence = ActivityEvidence()
        let worker = MeetingCaptureSpeechActivityWorker(factory: { QuietModel(evidence: evidence) }, clock: { 0 }) {
            evidence.append($0, $1, $2)
        }
        let context = try MeetingRecordingClock(timebase: .init(startedHostTime: 1_000_000_000_000,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)).source(UUID())
        for index in 0..<8 {
            let gap = index >= 6 ? 0.1 : 0
            let start = 2 + Double(index) * 0.256 * 1.0003 + gap
            let end = 2 + Double(index + 1) * 0.256 * 1.0003 + gap
            let mapping = try context.mapping(frameCount: 4096,
                start: CMTime(seconds: 1_000 + start, preferredTimescale: 1_000_000_000),
                end: CMTime(seconds: 1_000 + end, preferredTimescale: 1_000_000_000), discontinuityBefore: index == 0 || index == 6)
            let packet = try context.timedCopy(sample(frames: 4096, at: 1_000 + start), mapping: mapping,
                producerEpoch: index < 6 ? 1 : 2)
            worker.offer(packet, start: start)
            await worker.drainForTesting()
        }
        let snapshot = evidence.snapshot
        XCTAssertEqual(snapshot.0, 2, "Only a true source boundary resets recurrent state")
        XCTAssertEqual(snapshot.1.count, 8)
        XCTAssertEqual(snapshot.1[5].1, 2 + 6 * 0.256 * 1.0003, accuracy: 2e-9)
        XCTAssertEqual(snapshot.1[6].0, 2 + 6 * 0.256 * 1.0003 + 0.1, accuracy: 2e-9)
        XCTAssertTrue(worker.confidentlyNonSpeech(start: snapshot.1[7].0, end: snapshot.1[7].1))
        XCTAssertFalse(worker.confidentlyNonSpeech(start: snapshot.1[5].0, end: snapshot.1[7].1))
        worker.stop(); await worker.join()
    }

    func testSourceClockCalibratesAdjacentAcquisitionAnchorsAndFiniteTailWithoutRetaggingNativeTime() throws {
        let clock = try MeetingRecordingClock(timebase: .init(startedHostTime: 1_000_000_000_000,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil,
            recordingTimePolicy: .hostMonotonicV1))
        let context = clock.source(UUID())
        let source = MeetingCaptureSourceClock(context: context)
        let first = try sample(rate: 48_000, frames: 480, at: 0)
        let second = try sample(rate: 48_000, frames: 480, at: 0.01)
        XCTAssertTrue(try source.offer(first, producerGeneration: 1,
            acquisitionStart: CMTime(seconds: 1_000.1, preferredTimescale: 1_000_000_000), sourceFrameStart: 0).isEmpty)
        let output = try source.offer(second, producerGeneration: 1,
            acquisitionStart: CMTime(seconds: 1_000.110003, preferredTimescale: 1_000_000_000), sourceFrameStart: 480)
        let measured = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: XCTUnwrap(output.first)))
        XCTAssertEqual(measured.mapping.spans.first?.hostStart.seconds ?? 0, 1_000.1, accuracy: 1e-9)
        XCTAssertEqual(measured.mapping.spans.last?.hostEnd.seconds ?? 0, 1_000.110003, accuracy: 1e-9)
        let tail = try XCTUnwrap(source.finish().first)
        let tailMap = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: tail)).mapping
        XCTAssertEqual(tailMap.spans.last?.hostEnd.seconds ?? 0, 1_000.120006, accuracy: 2e-9)
        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(first), .zero, "The source-owned packet remains unchanged")
        XCTAssertNil(MeetingCaptureClockMetadata.read(from: first))
        let copy = try context.timedCopy(tail, mapping: tailMap, producerEpoch: measured.producerEpoch)
        XCTAssertEqual(MeetingCaptureClockMetadata.read(from: copy)?.mapping, tailMap)
        let foreign = try MeetingRecordingClock(timebase: .init(startedHostTime: 0,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)).source(context.sourceID)
        XCTAssertThrowsError(try foreign.timedCopy(tail, mapping: tailMap, producerEpoch: 1))
    }

    func testContinuousNativeFramesCannotClaimAnImplausibleHostInterval() throws {
        let clock = try MeetingRecordingClock(timebase: .init(startedHostTime: 0,
            machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        let source = MeetingCaptureSourceClock(context: clock.source(UUID()))
        _ = try source.offer(sample(at: 0), producerGeneration: 1,
            acquisitionStart: CMTime(seconds: 100, preferredTimescale: 1_000), sourceFrameStart: 0)
        XCTAssertThrowsError(try source.offer(sample(at: 0.01), producerGeneration: 1,
            acquisitionStart: CMTime(seconds: 105, preferredTimescale: 1_000), sourceFrameStart: 160),
            "Ten milliseconds of PCM cannot authorize five seconds of speech or silence evidence")
    }

    func testNinetyMinuteIndependentSourcesMapOneHostAxisWithoutFalseBoundariesOrUnboundedHistory() throws {
        for (delay, drift) in [(0.3, -5e-6), (2.1, 7e-6)] {
            let timeline = try MeetingPCMSourceTimeline(originSeconds: 1_000, maximumSpans: 128)
            func host(_ index: Int) -> Double {
                1_000 + delay + Double(index) * 0.1 * (1 + drift) + sin(Double(index) * 0.17) * 0.0004
            }
            for index in 0..<54_000 {
                let current = mapping(frames: 1_600, start: host(index), end: host(index + 1))
                XCTAssertFalse(try timeline.record(sourceStartSample: index * 1_600, frameCount: 1_600,
                    presentationTime: host(index), clockMapping: current))
                if index > 0 {
                    XCTAssertNotNil(timeline.mapInterval(start: Double(index) * 0.1 - 0.05,
                        end: Double(index) * 0.1 + 0.05), "Calibration boundaries are not missing audio")
                }
                if index % 25 == 0 { timeline.discard(beforeSample: max(0, (index - 30) * 1_600)) }
                XCTAssertLessThanOrEqual(timeline.retainedSpanCount, 60)
            }
            XCTAssertFalse(timeline.hasGaps)
            XCTAssertEqual(try XCTUnwrap(timeline.mapEndTime(5_400)), host(54_000) - 1_000, accuracy: 2e-9)
        }
    }

    func testLegacyResidualsKeepNominalCoalescingAndOriginalSpanBudget() throws {
        let timeline = try MeetingPCMSourceTimeline(originSeconds: 100, maximumSpans: 1)
        XCTAssertFalse(try timeline.record(sourceStartSample: 0, frameCount: 16_000, presentationTime: 100))
        XCTAssertFalse(try timeline.record(sourceStartSample: 16_000, frameCount: 16_000, presentationTime: 101.000020))
        XCTAssertEqual(timeline.retainedSpanCount, 1)
        XCTAssertEqual(try XCTUnwrap(timeline.mapEndTime(2)), 2, accuracy: 1e-9)
    }

    func testExplicitGapPreservesBothBoundarySidesAndRejectsCrossGapQuery() throws {
        let timeline = try MeetingPCMSourceTimeline(originSeconds: 1_000)
        XCTAssertFalse(try timeline.record(sourceStartSample: 0, frameCount: 1_600, presentationTime: 1_001,
            clockMapping: mapping(frames: 1_600, start: 1_001, end: 1_001.1)))
        XCTAssertThrowsError(try timeline.record(sourceStartSample: 1_600, frameCount: 1_600, presentationTime: 1_003.5,
            clockMapping: mapping(frames: 1_600, start: 1_003.5, end: 1_003.6)), "Cross-packet gaps require an explicit source boundary")
        XCTAssertTrue(try timeline.record(sourceStartSample: 1_600, frameCount: 1_600, presentationTime: 1_003.5,
            clockMapping: mapping(frames: 1_600, start: 1_003.5, end: 1_003.6, boundary: true)))
        XCTAssertEqual(try XCTUnwrap(timeline.mapTime(0.1)), 3.5, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(timeline.mapEndTime(0.1)), 1.1, accuracy: 1e-9)
        XCTAssertNil(timeline.mapInterval(start: 0.05, end: 0.15))
        let measured = try timeline.measuredIntervals(fromSample: 800, throughSample: 2_400)
        XCTAssertEqual(measured.count, 2)
        XCTAssertEqual(measured[0].lowerBound, 1.05, accuracy: 1e-9)
        XCTAssertEqual(measured[0].upperBound, 1.1, accuracy: 1e-9)
        XCTAssertEqual(measured[1].lowerBound, 3.5, accuracy: 1e-9)
        XCTAssertEqual(measured[1].upperBound, 3.55, accuracy: 1e-9)
    }

    func testMappingValidationSliceAppendAndInversePreserveFractionalAndGapEvidence() throws {
        let first = mapping(frames: 100, start: 1_000, end: 1_000.1)
        let second = mapping(frames: 100, start: 1_002, end: 1_002.1, boundary: true)
        let combined = try first.appending(second)
        XCTAssertEqual(combined.frameCount, 200)
        XCTAssertEqual(combined.spans.count, 2)
        XCTAssertEqual(try XCTUnwrap(combined.hostTime(atFrame: 100)), time(1_002))
        XCTAssertEqual(try XCTUnwrap(combined.hostTime(atFrame: 100, side: .end)), time(1_000.1))
        XCTAssertNil(combined.frame(atHostTime: time(1_001)))
        XCTAssertEqual(try XCTUnwrap(combined.frame(atHostTime: time(1_002.05))), 150, accuracy: 1e-6)
        let slice = try combined.sliced(frames: 50.5..<150.5, outputFrameCount: 80)
        XCTAssertEqual(slice.frameCount, 80)
        XCTAssertEqual(slice.spans.count, 2)
        XCTAssertTrue(slice.spans[1].discontinuityBefore)
        XCTAssertEqual(try XCTUnwrap(slice.hostTime(atFrame: 0)).seconds, 1_000.0505, accuracy: 1e-9)
        XCTAssertEqual(try XCTUnwrap(slice.hostTime(atFrame: 80)).seconds, 1_002.0505, accuracy: 1e-9)
        var unflaggedGap = combined; unflaggedGap.spans[1].discontinuityBefore = false
        XCTAssertThrowsError(try unflaggedGap.validated(), "Unknown host time cannot be blessed by an omitted boundary flag")
        XCTAssertThrowsError(try first.appending(mapping(frames: 100, start: 1_002, end: 1_002.1)))
        XCTAssertThrowsError(try first.validated(expectedFrameCount: 99))
        var corrupt = first; corrupt.spans[0].frameEnd = .nan
        XCTAssertThrowsError(try corrupt.validated())
        corrupt = first; corrupt.spans[0].hostEnd.timescale = 0
        XCTAssertThrowsError(try corrupt.validated())
        corrupt = first; corrupt.spans[0].frameStart = 1
        XCTAssertThrowsError(try corrupt.validated())
        XCTAssertThrowsError(try first.appending(mapping(frames: 100, start: 999, end: 999.1)))
        XCTAssertNil(first.hostTime(atFrame: .infinity))
    }

    func testCarrierBindsExactFrameAndRateCopiesAndNeverConfersCrossContextAuthority() throws {
        let original = try sample()
        let originalMapping = mapping(frames: 160, start: 1_000, end: 1_000.010001)
        try MeetingCaptureClockMetadata.attach(mapping: originalMapping, clockID: clockID, sourceID: sourceID,
            producerEpoch: 4, to: original)
        XCTAssertThrowsError(try MeetingCaptureClockMetadata.attach(mapping: originalMapping, clockID: UUID(),
            sourceID: sourceID, producerEpoch: 4, to: original), "A packet's recording owner is immutable")
        let exact = try sample()
        try MeetingCaptureClockMetadata.copyExact(from: original, to: exact)
        XCTAssertEqual(MeetingCaptureClockMetadata.read(from: original), MeetingCaptureClockMetadata.read(from: exact))
        var retimed: CMSampleBuffer?
        var changedTiming = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 16_000),
            presentationTimeStamp: CMTime(seconds: 1_001, preferredTimescale: 16_000), decodeTimeStamp: .invalid)
        XCTAssertEqual(CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: original,
            sampleTimingEntryCount: 1, sampleTimingArray: &changedTiming, sampleBufferOut: &retimed), noErr)
        XCTAssertNil(MeetingCaptureClockMetadata.read(from: try XCTUnwrap(retimed)),
            "Automatically propagated attachments cannot authorize an independently retimed buffer")
        XCTAssertThrowsError(try MeetingCaptureClockMetadata.copyExact(from: original, to: sample(frames: 159)))
        XCTAssertThrowsError(try MeetingCaptureClockMetadata.copyExact(from: original, to: sample(rate: 48_000)))
        XCTAssertThrowsError(try MeetingCaptureClockMetadata.copyExact(from: original, to: sample(at: 1_001)))
        XCTAssertThrowsError(try MeetingCaptureClockMetadata.attach(mapping: originalMapping, clockID: clockID,
            sourceID: sourceID, producerEpoch: 4, to: sample(frames: 159)))
        let converter = try MeetingCapturePCMConverter()
        let input = try pcm(rate: 48_000, frames: 480)
        let current = packet(mapping(frames: 480, start: 1_000, end: 1_000.01))
        _ = try converter.convert(input, presentationTime: CMTime(seconds: 1_000, preferredTimescale: 48_000), clockPacket: current)
        XCTAssertThrowsError(try converter.convert(input, presentationTime: CMTime(seconds: 1_000.01, preferredTimescale: 48_000),
            clockPacket: packet(mapping(frames: 480, start: 1_000.01, end: 1_000.02), source: UUID())))
        XCTAssertThrowsError(try converter.convert(input, presentationTime: CMTime(seconds: 1_000.01, preferredTimescale: 48_000)))
    }

    func testNativeConversionAndFiniteTailRetainMeasuredHostCoverageAtBothSupportedRates() throws {
        for rate in [44_100.0, 48_000.0] {
            for target in [16_000.0, 48_000.0] {
                let converter = try MeetingCapturePCMConverter(targetSampleRate: target)
                let frames = AVAudioFrameCount(rate / 100)
                let input = try pcm(rate: rate, frames: frames)
                let drift = -7e-6
                let count = 200
                var emitted: Int64 = 0, previousHostEnd: Double?
                func consume(_ sample: CMSampleBuffer?) throws {
                    guard let sample else { return }
                    let proof = try XCTUnwrap(MeetingCaptureClockMetadata.read(from: sample))
                    XCTAssertEqual(proof.clockID, clockID); XCTAssertEqual(proof.sourceID, sourceID)
                    XCTAssertEqual(proof.mapping.frameCount, Int64(CMSampleBufferGetNumSamples(sample)))
                    let start = try XCTUnwrap(proof.mapping.hostTime(atFrame: 0)).seconds
                    let end = try XCTUnwrap(proof.mapping.hostTime(atFrame: Double(proof.mapping.frameCount), side: .end)).seconds
                    XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(sample).seconds, start, accuracy: 1e-9)
                    if let previousHostEnd { XCTAssertEqual(start, previousHostEnd, accuracy: 2e-9) }
                    previousHostEnd = end
                    emitted += proof.mapping.frameCount
                }
                for index in 0..<count {
                    let start = 1_002 + Double(index) * 0.01 * (1 + drift)
                    let end = 1_002 + Double(index + 1) * 0.01 * (1 + drift)
                    try consume(converter.convert(input, presentationTime: CMTime(seconds: start, preferredTimescale: 1_000_000_000),
                        clockPacket: packet(mapping(frames: Int64(frames), start: start, end: end))))
                    XCTAssertLessThan(converter.retainedClockSpanCount, 10)
                }
                try consume(converter.finish())
                XCTAssertEqual(emitted, Int64(target * 2), "Finite conversion tail retains every measured output frame")
                XCTAssertEqual(try XCTUnwrap(previousHostEnd), 1_002 + 2 * (1 + drift), accuracy: 2e-9)
                XCTAssertEqual(converter.retainedClockSpanCount, 0)
            }
        }
    }

    func testExplicitBoundaryRequiresFreshConverterAndKeepsTailBeforeGap() throws {
        let converter = try MeetingCapturePCMConverter()
        let input = try pcm(rate: 48_000, frames: 4_800)
        _ = try converter.convert(input, presentationTime: CMTime(seconds: 1_000, preferredTimescale: 48_000),
            clockPacket: packet(mapping(frames: 4_800, start: 1_000, end: 1_000.1)))
        let afterGap = packet(mapping(frames: 4_800, start: 1_002.5, end: 1_002.6, boundary: true))
        XCTAssertThrowsError(try converter.convert(input, presentationTime: CMTime(seconds: 1_002.5, preferredTimescale: 48_000), clockPacket: afterGap))
        if let tail = try converter.finish(), let last = MeetingCaptureClockMetadata.read(from: tail) {
            XCTAssertLessThanOrEqual(try XCTUnwrap(last.mapping.hostTime(atFrame: Double(last.mapping.frameCount), side: .end)).seconds, 1_000.1 + 1e-9)
        }
        let resumed = try MeetingCapturePCMConverter()
        let first = try resumed.convert(input, presentationTime: CMTime(seconds: 1_002.5, preferredTimescale: 48_000), clockPacket: afterGap)
        if let first { XCTAssertTrue(try XCTUnwrap(MeetingCaptureClockMetadata.read(from: first)).mapping.spans[0].discontinuityBefore) }
    }
}
