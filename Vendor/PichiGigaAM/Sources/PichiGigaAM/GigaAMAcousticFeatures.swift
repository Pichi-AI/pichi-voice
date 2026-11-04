import Foundation

/// A small, versioned acoustic template. This is DSP derived from the input PCM,
/// not a hidden-state readout or an update to the GigaAM model's weights.
public struct GigaAMAcousticFeatures: Equatable, Sendable {
    public static let extractorVersion = "gigaam-mfcc20-delta40ms-v1"
    public static let sampleRate = 16_000
    public static let frameDuration: Double = 0.04
    public static let dimension = 40
    public static let maximumSamples = 15 * sampleRate
    public static let maximumFrames = 375

    /// Time-major rows: twenty non-energy cepstra followed by twenty deltas.
    public let values: [Float]
    public var frameCount: Int { self.values.count / Self.dimension }

    /// Reconstruct only this exact representation after the caller checks its
    /// saved extractor version. A profile from another encoder is incompatible.
    public init(values: [Float]) throws {
        guard !values.isEmpty, values.count % Self.dimension == 0,
              values.count <= Self.maximumFrames * Self.dimension,
              values.allSatisfy(\.isFinite) else { throw GigaAMAcousticError.invalidFeatures }
        var hasSignal = false
        for start in stride(from: 0, to: values.count, by: Self.dimension) {
            let norm = values[start..<(start + Self.dimension)].reduce(Float(0)) { $0 + $1 * $1 }
            guard norm.isFinite, norm < 1e-10 || (0.98...1.02).contains(norm) else { throw GigaAMAcousticError.invalidFeatures }
            hasSignal = hasSignal || norm > 0.98
        }
        guard hasSignal else { throw GigaAMAcousticError.invalidFeatures }
        self.values = values
    }

    /// Existing profile metadata uses a mean/L2 summary, while matching below
    /// always uses the full temporal sequence.
    public var meanL2: [Float]? {
        var mean = [Float](repeating: 0, count: Self.dimension)
        for frame in 0..<self.frameCount {
            for index in mean.indices { mean[index] += self.values[frame * Self.dimension + index] }
        }
        let norm = sqrt(mean.reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-6 else { return nil }
        return mean.map { $0 / norm }
    }

    /// No model load, download, global settings or persistent storage. The
    /// caller supplies one exact focal cut of mono 16 kHz PCM, at most 15 s.
    public static func extract(_ samples: [Float]) throws -> Self {
        try Task.checkCancellation()
        guard samples.count >= GigaAMFrontend.fftSize, samples.count <= Self.maximumSamples,
              samples.allSatisfy({ $0.isFinite && abs($0) <= 1 }) else { throw GigaAMAcousticError.invalidAudio }
        let rms = sqrt(samples.reduce(Double(0)) { $0 + Double($1) * Double($1) } / Double(samples.count))
        guard rms >= 0.000_01 else { throw GigaAMAcousticError.quietAudio }
        let frontend = try GigaAMFrontend()
        let mel = frontend.features(samples)
        try Task.checkCancellation()
        let count = (mel.frameCount + 3) / 4
        guard count <= Self.maximumFrames else { throw GigaAMAcousticError.invalidFeatures }
        let cepstra = 20
        let scale = sqrt(2.0 / Double(GigaAMFrontend.melCount))
        let basis: [Float] = (1...cepstra).flatMap { (coefficient: Int) -> [Float] in
            (0..<GigaAMFrontend.melCount).map { (bin: Int) -> Float in
                let angle = Double.pi * Double(coefficient) * (Double(bin) + 0.5) / Double(GigaAMFrontend.melCount)
                return Float(scale * cos(angle))
            }
        }
        var statics = [Float](repeating: 0, count: count * cepstra)
        for frame in 0..<count {
            if frame % 16 == 0 { try Task.checkCancellation() }
            let lower = frame * 4, upper = min(lower + 4, mel.frameCount)
            for coefficient in 0..<cepstra {
                var value: Float = 0
                for bin in 0..<GigaAMFrontend.melCount {
                    var average: Float = 0
                    for original in lower..<upper { average += mel.values[bin * mel.frameCount + original] }
                    value += average / Float(upper - lower) * basis[coefficient * GigaAMFrontend.melCount + bin]
                }
                statics[frame * cepstra + coefficient] = value
            }
        }
        var output = [Float](repeating: 0, count: count * Self.dimension)
        for frame in 0..<count {
            if frame % 16 == 0 { try Task.checkCancellation() }
            let audioStart = frame * 640, audioEnd = min(samples.count, audioStart + 640)
            let energy = samples[audioStart..<audioEnd].reduce(Double(0)) { $0 + Double($1) * Double($1) }
            guard sqrt(energy / Double(audioEnd - audioStart)) >= max(0.000_01, rms * 0.03) else { continue }
            var row = [Float](repeating: 0, count: Self.dimension)
            for coefficient in 0..<cepstra {
                row[coefficient] = statics[frame * cepstra + coefficient]
                var delta: Float = 0
                for offset in 1...2 {
                    delta += Float(offset) * (statics[min(count - 1, frame + offset) * cepstra + coefficient]
                        - statics[max(0, frame - offset) * cepstra + coefficient])
                }
                row[cepstra + coefficient] = delta / 10
            }
            // Excluding C0 removes broadband level. Independently normalizing
            // the two blocks prevents microphone gain from dominating distance.
            normalize(&row, range: 0..<cepstra, weight: 1)
            normalize(&row, range: cepstra..<Self.dimension, weight: 0.35)
            normalize(&row, range: 0..<Self.dimension, weight: 1)
            output.replaceSubrange((frame * Self.dimension)..<((frame + 1) * Self.dimension), with: row)
        }
        try Task.checkCancellation()
        return try Self(values: output)
    }

    private static func normalize(_ values: inout [Float], range: Range<Int>, weight: Float) {
        let norm = sqrt(values[range].reduce(Float(0)) { $0 + $1 * $1 })
        guard norm.isFinite, norm > 1e-6 else {
            for index in range { values[index] = 0 }
            return
        }
        for index in range { values[index] = values[index] / norm * weight }
    }
}

public enum GigaAMAcousticError: Error, Equatable {
    case invalidAudio
    case quietAudio
    case invalidFeatures
}
