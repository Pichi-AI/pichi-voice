import Foundation
#if arch(arm64)
import CoreML
import FluidAudio
#endif

/// One synchronous, scoped encoder body shared by meeting inference and explicit enrollment.
/// The caller owns serialization and cancellation; all model weights die before returning.
nonisolated enum MeetingSpeakerVoiceEncoder {
    static func encode(
        samples: [MeetingSpeakerVoiceSamples],
        directory: URL = MeetingSpeakerVoiceModelArtifacts.packageURL(),
        validateDefaultRoot: Bool = true
    ) throws -> [MeetingSpeakerVoiceProfile] {
        #if arch(arm64)
        guard !samples.isEmpty else { return [] }
        return try self.withPreparedEncoder(directory: directory, validateDefaultRoot: validateDefaultRoot) { extractor, mask in
            var profiles: [MeetingSpeakerVoiceProfile] = []
            for sample in samples.prefix(MeetingSpeakerVoiceSamples.maximumProfiles) {
                try Task.checkCancellation()
                guard sample.clips.count == 2 else { continue }
                var embeddings: [[Float]] = []
                for clip in sample.clips {
                    try Task.checkCancellation()
                    guard (48_000...160_000).contains(clip.count) else { continue }
                    let embedding: [Float]? = try autoreleasepool {
                        let output = try extractor.getEmbeddings(audio: clip, masks: [mask])
                        guard let embedding = output.first, embedding.count == 256,
                              embedding.allSatisfy(\.isFinite) else { return nil }
                        return embedding
                    }
                    if let embedding { embeddings.append(embedding) }
                }
                if embeddings.count == 2 {
                    profiles.append(.init(token: sample.token, embeddings: embeddings))
                }
            }
            return profiles
        }
        #else
        return []
        #endif
    }

    /// Prime the exact encoder graph on synthetic silence within the existing idle model
    /// lifecycle. No microphone, enrollment/profile or participant identity is involved.
    static func prepare(directory: URL = MeetingSpeakerVoiceModelArtifacts.packageURL(),
                        validateDefaultRoot: Bool = true) throws {
        #if arch(arm64)
        try self.withPreparedEncoder(directory: directory, validateDefaultRoot: validateDefaultRoot) { extractor, mask in
            _ = try extractor.getEmbeddings(audio: [Float](repeating: 0, count: 48_000), masks: [mask])
            try Task.checkCancellation()
        }
        #endif
    }

    #if arch(arm64)
    /// Both preparation and inference release weights/native temporaries before returning.
    private static func withPreparedEncoder<T>(directory: URL, validateDefaultRoot: Bool,
        _ body: (EmbeddingExtractor, [Float]) throws -> T) throws -> T {
        try autoreleasepool {
            try Task.checkCancellation()
            #if os(iOS)
            let computeUnits: MLComputeUnits = .cpuOnly
            #else
            let computeUnits: MLComputeUnits = .cpuAndNeuralEngine
            #endif
            if validateDefaultRoot { try MeetingSpeakerVoiceModelArtifacts.validateRootContainment() }
            try MeetingSpeakerVoiceModelArtifacts.validate(at: directory)
            let configuration = MLModelConfiguration()
            configuration.computeUnits = computeUnits
            let model = try MLModel(contentsOf: directory, configuration: configuration)
            try Task.checkCancellation()
            guard let maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue,
                  (1...4096).contains(maskFrames) else {
                throw MeetingModelResidencyError.unsupportedProvider
            }
            let extractor = EmbeddingExtractor(embeddingModel: model)
            let mask = [Float](repeating: 1, count: maskFrames)
            return try body(extractor, mask)
        }
    }
    #endif

}
