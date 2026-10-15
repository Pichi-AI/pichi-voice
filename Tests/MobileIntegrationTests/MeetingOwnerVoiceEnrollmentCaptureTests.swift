@preconcurrency import AVFoundation
import CoreMedia
import XCTest
#if os(iOS)
@testable import PichiVoiceMobile
#else
@testable import FluidVoice_Debug
#endif

final class MeetingOwnerVoiceEnrollmentCaptureTests: XCTestCase {
    func testSampleIsBoundedAndDrainedBeforeItIsTaken() async throws {
        let owner = try MeetingOwnerVoiceSampleBuffer()
        for second in 0..<21 {
            XCTAssertTrue(owner.enqueue(try Self.sample(second: second)))
            if second < 20 {
                let deadline = ContinuousClock.now.advanced(by: .seconds(2))
                while owner.capturedSeconds < Double(second + 1), ContinuousClock.now < deadline {
                    try await Task.sleep(for: .milliseconds(2))
                }
                XCTAssertEqual(owner.capturedSeconds, Double(second + 1), accuracy: 0.002)
            }
        }
        try await owner.finish()
        let samples = owner.take(discard: false)
        XCTAssertEqual(samples.count, MeetingOwnerVoiceSampleBuffer.maximumSamples)
        XCTAssertEqual(owner.capturedSeconds, 0)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertTrue(owner.take(discard: false).isEmpty)
    }

    func testCancelledSampleCannotAdmitMoreAudioAndIsDiscarded() async throws {
        let owner = try MeetingOwnerVoiceSampleBuffer()
        XCTAssertTrue(owner.enqueue(try Self.sample(second: 0)))
        owner.close()
        XCTAssertTrue(owner.enqueue(try Self.sample(second: 1)))
        try await owner.finish()
        XCTAssertLessThanOrEqual(owner.capturedSeconds, 1.002)
        XCTAssertTrue(owner.take(discard: true).isEmpty)
        XCTAssertEqual(owner.capturedSeconds, 0)
    }

    func testNormalStopPreservesCallbackAdmittedBeforeItsPCMReservation() async throws {
        let admitted = expectation(description: "Callback entered the owned producer group")
        let resumeProducer = DispatchSemaphore(value: 0)
        let owner = try MeetingOwnerVoiceSampleBuffer(afterAdmission: {
            admitted.fulfill()
            _ = resumeProducer.wait(timeout: .now() + 5)
        })
        let producer = Task.detached { owner.enqueue(try Self.sample(second: 0)) }
        await fulfillment(of: [admitted], timeout: 2)

        // This is the platform Stop interleaving: admission has closed while an
        // already-admitted callback is still preparing its bounded PCM reservation.
        owner.close()
        let finishing = Task { try await owner.finish() }
        resumeProducer.signal()
        let accepted = try await producer.value
        XCTAssertTrue(accepted, "Normal Stop must not turn owned PCM into an invalid-buffer failure")
        try await finishing.value
        try owner.checkFailure()
        let samples = owner.take(discard: false)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertEqual(owner.capturedSeconds, 0)
    }

    func testTerminalFailureStillRejectsAnAdmittedCallbackAndDiscardsItsSample() async throws {
        let admitted = expectation(description: "Callback entered before terminal failure")
        let resumeProducer = DispatchSemaphore(value: 0)
        let owner = try MeetingOwnerVoiceSampleBuffer(afterAdmission: {
            admitted.fulfill()
            _ = resumeProducer.wait(timeout: .now() + 5)
        })
        let producer = Task.detached { owner.enqueue(try Self.sample(second: 0)) }
        await fulfillment(of: [admitted], timeout: 2)

        owner.fail(MeetingOwnerVoiceCaptureError.interrupted)
        resumeProducer.signal()
        let accepted = try await producer.value
        XCTAssertFalse(accepted)
        do {
            try await owner.finish()
            XCTFail("The interrupted sample must fail closed")
        } catch {
            XCTAssertTrue(error is MeetingOwnerVoiceCaptureError, "The original failure must be preserved")
        }
        XCTAssertTrue(owner.take(discard: true).isEmpty)
        XCTAssertEqual(owner.capturedSeconds, 0)
    }

    func testFailureCannotProduceAnAcceptedDraftSample() async throws {
        let owner = try MeetingOwnerVoiceSampleBuffer()
        XCTAssertTrue(owner.enqueue(try Self.sample(second: 0)))
        owner.fail(MeetingOwnerVoiceCaptureError.interrupted)
        do {
            try await owner.finish()
            XCTFail("The interrupted sample must fail closed")
        } catch {
            XCTAssertTrue(error is MeetingOwnerVoiceCaptureError)
        }
        XCTAssertTrue(owner.take(discard: true).isEmpty)
        XCTAssertEqual(owner.capturedSeconds, 0)
    }

    @MainActor func testProfileErrorsHaveUserFacingMessages() {
        for error in [MeetingOwnerVoiceProfileError.invalidAudio, .insufficientSpeech, .inconsistentVoice,
                      .invalidProfile, .staleDraft, .busy] {
            let message = MeetingOwnerVoiceEnrollmentModel.message(for: error)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains("MeetingOwnerVoiceProfileError"))
            XCTAssertFalse(message.contains("error 1"))
        }
    }

#if os(iOS) && DEBUG
    func testIOSRuntimeStopDrainsAdmittedPCMIntoRAMOnlyEnrollment() async throws {
        let owner = try MeetingOwnerVoiceSampleBuffer()
        let events = try await self.stopIOSRuntimeWithAdmittedProducer(writer: nil, consumer: owner)
        try await owner.finish()
        let samples = owner.take(discard: false)
        XCTAssertEqual(samples.count, 16_000)
        XCTAssertTrue(samples.allSatisfy(\.isFinite))
        XCTAssertTrue(events.interruptions.isEmpty, "Normal Stop cannot become capture backpressure")
    }

    func testIOSRuntimeStopDrainsAdmittedPCMBeforeFileWriterStops() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("SyntheticStopDrain.\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic-stop-drain",
            sourceDisplayName: "Synthetic PCM", format: nil,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil),
            health: .waiting, chunks: [], captureMethod: .audioEngine)
        let writerEvents = IOSStopDrainEventProbe()
        let writer = try MeetingAudioChunkWriter(track: track, sessionDirectory: directory, chunkDuration: 60,
            eventHandler: { writerEvents.record($0) })
        let runtimeEvents = try await self.stopIOSRuntimeWithAdmittedProducer(writer: writer, consumer: nil)
        let stopped = await writer.stop()
        XCTAssertTrue(runtimeEvents.interruptions.isEmpty)
        XCTAssertTrue(writerEvents.interruptions.isEmpty)
        let chunk = try XCTUnwrap(stopped.chunks.first)
        XCTAssertEqual(stopped.chunks.count, 1)
        XCTAssertEqual(chunk.finalizationState, .finalized)
        let audio = try AVAudioFile(forReading: directory.appendingPathComponent(chunk.relativeFilePath))
        XCTAssertEqual(audio.length, 16_000, "The synthetic admitted callback must reach the retained-file sink")
    }

    func testIOSRuntimeTerminalPCMFailureStillFailsStop() async throws {
        let owner = try MeetingOwnerVoiceSampleBuffer()
        let events = IOSStopDrainEventProbe()
        let runtime = try IOSMeetingMicrophoneRuntime(trackID: UUID(),
            microphone: .init(captureDeviceID: "synthetic-invalid-time", coreAudioUID: nil, displayName: "Synthetic PCM"),
            writer: nil, memoryConsumer: owner, eventHandler: { events.record($0) }, liveAudioHandler: nil)
        // A sample-time-only timestamp deliberately lacks the required host clock.
        runtime.acceptForTesting(try Self.pcm(), time: AVAudioTime(sampleTime: 0, atRate: 16_000))
        do {
            try await runtime.stop()
            XCTFail("A genuine PCM clock failure cannot be hidden by the normal Stop drain")
        } catch {
            XCTAssertEqual(error as? MeetingCapturePCMError, .invalidPresentationTime)
        }
        try await owner.finish()
        XCTAssertTrue(owner.take(discard: false).isEmpty)
        XCTAssertEqual(events.interruptions, [.clockDiscontinuity, .captureStoppedUnexpectedly])
    }

    private func stopIOSRuntimeWithAdmittedProducer(writer: MeetingAudioChunkWriter?,
        consumer: (any MeetingMemoryAudioConsuming)?) async throws -> IOSStopDrainEventProbe {
        let admitted = expectation(description: "iOS tap admitted before PCM reservation")
        let resumeProducer = DispatchSemaphore(value: 0)
        defer { resumeProducer.signal() }
        let events = IOSStopDrainEventProbe()
        let runtime = try IOSMeetingMicrophoneRuntime(trackID: writer?.trackID ?? UUID(),
            microphone: .init(captureDeviceID: "synthetic-stop-drain", coreAudioUID: nil, displayName: "Synthetic PCM"),
            writer: writer, memoryConsumer: consumer, eventHandler: { events.record($0) }, liveAudioHandler: nil,
            afterAdmission: { admitted.fulfill(); _ = resumeProducer.wait(timeout: .now() + 5) })
        // Neither runtime.start() nor a system microphone permission is needed. The actual
        // tap admission, native copy, converter, sink delivery and Stop join still execute.
        let producer = Task.detached {
            runtime.acceptForTesting(try Self.pcm(), time: AVAudioTime(hostTime: AVAudioTime.hostTime(forSeconds: 1)))
        }
        await fulfillment(of: [admitted], timeout: 2)
        let stopping = Task.detached { try await runtime.stop() }
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !runtime.hasClosedAdmissionForTesting, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        XCTAssertTrue(runtime.hasClosedAdmissionForTesting, "Stop must close admission before releasing the held producer")
        resumeProducer.signal()
        try await producer.value
        try await stopping.value
        return events
    }
#endif

    private nonisolated static func sample(second: Int) throws -> CMSampleBuffer {
        try MeetingCapturePCMConverter.sampleBuffer(buffer: self.pcm(),
            presentationTime: CMTime(value: Int64(second * 16_000), timescale: 16_000))
    }

    private nonisolated static func pcm() throws -> AVAudioPCMBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        pcm.frameLength = 16_000
        let output = try XCTUnwrap(pcm.floatChannelData?[0])
        for index in 0..<16_000 { output[index] = 0.05 * sin(Float(index) * 2 * .pi * 180 / 16_000) }
        return pcm
    }
}

#if os(iOS) && DEBUG
private nonisolated final class IOSStopDrainEventProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var kinds: [MeetingInterruptionKind] = []
    func record(_ event: MeetingCaptureEvent) {
        if case let .interrupted(kind, _, _) = event { self.lock.withLock { self.kinds.append(kind) } }
    }
    var interruptions: [MeetingInterruptionKind] { self.lock.withLock { self.kinds } }
}
#endif
