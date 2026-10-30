import Foundation

/// GigaAM's learned decoder.enc_out representation, not the separate MFCC recipe.
/// Acquisition and frame offsets belong to the admitted provider. Its model
/// fingerprint must accompany persisted frames; equal dimensions do not prove
/// that features from another checkpoint are compatible.
public struct GigaAMEncoderFeatures: Equatable, Sendable {
    public static let extractorVersion = "gigaam-dec-encoder768-l2-40ms-v1"
    public static let dimension = 768
    public static let frameDuration: Double = 0.04
    public static let maximumFrames = 375

    /// Time-major, per-frame L2-normalized learned encoder states.
    public let values: [Float]
    public var frameCount: Int { self.values.count / Self.dimension }

    /// Normalization occurs only on copied feature states, never on original PCM.
    /// An all-zero matrix is invalid; zero padding rows retain their positions.
    public init(values: [Float]) throws {
        try Task.checkCancellation()
        guard !values.isEmpty, values.count % Self.dimension == 0,
              values.count <= Self.maximumFrames * Self.dimension,
              values.allSatisfy(\.isFinite) else { throw GigaAMAcousticError.invalidFeatures }
        var normalized = values
        var hasSignal = false
        for row in 0..<(values.count / Self.dimension) {
            if row % 16 == 0 { try Task.checkCancellation() }
            let range = (row * Self.dimension)..<((row + 1) * Self.dimension)
            let norm = sqrt(values[range].reduce(Double(0)) { $0 + Double($1) * Double($1) })
            guard norm.isFinite else { throw GigaAMAcousticError.invalidFeatures }
            if norm <= 1e-8 {
                for index in range { normalized[index] = 0 }
            } else {
                hasSignal = true
                for index in range { normalized[index] = Float(Double(values[index]) / norm) }
            }
        }
        guard hasSignal else { throw GigaAMAcousticError.invalidFeatures }
        self.values = normalized
    }

    public var meanL2: [Float]? {
        var mean = [Double](repeating: 0, count: Self.dimension)
        for row in 0..<self.frameCount {
            for index in mean.indices { mean[index] += Double(self.values[row * Self.dimension + index]) }
        }
        let norm = sqrt(mean.reduce(0) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-8 else { return nil }
        return mean.map { Float($0 / norm) }
    }
}

/// A bounded feature window with a non-overlapping ownership interval. The
/// encoder may use overlapping context while a spoken occurrence is corrected
/// only once. Model fingerprints remain the admitted runtime's responsibility.
public struct GigaAMEncoderWindow: Sendable {
    public let offset: Double
    public let ownership: Range<Double>
    public let features: GigaAMEncoderFeatures

    public init(offset: Double, ownership: Range<Double>, features: GigaAMEncoderFeatures) throws {
        guard offset.isFinite, offset >= 0, ownership.lowerBound.isFinite,
              ownership.upperBound.isFinite, ownership.lowerBound >= offset,
              ownership.lowerBound < ownership.upperBound,
              ownership.upperBound <= offset + Double(features.frameCount) * GigaAMEncoderFeatures.frameDuration + 0.081 else {
            throw GigaAMAcousticError.invalidFeatures
        }
        self.offset = offset
        self.ownership = ownership
        self.features = features
    }
}
