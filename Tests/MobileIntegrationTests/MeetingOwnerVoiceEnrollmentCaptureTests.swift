@preconcurrency import AVFoundation
import CoreMedia
import XCTest
@testable import PichiVoiceMobile

final class MeetingOwnerVoiceEnrollmentCaptureTests: XCTestCase {
    func testSampleIsBoundedAndDrainedBeforeItIsTaken() async throws {
        let owner = try MeetingOwnerVoiceSampleBuffer()
        for second in 0..<21 {
            XCTAssertTrue(owner.enqueue(try sample(second: second)))
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
        XCTAssertTrue(owner.enqueue(try sample(second: 0)))
        owner.close()
        XCTAssertTrue(owner.enqueue(try sample(second: 1)))
        try await owner.finish()
        XCTAssertLessThanOrEqual(owner.capturedSeconds, 1.002)
        XCTAssertTrue(owner.take(discard: true).isEmpty)
        XCTAssertEqual(owner.capturedSeconds, 0)
    }

    func testFailureCannotProduceAnAcceptedDraftSample() async throws {
        let owner = try MeetingOwnerVoiceSampleBuffer()
        XCTAssertTrue(owner.enqueue(try sample(second: 0)))
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

    private func sample(second: Int) throws -> CMSampleBuffer {
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
