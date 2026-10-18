import Foundation

/// Optional live-input capability of the existing per-epoch diarizer. One owner sends every
/// sample, including silence, in order. Calls are joined and serial; a gap is never padded or
/// hidden. The owner must acknowledge activity only after all consumers release that prefix.
nonisolated protocol MeetingIncrementalNemotronDiarizerSession: MeetingNemotronDiarizerSession {
    func appendStreaming(_ samples: [Float], sourceStartSample: Int) async throws -> MeetingIncrementalDiarizationUpdate
    func finishStreaming(totalSamples: Int) async throws -> MeetingIncrementalDiarizationUpdate
    func discardActivity(beforeSample: Int) async throws
    /// Joins an admitted native call before releasing model state. No further input is valid.
    func cleanupStreaming() async
}

/// Activity is a non-destructive snapshot, not a delta. Open voices retain their real start
/// internally and are clipped to this retained window in the snapshot. The watermark covers
/// emitted 10 ms output only, excluding the model's still-buffered right context.
nonisolated struct MeetingIncrementalDiarizationUpdate: Equatable, Sendable {
    let activity: [MeetingNemotronSpeakerSegment]
    let acceptedThroughSample: Int
    let processedThroughSample: Int
    let retainedFromSample: Int
    let isFinal: Bool
}

nonisolated enum MeetingIncrementalDiarizationError: Error, Equatable {
    case invalidInput
    case nonContiguousInput
    case alreadyFinished
    case concurrentOperation
    case closed
    case activityCapacityExceeded
    case invalidWatermark
}

/// Exact source/output clocks shared by native input and model-free contract checks. No audio,
/// probabilities, model selection or persistence belongs here.
nonisolated struct MeetingIncrementalDiarizationClock {
    private(set) var acceptedThroughSample = 0
    private(set) var processedThroughSample = 0
    private(set) var retainedFromSample = 0
    private(set) var isFinal = false

    func validateAppend(sampleCount: Int, sourceStartSample: Int) throws {
        guard !self.isFinal else { throw MeetingIncrementalDiarizationError.alreadyFinished }
        guard sampleCount > 0, sampleCount <= 320_000,
              sampleCount <= Int.max - self.acceptedThroughSample else {
            throw MeetingIncrementalDiarizationError.invalidInput
        }
        guard sourceStartSample == self.acceptedThroughSample else {
            throw MeetingIncrementalDiarizationError.nonContiguousInput
        }
    }

    mutating func accept(sampleCount: Int, sourceStartSample: Int, outputFrameCount: Int) throws {
        try self.validateAppend(sampleCount: sampleCount, sourceStartSample: sourceStartSample)
        let accepted = self.acceptedThroughSample + sampleCount
        let processed = try Self.outputSample(outputFrameCount, accepted: accepted)
        guard processed >= self.processedThroughSample else { throw MeetingIncrementalDiarizationError.invalidWatermark }
        self.acceptedThroughSample = accepted
        self.processedThroughSample = processed
    }

    func validateFinish(totalSamples: Int) throws {
        guard !self.isFinal else { throw MeetingIncrementalDiarizationError.alreadyFinished }
        guard totalSamples == self.acceptedThroughSample else { throw MeetingIncrementalDiarizationError.nonContiguousInput }
    }

    mutating func finish(totalSamples: Int, outputFrameCount: Int) throws {
        try self.validateFinish(totalSamples: totalSamples)
        let processed = try Self.outputSample(outputFrameCount, accepted: totalSamples)
        guard processed == totalSamples else { throw MeetingIncrementalDiarizationError.invalidWatermark }
        self.processedThroughSample = processed
        self.isFinal = true
    }

    mutating func discard(beforeSample: Int) throws {
        guard beforeSample >= self.retainedFromSample, beforeSample <= self.processedThroughSample else {
            throw MeetingIncrementalDiarizationError.invalidWatermark
        }
        self.retainedFromSample = beforeSample
    }

    private static func outputSample(_ frameCount: Int, accepted: Int) throws -> Int {
        // The native frontend centers a 400-sample window in a 512-sample FFT. Its final
        // frame count is 1 + floor((N + 112) / 160), so an arbitrary Stop can emit TWO
        // extra frames when N % 160 >= 48. Integer decomposition avoids N + 112 overflow.
        // Keep the same exact frontend bound and clip padding out of acoustic coverage.
        let maximumFrames = accepted / 160 + 1 + (accepted % 160 + 112) / 160
        guard frameCount >= 0, frameCount <= Int.max / 160,
              frameCount <= maximumFrames else { throw MeetingIncrementalDiarizationError.invalidWatermark }
        return min(accepted, frameCount * 160)
    }
}
