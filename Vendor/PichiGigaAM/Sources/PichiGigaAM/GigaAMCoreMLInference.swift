@preconcurrency import CoreML
import Foundation

public struct GigaAMExecutionStatus: Sendable, Equatable {
    public enum Backend: String, Sendable { case cpu, gpu, neuralEngine }
    public enum FallbackReason: String, Sendable {
        case compatibleExportMissing, invalidExport, gpuUnavailable, incompatibleExport
        case acceleratorLoadFailed, acceleratorInferenceFailed, explicitCPU, unsupportedInputShape
        case memoryBudget, backgroundExecution
    }
    public let backend: Backend
    public let fallbackReason: FallbackReason?
}

/// The shipped Core ML graph is consumed unchanged. This object owns only its
/// private compilation derivative and one loaded model at a time.
final class GigaAMCoreMLInference {
    struct Output {
        let values: [Float]
        let frameCount: Int
        let vocabularySize: Int
    }

    private let compiledURL: URL
    private let featureFrameCount: Int
    private var model: MLModel?
    private var logitsName: String?
    private var lengthName: String?
    var isLoaded: Bool { self.model != nil }

    init(packageURL: URL, featureFrameCount: Int) throws {
        guard (2_199...8_000).contains(featureFrameCount) else { throw GigaAMError.incompatibleModel }
        self.featureFrameCount = featureFrameCount
        self.compiledURL = try MLModel.compileModel(at: packageURL)
    }

    deinit {
        self.model = nil
        try? FileManager.default.removeItem(at: self.compiledURL)
    }

    func load(gpu: Bool) throws {
        self.model = nil
        self.logitsName = nil
        self.lengthName = nil
        try Task.checkCancellation()
        let configuration = MLModelConfiguration()
        configuration.computeUnits = gpu ? .cpuAndGPU : .cpuOnly
        let model = try MLModel(contentsOf: self.compiledURL, configuration: configuration)
        let inputs = model.modelDescription.inputDescriptionsByName
        guard inputs["features"]?.multiArrayConstraint?.shape.map(\.intValue) == [1, GigaAMFrontend.melCount, self.featureFrameCount],
              inputs["features"]?.multiArrayConstraint?.dataType == .float32,
              inputs["feature_lengths"]?.multiArrayConstraint?.shape.map(\.intValue) == [1],
              inputs["feature_lengths"]?.multiArrayConstraint?.dataType == .int32 else { throw GigaAMError.incompatibleModel }
        let outputs = model.modelDescription.outputDescriptionsByName
        let logits = outputs.filter {
            let type = $0.value.multiArrayConstraint?.dataType
            return $0.value.multiArrayConstraint?.shape.count == 3 && (type == .float16 || type == .float32)
        }
        let lengths = outputs.filter { $0.value.multiArrayConstraint?.shape.map(\.intValue) == [1] && $0.value.multiArrayConstraint?.dataType == .int32 }
        guard logits.count == 1, lengths.count == 1 else { throw GigaAMError.incompatibleModel }
        try Task.checkCancellation()
        self.logitsName = logits.first!.key
        self.lengthName = lengths.first!.key
        self.model = model
    }

    func unloadModel() {
        self.model = nil
        self.logitsName = nil
        self.lengthName = nil
    }

    func predict(features: [Float], frameCount: Int) throws -> Output {
        try Task.checkCancellation()
        guard let model = self.model, let logitsName = self.logitsName, let lengthName = self.lengthName else { throw GigaAMError.notPrepared }
        guard frameCount > 0, frameCount <= self.featureFrameCount,
              features.count == GigaAMFrontend.melCount * frameCount else { throw GigaAMError.invalidAudio }
        let input = try MLMultiArray(shape: [1, NSNumber(value: GigaAMFrontend.melCount), NSNumber(value: self.featureFrameCount)], dataType: .float32)
        let data = input.dataPointer.bindMemory(to: Float.self, capacity: input.count)
        data.initialize(repeating: 0, count: input.count)
        for mel in 0..<GigaAMFrontend.melCount {
            for frame in 0..<frameCount {
                data[mel * self.featureFrameCount + frame] = features[mel * frameCount + frame]
            }
        }
        let lengths = try MLMultiArray(shape: [1], dataType: .int32)
        lengths[0] = NSNumber(value: Int32(frameCount))
        let result = try model.prediction(from: MLDictionaryFeatureProvider(dictionary: ["features": input, "feature_lengths": lengths]))
        try Task.checkCancellation()
        guard let logits = result.featureValue(for: logitsName)?.multiArrayValue,
              let outputLengths = result.featureValue(for: lengthName)?.multiArrayValue else { throw GigaAMError.invalidOutput }
        let shape = logits.shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[2] > 1 else { throw GigaAMError.invalidOutput }
        let validFrames = try Self.validFrameCount(inputFrames: frameCount,
                                                   reportedFrames: outputLengths[0].intValue,
                                                   availableFrames: shape[1])
        return try Self.readLogits(logits, validFrames: validFrames)
    }

    static func validFrameCount(inputFrames: Int, reportedFrames: Int, availableFrames: Int) throws -> Int {
        // The published FP16 graph rounds its length arithmetic above 2048
        // input frames: e.g. 2199 reports 551 rather than 550. Bound readback by
        // the true audio length and physical output, as on the ONNX path.
        guard inputFrames > 0, reportedFrames > 0, availableFrames > 0,
              reportedFrames <= availableFrames + 1 else { throw GigaAMError.invalidOutput }
        return min((inputFrames + 3) / 4, reportedFrames, availableFrames)
    }

    /// Published models may return FP16 and padded rows despite the model card.
    static func readLogits(_ logits: MLMultiArray, validFrames: Int) throws -> Output {
        let shape = logits.shape.map(\.intValue)
        let strides = logits.strides.map(\.intValue)
        guard shape.count == 3, strides.count == 3, shape[0] == 1,
              validFrames > 0, validFrames <= shape[1], shape[2] > 1,
              strides.allSatisfy({ $0 > 0 }), [.float16, .float32].contains(logits.dataType) else {
            throw GigaAMError.invalidOutput
        }
        let span = (shape[1] - 1) * strides[1] + (shape[2] - 1) * strides[2] + 1
        var values = [Float](repeating: 0, count: validFrames * shape[2])
        if logits.dataType == .float16 {
            #if arch(arm64)
            let source = logits.dataPointer.bindMemory(to: Float16.self, capacity: span)
            for frame in 0..<validFrames {
                for token in 0..<shape[2] {
                    values[frame * shape[2] + token] = Float(source[frame * strides[1] + token * strides[2]])
                }
            }
            #else
            // Swift Float16 is unavailable on Intel macOS. Core ML's numeric
            // subscript reads the same FP16 tensor using its actual strides.
            for frame in 0..<validFrames {
                for token in 0..<shape[2] {
                    let index = [NSNumber(value: 0), NSNumber(value: frame), NSNumber(value: token)]
                    values[frame * shape[2] + token] = logits[index].floatValue
                }
            }
            #endif
        } else {
            let source = logits.dataPointer.bindMemory(to: Float.self, capacity: span)
            for frame in 0..<validFrames {
                for token in 0..<shape[2] {
                    values[frame * shape[2] + token] = source[frame * strides[1] + token * strides[2]]
                }
            }
        }
        guard values.allSatisfy(\.isFinite) else { throw GigaAMError.invalidOutput }
        return Output(values: values, frameCount: validFrames, vocabularySize: shape[2])
    }
}
