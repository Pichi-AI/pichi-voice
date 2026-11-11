@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Bounded scalar correspondence between compact inference PCM and measured meeting time.
/// Missing source packets are unknown time, never synthetic silence. Inference stays on its
/// compact sample clock; publication maps native envelopes into the existing presentation-time
/// contract, while source VAD queries only measured contiguous intervals.
final nonisolated class MeetingPCMSourceTimeline: @unchecked Sendable {
    // Scalar history spans several protected inference windows. Resampling small native
    // packets can split each calibration span again, unlike a single packet/chunk mapping.
    // This remains a fixed bound (about 2.5 MiB of scalar spans per source).
    static let maximumRetainedSpans = 65_536
    enum Failure: String, Error, Equatable { case invalidConfiguration, invalidTimestamp, nonContiguousInput, spanBudgetExceeded }
    enum BoundarySide { case start, end }
    private struct Span {
        var compactStart: Double
        var compactEnd: Double
        var physicalStart: Double
        var physicalEnd: Double
        var discontinuityBefore: Bool
        func physicalTime(at sample: Double) -> Double {
            physicalStart + (sample - compactStart) / (compactEnd - compactStart) * (physicalEnd - physicalStart)
        }
    }
    private let lock = NSLock()
    private var originSeconds: Double?
    private let maximumSpans: Int
    private let recordingTimePolicy: MeetingRecordingTimePolicy?
    private var spans: [Span] = []
    private var acceptedThroughSample = 0
    private var lastPhysicalEnd: Double?
    private var lastHostEnd: MeetingMediaTime?
    private var observedGaps = false

    init(originSeconds: Double? = nil, maximumSpans: Int = MeetingPCMSourceTimeline.maximumRetainedSpans,
         recordingTimePolicy: MeetingRecordingTimePolicy? = nil) throws {
        guard originSeconds.map({ $0.isFinite && $0 >= 0 }) != false,
              maximumSpans > 0, maximumSpans <= Self.maximumRetainedSpans else {
            throw Failure.invalidConfiguration
        }
        self.originSeconds = originSeconds
        self.maximumSpans = maximumSpans
        self.recordingTimePolicy = recordingTimePolicy
    }

    /// Atomic admission before the transport owns this packet. True seals the preceding ASR
    /// window so speech separated by an absent source interval cannot become one hypothesis.
    @discardableResult
    func record(sourceStartSample: Int, frameCount: Int, presentationTime: Double,
                clockMapping: MeetingAudioClockMapping? = nil) throws -> Bool {
        try self.lock.withLock {
            guard self.recordingTimePolicy == nil || clockMapping != nil else { throw Failure.invalidTimestamp }
            guard sourceStartSample == self.acceptedThroughSample, frameCount > 0,
                  frameCount <= Int.max - sourceStartSample else { throw Failure.nonContiguousInput }
            guard presentationTime.isFinite, presentationTime >= 0 else { throw Failure.invalidTimestamp }
            // In-room capture and VAD share the first measured PCM origin. Online sources
            // are both bound to the attempt's fixed session origin instead.
            let origin = self.originSeconds ?? presentationTime
            let physicalStart = presentationTime - origin
            guard physicalStart.isFinite, physicalStart >= -1.0 / 16_000 else { throw Failure.invalidTimestamp }
            let measuredStart = max(0, physicalStart)
            let end = sourceStartSample + frameCount
            let additions: [Span]
            let discontinuous: Bool
            if let clockMapping {
                _ = try clockMapping.validated(expectedFrameCount: Int64(frameCount))
                additions = clockMapping.spans.map {
                    Span(compactStart: Double(sourceStartSample) + $0.frameStart,
                         compactEnd: Double(sourceStartSample) + $0.frameEnd,
                         physicalStart: $0.hostStart.seconds - origin,
                         physicalEnd: $0.hostEnd.seconds - origin,
                         discontinuityBefore: $0.discontinuityBefore)
                }
                let orderedBoundary: Bool
                if let previous = self.lastHostEnd, let first = clockMapping.spans.first?.hostStart {
                    orderedBoundary = MeetingAudioClockMapping.isOrderedBoundary(from: previous, to: first,
                        discontinuityBefore: clockMapping.spans.first?.discontinuityBefore == true)
                } else {
                    orderedBoundary = self.lastPhysicalEnd.map { previous in
                        additions.first.map { first in first.physicalStart >= previous - 1e-9
                            && (first.discontinuityBefore || abs(first.physicalStart - previous) <= 1e-9) } ?? false
                    } ?? true
                }
                guard let first = additions.first,
                      additions.allSatisfy({ $0.physicalStart >= -1e-9 }),
                      orderedBoundary
                else { throw Failure.invalidTimestamp }
                discontinuous = self.lastPhysicalEnd != nil && additions.first?.discontinuityBefore == true
            } else {
                let gap = self.lastPhysicalEnd.map { measuredStart - $0 } ?? measuredStart
                guard gap >= -1.0 / 16_000 - 1e-9 else { throw Failure.invalidTimestamp }
                discontinuous = self.lastPhysicalEnd != nil && gap > 1.0 / 16_000 + 1e-9
                additions = [Span(compactStart: Double(sourceStartSample), compactEnd: Double(end),
                                  physicalStart: measuredStart, physicalEnd: measuredStart + Double(frameCount) / 16_000,
                                  discontinuityBefore: discontinuous)]
            }
            var candidate = self.spans
            for span in additions {
                if clockMapping == nil, let last = candidate.last, !discontinuous,
                   last.compactEnd == span.compactStart {
                    // Metadata-free recordings keep the original nominal-span treatment of
                    // sub-sample timestamp residuals, including the historical span budget.
                    candidate[candidate.count - 1].compactEnd = span.compactEnd
                    candidate[candidate.count - 1].physicalEnd = last.physicalStart
                        + (span.compactEnd - last.compactStart) / 16_000
                } else if let last = candidate.last, !span.discontinuityBefore,
                   abs(last.compactEnd - span.compactStart) <= 1e-7,
                   abs(last.physicalEnd - span.physicalStart) <= 1e-9,
                   abs((last.physicalEnd - last.physicalStart) / (last.compactEnd - last.compactStart)
                       - (span.physicalEnd - span.physicalStart) / (span.compactEnd - span.compactStart)) <= 1e-12 {
                    candidate[candidate.count - 1].compactEnd = span.compactEnd
                    candidate[candidate.count - 1].physicalEnd = span.physicalEnd
                } else { candidate.append(span) }
            }
            guard candidate.count <= self.maximumSpans else { throw Failure.spanBudgetExceeded }
            self.originSeconds = origin
            self.spans = candidate
            self.acceptedThroughSample = end
            self.lastPhysicalEnd = additions.last?.physicalEnd
            self.lastHostEnd = clockMapping?.spans.last?.hostEnd
            self.observedGaps = self.observedGaps || discontinuous || additions.dropFirst().contains(where: { $0.discontinuityBefore })
            return discontinuous
        }
    }

    /// At a compact boundary shared by two physical spans, start selects the later physical
    /// interval and end selects the earlier one. No lookup bridges an unknown source gap.
    func mapTime(_ seconds: Double, side: BoundarySide = .start) -> Double? {
        self.lock.withLock { self.mapTimeLocked(seconds, side: side) }
    }

    func mapEndTime(_ seconds: Double) -> Double? { self.mapTime(seconds, side: .end) }

    /// Map only measured PCM between two joined source cursors. Never fill a physical
    /// gap, and never include audio beyond the protected compact-source watermark.
    func measuredIntervals(fromSample: Int, throughSample: Int) throws -> [Range<Double>] {
        try self.lock.withLock {
            guard fromSample >= 0, throughSample >= fromSample,
                  throughSample <= self.acceptedThroughSample else { throw Failure.nonContiguousInput }
            return self.spans.compactMap { span in
                let start = max(Double(fromSample), span.compactStart)
                let end = min(Double(throughSample), span.compactEnd)
                guard end > start else { return nil }
                let lower = span.physicalTime(at: start)
                let upper = span.physicalTime(at: end)
                return lower..<upper
            }
        }
    }

    func mapInterval(start: Double, end: Double) -> (start: Double, end: Double)? {
        self.lock.withLock {
            guard start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
            if start == end, let mapped = self.mapTimeLocked(start, side: .start) { return (mapped, mapped) }
            let first = start * 16_000, last = end * 16_000
            let covered = self.spans.filter { $0.compactEnd > first + 1e-5 && $0.compactStart < last - 1e-5 }
            guard let initial = covered.first, let terminal = covered.last,
                  first >= initial.compactStart - 1e-5, last <= terminal.compactEnd + 1e-5,
                  !covered.dropFirst().contains(where: { $0.discontinuityBefore }) else { return nil }
            return (initial.physicalTime(at: first), terminal.physicalTime(at: last))
        }
    }

    /// The publication owner retires only intervals no pending word, preview or VAD query needs.
    /// Keep the terminal span until a successor exists, retaining the just-acknowledged end.
    func discard(beforeSample: Int) {
        self.lock.withLock {
            guard beforeSample > 0 else { return }
            let removable = self.spans.prefix { $0.compactEnd < Double(beforeSample) }.count
            if removable > 0 { self.spans.removeFirst(min(removable, max(0, self.spans.count - 1))) }
        }
    }

    var hasGaps: Bool { self.lock.withLock { self.observedGaps } }
    var retainedSpanCount: Int { self.lock.withLock { self.spans.count } }

    private func mapTimeLocked(_ seconds: Double, side: BoundarySide) -> Double? {
        guard seconds.isFinite, seconds >= 0 else { return nil }
        let sample = seconds * 16_000
        let matches: (Span) -> Bool = {
            sample >= Double($0.compactStart) - 1e-5 && sample <= Double($0.compactEnd) + 1e-5
        }
        let span = side == .start ? self.spans.last(where: matches) : self.spans.first(where: matches)
        guard let span else { return nil }
        return span.physicalTime(at: sample)
    }
}

// MARK: - Shared frame-to-host correspondence

extension MeetingAudioClockMapping {
    enum Failure: Error, Equatable { case invalidMapping, spanBudgetExceeded }
    enum BoundarySide { case start, end }
    static let maximumSpans = 8_192

    /// Preserve the existing one-nanosecond rounding allowance using rational clock values.
    /// Subtracting large absolute Double uptimes can turn exactly 1 ns into 1.0186 ns.
    static func isOrderedBoundary(from previous: MeetingMediaTime, to next: MeetingMediaTime,
                                  discontinuityBefore: Bool) -> Bool {
        guard previous.timescale > 0, next.timescale > 0 else { return false }
        let delta = CMTimeSubtract(CMTime(value: next.value, timescale: next.timescale),
                                   CMTime(value: previous.value, timescale: previous.timescale))
        guard delta.isNumeric, delta >= CMTime(value: -1, timescale: 1_000_000_000) else { return false }
        return discontinuityBefore || delta <= CMTime(value: 1, timescale: 1_000_000_000)
    }

    @discardableResult
    func validated(expectedFrameCount: Int64? = nil) throws -> Self {
        guard self.version == 1, self.frameCount >= 0, self.frameCount <= Int64(1 << 52),
              expectedFrameCount.map({ $0 == self.frameCount }) ?? true,
              self.spans.count <= Self.maximumSpans else { throw Failure.invalidMapping }
        if self.frameCount == 0 {
            guard self.spans.isEmpty else { throw Failure.invalidMapping }
            return self
        }
        guard !self.spans.isEmpty else { throw Failure.invalidMapping }
        var frameEnd: Double = 0
        var hostEnd: MeetingMediaTime?
        for span in self.spans {
            guard span.frameStart.isFinite, span.frameEnd.isFinite,
                  abs(span.frameStart - frameEnd) <= 1e-7, span.frameEnd > span.frameStart,
                  span.frameEnd <= Double(self.frameCount) + 1e-7,
                  span.hostStart.timescale > 0, span.hostEnd.timescale > 0,
                  span.hostStart.value >= 0, span.hostEnd.value >= 0,
                  span.hostStart.seconds.isFinite, span.hostEnd.seconds.isFinite,
                  span.hostEnd.seconds < Double(Int64.max) / 1_000_000_000 - 1,
                  span.hostEnd.seconds > span.hostStart.seconds,
                  hostEnd.map({ Self.isOrderedBoundary(from: $0, to: span.hostStart,
                      discontinuityBefore: span.discontinuityBefore) }) ?? true
            else { throw Failure.invalidMapping }
            frameEnd = span.frameEnd; hostEnd = span.hostEnd
        }
        guard abs(frameEnd - Double(self.frameCount)) <= 1e-7 else { throw Failure.invalidMapping }
        return self
    }

    func hostTime(atFrame frame: Double, side: BoundarySide = .start) -> MeetingMediaTime? {
        guard frame.isFinite, frame >= 0, frame <= Double(self.frameCount),
              (try? self.validated()) != nil else { return nil }
        let predicate: (MeetingAudioClockSpan) -> Bool = { frame >= $0.frameStart - 1e-7 && frame <= $0.frameEnd + 1e-7 }
        let span = side == .start ? self.spans.last(where: predicate) : self.spans.first(where: predicate)
        guard let span else { return nil }
        return Self.mediaTime(span.hostStart.seconds + (frame - span.frameStart) / (span.frameEnd - span.frameStart)
                              * (span.hostEnd.seconds - span.hostStart.seconds))
    }

    func frame(atHostTime hostTime: MeetingMediaTime, side: BoundarySide = .start) -> Double? {
        guard hostTime.timescale > 0, hostTime.value >= 0, (try? self.validated()) != nil else { return nil }
        let time = hostTime.seconds
        let predicate: (MeetingAudioClockSpan) -> Bool = { time >= $0.hostStart.seconds - 1e-9 && time <= $0.hostEnd.seconds + 1e-9 }
        let span = side == .start ? self.spans.last(where: predicate) : self.spans.first(where: predicate)
        guard let span else { return nil }
        return span.frameStart + (time - span.hostStart.seconds) / (span.hostEnd.seconds - span.hostStart.seconds)
            * (span.frameEnd - span.frameStart)
    }

    /// Slice measured frames and optionally express the same interval in a new integer frame extent.
    /// This handles fractional native positions at resampler boundaries without fabricating PCM.
    func sliced(frames: Range<Double>, outputFrameCount: Int64? = nil) throws -> Self {
        _ = try self.validated()
        guard frames.lowerBound.isFinite, frames.upperBound.isFinite,
              frames.lowerBound >= 0, frames.upperBound > frames.lowerBound,
              frames.upperBound <= Double(self.frameCount) + 1e-7 else { throw Failure.invalidMapping }
        let width = frames.upperBound - frames.lowerBound
        let count: Int64
        if let outputFrameCount { count = outputFrameCount }
        else {
            guard width <= Double(Int64.max), abs(width - width.rounded()) <= 1e-7 else { throw Failure.invalidMapping }
            count = Int64(width.rounded())
        }
        guard count > 0 else { throw Failure.invalidMapping }
        let scale = Double(count) / width
        var spans: [MeetingAudioClockSpan] = []
        for span in self.spans {
            let lower = max(frames.lowerBound, span.frameStart)
            let upper = min(frames.upperBound, span.frameEnd)
            guard upper > lower else { continue }
            let slope = (span.hostEnd.seconds - span.hostStart.seconds) / (span.frameEnd - span.frameStart)
            spans.append(.init(frameStart: (lower - frames.lowerBound) * scale,
                               frameEnd: (upper - frames.lowerBound) * scale,
                               hostStart: Self.mediaTime(span.hostStart.seconds + (lower - span.frameStart) * slope),
                               hostEnd: Self.mediaTime(span.hostStart.seconds + (upper - span.frameStart) * slope),
                               discontinuityBefore: span.discontinuityBefore && abs(lower - span.frameStart) <= 1e-7))
        }
        return try Self(frameCount: count, spans: spans).validated()
    }

    func appending(_ other: Self) throws -> Self {
        _ = try self.validated(); _ = try other.validated()
        let (count, overflow) = self.frameCount.addingReportingOverflow(other.frameCount)
        guard !overflow else { throw Failure.invalidMapping }
        var result = self.spans
        for var span in other.spans {
            span.frameStart += Double(self.frameCount); span.frameEnd += Double(self.frameCount)
            if let last = result.last, !span.discontinuityBefore,
               abs(last.hostEnd.seconds - span.hostStart.seconds) <= 1e-9,
               abs((last.hostEnd.seconds - last.hostStart.seconds) / (last.frameEnd - last.frameStart)
                   - (span.hostEnd.seconds - span.hostStart.seconds) / (span.frameEnd - span.frameStart)) <= 1e-12 {
                result[result.count - 1].frameEnd = span.frameEnd
                result[result.count - 1].hostEnd = span.hostEnd
            } else { result.append(span) }
        }
        guard result.count <= Self.maximumSpans else { throw Failure.spanBudgetExceeded }
        return try Self(frameCount: count, spans: result).validated()
    }

    static func mediaTime(_ seconds: Double) -> MeetingMediaTime {
        guard seconds.isFinite, seconds >= 0, seconds < Double(Int64.max) / 1_000_000_000 - 1 else {
            return MeetingMediaTime(value: 0, timescale: 0)
        }
        return MeetingMediaTime(value: Int64((seconds * 1_000_000_000).rounded()), timescale: 1_000_000_000)
    }
}

/// An immutable, frame-bound timing attachment. It carries acquisition correspondence only;
/// microphone permission always remains with the session's existing admission owner.
nonisolated enum MeetingCaptureClockMetadata {
    enum Failure: LocalizedError, Equatable {
        case invalidBuffer, contextMismatch
        var errorDescription: String? { PichiLocalization.text("Audio timing could not be verified.") }
    }
    struct Packet: Codable, Sendable, Equatable {
        let mapping: MeetingAudioClockMapping
        let clockID: UUID
        let sourceID: UUID
        let producerEpoch: UInt64

        func sliced(frames: Range<Double>) throws -> Self {
            .init(mapping: try self.mapping.sliced(frames: frames), clockID: self.clockID,
                  sourceID: self.sourceID, producerEpoch: self.producerEpoch)
        }

        func appending(_ next: Self) throws -> Self {
            guard self.clockID == next.clockID, self.sourceID == next.sourceID,
                  self.producerEpoch == next.producerEpoch else { throw Failure.contextMismatch }
            return .init(mapping: try self.mapping.appending(next.mapping), clockID: self.clockID,
                         sourceID: self.sourceID, producerEpoch: self.producerEpoch)
        }
    }
    private final class Box: NSObject {
        let packet: Packet
        let pts: CMTime
        let sampleRate: Double
        init(_ packet: Packet, pts: CMTime, sampleRate: Double) {
            self.packet = packet; self.pts = pts; self.sampleRate = sampleRate
        }
    }
    private static let key = "ai.pichi.voice.captureClockMapping.v1" as CFString

    static func attach(mapping: MeetingAudioClockMapping, clockID: UUID, sourceID: UUID,
                       producerEpoch: UInt64, to sample: CMSampleBuffer) throws {
        let frames = CMSampleBufferGetNumSamples(sample)
        guard frames > 0, CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              asbd.mSampleRate.isFinite, asbd.mSampleRate > 0,
              CMSampleBufferGetPresentationTimeStamp(sample).isNumeric else { throw Failure.invalidBuffer }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        _ = try mapping.validated(expectedFrameCount: Int64(frames))
        let packet = Packet(mapping: mapping, clockID: clockID, sourceID: sourceID, producerEpoch: producerEpoch)
        if let existing = CMGetAttachment(sample, key: self.key, attachmentModeOut: nil) {
            guard let box = existing as? Box, box.packet == packet, box.pts == pts,
                  box.sampleRate == asbd.mSampleRate else { throw Failure.contextMismatch }
            return
        }
        CMSetAttachment(sample, key: self.key, value: Box(packet, pts: pts, sampleRate: asbd.mSampleRate), attachmentMode: kCMAttachmentMode_ShouldPropagate)
    }

    static func read(from sample: CMSampleBuffer) -> Packet? {
        guard let box = CMGetAttachment(sample, key: self.key, attachmentModeOut: nil) as? Box,
              CMSampleBufferIsValid(sample), CMSampleBufferDataIsReady(sample),
              let description = CMSampleBufferGetFormatDescription(sample),
              let asbd = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
              box.sampleRate == asbd.mSampleRate, box.pts == CMSampleBufferGetPresentationTimeStamp(sample),
              (try? box.packet.mapping.validated(expectedFrameCount: Int64(CMSampleBufferGetNumSamples(sample)))) != nil
        else { return nil }
        return box.packet
    }

    static func copyExact(from source: CMSampleBuffer, to target: CMSampleBuffer) throws {
        guard let packet = self.read(from: source),
              CMSampleBufferGetNumSamples(source) == CMSampleBufferGetNumSamples(target),
              CMSampleBufferGetPresentationTimeStamp(source) == CMSampleBufferGetPresentationTimeStamp(target),
              let first = CMSampleBufferGetFormatDescription(source), let second = CMSampleBufferGetFormatDescription(target),
              let sourceASBD = CMAudioFormatDescriptionGetStreamBasicDescription(first)?.pointee,
              let targetASBD = CMAudioFormatDescriptionGetStreamBasicDescription(second)?.pointee,
              sourceASBD.mSampleRate == targetASBD.mSampleRate else { throw Failure.invalidBuffer }
        try self.attach(mapping: packet.mapping, clockID: packet.clockID, sourceID: packet.sourceID,
                        producerEpoch: packet.producerEpoch, to: target)
    }
}
