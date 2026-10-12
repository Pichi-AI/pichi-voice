import Accelerate
import Foundation

/// GigaAM v3 log-mel frontend, matching the optimized ONNX exports.
/// Periodic bf16-rounded Hann, 320-point STFT, 160-sample hop, 64 HTK filters.
final class GigaAMFrontend {
    static let sampleRate = 16_000
    static let fftSize = 320
    static let hop = 160
    static let melCount = 64
    private static let binCount = fftSize / 2 + 1

    private let setup: vDSP_DFT_Setup
    private let window: [Float]
    private let filters: [Float]

    init() throws {
        guard let setup = vDSP_DFT_zop_CreateSetup(nil, vDSP_Length(Self.fftSize), .FORWARD) else {
            throw GigaAMError.frontendInitialization
        }
        self.setup = setup
        self.window = (0..<Self.fftSize).map { index in
            Self.bf16(Float(0.5 - 0.5 * cos(2 * .pi * Double(index) / Double(Self.fftSize))))
        }
        let maxMel = 2595 * log10(1 + 8000.0 / 700)
        let points = (0..<(Self.melCount + 2)).map { index in
            700 * (pow(10, maxMel * Double(index) / Double(Self.melCount + 1) / 2595) - 1)
        }
        var filters = [Float](repeating: 0, count: Self.binCount * Self.melCount)
        for bin in 0..<Self.binCount {
            let frequency = Double(bin) * 50
            for mel in 0..<Self.melCount {
                let up = (frequency - points[mel]) / (points[mel + 1] - points[mel])
                let down = (points[mel + 2] - frequency) / (points[mel + 2] - points[mel + 1])
                filters[bin * Self.melCount + mel] = Self.bf16(Float(max(0, min(up, down))))
            }
        }
        self.filters = filters
    }

    deinit { vDSP_DFT_DestroySetup(self.setup) }

    static func bf16(_ value: Float) -> Float {
        let bits = value.bitPattern
        return Float(bitPattern: (bits &+ 0x7fff &+ ((bits >> 16) & 1)) & 0xffff0000)
    }

    /// Returns contiguous [1, 64, T], with no centered STFT padding.
    func features(_ samples: [Float]) -> (values: [Float], frameCount: Int) {
        let audio = samples.count < Self.fftSize
            ? samples + [Float](repeating: 0, count: Self.fftSize - samples.count)
            : samples
        let frameCount = (audio.count - Self.fftSize) / Self.hop + 1
        var packed = [Float](repeating: 0, count: Self.melCount * frameCount)
        var inputReal = [Float](repeating: 0, count: Self.fftSize)
        let inputImaginary = [Float](repeating: 0, count: Self.fftSize)
        var outputReal = inputReal
        var outputImaginary = inputReal
        var power = [Float](repeating: 0, count: Self.binCount)
        for frame in 0..<frameCount {
            let offset = frame * Self.hop
            for index in 0..<Self.fftSize {
                inputReal[index] = audio[offset + index] * self.window[index]
            }
            vDSP_DFT_Execute(self.setup, inputReal, inputImaginary, &outputReal, &outputImaginary)
            for bin in 0..<Self.binCount {
                power[bin] = outputReal[bin] * outputReal[bin] + outputImaginary[bin] * outputImaginary[bin]
            }
            for mel in 0..<Self.melCount {
                // Double accumulation matches the existing JS frontend, which computes
                // its filter sum in IEEE double before storing the float32 result.
                var sum = 0.0
                for bin in 0..<Self.binCount {
                    sum += Double(power[bin]) * Double(self.filters[bin * Self.melCount + mel])
                }
                packed[mel * frameCount + frame] = Float(log(min(max(sum, 1e-9), 1e9)))
            }
        }
        return (packed, frameCount)
    }
}
