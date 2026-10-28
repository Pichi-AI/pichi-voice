@preconcurrency import AVFoundation
import CoreMedia
import Combine
import XCTest
#if os(iOS)
@testable import PichiVoiceMobile
#else
@testable import FluidVoice_Debug
#endif

final class MeetingOwnerVoiceEnrollmentCaptureTests: XCTestCase {
    @MainActor
    func testEnrollmentJoinsIdleRetirementBeforeMicrophoneAndCancellationHandback() async throws {
        let restoreProfile = admitSyntheticEnrollmentProfile()
        defer { restoreProfile() }
        let residency = MeetingModelResidencyCoordinator()
        let idleOwner = MeetingIdlePreparedResourceOwner(residency: residency)
        let resource = EnrollmentIdleRetirementProbe()
        let prepared = try await idleOwner.prepare(identity: resource.configurationIdentity) { resource }
        let token = try XCTUnwrap(prepared)
        let audio = EnrollmentAudioLeaseProbe(residency: residency)
        var captureConstructions = 0
        let model = MeetingOwnerVoiceEnrollmentModel(audioArbiter: audio, modelResidency: residency,
            makeCapture: { captureConstructions += 1; throw EnrollmentCaptureProbeFailure.unexpectedHardware })
        model.start(microphone: .init(captureDeviceID: "synthetic-unopened", displayName: "Synthetic"))
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await resource.cleanupStarted), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(2))
        }
        let beganRetirement = await resource.cleanupStarted
        XCTAssertTrue(beganRetirement)
        XCTAssertEqual(model.phase, .preparing)
        XCTAssertEqual(audio.acquisitions, 1)
        XCTAssertEqual(audio.releases, 0)
        XCTAssertEqual(captureConstructions, 0)
        model.cancel()
        XCTAssertEqual(audio.releases, 0, "The audio lease must outlive the joined idle drain")
        await resource.finishCleanup()
        await self.waitForEnrollmentCleanup(model)
        await idleOwner.cancel(token)
        XCTAssertEqual(captureConstructions, 0)
        XCTAssertEqual(audio.releases, 1)
        XCTAssertFalse(audio.releaseHadModelWork)
        XCTAssertFalse(residency.hasOrdinaryOperations)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testEnrollmentAdmissionRejectsQueuedIdleAndReleasesTokenBeforeAudio() async {
        let restoreProfile = admitSyntheticEnrollmentProfile()
        defer { restoreProfile() }
        let residency = MeetingModelResidencyCoordinator()
        let audio = EnrollmentAudioLeaseProbe(residency: residency)
        var captureConstructions = 0
        let model = MeetingOwnerVoiceEnrollmentModel(audioArbiter: audio, modelResidency: residency,
            makeCapture: { captureConstructions += 1; throw EnrollmentCaptureProbeFailure.unexpectedHardware })
        var observedAdmission = false
        var rejectedQueuedIdle = false
        let observer = residency.ordinaryOperationEvents.sink {
            MainActor.assumeIsolated {
                guard residency.hasOrdinaryOperations, !observedAdmission else { return }
                observedAdmission = true
                do {
                    try residency.beginIdlePreparation(token: .init(id: UUID()), identity: "queued-idle",
                        adopt: { nil }, retire: {})
                    XCTFail("A queued idle load cannot enter during enrollment admission")
                } catch MeetingModelResidencyError.busy { rejectedQueuedIdle = true }
                catch { XCTFail("Unexpected admission error") }
                // Cancel before the capture factory, after a real ordinary token exists.
                model.cancel()
            }
        }
        defer { observer.cancel() }
        model.start(microphone: .init(captureDeviceID: "synthetic-unopened", displayName: "Synthetic"))
        await self.waitForEnrollmentCleanup(model)
        XCTAssertTrue(observedAdmission)
        XCTAssertTrue(rejectedQueuedIdle)
        XCTAssertEqual(captureConstructions, 0)
        XCTAssertEqual(audio.releases, 1)
        XCTAssertFalse(audio.releaseHadModelWork)
        XCTAssertFalse(residency.hasOrdinaryOperations)
        XCTAssertNil(model.error)
    }

    @MainActor
    func testEnrollmentAdmissionFailureNeverConstructsCaptureAndReleasesAudio() async {
        let restoreProfile = admitSyntheticEnrollmentProfile()
        defer { restoreProfile() }
        let residency = MeetingModelResidencyCoordinator()
        residency.beginTermination()
        let audio = EnrollmentAudioLeaseProbe(residency: residency)
        var captureConstructions = 0
        let model = MeetingOwnerVoiceEnrollmentModel(audioArbiter: audio, modelResidency: residency,
            makeCapture: { captureConstructions += 1; throw EnrollmentCaptureProbeFailure.unexpectedHardware })
        model.start(microphone: .init(captureDeviceID: "synthetic-unopened", displayName: "Synthetic"))
        await self.waitForEnrollmentCleanup(model)
        XCTAssertEqual(captureConstructions, 0)
        XCTAssertEqual(audio.acquisitions, 1)
        XCTAssertEqual(audio.releases, 1)
        XCTAssertFalse(residency.hasOrdinaryOperations)
        XCTAssertNotNil(model.error)
    }

    @MainActor
    func testBusyConcealRetainsEnrollmentUntilRootStopJoins() async throws {
        let restoreProfile = admitSyntheticEnrollmentProfile()
        defer { restoreProfile() }
        let residency = MeetingModelResidencyCoordinator()
        let idleOwner = MeetingIdlePreparedResourceOwner(residency: residency)
        let resource = EnrollmentIdleRetirementProbe()
        let prepared = try await idleOwner.prepare(identity: resource.configurationIdentity) { resource }
        let token = try XCTUnwrap(prepared)
        let audio = EnrollmentAudioLeaseProbe(residency: residency)
        var captureConstructions = 0
        let model = MeetingOwnerVoiceEnrollmentModel(audioArbiter: audio, modelResidency: residency,
            makeCapture: { captureConstructions += 1; throw EnrollmentCaptureProbeFailure.unexpectedHardware })
        model.start(microphone: .init(captureDeviceID: "synthetic-unopened", displayName: "Synthetic"))
        XCTAssertTrue(PrivateProfileService.shared.hasRetainedCaptureStopHandler)
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while !(await resource.cleanupStarted), ContinuousClock.now < deadline { await Task.yield() }
        let cleanupStarted = await resource.cleanupStarted
        XCTAssertTrue(cleanupStarted)
        PrivateProfileStorage.conceal(generation: UUID())
        try await model.prepareForPrivateProfileTransition()
        XCTAssertEqual(model.phase, .preparing)
        XCTAssertEqual(audio.releases, 0, "Logout retains the original enrollment owner")
        let stop = Task { await PrivateProfileService.shared.requestCaptureStop() }
        await Task.yield()
        await resource.finishCleanup()
        await stop.value
        await idleOwner.cancel(token)
        XCTAssertEqual(captureConstructions, 0, "Root Stop while preparing never opens microphone hardware")
        XCTAssertEqual(audio.releases, 1)
        XCTAssertFalse(PrivateProfileService.shared.hasRetainedCaptureStopHandler)
        XCTAssertEqual(model.phase, .idle)
        XCTAssertFalse(model.hasProfile)
        XCTAssertNil(model.error)
    }

    /// Enrollment admission belongs to this fixture, independent of whether the
    /// inert hosted application has completed its normal account restoration.
    @MainActor
    private func admitSyntheticEnrollmentProfile() -> @MainActor () -> Void {
        let original = PrivateProfileStorage.current
        let originalAdmission = PrivateProfileStorage.acceptsNewWork
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SyntheticEnrollmentProfile." + UUID().uuidString, isDirectory: true)
        PrivateProfileStorage.select(.init(id: "guest", context: nil, generation: UUID(),
            rootDirectory: root, legacyRootDirectory: root, isReadable: true))
        return {
            PrivateProfileStorage.select(original)
            if !originalAdmission { PrivateProfileStorage.closeAdmission() }
        }
    }

    @MainActor
    private func waitForEnrollmentCleanup(_ model: MeetingOwnerVoiceEnrollmentModel) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(2))
        while model.isBusy, ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(2)) }
        XCTAssertEqual(model.phase, .idle)
        XCTAssertEqual(model.seconds, 0)
    }

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

private enum EnrollmentCaptureProbeFailure: Error { case unexpectedHardware }

private actor EnrollmentIdleRetirementProbe: MeetingIdlePreparedResource {
    nonisolated let configurationIdentity = "owner-enrollment-test"
    private(set) var cleanupStarted = false
    private var released = false
    private var continuation: CheckedContinuation<Void, Never>?
    func cleanup() async {
        cleanupStarted = true
        guard !released else { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func finishCleanup() {
        released = true
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class EnrollmentAudioLeaseProbe: MeetingAudioActivityArbitrating {
    let residency: MeetingModelResidencyCoordinator
    let lease = MeetingAudioActivityLease(id: UUID())
    private(set) var acquisitions = 0
    private(set) var releases = 0
    private(set) var releaseHadModelWork = true
    init(residency: MeetingModelResidencyCoordinator) { self.residency = residency }
    func acquireMeetingCapture() async throws -> MeetingAudioActivityLease {
        acquisitions += 1
        return lease
    }
    func release(_ lease: MeetingAudioActivityLease) async {
        XCTAssertEqual(lease, self.lease)
        releaseHadModelWork = residency.hasOrdinaryOperations
        releases += 1
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
