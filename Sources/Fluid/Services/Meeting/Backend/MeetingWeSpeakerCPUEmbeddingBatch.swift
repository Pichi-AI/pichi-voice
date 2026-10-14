import CoreML
import Foundation

/// The pinned WeSpeaker export has three independent waveform lanes. The inherited extractor
/// predicts once per clip while using only lane zero. This CPU-only adapter fills up to three
/// distinct clips without changing repeat padding, masks, weights or embedding interpretation.
nonisolated enum MeetingWeSpeakerCPUEmbeddingBatch {
    nonisolated enum Failure: Error { case unsupportedContract, invalidClips, invalidOutput }
    static let maximumClips = 3
    static let waveformFrames = 160_000
    static let embeddingDimensions = 256

    static func supports(_ model: MLModel) -> Bool {
        let inputs = model.modelDescription.inputDescriptionsByName
        guard let waveform = inputs["waveform"]?.multiArrayConstraint,
              let mask = inputs["mask"]?.multiArrayConstraint,
              let output = model.modelDescription.outputDescriptionsByName["embedding"]?.multiArrayConstraint else { return false }
        let maskShape = mask.shape.map(\.intValue)
        return waveform.shape.map(\.intValue) == [3, waveformFrames]
            && waveform.dataType == .float32 && mask.dataType == .float32
            && maskShape.count == 2 && maskShape[0] == 3 && (10...4_096).contains(maskShape[1])
            && output.shape.map(\.intValue) == [3, embeddingDimensions] && output.dataType == .float32
    }

    static func embeddings(clips: [[Float]], model: MLModel) throws -> [[Float]] {
        guard supports(model), let maskFrames = model.modelDescription.inputDescriptionsByName["mask"]?.multiArrayConstraint?.shape.last?.intValue else {
            throw Failure.unsupportedContract
        }
        guard (1...maximumClips).contains(clips.count), clips.allSatisfy({
            (48_000...waveformFrames).contains($0.count) && $0.allSatisfy(\.isFinite)
        }) else { throw Failure.invalidClips }
        try Task.checkCancellation()
        let waveform = try MLMultiArray(shape: [3, NSNumber(value: waveformFrames)], dataType: .float32)
        let mask = try MLMultiArray(shape: [3, NSNumber(value: maskFrames)], dataType: .float32)
        guard waveform.strides.map(\.intValue) == [waveformFrames, 1],
              mask.strides.map(\.intValue) == [maskFrames, 1] else { throw Failure.unsupportedContract }
        let waveformPointer = waveform.dataPointer.assumingMemoryBound(to: Float.self)
        let maskPointer = mask.dataPointer.assumingMemoryBound(to: Float.self)
        // Explicitly clear every unused lane; no previous prediction can affect this batch.
        _ = memset(waveformPointer, 0, waveform.count * MemoryLayout<Float>.size)
        _ = memset(maskPointer, 0, mask.count * MemoryLayout<Float>.size)
        for (lane, clip) in clips.enumerated() {
            try Task.checkCancellation()
            let row = waveformPointer.advanced(by: lane * waveformFrames)
            clip.withUnsafeBufferPointer { source in
                _ = memcpy(row, source.baseAddress!, clip.count * MemoryLayout<Float>.size)
            }
            var filled = clip.count
            // Exactly the inherited repeat-padding rule, with no zero padding of used rows.
            while filled < waveformFrames {
                let count = min(filled, waveformFrames - filled)
                _ = memcpy(row.advanced(by: filled), row, count * MemoryLayout<Float>.size)
                filled += count
            }
            let maskRow = maskPointer.advanced(by: lane * maskFrames)
            for frame in 0..<maskFrames { maskRow[frame] = 1 }
        }
        let features = try MLDictionaryFeatureProvider(dictionary: [
            "waveform": MLFeatureValue(multiArray: waveform), "mask": MLFeatureValue(multiArray: mask),
        ])
        let predicted = try model.prediction(from: features, options: MLPredictionOptions())
        try Task.checkCancellation()
        guard let output = predicted.featureValue(for: "embedding")?.multiArrayValue,
              output.shape.map(\.intValue) == [3, embeddingDimensions], output.dataType == .float32,
              output.strides.map(\.intValue) == [embeddingDimensions, 1] else {
            throw Failure.invalidOutput
        }
        let embeddings = output.dataPointer.assumingMemoryBound(to: Float.self)
        return try clips.indices.map { lane in
            let values = Array(UnsafeBufferPointer(start: embeddings.advanced(by: lane * embeddingDimensions), count: embeddingDimensions))
            guard values.allSatisfy(\.isFinite) else { throw Failure.invalidOutput }
            return values
        }
    }
}
