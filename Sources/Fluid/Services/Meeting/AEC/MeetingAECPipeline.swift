@preconcurrency import AVFoundation
import CoreMedia
import Foundation

/// Serial-owner AEC3 streaming core. The runtime calls every method on the one shared SCK sample
/// queue, so extraction, joining, bridge calls, reset, and emission ordering cannot overlap.
final nonisolated class MeetingAECPipeline: @unchecked Sendable {
    private var joiner = MeetingAECStreamJoiner()
    private let processor: any MeetingAECProcessing
    let committer: MeetingAECOutputCommitter
    private let diagnosticObserver: (@Sendable (MeetingAECJoinedFrame, [Float], MeetingAECBridgeStatistics) -> Void)?
    private let fallbackObserver: @Sendable (MeetingAECFailure) -> Void
    private(set) var stopped = false
    /// Retry AEC on a new route, not on every callback while the current route is failing.
    private var fallbackFailure: MeetingAECFailure?

    init(
        processor: any MeetingAECProcessing,
        committer: MeetingAECOutputCommitter,
        diagnosticObserver: (@Sendable (MeetingAECJoinedFrame, [Float], MeetingAECBridgeStatistics) -> Void)? = nil,
        fallbackObserver: @escaping @Sendable (MeetingAECFailure) -> Void = { failure in
            DebugLogger.shared.warning(
                "aec_fallback reason=\(failure.rawValue) route=speaker targetProtection=unfiltered",
                source: "MeetingAECPipeline"
            )
        }
    ) {
        self.processor = processor
        self.committer = committer
        self.diagnosticObserver = diagnosticObserver
        self.fallbackObserver = fallbackObserver
    }

    func consumeRender(_ sampleBuffer: CMSampleBuffer, stream: MeetingAECStreamToken) {
        guard !self.stopped, self.fallbackFailure == nil else { return }
        switch MeetingAECPCMAdapter.extract(sampleBuffer, kind: .render, stream: stream) {
        case let .success(block):
            self.handle(self.joiner.append(block))
        case let .failure(failure):
            self.handleInputFailure(failure, currentRawCapture: nil)
        }
    }

    func consumeCapture(_ sampleBuffer: CMSampleBuffer, stream: MeetingAECStreamToken) {
        guard !self.stopped else { return }
        if self.fallbackFailure != nil {
            self.committer.commitUnfiltered(sampleBuffer)
            return
        }
        switch MeetingAECPCMAdapter.extract(sampleBuffer, kind: .capture, stream: stream) {
        case let .success(block):
            self.handle(self.joiner.append(block))
        case let .failure(failure):
            self.handleInputFailure(failure, currentRawCapture: sampleBuffer)
        }
    }

    /// Validates an armed callback without feeding it to a future epoch. The callback remains on
    /// the byte-identical raw path; AEC begins only with subsequent callbacks after both inputs pass.
    /// Returns the precise extraction failure so the armed gate demotes with the real cause.
    static func firstFormatFailure(
        _ sampleBuffer: CMSampleBuffer,
        kind: MeetingAECInputKind,
        stream: MeetingAECStreamToken
    ) -> MeetingAECFailure? {
        if case let .failure(failure) = MeetingAECPCMAdapter.extract(sampleBuffer, kind: kind, stream: stream) {
            return failure
        }
        return nil
    }

    func invalidate(
        reason: MeetingAECFailure,
        boundary: MeetingMicrophoneTranscriptGate.InvalidationBoundary?,
        preservingCapturedSpeech: Bool = false
    ) {
        guard !self.stopped else { return }
        self.flushPendingCapture(reason: reason, admit: false, retainOnly: preservingCapturedSpeech)
        if preservingCapturedSpeech { self.committer.finish() }
        else { self.committer.invalidateForExternalBoundary(boundary) }
        self.stopped = true
    }

    /// Echo uncertainty does not invalidate already captured speech. Route changes retire local
    /// authority before this flush; same-owner format validation can keep using its raw committer.
    func retireForEchoChange(retainOnly: Bool) {
        guard !self.stopped else { return }
        self.flushPendingCapture(reason: .streamChanged, admit: true, retainOnly: retainOnly)
        self.stopped = true
    }

    func stop(boundary: MeetingMicrophoneTranscriptGate.InvalidationBoundary?) {
        guard !self.stopped else { return }
        self.flushPendingCapture(reason: .stopped, admit: false, retainOnly: true)
        self.committer.finish()
        self.stopped = true
    }

    private func flushPendingCapture(reason: MeetingAECFailure, admit: Bool, retainOnly: Bool) {
        for emission in self.joiner.flush(reason: reason) {
            let samples: [Float]
            let time: CMTime
            switch emission {
            case let .paired(frame): samples = frame.capture.samples; time = frame.capture.presentationTime
            case let .bypass(slice, _): samples = slice.samples; time = slice.presentationTime
            case .reset: continue
            }
            guard let raw = MeetingAECPCMAdapter.synthesize(samples: samples, presentationTime: time) else {
                self.committer.failTerminal(.outputSynthesis)
                continue
            }
            if retainOnly { self.committer.retainPendingCapture(raw, unfiltered: true) }
            else if admit { self.committer.commitUnfiltered(raw) }
            else { self.committer.commitRaw(raw, failure: reason) }
        }
    }

    private func handleInputFailure(
        _ failure: MeetingAECFailure,
        currentRawCapture: CMSampleBuffer?
    ) {
        self.handle(self.joiner.flush(reason: failure))
        self.recordFallback(failure)
        if let currentRawCapture {
            self.committer.commitUnfiltered(currentRawCapture)
        }
    }

    private func handle(_ emissions: [MeetingAECJoinerEmission], allowFallback: Bool = true) {
        var flushRemainingCapture = false
        for emission in emissions {
            switch emission {
            case let .paired(joined):
                if self.fallbackFailure == nil {
                    if !self.process(joined, allowFallback: allowFallback) { flushRemainingCapture = true }
                } else {
                    self.commitRaw(joined.capture, failure: self.fallbackFailure ?? .bridgeProcessing, allowFallback: allowFallback)
                }
            case let .bypass(slice, failure):
                guard let raw = MeetingAECPCMAdapter.synthesize(
                    samples: slice.samples,
                    presentationTime: slice.presentationTime
                ) else {
                    self.committer.invalidateForExternalBoundary(nil)
                    continue
                }
                if allowFallback {
                    self.recordFallback(failure)
                    self.committer.commitUnfiltered(raw)
                } else {
                    self.committer.commitRaw(raw, failure: failure)
                }
            case let .reset(failure):
                if allowFallback, failure != .stopped { self.recordFallback(failure) }
            }
        }
        if flushRemainingCapture {
            self.handle(self.joiner.flush(reason: self.fallbackFailure ?? .bridgeProcessing), allowFallback: allowFallback)
        }
    }

    @discardableResult
    private func process(_ joined: MeetingAECJoinedFrame, allowFallback: Bool) -> Bool {
        do {
            let result = try self.processor.process(
                render: joined.render.samples,
                capture: joined.capture.samples
            )
            self.diagnosticObserver?(joined, result.samples, result.statistics)
            let mayPromote = joined.clockAttested
                && joined.pairedFrameCount > MeetingAECConstants.attestationFrames
            if !mayPromote {
                guard let raw = MeetingAECPCMAdapter.synthesize(
                    samples: joined.capture.samples, presentationTime: joined.capture.presentationTime
                ) else {
                    self.beginFallback(joined.capture, failure: .outputSynthesis, allowFallback: allowFallback)
                    return false
                }
                self.committer.commitUnfiltered(raw)
                return true
            }
            guard let output = MeetingAECPCMAdapter.synthesize(
                samples: result.samples,
                presentationTime: joined.capture.presentationTime
            ) else {
                self.beginFallback(joined.capture, failure: .outputSynthesis, allowFallback: allowFallback)
                return false
            }
            let original = MeetingAECPCMAdapter.synthesize(
                samples: joined.capture.samples, presentationTime: joined.capture.presentationTime
            )
            self.committer.commitProcessed(output, mayPromote: mayPromote, originalCapture: original)
            return true
        } catch let failure as MeetingAECFailure {
            self.beginFallback(joined.capture, failure: failure, allowFallback: allowFallback)
            return false
        } catch {
            self.beginFallback(joined.capture, failure: .bridgeProcessing, allowFallback: allowFallback)
            return false
        }
    }

    private func beginFallback(_ capture: MeetingAECFrame, failure: MeetingAECFailure, allowFallback: Bool) {
        self.recordFallback(failure, report: allowFallback)
        self.commitRaw(capture, failure: failure, allowFallback: allowFallback)
    }

    /// The existing route latch bounds support diagnostics to its first failure. Lifecycle flushes
    /// keep their original state transitions without being reported as a filtering failure.
    private func recordFallback(_ failure: MeetingAECFailure, report: Bool = true) {
        if report, failure != .stopped, self.fallbackFailure == nil {
            self.fallbackObserver(failure)
        }
        self.fallbackFailure = failure
    }

    private func commitRaw(_ capture: MeetingAECFrame, failure: MeetingAECFailure, allowFallback: Bool = true) {
        if let raw = MeetingAECPCMAdapter.synthesize(
            samples: capture.samples,
            presentationTime: capture.presentationTime
        ) {
            if allowFallback {
                self.committer.commitUnfiltered(raw)
            } else {
                self.committer.commitRaw(raw, failure: failure)
            }
        } else {
            self.committer.invalidateForExternalBoundary(nil)
        }
    }
}
