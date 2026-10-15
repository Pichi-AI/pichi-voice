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

    private nonisolated static func sample(second: Int) throws -> CMSampleBuffer {
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                                sampleRate: 16_000, channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
        pcm.frameLength = 16_000
        let output = try XCTUnwrap(pcm.floatChannelData?[0])
        for index in 0..<16_000 { output[index] = 0.05 * sin(Float(index) * 2 * .pi * 180 / 16_000) }
        return try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm,
            presentationTime: CMTime(value: Int64(second * 16_000), timescale: 16_000))
    }
}
