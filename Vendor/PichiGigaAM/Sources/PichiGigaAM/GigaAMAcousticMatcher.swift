import Foundation

/// Candidate-cut matching, not unrestricted keyword spotting. The provider owns
/// word boundaries, exact-rule protection and arbitration between dictionary labels.
public enum GigaAMAcousticMatcher {
    public static let encoderCalibrationVersion = "gigaam-encoder-loo-contrast-v1"

    public struct Calibration: Equatable, Sendable {
        public let acceptanceDistance: Float
        public let referenceSpread: Float
        fileprivate let references: [GigaAMAcousticFeatures]
    }

    public struct Match: Equatable, Sendable {
        public let distance: Float
        /// Acoustic consistency only. The provider must still arbitrate word
        /// boundaries, competing labels and lexical/contextual evidence.
        public let accepted: Bool
    }

    /// Separate learned-feature calibration. MFCC operating points remain intact.
    public struct EncoderCalibration: Equatable, Sendable {
        public let acceptanceDistance: Float
        public let referenceSpread: Float
        public let maximumLeaveOneOutDistance: Float
        public let nearestContrastDistance: Float?
        fileprivate let references: [GigaAMEncoderFeatures]
    }

    // Conservative initial operating range for this cepstral representation.
    // These are not inherited Parakeet encoder thresholds or a general accuracy claim.
    private static let absoluteDistanceLimit: Float = 0.04
    private static let maximumReferenceSpread: Float = 0.22
    private static let minimumFrames = 4
    private static let maximumReferences = 10
    private static let maximumEncoderDistance: Float = 0.45
    private static let maximumEncoderReferenceError: Float = 0.35
    private static let maximumEncoderContrasts = 128

    /// Derive the operating point only from enrolled references and optional
    /// training contrasts. Every reference must generalize to two other examples.
    /// No held-out query, label spelling or desired success rate enters calibration.
    public static func calibrateEncoder(
        references: [GigaAMEncoderFeatures], contrastReferences: [GigaAMEncoderFeatures] = []
    ) throws -> EncoderCalibration? {
        try Task.checkCancellation()
        guard (3...Self.maximumReferences).contains(references.count),
              contrastReferences.count <= Self.maximumEncoderContrasts else { return nil }
        var pairwise = [[Float?]](repeating: [Float?](repeating: nil, count: references.count), count: references.count)
        var spread: Float = 0
        for index in references.indices {
            for other in 0..<index {
                guard let value = try self.distanceEncoder(references[index], references[other]) else { return nil }
                pairwise[index][other] = value; pairwise[other][index] = value
                spread = max(spread, value)
            }
        }
        var leaveOneOut: [Float] = []
        for index in references.indices {
            let scores = pairwise[index].compactMap { $0 }.sorted()
            guard scores.count >= 2 else { return nil }
            leaveOneOut.append((scores[0] + scores[1]) / 2)
        }
        guard let maximumError = leaveOneOut.max(), maximumError <= Self.maximumEncoderReferenceError,
              spread <= Self.maximumEncoderDistance else { return nil }
        var closestContrast: Float?
        for contrast in contrastReferences {
            try Task.checkCancellation()
            guard let score = try self.encoderScore(query: contrast, references: references) else { continue }
            closestContrast = min(closestContrast ?? score, score)
        }
        let threshold: Float
        if let closestContrast {
            // Overlapping reference/contrast distributions require better examples,
            // not a wider threshold. Identical contradictory examples fail closed.
            guard closestContrast - maximumError >= max(0.01, maximumError * 0.1) else { return nil }
            threshold = min(Self.maximumEncoderDistance, (maximumError + closestContrast) / 2)
        } else {
            // A single dictionary term remains useful without assuming an unseen
            // negative distribution. Use a smaller reference-only allowance.
            threshold = min(0.30, max(0.025, maximumError * 1.2 + 0.01))
        }
        return EncoderCalibration(acceptanceDistance: threshold, referenceSpread: spread,
            maximumLeaveOneOutDistance: maximumError, nearestContrastDistance: closestContrast, references: references)
    }

    public static func matchEncoder(
        query: GigaAMEncoderFeatures, references: [GigaAMEncoderFeatures],
        calibration: EncoderCalibration, negativeReferences: [GigaAMEncoderFeatures] = []
    ) throws -> Match? {
        try Task.checkCancellation()
        guard references == calibration.references, (3...Self.maximumReferences).contains(references.count),
              negativeReferences.count <= 32, calibration.acceptanceDistance.isFinite,
              (0...Self.maximumEncoderDistance).contains(calibration.acceptanceDistance),
              let score = try self.encoderScore(query: query, references: references) else { return nil }
        guard score <= calibration.acceptanceDistance else { return Match(distance: score, accepted: false) }
        for negative in negativeReferences {
            if let distance = try self.distanceEncoder(negative, query),
               distance <= min(Self.maximumEncoderDistance, score + 0.01) {
                return Match(distance: score, accepted: false)
            }
        }
        return Match(distance: score, accepted: true)
    }

    private static func encoderScore(query: GigaAMEncoderFeatures, references: [GigaAMEncoderFeatures]) throws -> Float? {
        let scores = try references.compactMap { try self.distanceEncoder($0, query) }.sorted()
        guard scores.count >= 2 else { return nil }
        return (scores[0] + scores[1]) / 2
    }

    public static func distanceEncoder(_ reference: GigaAMEncoderFeatures, _ query: GigaAMEncoderFeatures) throws -> Float? {
        try Task.checkCancellation()
        guard let r = self.activeBounds(values: reference.values, dimension: GigaAMEncoderFeatures.dimension),
              let q = self.activeBounds(values: query.values, dimension: GigaAMEncoderFeatures.dimension) else { return nil }
        return try self.sequenceDistance(reference: reference.values, referenceRange: r,
            query: query.values, queryRange: q, dimension: GigaAMEncoderFeatures.dimension)
    }

    /// Every pair must be compatible; three unrelated recordings never form a
    /// permissive profile just because one pair happens to sound alike.
    public static func calibrate(references: [GigaAMAcousticFeatures]) throws -> Calibration? {
        try Task.checkCancellation()
        guard (3...Self.maximumReferences).contains(references.count),
              references.allSatisfy({ $0.frameCount >= Self.minimumFrames }) else { return nil }
        var distances: [Float] = []
        for i in references.indices {
            for j in 0..<i {
                guard let value = try self.distance(references[i], references[j]),
                      value <= Self.maximumReferenceSpread else { return nil }
                distances.append(value)
            }
        }
        guard let spread = distances.max() else { return nil }
        // Leave limited room for unseen contexts, with an absolute rejection
        // ceiling even when the enrollments themselves are unusually variable.
        let threshold = min(Self.absoluteDistanceLimit, max(0.02, spread * 1.35 + 0.025))
        return Calibration(acceptanceDistance: threshold, referenceSpread: spread, references: references)
    }

    public static func match(
        query: GigaAMAcousticFeatures,
        references: [GigaAMAcousticFeatures],
        calibration: Calibration,
        negativeReferences: [GigaAMAcousticFeatures] = []
    ) throws -> Match? {
        try Task.checkCancellation()
        guard references == calibration.references, (3...Self.maximumReferences).contains(references.count),
              negativeReferences.count <= 32,
              calibration.acceptanceDistance.isFinite,
              (0...Self.absoluteDistanceLimit).contains(calibration.acceptanceDistance) else { return nil }
        let distances = try references.compactMap { try self.distance($0, query) }.sorted()
        // Require agreement with two recordings rather than one nearest neighbor.
        guard distances.count >= 2 else { return nil }
        let value = (distances[0] + distances[1]) / 2
        guard value <= calibration.acceptanceDistance else { return Match(distance: value, accepted: false) }
        // A saved negative can only veto an acoustic acceptance. Similarity to
        // a negative never creates a positive candidate or widens its threshold.
        for negative in negativeReferences {
            if let distance = try self.distance(negative, query),
               distance <= min(Self.absoluteDistanceLimit, value + 0.01) {
                return Match(distance: value, accepted: false)
            }
        }
        return Match(distance: value, accepted: true)
    }

    /// Global DTW over two word cuts, with a duration-ratio guard, normalized
    /// progress band and small warp penalty. Memory is linear in sequence length.
    public static func distance(_ reference: GigaAMAcousticFeatures, _ query: GigaAMAcousticFeatures) throws -> Float? {
        try Task.checkCancellation()
        guard let r = self.activeBounds(reference), let q = self.activeBounds(query) else { return nil }
        return try self.sequenceDistance(reference: reference.values, referenceRange: r,
            query: query.values, queryRange: q, dimension: GigaAMAcousticFeatures.dimension)
    }

    // Shared arithmetic and cancellation bounds; recipe-specific calibration and
    // feature validation stay separate. Workspace remains two dynamic-program rows.
    private static func sequenceDistance(
        reference: [Float], referenceRange r: Range<Int>, query: [Float], queryRange q: Range<Int>, dimension: Int
    ) throws -> Float? {
        let n = r.count, m = q.count
        guard n >= Self.minimumFrames, m >= Self.minimumFrames,
              Double(max(n, m)) / Double(min(n, m)) <= 1.8 else { return nil }
        let width = m + 1
        var previous = [Float](repeating: .infinity, count: width)
        var previousSteps = [Int](repeating: 0, count: width)
        previous[0] = 0
        for i in 1...n {
            if i % 8 == 0 { try Task.checkCancellation() }
            var current = [Float](repeating: .infinity, count: width)
            var steps = [Int](repeating: 0, count: width)
            for j in 1...m {
                guard abs(Double(i - 1) / Double(max(1, n - 1)) - Double(j - 1) / Double(max(1, m - 1))) <= 0.30 else { continue }
                var dot: Float = 0
                for k in 0..<dimension {
                    dot += reference[(r.lowerBound + i - 1) * dimension + k]
                        * query[(q.lowerBound + j - 1) * dimension + k]
                }
                let cost = 1 - min(1, max(-1, dot))
                var best = previous[j - 1], count = previousSteps[j - 1]
                if previous[j] + 0.025 < best { best = previous[j] + 0.025; count = previousSteps[j] }
                if current[j - 1] + 0.025 < best { best = current[j - 1] + 0.025; count = steps[j - 1] }
                current[j] = best + cost
                steps[j] = count + 1
            }
            previous = current
            previousSteps = steps
        }
        try Task.checkCancellation()
        guard previous[m].isFinite, previousSteps[m] > 0 else { return nil }
        return previous[m] / Float(previousSteps[m])
    }

    private static func activeBounds(_ features: GigaAMAcousticFeatures) -> Range<Int>? {
        self.activeBounds(values: features.values, dimension: GigaAMAcousticFeatures.dimension)
    }

    private static func activeBounds(values: [Float], dimension: Int) -> Range<Int>? {
        var first: Int?, last = 0, active = 0
        for row in 0..<(values.count / dimension) {
            let start = row * dimension
            if values[start..<(start + dimension)].contains(where: { $0 != 0 }) {
                first = first ?? row
                last = row
                active += 1
            }
        }
        guard let first, active >= Self.minimumFrames, active * 2 >= last - first + 1 else { return nil }
        return first..<(last + 1)
    }
}
