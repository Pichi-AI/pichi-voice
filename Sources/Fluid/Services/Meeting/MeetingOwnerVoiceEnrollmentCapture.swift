@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// A short sample owner for explicit voice enrollment. The meeting adapters and PCM
/// transport are reused, but no session, audio writer or filesystem path is constructed.
@MainActor
final class MeetingOwnerVoiceEnrollmentCapture {
    static let maximumSeconds: Double = 20
    private let samples: MeetingOwnerVoiceSampleBuffer
    #if os(iOS)
    private var runtime: IOSMeetingMicrophoneRuntime?
    #else
    private var runtime: MeetingAVCaptureMicrophoneComponent?
    #endif

    init() throws { self.samples = try MeetingOwnerVoiceSampleBuffer() }

    var capturedSeconds: Double { self.samples.capturedSeconds }
    func checkFailure() throws { try self.samples.checkFailure() }

    func start(microphone: MeetingMicrophoneIdentity) async throws {
        try Task.checkCancellation()
        #if os(iOS)
        try await IOSMeetingCaptureEngine().preflightPermissions()
        #else
        try await MeetingCaptureEngine().preflightPermissions()
        #endif
        try Task.checkCancellation()
        let samples = self.samples
        #if os(iOS)
        let runtime = try IOSMeetingMicrophoneRuntime(trackID: UUID(), microphone: microphone,
            writer: nil, memoryConsumer: samples, eventHandler: { event in
                if case .interrupted = event { samples.fail(MeetingOwnerVoiceCaptureError.interrupted) }
            }, liveAudioHandler: nil)
        #else
        let runtime = try MeetingAVCaptureMicrophoneComponent(microphone: microphone,
            onSample: { sample in _ = samples.enqueue(sample) },
            onTerminalStop: { _ in samples.fail(MeetingOwnerVoiceCaptureError.interrupted) })
        #endif
        self.runtime = runtime
        do {
            try await runtime.start()
            try Task.checkCancellation()
        } catch {
            _ = try? await self.stop(discard: true)
            throw error
        }
    }

    /// Stop joins both the platform microphone and the admitted PCM work before
    /// callers may release the shared audio lease. Cancellation never bypasses this join.
    func stop(discard: Bool) async throws -> [Float] {
        self.samples.close()
        var failure: Error?
        if let runtime = self.runtime {
            do { try await runtime.stop() } catch { failure = error }
            self.runtime = nil
        }
        do { try await self.samples.finish() } catch { failure = failure ?? error }
        let result = self.samples.take(discard: discard || failure != nil)
        if let failure { throw failure }
        return result
    }
}

nonisolated enum MeetingOwnerVoiceCaptureError: LocalizedError {
    case interrupted
    var errorDescription: String? {
        PichiLocalization.text("Voice enrollment was interrupted. Please record a new sample.")
    }
}

/// At most 320,000 mono Float32 samples (1.22 MiB), plus the existing bounded
/// transport queue. A full sample is a normal completion, never a file fallback.
final nonisolated class MeetingOwnerVoiceSampleBuffer: MeetingMemoryAudioConsuming, @unchecked Sendable {
    private let lock = NSLock()
    private let queue = DispatchQueue(label: "voice.enrollment.pcm", qos: .userInitiated)
    private let producers = DispatchGroup()
    private let gate = MeetingPCMIntakeGate()
    private let converter: MeetingCapturePCMConverter
    private var accepting = true
    private var samples: [Float] = []
    private var failure: Error?
    static let maximumSamples = 320_000

    init() throws { self.converter = try MeetingCapturePCMConverter() }

    var capturedSeconds: Double { self.lock.withLock { Double(self.samples.count) / 16_000 } }

    func enqueue(_ sampleBuffer: CMSampleBuffer) -> Bool {
        let admitted = self.lock.withLock {
            guard self.accepting, self.failure == nil, self.samples.count < Self.maximumSamples else { return false }
            self.producers.enter()
            return true
        }
        // A completed 20s sample deliberately ignores remaining microphone callbacks.
        guard admitted else { return true }
        defer { self.producers.leave() }
        let frames = CMSampleBufferGetNumSamples(sampleBuffer)
        guard let description = CMSampleBufferGetFormatDescription(sampleBuffer),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description),
              let reservation = self.gate.reserve(frames: frames, channels: Int(asbd.pointee.mChannelsPerFrame),
                                                  sampleRate: asbd.pointee.mSampleRate)
        else { self.fail(MeetingCapturePCMError.invalidBuffer); return false }
        guard let owned = MeetingLiveSampleCopy.copy(sampleBuffer) else {
            self.gate.release(reservation)
            self.fail(MeetingCapturePCMError.invalidBuffer)
            return false
        }
        self.queue.async {
            defer { self.gate.release(reservation) }
            guard self.lock.withLock({ self.failure == nil }) else { return }
            do {
                if let converted = try self.converter.convert(owned.buffer, presentationTime: owned.pts) {
                    try self.append(converted)
                }
            } catch { self.fail(error) }
        }
        return true
    }

    func fail(_ error: Error) {
        self.lock.withLock { self.failure = self.failure ?? error; self.accepting = false }
        self.gate.close()
    }

    func checkFailure() throws {
        if let failure = self.lock.withLock({ self.failure }) { throw failure }
    }

    func close() { self.lock.withLock { self.accepting = false }; self.gate.close() }

    func finish() async throws {
        self.close()
        await withCheckedContinuation { continuation in
            self.producers.notify(queue: self.queue) { continuation.resume() }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            self.queue.async {
                do {
                    if let failure = self.lock.withLock({ self.failure }) { throw failure }
                    if let tail = try self.converter.finish() { try self.append(tail) }
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }

    func take(discard: Bool) -> [Float] {
        self.lock.withLock {
            defer { self.samples = [] }
            return discard ? [] : self.samples
        }
    }

    private func append(_ sampleBuffer: CMSampleBuffer) throws {
        guard let owned = MeetingLiveSampleCopy.copy(sampleBuffer),
              let pcm = owned.buffer.floatChannelData?[0] else { throw MeetingCapturePCMError.invalidBuffer }
        let count = Int(owned.buffer.frameLength)
        guard (0..<count).allSatisfy({ pcm[$0].isFinite }) else { throw MeetingCapturePCMError.nonFiniteSample }
        self.lock.withLock {
            let available = min(count, Self.maximumSamples - self.samples.count)
            if available > 0 { self.samples.append(contentsOf: UnsafeBufferPointer(start: pcm, count: available)) }
        }
    }
}
