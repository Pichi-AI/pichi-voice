import CoreML
import Foundation

/// Synchronous, single-owner offline seam. Implementations retain only one recurrent state.
nonisolated protocol MeetingSpeechActivityFrameModel {
    mutating func probability(samples: [Float], reset: Bool) throws -> Float
}

/// Direct adapter for the audited cached Silero 256ms v6 model; never invokes a downloader.
/// Its output is 1-product(1-p_i) across eight internal 32ms outputs, NOT voiced duration,
/// near-end probability, or eight independent observations for policy confidence.
nonisolated struct MeetingLocalSileroActivityModel: MeetingSpeechActivityFrameModel {
    enum Failure: Error { case schema, input, output }
    private let model: MLModel
    private var context = [Float](repeating: 0, count: 64)
    private var hidden = [Float](repeating: 0, count: 128)
    private var cell = [Float](repeating: 0, count: 128)

    init(modelURL: URL) throws {
        let configuration = MLModelConfiguration()
        configuration.computeUnits = .cpuOnly
        self.model = try MLModel(contentsOf: modelURL, configuration: configuration)
        func matches(_ descriptions: [String: MLFeatureDescription], _ shapes: [String: [Int]]) -> Bool {
            Set(descriptions.keys) == Set(shapes.keys) && shapes.allSatisfy { key, shape in
                guard let constraint = descriptions[key]?.multiArrayConstraint else { return false }
                return constraint.dataType == .float32 && constraint.shape.map(\.intValue) == shape
            }
        }
        guard matches(
            self.model.modelDescription.inputDescriptionsByName,
            ["audio_input": [1, 4160], "hidden_state": [1, 128], "cell_state": [1, 128]]
        ),
            matches(
                self.model.modelDescription.outputDescriptionsByName,
                ["vad_output": [1, 1, 1], "new_hidden_state": [1, 128], "new_cell_state": [1, 128]]
            )
        else { throw Failure.schema }
    }

    mutating func probability(samples: [Float], reset: Bool) throws -> Float {
        guard samples.count == 4096, samples.allSatisfy(\.isFinite) else { throw Failure.input }
        if reset {
            self.context = [Float](repeating: 0, count: 64)
            self.hidden = [Float](repeating: 0, count: 128); self.cell = self.hidden
        }
        // CoreML feature providers bridge through Objective-C. Drain temporary arrays and
        // providers per frame even when this adapter runs on a long-lived worker thread.
        return try autoreleasepool {
            func array(_ values: [Float]) throws -> MLMultiArray {
                let array = try MLMultiArray(shape: [1, NSNumber(value: values.count)], dataType: .float32)
                // Fresh MLMultiArray storage is contiguous; avoid one NSNumber per sample.
                values.withUnsafeBufferPointer { source in
                    array.dataPointer.assumingMemoryBound(to: Float.self).update(from: source.baseAddress!, count: source.count)
                }
                return array
            }
            let features = try MLDictionaryFeatureProvider(dictionary: [
                "audio_input": array(context + samples), "hidden_state": array(self.hidden), "cell_state": array(self.cell),
            ])
            let output = try model.prediction(from: features)
            func values(_ name: String, count: Int) throws -> [Float] {
                guard let array = output.featureValue(for: name)?.multiArrayValue,
                      array.dataType == .float32, array.count == count else { throw Failure.output }
                var stride = 1
                var contiguous = true
                for (dimension, actualStride) in zip(array.shape.reversed(), array.strides.reversed()) {
                    if dimension.intValue > 1 && actualStride.intValue != stride { contiguous = false }
                    stride *= dimension.intValue
                }
                let values: [Float]
                if contiguous {
                    values = Array(UnsafeBufferPointer(start: array.dataPointer.assumingMemoryBound(to: Float.self), count: count))
                } else {
                    values = (0..<count).map { array[$0].floatValue }
                }
                guard values.allSatisfy(\.isFinite) else { throw Failure.output }
                return values
            }
            let p = try values("vad_output", count: 1)[0]
            guard (0...1).contains(p) else { throw Failure.output }
            let nextHidden = try values("new_hidden_state", count: 128)
            let nextCell = try values("new_cell_state", count: 128)
            self.hidden = nextHidden; self.cell = nextCell; self.context = Array(samples.suffix(64))
            return p
        }
    }
}

nonisolated struct MeetingSpeechActivityDetector<Model: MeetingSpeechActivityFrameModel> {
    static var version: String { "speech-shadow-b2-v2" }
    struct Frame: Codable, Equatable {
        enum Unknown: String, Codable { case invalidInput, unscoredCoverage, contextWarmup, modelFailure, overBudget, budgetCooldown, cancelled, disabled }
        let start: Double
        let epoch: UInt64
        let probability: Float?
        let unknown: Unknown?
        /// Window-level activity only; not a voiced-duration annotation or near-end decision.
        var active: Bool? { self.probability.map { $0 >= 0.85 } }
    }

    private var model: Model
    private var lastEnd: Double?
    private var scope: String?
    private var sessionID: UUID?
    private var needsReset = true
    private var modelFailures = 0
    private var consecutiveOverBudget = 0
    // nil is normal operation, zero permits one recovery prediction. Positive values
    // consume only real, valid, contiguous PCM, not wall time or padded samples.
    private var budgetCooldownRemainingSamples: Int?
    private static var budgetCooldownSamples: Int { 32_000 }
    private let clock: () -> Double
    init(model: Model, clock: @escaping () -> Double = { ProcessInfo.processInfo.systemUptime }) {
        self.model = model; self.clock = clock
    }

    /// Caller supplies exactly 4096 real 16kHz samples and validity flags. No tail padding.
    /// A first frame after reset is model warmup and intentionally unmeasured in the sidecar.
    /// One prediction cannot be preempted; budget/cancellation are checked before AND after it.
    mutating func process(
        samples: [Float],
        valid: [Bool],
        start: Double,
        session: UUID,
        epoch: UInt64,
        route: String,
        cancelled: () -> Bool = { false }
    ) -> Frame {
        if self.sessionID != session {
            self.modelFailures = 0; self.consecutiveOverBudget = 0
            self.budgetCooldownRemainingSamples = nil; self.needsReset = true
            self.scope = nil; self.lastEnd = nil
        }
        self.sessionID = session
        func unknown(_ reason: Frame.Unknown) -> Frame {
            Frame(start: start.isFinite ? start : 0, epoch: epoch, probability: nil, unknown: reason)
        }
        guard start.isFinite, start >= 0, !route.isEmpty,
              samples.count == 4096, valid.count == samples.count,
              samples.allSatisfy(\.isFinite)
        else {
            self.resetUnscoredContext(); return unknown(.invalidInput)
        }
        let nextScope = "\(session):\(epoch):\(route)"
        if self.scope != nextScope || self.lastEnd.map({ abs($0 - start) > 1.0 / 32_000 }) != false {
            self.needsReset = true
            // A gap, replay or new source epoch cannot shorten the recovery interval.
            if self.budgetCooldownRemainingSamples != nil {
                self.budgetCooldownRemainingSamples = Self.budgetCooldownSamples
            }
        }
        self.scope = nextScope; self.lastEnd = start + 0.256
        guard !cancelled() else { self.resetUnscoredContext(); return unknown(.cancelled) }
        guard self.modelFailures < 3 else { self.needsReset = true; return unknown(.disabled) }
        guard valid.allSatisfy({ $0 }) else { self.resetUnscoredContext(); return unknown(.unscoredCoverage) }
        if let remaining = self.budgetCooldownRemainingSamples, remaining > 0 {
            self.budgetCooldownRemainingSamples = max(0, remaining - samples.count)
            self.needsReset = true
            return unknown(.budgetCooldown)
        }
        let reset = self.needsReset, began = self.clock()
        do {
            let probability = try model.probability(samples: samples, reset: reset)
            guard !cancelled() else { self.resetUnscoredContext(); return unknown(.cancelled) }
            guard probability.isFinite, (0...1).contains(probability) else {
                self.modelFailures += 1; self.consecutiveOverBudget = 0
                self.needsReset = true; return unknown(.modelFailure)
            }
            self.modelFailures = 0
            let elapsed = self.clock() - began
            guard elapsed.isFinite, elapsed >= 0, elapsed <= 0.1 else {
                self.consecutiveOverBudget += 1; self.needsReset = true
                if self.budgetCooldownRemainingSamples != nil || self.consecutiveOverBudget >= 3 {
                    // After the initial three slow calls, retry at most once per new
                    // two seconds of source PCM. A slow recovery call cools down again.
                    self.budgetCooldownRemainingSamples = Self.budgetCooldownSamples
                    self.consecutiveOverBudget = 0
                }
                return unknown(.overBudget)
            }
            self.consecutiveOverBudget = 0; self.budgetCooldownRemainingSamples = nil
            self.needsReset = false
            if reset { return unknown(.contextWarmup) }
            return Frame(start: start, epoch: epoch, probability: probability, unknown: nil)
        } catch {
            self.modelFailures += 1; self.consecutiveOverBudget = 0
            self.needsReset = true; return unknown(.modelFailure)
        }
    }

    private mutating func resetUnscoredContext() {
        self.needsReset = true
        if self.modelFailures < 3 { self.modelFailures = 0 }
        self.consecutiveOverBudget = 0
        if self.budgetCooldownRemainingSamples != nil {
            self.budgetCooldownRemainingSamples = Self.budgetCooldownSamples
        }
    }
}

/// Offline B2 diagnostic combination. Correlated signals are never multiplied into confidence.
/// All combinations remain uncertain: no calibrated near-end/absence evidence exists yet.
nonisolated enum MeetingSpeechPlaybackShadowPolicy {
    enum TemporalContext: String, Codable { case supported, notSupported, mixed, unavailable }
    enum Reason: String, Codable {
        case missingSpeechEvidence, mixedOrLeakedActivity, activityWithoutReliablePlaybackMatch
        case duplicateWithoutDetectedActivity, negativeActivityIsNotAbsence
    }

    static func reason(activity: Bool?, reliableDuplicate: Bool) -> Reason {
        guard let activity else { return .missingSpeechEvidence }
        if activity { return reliableDuplicate ? .mixedOrLeakedActivity : .activityWithoutReliablePlaybackMatch }
        return reliableDuplicate ? .duplicateWithoutDetectedActivity : .negativeActivityIsNotAbsence
    }

    /// Join by interval overlap, not a single enclosing 2s window: 256ms frames often straddle
    /// that grid. All overlapping evidence must cover the frame in the same epoch. Mixed
    /// windows stay explicit and never borrow a sibling's supported state.
    static func temporalContext(
        start: Double,
        epoch: UInt64,
        windows: [MeetingPlaybackDuplicateDetector.Result]
    ) -> TemporalContext {
        guard start.isFinite, start >= 0 else { return .unavailable }
        let end = start + 0.256
        let overlapping = windows.filter { $0.end > start && $0.start < end }.sorted { $0.start < $1.start }
        var cursor = start, supported = false, unsupported = false
        for window in overlapping {
            guard window.epoch == epoch, window.start.isFinite, window.end.isFinite,
                  window.end > window.start, window.start <= cursor + 1e-9,
                  window.state != .insufficientEvidence else { return .unavailable }
            if window.state == .duplicateSupported { supported = true } else { unsupported = true }
            cursor = max(cursor, min(end, window.end))
        }
        guard cursor >= end - 1e-9 else { return .unavailable }
        return supported ? (unsupported ? .mixed : .supported) : .notSupported
    }
}
