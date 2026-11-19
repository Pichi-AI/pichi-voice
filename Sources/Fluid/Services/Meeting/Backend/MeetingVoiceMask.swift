import Foundation

/// A streaming channel vocoder for a single, serially owned 16 kHz mono recording stream.
/// Smoothed band amplitudes modulate an independent harmonic carrier and noise for fricatives.
/// The synthetic pitch and vocal-tract warp are chosen once per recording.
nonisolated final class MeetingVoiceMask {
    private static let rate: Double = 16_000
    private static let bandCount = 22

    private struct Filter {
        let gain: Float
        let feedback1: Float
        let feedback2: Float
        var memory1: Float = 0
        var memory2: Float = 0

        init(frequency: Double, bandwidth: Double) {
            let omega = 2 * Double.pi * frequency / MeetingVoiceMask.rate
            let alpha = sin(omega) * bandwidth / (2 * frequency)
            gain = Float(alpha / (1 + alpha))
            feedback1 = Float(2 * cos(omega) / (1 + alpha))
            feedback2 = Float((alpha - 1) / (1 + alpha))
        }

        mutating func apply(_ input: Float) -> Float {
            let output = gain * input + memory1
            memory1 = feedback1 * output + memory2
            memory2 = feedback2 * output - gain * input
            return output
        }

        mutating func reset() {
            memory1 = 0
            memory2 = 0
        }
    }

    private struct Band {
        var analysis: Filter
        var noise: Filter
        var level: Float = 0
        let noiseGain: Float
    }

    private var bands: [Band] = []
    private let period: Int
    // Phase-major storage keeps the carrier values for one sample contiguous.
    private let carrier: [Float]
    private var phase = 0
    private var random: UInt32 = 1

    convenience init() {
        self.init(seed: UInt32.random(in: .min ... .max))
    }

    /// Explicit profiles allow reproducible evaluation. Production draws a fresh profile for
    /// each writer. It is independent of the input voice and is never persisted.
    init(seed: UInt32) {
        period = 96 + Int(seed & 63)
        var carrier = [Float](repeating: 0, count: period * Self.bandCount)
        let magnitude = 0.085 + 0.15 * Double((seed >> 8) & 255) / 255
        let warp = (seed & 64) == 0 ? magnitude : -magnitude
        // Equally spaced analysis bands on the mel scale. At synthesis, a smooth monotonic
        // warp moves the vocal-tract envelope while retaining the order of phonetic bands.
        let first = log1p(120.0 / 700)
        let step = (log1p(7_250.0 / 700) - first) / Double(Self.bandCount - 1)
        for index in 0..<Self.bandCount {
            let mel = first + Double(index) * step
            let center = 700 * expm1(mel)
            let width = 700 * (exp(mel + step / 2) - exp(mel - step / 2))
            let outputCenter = center * (1 + warp * (1 - center / 8_000))
            let outputWidth = width * outputCenter / center
            let noiseMix = min(0.92, 0.12 + 0.8 * pow(center / 7_250, 0.7))
            let noiseFilter = Filter(frequency: outputCenter, bandwidth: outputWidth)
            // White input with unit variance has output variance gain for this band-pass.
            let noiseGain = Float(noiseMix / sqrt(Double(noiseFilter.gain)))
            bands.append(.init(analysis: Filter(frequency: center, bandwidth: width),
                               noise: noiseFilter, noiseGain: noiseGain))

            var wave = [Double](repeating: 0, count: period)
            for harmonic in 1..<(period / 2) {
                let frequency = Double(harmonic) * Self.rate / Double(period)
                let offset = (frequency - outputCenter) / outputWidth
                let weight = exp(-2.77 * offset * offset)
                guard weight > 0.0001 else { continue }
                // Fixed phase dispersion avoids a large pulse crest when many bands are active.
                let harmonicPhase = Double(harmonic * harmonic) * 0.27
                for sample in wave.indices {
                    let angle = 2 * Double.pi * Double(harmonic * sample) / Double(period)
                    wave[sample] += weight * sin(angle + harmonicPhase)
                }
            }
            let rms = sqrt(wave.reduce(0) { $0 + $1 * $1 } / Double(period))
            let harmonicGain = sqrt(1 - noiseMix * noiseMix) / max(rms, 0.001)
            for sample in wave.indices {
                carrier[sample * Self.bandCount + index] = Float(wave[sample] * harmonicGain)
            }
        }
        self.carrier = carrier
    }

    /// Discard analysis tails and synthetic carrier history at an explicit recording gap.
    func reset() {
        for index in bands.indices {
            bands[index].analysis.reset()
            bands[index].noise.reset()
            bands[index].level = 0
        }
        phase = 0
        random = 1
    }

    func process(_ samples: UnsafeMutableBufferPointer<Float>) {
        for offset in samples.indices {
            let sample = samples[offset]
            let input = sample.isFinite ? max(-1, min(1, sample)) : 0
            random = random &* 1_664_525 &+ 1_013_904_223
            let noise = Float(Int32(bitPattern: random)) * (1.7320508 / 2_147_483_648)
            var sum: Float = 0
            let base = phase * Self.bandCount
            for index in bands.indices {
                let energy = abs(bands[index].analysis.apply(input))
                // About 8 ms smoothing time attenuates the input's pitch-rate modulation.
                bands[index].level += 0.008 * (energy - bands[index].level)
                let excitation = carrier[base + index] + bands[index].noise.apply(noise) * bands[index].noiseGain
                sum += bands[index].level * excitation
            }
            samples[offset] = min(1, max(-1, 0.85 * sum))
            phase = (phase + 1) % period
        }
    }
}
