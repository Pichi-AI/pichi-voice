import AVFoundation
import CoreMedia
import Foundation
import os

nonisolated struct PichiMeetingCaptionRecognition: Sendable {
    let text: String
    let endOfUtteranceProbability: Float?
    let words: [ASRWordTiming]
    let segmentTimings: [ASRSegmentTiming]

    init(text: String, endOfUtteranceProbability: Float?, words: [ASRWordTiming] = [],
         segmentTimings: [ASRSegmentTiming] = []) {
        self.text = text
        self.endOfUtteranceProbability = endOfUtteranceProbability
        self.words = words
        self.segmentTimings = segmentTimings
    }

    /// A growing input buffer is not word coverage. Preserve actual provider
    /// intervals when present; otherwise show the hypothesis without retiring waves.
    func nativeCoverage(sampleCount: Int, sampleRate: Double) -> Range<TimeInterval>? {
        guard sampleCount > 0, sampleRate.isFinite, sampleRate > 0,
              self.words.count <= 8192, self.segmentTimings.count <= 8192 else { return nil }
        let duration = Double(sampleCount) / sampleRate
        let wordSegments = self.words.map { ASRSegmentTiming(text: $0.text, start: $0.start, end: $0.end) }
        let words = ASRSegmentTiming.validated(wordSegments, text: self.text, duration: duration)
        let intervals = words.isEmpty
            ? ASRSegmentTiming.validated(self.segmentTimings, text: self.text, duration: duration) : words
        guard let first = intervals.first, let last = intervals.last else { return nil }
        return first.start..<last.end
    }

    /// A forced buffer rotation needs a closed word and real acoustic space before its
    /// successor. Never guess a split from character counts or provider token pieces.
    func rotation(sampleCount: Int, sampleRate: Double) -> (text: String, sample: Int)? {
        guard sampleCount > 0, sampleRate.isFinite, sampleRate > 0,
              self.words.count > 1, self.words.count <= 8192 else { return nil }
        var cursor = self.text.startIndex
        var ranges: [Range<String.Index>] = []
        var previousEnd = 0.0
        let duration = Double(sampleCount) / sampleRate
        for word in self.words {
            let body = word.text.trimmingCharacters(in: .whitespacesAndNewlines)
            while cursor < self.text.endIndex, self.text[cursor].isWhitespace {
                cursor = self.text.index(after: cursor)
            }
            guard !body.isEmpty, word.start.isFinite, word.end.isFinite,
                  word.start >= previousEnd, word.end > word.start, word.end <= duration,
                  let range = self.text.range(of: body, options: .anchored, range: cursor..<self.text.endIndex)
            else { return nil }
            ranges.append(range)
            cursor = range.upperBound
            previousEnd = word.end
        }
        guard self.text[cursor...].allSatisfy(\.isWhitespace) else { return nil }
        for index in (0..<(self.words.count - 1)).reversed() {
            let word = self.words[index]
            let successor = self.words[index + 1]
            let separator = self.text[ranges[index].upperBound..<ranges[index + 1].lowerBound]
            guard word.end <= duration - 1, !separator.isEmpty,
                  separator.allSatisfy(\.isWhitespace), successor.start >= word.end else { continue }
            let sample = Int(((word.end + successor.start) * 0.5 * sampleRate).rounded(.down))
            guard sample >= 5600, sample < sampleCount else { continue }
            return (String(self.text[..<ranges[index].upperBound]).trimmingCharacters(in: .whitespacesAndNewlines), sample)
        }
        return nil
    }
}

/// One shared, serialized model capability; each capture track owns its own audio/turn buffers.
nonisolated protocol PichiMeetingCaptionRecognizing: Sendable {
    func prepare() async throws
    func recognize(_ samples: [Float]) async throws -> PichiMeetingCaptionRecognition
    func recognizeWithWordTimings(_ samples: [Float]) async throws -> PichiMeetingCaptionRecognition
    func unload() async
}

extension PichiMeetingCaptionRecognizing {
    func recognizeWithWordTimings(_ samples: [Float]) async throws -> PichiMeetingCaptionRecognition {
        try await self.recognize(samples)
    }
}

/// Both online-call tracks share this provider, so loading live captions retains one set of
/// weights. Partial captions are periodic batch hypotheses, then replaced by the final pipeline.
@MainActor
final class PichiMeetingCaptionRecognizer: PichiMeetingCaptionRecognizing {
    private let configuration: MeetingFinalProcessingConfiguration?
    private var provider: (any TranscriptionProvider)?
    private var preparation: Task<Void, Error>?
    private var isStopped = false
    private var inference: Task<PichiMeetingCaptionRecognition, Error>?

    /// Install the input owners synchronously before capture can offer its first packet.
    /// Provider construction remains on its existing main-actor preparation boundary.
    nonisolated init(configuration: MeetingFinalProcessingConfiguration) {
        self.configuration = configuration
    }

    /// A fixed provider can be supplied by an existing composition boundary or deterministic test.
    /// This recognizer owns its preparation and joined release; it must not borrow another owner's runtime.
    init(provider: any TranscriptionProvider) {
        self.configuration = nil
        self.provider = provider
    }

    @MainActor func prepare() async throws {
        guard !self.isStopped else { throw CancellationError() }
        if let preparation {
            try await withTaskCancellationHandler {
                try await preparation.value
                try Task.checkCancellation()
            } onCancel: {
                preparation.cancel()
            }
            return
        }
        let preparation = Task { @MainActor in
            try Task.checkCancellation()
            if self.provider == nil, let configuration = self.configuration {
                self.provider = try PichiMeetingProviderFactory.make(configuration)
            }
            guard !self.isStopped, let provider = self.provider else { throw CancellationError() }
            try Task.checkCancellation()
            try await provider.prepare(progressHandler: nil)
            DebugLogger.shared.info("Buffered caption provider prepared; backend=\(provider.executionStatus?.backend.rawValue ?? "unreported")",
                source: "PichiMeetingCaptionRecognizer")
        }
        self.preparation = preparation
        try await withTaskCancellationHandler {
            try await preparation.value
            try Task.checkCancellation()
        } onCancel: {
            preparation.cancel()
        }
    }

    @MainActor func recognize(_ samples: [Float]) async throws -> PichiMeetingCaptionRecognition {
        try await self.recognize(samples, wordTimings: false)
    }

    @MainActor func recognizeWithWordTimings(_ samples: [Float]) async throws -> PichiMeetingCaptionRecognition {
        try await self.recognize(samples, wordTimings: true)
    }

    private func recognize(_ samples: [Float], wordTimings: Bool) async throws -> PichiMeetingCaptionRecognition {
        guard !self.isStopped, let provider else { throw CancellationError() }
        let previous = self.inference
        let work = Task { @MainActor in
            _ = await previous?.result
            try Task.checkCancellation()
            if wordTimings, provider.supportsWordTimings {
                let output = try await provider.transcribeWithWordTimings(samples)
                return PichiMeetingCaptionRecognition(text: output.result.text,
                    endOfUtteranceProbability: output.result.endOfUtteranceProbability, words: output.words,
                    segmentTimings: output.result.segmentTimings)
            }
            let result = try await provider.transcribeStreaming(samples)
            return PichiMeetingCaptionRecognition(text: result.text, endOfUtteranceProbability: result.endOfUtteranceProbability,
                segmentTimings: result.segmentTimings)
        }
        self.inference = work
        return try await withTaskCancellationHandler {
            try await work.value
        } onCancel: {
            work.cancel()
        }
    }

    /// Called once by the coordinator after both track workers have drained.
    @MainActor func unload() async {
        self.isStopped = true
        self.preparation?.cancel()
        _ = await self.preparation?.result
        self.preparation = nil
        self.inference?.cancel()
        _ = await self.inference?.result
        self.inference = nil
        await self.provider?.releaseResidency()
        self.provider = nil
    }
}

/// The capture callback can invalidate an era even while the actor is suspended in inference.
final nonisolated class PichiMeetingCaptionInputEpoch: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UInt64 = 0
    private var latestOfferedEnd: TimeInterval?
    var current: UInt64 { self.lock.withLock { self.value } }

    /// Capture does constant work: stamp one scalar and obtain its era atomically. Use the
    /// latest offered clock, not an all-time maximum, so backward clock resets remain valid.
    func recordOffer(end: CMTime) -> UInt64 {
        self.lock.withLock {
            if end.isNumeric, end.seconds.isFinite { self.latestOfferedEnd = end.seconds }
            return self.value
        }
    }

    func latestEnd(in epoch: UInt64) -> TimeInterval? {
        self.lock.withLock { self.value == epoch ? self.latestOfferedEnd : nil }
    }

    func advance() {
        self.lock.withLock { self.value &+= 1; self.latestOfferedEnd = nil }
    }
}

/// Buffered captions for the retained-files path. Copied PCM crosses a bounded I/O handoff
/// into an anonymous disk FIFO, so preparation/inference cannot evict opening speech.
/// Memory-only/protected streaming recordings use their existing separate PCM owner.
/// Resampling, inference and endpointing run on this actor.
actor PichiMeetingBufferedTrackEngine {
    typealias PartialHandler = @Sendable (MeetingAudioTrackKind, UUID, String, CMTime, CMTime) -> Void
    typealias UtteranceHandler = @Sendable (MeetingAudioTrackKind, UUID, String, CMTime, CMTime) -> Void
    typealias DegradedHandler = @Sendable (MeetingAudioTrackKind, String) -> Void
    typealias ReadyHandler = @Sendable (MeetingAudioTrackKind) -> Void

    private typealias Input = MeetingLiveAudioFIFO.Input
    private nonisolated let queue = MeetingLiveAudioFIFO()
    private nonisolated let inputEpoch = PichiMeetingCaptionInputEpoch()
    private var activeInputEpoch: UInt64?
    private static let sampleRate: Double = 16_000
    private static let blockSamples = 1600
    private static let minimumTurnSamples = 5600
    private static let partialIntervalSamples = 20_000
    /// Two capture blocks plus drain-polling tolerance. Final turns always take priority
    /// over redecoding an obsolete prefix while queued PCM is farther ahead.
    private static let maximumPartialBacklogSeconds = 0.25
    private static let maximumTurnSamples = 320_000
    private static let preRollSamples = 2400
    private static let pauseSamples = 11_200
    /// A conservative energy gate avoids decoding pure silence. It is not speaker/VAD evidence.
    private static let energyThreshold: Float = 0.006
    private static let eouThreshold: Float = 0.5

    private let kind: MeetingAudioTrackKind
    private let recognizer: any PichiMeetingCaptionRecognizing
    private let targetFormat = AVAudioFormat(
        commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false
        // This fixed valid PCM format is the app's existing ASR contract.
        // swiftlint:disable:next force_unwrapping
    )!
    private var converter: AVAudioConverter?
    private var converterSourceFormat: AVAudioFormat?
    private var loadTask: Task<Void, Never>?
    private var drainTask: Task<Void, Never>?
    private var isReady = false
    private var hasStarted = false
    private var isStopped = false
    private var generation = 0
    private var preRoll: [Float] = []
    private var samples: [Float] = []
    private var quietSamples = 0
    private var lastRecognitionSampleCount = 0
    private var lastRecognition: PichiMeetingCaptionRecognition?
    private var turnID: UUID?
    private var startPTS: CMTime?
    private var endPTS: CMTime?
    private var lastBufferEndPTS: CMTime?
    private var onPartial: PartialHandler?
    private var onUtterance: UtteranceHandler?
    private var onDegraded: DegradedHandler?
    private var onReady: ReadyHandler?

    init(kind: MeetingAudioTrackKind, recognizer: any PichiMeetingCaptionRecognizing) {
        self.kind = kind
        self.recognizer = recognizer
    }

    func configure(
        onPartial: @escaping PartialHandler,
        onUtterance: @escaping UtteranceHandler,
        onDegraded: @escaping DegradedHandler,
        onReady: @escaping ReadyHandler
    ) {
        guard !self.isStopped else { return }
        self.onPartial = onPartial
        self.onUtterance = onUtterance
        self.onDegraded = onDegraded
        self.onReady = onReady
    }

    func start() {
        guard !self.hasStarted, !self.isStopped else { return }
        self.hasStarted = true
        self.loadTask = Task { [weak self] in
            guard let self else { return }
            let started = ContinuousClock.now
            do {
                try await self.recognizer.prepare()
                try Task.checkCancellation()
                await self.markReady()
                DebugLogger.shared.info("Buffered captions prepared in \(started.duration(to: .now)); track=\(self.kind.rawValue)",
                    source: "PichiMeetingBufferedTrackEngine")
            } catch {
                guard !Task.isCancelled else { return }
                await self.markLoadFailed(error)
            }
        }
        self.drainTask = Task { [weak self] in await self?.drainLoop() }
    }

    nonisolated func offer(_ sample: MeetingLiveSampleCopy.Sample) {
        let epoch = self.inputEpoch.recordOffer(end: sample.pts + sample.duration)
        self.queue.enqueue(Input(sample: sample, epoch: epoch))
    }

    /// Synchronous capture-era barrier. Old queued/batched PCM and late inference are discarded.
    nonisolated func requestReset() { self.inputEpoch.advance() }

    func reset() {
        self.clearTurn()
        self.preRoll.removeAll(keepingCapacity: true)
        self.lastBufferEndPTS = nil
    }

    func stop() async {
        self.isStopped = true
        self.generation &+= 1
        self.loadTask?.cancel()
        self.drainTask?.cancel()
        await self.queue.close()
        await self.loadTask?.value
        await self.drainTask?.value
        self.loadTask = nil
        self.drainTask = nil
        self.isReady = false
        self.clearTurn()
        self.preRoll.removeAll()
        self.converter = nil
        self.onPartial = nil
        self.onUtterance = nil
        self.onDegraded = nil
        self.onReady = nil
    }

    private func markReady() {
        guard !self.isStopped else { return }
        self.isReady = true
        self.onReady?(self.kind)
    }

    private func markLoadFailed(_ error: Error) async {
        guard !self.isStopped else { return }
        self.drainTask?.cancel()
        await self.queue.close()
        guard !self.isStopped else { return }
        self.onDegraded?(self.kind, "Buffered captions could not load: \(error.localizedDescription)")
    }

    private func drainLoop() async {
        while !Task.isCancelled {
            guard self.isReady else {
                try? await Task.sleep(nanoseconds: 100_000_000)
                continue
            }
            let dropped = self.queue.takeDroppedCount()
            if dropped > 0 {
                self.reset()
                self.onDegraded?(self.kind, "Live captions dropped audio and resynced. The recording is preserved.")
            }
            let batch: [Input]
            do {
                batch = try await self.queue.drainBatch()
            } catch {
                guard !Task.isCancelled, !self.isStopped else { return }
                let reason = (error as? MeetingLiveAudioFIFO.Failure)?.rawValue ?? "storageUnavailable"
                DebugLogger.shared.warning("Caption input paused; reason=\(reason); track=\(self.kind.rawValue)",
                    source: "PichiMeetingBufferedTrackEngine")
                self.onDegraded?(self.kind, "Live caption buffering failed. The recording is preserved.")
                await self.queue.close()
                return
            }
            guard !batch.isEmpty else {
                try? await Task.sleep(nanoseconds: 20_000_000)
                continue
            }
            for input in batch where !Task.isCancelled {
                await self.consume(input)
            }
        }
    }

    private func consume(_ input: Input) async {
        guard input.epoch == self.inputEpoch.current else { return }
        if self.activeInputEpoch != input.epoch {
            self.reset()
            self.activeInputEpoch = input.epoch
        }
        let sample = input.sample
        guard !self.isStopped, let converted = self.convert(sample.buffer), !converted.isEmpty else { return }
        if let previous = self.lastBufferEndPTS,
           abs((sample.pts - previous).seconds) > 0.25 {
            self.reset()
        }
        self.lastBufferEndPTS = sample.pts + sample.duration
        var offset = 0
        while offset < converted.count {
            guard !Task.isCancelled, !self.isStopped, input.epoch == self.inputEpoch.current else { return }
            let room = Self.maximumTurnSamples - self.samples.count
            let upper = min(converted.count, offset + min(Self.blockSamples, max(1, room)))
            let block = Array(converted[offset..<upper])
            let start = sample.pts + CMTime(
                seconds: sample.duration.seconds * Double(offset) / Double(converted.count),
                preferredTimescale: 1_000_000_000
            )
            let end = sample.pts + CMTime(
                seconds: sample.duration.seconds * Double(upper) / Double(converted.count),
                preferredTimescale: 1_000_000_000
            )
            await self.consumeBlock(block, start: start, end: end)
            offset = upper
        }
    }

    private func consumeBlock(_ block: [Float], start: CMTime, end: CMTime) async {
        guard block.allSatisfy(\.isFinite) else { self.reset(); return }
        let squareMean = block.reduce(Float(0)) { $0 + $1 * $1 } / Float(block.count)
        let active = squareMean.squareRoot() >= Self.energyThreshold
        if self.turnID == nil {
            guard active else {
                self.preRoll.append(contentsOf: block)
                self.preRoll = Array(self.preRoll.suffix(Self.preRollSamples))
                return
            }
            self.turnID = UUID()
            self.startPTS = start - CMTime(seconds: Double(self.preRoll.count) / Self.sampleRate, preferredTimescale: 16_000)
            self.samples = self.preRoll
            self.preRoll.removeAll(keepingCapacity: true)
        }
        self.samples.append(contentsOf: block)
        self.endPTS = end
        self.quietSamples = active ? 0 : self.quietSamples + block.count
        let shouldFinish = self.quietSamples >= Self.pauseSamples || self.samples.count >= Self.maximumTurnSamples
        if shouldFinish {
            await self.finishTurn(rotateAtWordBoundary: self.samples.count >= Self.maximumTurnSamples)
            return
        }
        if self.samples.count >= Self.minimumTurnSamples,
           self.samples.count - self.lastRecognitionSampleCount >= Self.partialIntervalSamples,
           self.canRecognizeCurrentPartial(at: end) {
            await self.recognizePartial()
        }
    }

    /// A drained batch is no longer in the queue while inference is awaited, so queue count
    /// alone cannot reveal its remaining backlog. The capture-era head covers both that batch
    /// and later arrivals. Suppression changes only preview work, never PCM or final coverage.
    private func canRecognizeCurrentPartial(at end: CMTime) -> Bool {
        guard let epoch = self.activeInputEpoch, epoch == self.inputEpoch.current else { return false }
        guard let latest = self.inputEpoch.latestEnd(in: epoch), end.isNumeric, end.seconds.isFinite else { return false }
        return latest - end.seconds <= Self.maximumPartialBacklogSeconds
    }

    private func recognizePartial() async {
        let generation = self.generation
        let input = self.samples
        do {
            let result = try await self.recognizer.recognize(input)
            guard !self.isStopped, !Task.isCancelled, self.generation == generation,
                  self.activeInputEpoch == self.inputEpoch.current,
                  let turnID, let startPTS, self.endPTS != nil else { return }
            self.lastRecognition = result
            self.lastRecognitionSampleCount = input.count
            let coverage = result.nativeCoverage(sampleCount: input.count, sampleRate: Self.sampleRate)
            let coveredStart = coverage.map {
                startPTS + CMTime(seconds: $0.lowerBound, preferredTimescale: 16_000)
            } ?? startPTS
            let coveredEnd = coverage.map {
                startPTS + CMTime(seconds: $0.upperBound, preferredTimescale: 16_000)
            } ?? .invalid
            self.onPartial?(self.kind, turnID, result.text, coveredStart, coveredEnd)
            // The model head sees only this current utterance. Require a small acoustic pause,
            // and retain a silence/duration fallback for artifacts without an EOU head.
            if (result.endOfUtteranceProbability ?? 0) >= Self.eouThreshold, self.quietSamples >= 2400 {
                await self.finishTurn()
            }
        } catch {
            guard !self.isStopped, !Task.isCancelled else { return }
            self.onDegraded?(self.kind, "Buffered captions hit an error and resynced.")
            self.reset()
        }
    }

    private func finishTurn(rotateAtWordBoundary: Bool = false) async {
        guard let turnID, let startPTS, let endPTS else { return }
        let generation = self.generation
        do {
            let result: PichiMeetingCaptionRecognition
            if rotateAtWordBoundary {
                // Keep Tiny's bounded fast recipe and the existing memory cap. Reserve
                // the last second inside this input as future context, never add a 21st.
                result = try await self.recognizer.recognizeWithWordTimings(self.samples)
            } else if self.lastRecognitionSampleCount == self.samples.count, let cached = self.lastRecognition {
                result = cached
            } else {
                result = try await self.recognizer.recognize(self.samples)
            }
            guard !self.isStopped, !Task.isCancelled, self.generation == generation,
                  self.activeInputEpoch == self.inputEpoch.current else { return }
            let rotation = rotateAtWordBoundary ? result.rotation(sampleCount: self.samples.count, sampleRate: Self.sampleRate) : nil
            let retained = rotation.map { Array(self.samples[$0.sample...]) } ?? []
            let boundary = rotation.map { startPTS + CMTime(value: Int64($0.sample), timescale: 16_000) } ?? endPTS
            let quietSamples = self.quietSamples
            let text = rotation?.text ?? result.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if rotateAtWordBoundary {
                let fullSamples = self.samples.count
                let committedSamples = rotation?.sample ?? fullSamples
                let carriedSamples = retained.count
                let wordCount = result.words.count
                let timedEvidenceValid = rotation != nil
                let reason = timedEvidenceValid ? "closed_word_gap" : "unusable_word_boundary"
                DebugLogger.shared.logLazy(source: "PichiMeetingBufferedTrackEngine") {
                    "caption_forced_boundary reason=\(reason) full_samples=\(fullSamples) committed_samples=\(committedSamples) " +
                        "carried_samples=\(carriedSamples) words=\(wordCount) timed_evidence_valid=\(timedEvidenceValid)"
                }
            }
            // A successful empty decode still completes this exact input interval. Reset,
            // failure and cancellation only clear partials; they never emit this completion.
            self.onUtterance?(self.kind, turnID, text, startPTS, boundary)
            self.clearTurn()
            if !retained.isEmpty {
                self.turnID = UUID()
                self.startPTS = boundary
                self.endPTS = endPTS
                self.samples = retained
                self.quietSamples = min(quietSamples, retained.count)
            }
        } catch {
            guard !self.isStopped, !Task.isCancelled else { return }
            self.onDegraded?(self.kind, "Buffered captions hit an error and resynced.")
            self.reset()
        }
    }

    private func clearTurn() {
        if let turnID, let startPTS {
            self.onPartial?(self.kind, turnID, "", startPTS, self.endPTS ?? startPTS)
        }
        self.generation &+= 1
        self.samples.removeAll(keepingCapacity: true)
        self.quietSamples = 0
        self.lastRecognitionSampleCount = 0
        self.lastRecognition = nil
        self.turnID = nil
        self.startPTS = nil
        self.endPTS = nil
    }

    /// Identical target contract to the upstream live engine, with a persistent converter.
    private func convert(_ source: AVAudioPCMBuffer) -> [Float]? {
        let format = source.format
        let buffer: AVAudioPCMBuffer
        if format == self.targetFormat {
            buffer = source
        } else {
            if self.converter == nil || self.converterSourceFormat != format {
                self.converterSourceFormat = format
                self.converter = AVAudioConverter(from: format, to: self.targetFormat)
            }
            guard let converter else { return nil }
            let capacity = AVAudioFrameCount((Double(source.frameLength) * Self.sampleRate / format.sampleRate).rounded(.up)) + 16
            guard let output = AVAudioPCMBuffer(pcmFormat: self.targetFormat, frameCapacity: capacity) else { return nil }
            let supplied = OSAllocatedUnfairLock(initialState: false)
            var error: NSError?
            let status = converter.convert(to: output, error: &error) { _, inputStatus in
                let alreadySupplied = supplied.withLock { state in
                    defer { state = true }
                    return state
                }
                inputStatus.pointee = alreadySupplied ? .noDataNow : .haveData
                return alreadySupplied ? nil : source
            }
            guard status != .error else { return nil }
            buffer = output
        }
        guard let channel = buffer.floatChannelData?[0] else { return nil }
        return Array(UnsafeBufferPointer(start: channel, count: Int(buffer.frameLength)))
    }

    #if DEBUG
    func consumeForTesting(_ sample: MeetingLiveSampleCopy.Sample) async {
        let epoch = self.inputEpoch.recordOffer(end: sample.pts + sample.duration)
        await self.consume(Input(sample: sample, epoch: epoch))
    }
    func bufferedSampleCountForTesting() -> Int { self.samples.count }
    func inputStateForTesting() async -> MeetingLiveAudioFIFO.TestingState { await self.queue.testingState() }
    #endif
}

/// Live recognition yields to durable recording under pressure. No capture writer is stopped.
final nonisolated class PichiMeetingCaptionMemoryMonitor: @unchecked Sendable {
    private let source: any DispatchSourceMemoryPressure

    init(onPressure: @escaping @Sendable () -> Void) {
        self.source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical], queue: .global(qos: .utility))
        self.source.setEventHandler(handler: onPressure)
        self.source.resume()
    }

    func stop() { self.source.cancel() }
    deinit { self.source.cancel() }
}
