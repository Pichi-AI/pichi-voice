import CoreML
import Foundation

/// A bounded GigaAM Core ML inference facade that keeps both the long and
/// six-second graph ready for preview calls.
///
/// The package directory is an already verified `coreMLModel` import. The
/// six-second graph is materialized once into a private staging directory and
/// both compilation derivatives are retained until the actor is released.
public actor GigaAMNeuralPreviewEngine {
    private static let shortWindowSampleCount = 6 * GigaAMFrontend.sampleRate
    private static let longWindowSampleCount = 25 * GigaAMFrontend.sampleRate

    private let frontend: GigaAMFrontend
    private let vocabulary: GigaAMVocabulary
    private let longBackend: GigaAMCoreMLInference
    private let shortBackend: GigaAMCoreMLInference

    public init(directory: URL) async throws {
        guard Self.isSupportedPlatform else {
            throw GigaAMError.incompatibleModel
        }
        let descriptor = GigaAMModelCatalog.coreMLModel
        guard case .coreML(let configuration) = descriptor.format else {
            throw GigaAMError.incompatibleModel
        }
        try descriptor.verify(in: directory)
        try Task.checkCancellation()

        guard let vocabularyFile = descriptor.vocabularyFile else {
            throw GigaAMError.invalidVocabulary
        }
        let pieces = try String(contentsOf: directory.appendingPathComponent(vocabularyFile), encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var tokens = pieces
        if tokens.last == "" { tokens.removeLast() }
        guard !tokens.isEmpty, tokens.count <= 65_535, tokens.first == "<unk>",
              !tokens.contains("<blk>") else { throw GigaAMError.invalidVocabulary }
        let vocabulary = GigaAMVocabulary(tokens: tokens + ["<blk>"], blankID: tokens.count,
                                           unknownID: 0, subword: true)
        let frontend = try GigaAMFrontend(windowURL: directory.appendingPathComponent(configuration.windowFile),
                                          melFilterbankURL: directory.appendingPathComponent(configuration.melFilterbankFile))
        let package = directory.appendingPathComponent(descriptor.modelFile, isDirectory: true)

        let stagingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pichi-gigaam-short-\(UUID().uuidString).mlpackage", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stagingURL) }
        self.frontend = frontend
        self.vocabulary = vocabulary
        try Task.checkCancellation()
        try FileManager.default.createDirectory(at: stagingURL, withIntermediateDirectories: true)
        try GigaAMShortGraph.materialize(from: package, into: stagingURL)
        try Task.checkCancellation()
        let long = try GigaAMCoreMLInference(packageURL: package,
                                             featureFrameCount: configuration.featureFrameCount)
        let short = try GigaAMCoreMLInference(packageURL: stagingURL,
                                              featureFrameCount: GigaAMShortGraph.frameCount)
        try short.load(computeUnits: .cpuAndNeuralEngine)
        try long.load(computeUnits: .cpuAndNeuralEngine)
        self.shortBackend = short
        self.longBackend = long
    }

    private static var isSupportedPlatform: Bool {
        #if os(macOS) && arch(arm64)
            return true
        #else
            return false
        #endif
    }

    /// Routes short input to the materialized six-second graph and bounded
    /// long input to the verified 25-second graph.
    public func recognize(_ samples: [Float], longContext: Bool) throws -> [GigaAMWordTiming] {
        try Task.checkCancellation()
        try Self.validate(samples, longContext: longContext)
        return try autoreleasepool {
            let backend = longContext ? self.longBackend : self.shortBackend
            let features = self.frontend.features(samples)
            guard features.frameCount <= backend.capacity else { throw GigaAMError.invalidAudio }
            let output = try backend.predict(features: features.values, frameCount: features.frameCount)
            guard output.vocabularySize == self.vocabulary.tokens.count else { throw GigaAMError.invalidOutput }
            let duration = Double(samples.count) / Double(GigaAMFrontend.sampleRate)
            return try GigaAMCTC.decode(logProbabilities: output.values, frameCount: output.frameCount,
                                        vocabulary: self.vocabulary, audioDuration: duration)
        }
    }
    static func validate(_ samples: [Float], longContext: Bool) throws {
        let capacity = longContext ? longWindowSampleCount : shortWindowSampleCount
        guard !samples.isEmpty, samples.count <= capacity, samples.allSatisfy(\.isFinite) else {
            throw GigaAMError.invalidAudio
        }
    }

}

