import CoreML
import Foundation

/// A bounded GigaAM Core ML inference facade that keeps both the long and
/// six-second graph ready for preview calls.
///
/// Preparation verifies the model catalog artifacts before using them. The
/// six-second graph is materialized once into a private staging directory and
/// both compilation derivatives are retained until the actor is released.
public actor GigaAMNeuralPreviewEngine {
    private static let shortWindowSampleCount = 6 * GigaAMFrontend.sampleRate
    private static let longWindowSampleCount = 25 * GigaAMFrontend.sampleRate

    private let runtime: GigaAMRuntime

    /// Compatibility facade for callers which only request previews. Dictation
    /// uses the preview methods on its already loaded canonical runtime.
    public init(directory: URL) async throws {
        guard Self.isSupportedPlatform else { throw GigaAMError.incompatibleModel }
        let runtime = try GigaAMRuntime()
        try await runtime.load(descriptor: GigaAMModelCatalog.coreMLModel, directory: directory)
        guard try await runtime.prepareAdaptivePreview() else { throw GigaAMError.incompatibleModel }
        self.runtime = runtime
    }

    static var isSupportedPlatform: Bool {
        #if os(macOS) && arch(arm64)
        return true
        #else
        return false
        #endif
    }

    public func recognize(_ samples: [Float], longContext: Bool) async throws -> [GigaAMWordTiming] {
        try await self.runtime.recognizePreview(samples, longContext: longContext)
    }

    static func validate(_ samples: [Float], longContext: Bool) throws {
        let capacity = longContext ? longWindowSampleCount : shortWindowSampleCount
        guard !samples.isEmpty, samples.count <= capacity, samples.allSatisfy(\.isFinite) else {
            throw GigaAMError.invalidAudio
        }
    }

}
