import Foundation

/// Candidate-cut matching, not unrestricted keyword spotting. The provider owns
/// word boundaries, exact-rule protection and arbitration between dictionary labels.
public enum GigaAMAcousticMatcher {
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

    // Conservative initial operating range for this cepstral representation.
    // These are not inherited Parakeet encoder thresholds or a general accuracy claim.
    private static let absoluteDistanceLimit: Float = 0.04
    private static let maximumReferenceSpread: Float = 0.22
    private static let minimumFrames = 4
    private static let maximumReferences = 10

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
                for k in 0..<GigaAMAcousticFeatures.dimension {
                    dot += reference.values[(r.lowerBound + i - 1) * GigaAMAcousticFeatures.dimension + k]
                        * query.values[(q.lowerBound + j - 1) * GigaAMAcousticFeatures.dimension + k]
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
        var first: Int?, last = 0, active = 0
        for row in 0..<features.frameCount {
            let start = row * GigaAMAcousticFeatures.dimension
            if features.values[start..<(start + GigaAMAcousticFeatures.dimension)].contains(where: { $0 != 0 }) {
                first = first ?? row
                last = row
                active += 1
            }
        }
        guard let first, active >= Self.minimumFrames, active * 2 >= last - first + 1 else { return nil }
        return first..<(last + 1)
    }
}
