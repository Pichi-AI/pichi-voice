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
        // Return only bounded Swift embeddings. The model and autoreleased native
        // temporaries must retire before the next sequential inference phase.
        return try autoreleasepool {
            guard !samples.isEmpty else { return [] }
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
}
