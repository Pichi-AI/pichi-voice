import Foundation
import TranscribeCpp

/// Uses the already bundled native engine and the published GGUF unchanged.
/// Its owning GigaAMRuntime actor serializes loading, prediction and teardown.
final class GigaAMGGUFInference {
    private let modelURL: URL
    private let modelSHA256: String
    private var model: Model?
    private var session: Session?
    private(set) var usesGPU = false
    var isLoaded: Bool { self.session != nil }

    init(modelURL: URL, modelSHA256: String) {
        self.modelURL = modelURL
        self.modelSHA256 = modelSHA256
    }

    deinit { self.unload() }

    func load(gpu: Bool) throws {
        self.unload()
        try autoreleasepool {
            try Task.checkCancellation()
            // Backend recovery must never reopen a different external file
            // under the frozen attempt's fingerprint.
            guard try GigaAMModelDescriptor.sha256(of: self.modelURL) == self.modelSHA256 else {
                throw GigaAMError.checksumMismatch(self.modelURL.lastPathComponent)
            }
            let model = try Model(path: self.modelURL.path, options: .init(backend: gpu ? .metal : .cpu))
            let capabilities = model.capabilities
            let device = try model.device
            guard model.arch == "gigaam", model.variant == "gigaam-v3-e2e-ctc",
                  capabilities.nativeSampleRate == 16_000,
                  capabilities.languages.contains("ru"), capabilities.maxTimestampKind == .token else {
                throw GigaAMError.incompatibleModel
            }
            guard gpu ? device.kind == "metal" : device.kind == "cpu" else {
                throw TranscribeError.backend("The requested GigaAM execution backend was not selected.")
            }
            let session = try model.session(.init(nThreads: Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount)))))
            try Task.checkCancellation()
            self.model = model
            self.session = session
            self.usesGPU = gpu
        }
    }

    func unload() {
        autoreleasepool {
            self.session?.clearCancellationToken()
            self.session = nil
            self.model = nil
            self.usesGPU = false
        }
    }

    func predict(_ samples: [Float], cancellationToken: CancellationToken? = nil) throws -> [GigaAMWordTiming] {
        try autoreleasepool {
            try Task.checkCancellation()
            guard let session = self.session else { throw GigaAMError.notPrepared }
            guard samples.count <= 22 * 16_000, samples.allSatisfy(\.isFinite) else { throw GigaAMError.invalidAudio }
            guard !samples.isEmpty else { return [] }
            if cancellationToken?.isCancelled == true { throw CancellationError() }
            // The native SDK requires a complete first analysis window, as the
            // legacy frontend does. Keep the unpadded duration for word bounds.
            let pcm = samples.count < GigaAMFrontend.fftSize
                ? samples + [Float](repeating: 0, count: GigaAMFrontend.fftSize - samples.count)
                : samples
            if let cancellationToken { session.setCancellationToken(cancellationToken) }
            defer { if cancellationToken != nil { session.clearCancellationToken() } }
            let result: Transcript
            do {
                result = try session.run(pcm, options: .init(timestamps: .token, language: "ru"))
            } catch TranscribeError.aborted {
                // Native partial output must not escape cancellation as a result.
                throw CancellationError()
            }
            try Task.checkCancellation()
            if cancellationToken?.isCancelled == true { throw CancellationError() }
            guard result.timestampKind == .token,
                  result.tokens.count <= (pcm.count + 639) / 640 + 1 else { throw GigaAMError.invalidOutput }
            let emissions = try result.tokens.compactMap { token -> GigaAMCTCEmission? in
                guard token.id >= 0, token.id <= 256, token.t0Ms >= 0, token.t1Ms >= token.t0Ms else {
                    throw GigaAMError.invalidOutput
                }
                if token.id == 0 || token.id == 256 { return nil }
                return GigaAMCTCEmission(piece: token.text, start: Double(token.t0Ms) / 1_000,
                                         end: Double(token.t1Ms) / 1_000, confidence: token.p)
            }
            return try GigaAMCTC.words(emissions: emissions, subword: true,
                                       audioDuration: Double(samples.count) / 16_000)
        }
    }
}
