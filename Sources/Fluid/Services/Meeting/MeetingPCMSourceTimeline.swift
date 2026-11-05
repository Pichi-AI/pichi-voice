import Foundation

/// Bounded scalar correspondence between compact inference PCM and measured meeting time.
/// Missing source packets are unknown time, never synthetic silence. Native evidence stays on
/// its original compact sample clock; publication and source VAD explicitly map its intervals.
final nonisolated class MeetingPCMSourceTimeline: @unchecked Sendable {
    enum Failure: Error, Equatable { case invalidConfiguration, invalidTimestamp, nonContiguousInput, spanBudgetExceeded }
    enum BoundarySide { case start, end }
    private struct Span {
        var compactStart: Int
        var compactEnd: Int
        var physicalStart: Double
        var physicalEnd: Double { physicalStart + Double(compactEnd - compactStart) / 16_000 }
    }
    private let lock = NSLock()
    private let originSeconds: Double
    private let maximumSpans: Int
    private var spans: [Span] = []
    private var acceptedThroughSample = 0
    private var lastPhysicalEnd: Double?
    private var observedGaps = false

    init(originSeconds: Double, maximumSpans: Int = 8_192) throws {
        guard originSeconds.isFinite, originSeconds >= 0, maximumSpans > 0, maximumSpans <= 8_192 else {
            throw Failure.invalidConfiguration
        }
        self.originSeconds = originSeconds
        self.maximumSpans = maximumSpans
    }

    /// Atomic admission before the transport owns this packet. True seals the preceding ASR
    /// window so speech separated by an absent source interval cannot become one hypothesis.
    @discardableResult
    func record(sourceStartSample: Int, frameCount: Int, presentationTime: Double) throws -> Bool {
        try self.lock.withLock {
            guard sourceStartSample == self.acceptedThroughSample, frameCount > 0,
                  frameCount <= Int.max - sourceStartSample else { throw Failure.nonContiguousInput }
            let physicalStart = presentationTime - self.originSeconds
            guard physicalStart.isFinite, physicalStart >= -1.0 / 16_000 else { throw Failure.invalidTimestamp }
            let measuredStart = max(0, physicalStart)
            let gap = self.lastPhysicalEnd.map { measuredStart - $0 } ?? measuredStart
            guard gap >= -1.0 / 16_000 - 1e-9 else { throw Failure.invalidTimestamp }
            let discontinuous = self.lastPhysicalEnd != nil && gap > 1.0 / 16_000 + 1e-9
            let coalesce = !discontinuous && self.spans.last?.compactEnd == sourceStartSample
            guard coalesce || self.spans.count < self.maximumSpans else { throw Failure.spanBudgetExceeded }
            let end = sourceStartSample + frameCount
            if coalesce {
                self.spans[self.spans.count - 1].compactEnd = end
            } else {
                self.spans.append(.init(compactStart: sourceStartSample, compactEnd: end, physicalStart: measuredStart))
            }
            self.acceptedThroughSample = end
            self.lastPhysicalEnd = measuredStart + Double(frameCount) / 16_000
            self.observedGaps = self.observedGaps || discontinuous
            return discontinuous
        }
    }

    /// At a compact boundary shared by two physical spans, start selects the later physical
    /// interval and end selects the earlier one. No lookup bridges an unknown source gap.
    func mapTime(_ seconds: Double, side: BoundarySide = .start) -> Double? {
        self.lock.withLock { self.mapTimeLocked(seconds, side: side) }
    }

    func mapEndTime(_ seconds: Double) -> Double? { self.mapTime(seconds, side: .end) }

    func mapInterval(start: Double, end: Double) -> (start: Double, end: Double)? {
        self.lock.withLock {
            guard start.isFinite, end.isFinite, start >= 0, end >= start else { return nil }
            if start == end, let mapped = self.mapTimeLocked(start, side: .start) { return (mapped, mapped) }
            let first = start * 16_000, last = end * 16_000
            guard let span = self.spans.first(where: {
                first >= Double($0.compactStart) - 1e-5 && first < Double($0.compactEnd) - 1e-5
                    && last <= Double($0.compactEnd) + 1e-5
            }) else { return nil }
            return (span.physicalStart + (first - Double(span.compactStart)) / 16_000,
                    span.physicalStart + (last - Double(span.compactStart)) / 16_000)
        }
    }

    /// The publication owner retires only intervals no pending word, preview or VAD query needs.
    /// Keep the terminal span until a successor exists, retaining the just-acknowledged end.
    func discard(beforeSample: Int) {
        self.lock.withLock {
            guard beforeSample > 0 else { return }
            let removable = self.spans.prefix { $0.compactEnd < beforeSample }.count
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
        return span.physicalStart + (sample - Double(span.compactStart)) / 16_000
    }
}
