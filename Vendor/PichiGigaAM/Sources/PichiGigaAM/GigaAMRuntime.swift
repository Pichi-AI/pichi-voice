import Foundation
import OnnxRuntimeBindings

public enum GigaAMExecutionProvider: String, Sendable {
    case cpu
    case coreML
}

/// One serialized native session. Reuse an instance across the meeting's two tracks.
/// Releasing this actor releases model weights; unload() permits explicit residency control.
public actor GigaAMRuntime {
    private var environment: ORTEnv?
    private var session: ORTSession?
    private var vocabulary: GigaAMVocabulary?
    private var descriptor: GigaAMModelDescriptor?
    private var loadedURL: URL?
    private let frontend: GigaAMFrontend

    public init() throws { self.frontend = try GigaAMFrontend() }

    public var isReady: Bool { self.session != nil }

    public func load(descriptor: GigaAMModelDescriptor, directory: URL, executionProvider: GigaAMExecutionProvider = .cpu) throws {
        try Task.checkCancellation()
        let modelURL = directory.appendingPathComponent(descriptor.modelFile)
        if self.loadedURL == modelURL, self.session != nil { return }
        // Do not retain both old and new models during a model switch.
        self.unload()
        try descriptor.verify(in: directory)
        let vocabulary: GigaAMVocabulary
        if let file = descriptor.vocabularyFile {
            vocabulary = try GigaAMVocabulary(contents: String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8))
        } else {
            vocabulary = .russianCharacters
        }
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))))
        try options.setGraphOptimizationLevel(.all)
        // Dynamic GigaAM shapes are supported by the CPU EP on both architectures.
        // CoreML remains opt-in until a particular export/device passes parity.
        if executionProvider == .coreML {
            let coreML = ORTCoreMLExecutionProviderOptions()
            coreML.createMLProgram = true
            coreML.onlyEnableForDevicesWithANE = true
            try options.appendCoreMLExecutionProvider(with: coreML)
        }
        let session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
        guard Set(try session.inputNames()).isSuperset(of: ["features", "feature_lengths"]),
              Set(try session.outputNames()).contains("log_probs") else { throw GigaAMError.incompatibleModel }
        try Task.checkCancellation()
        self.environment = environment
        self.session = session
        self.vocabulary = vocabulary
        self.descriptor = descriptor
        self.loadedURL = modelURL
    }

    public func unload() {
        self.session = nil
        self.environment = nil
        self.vocabulary = nil
        self.descriptor = nil
        self.loadedURL = nil
    }

    /// Audio is 16 kHz mono float PCM. Long inputs use overlapping, bounded windows.
    /// Every word keeps its CTC-derived timing; midpoint ownership avoids duplicated overlap.
    public func transcribe(_ samples: [Float]) throws -> GigaAMTranscript {
        try Task.checkCancellation()
        guard samples.allSatisfy(\.isFinite) else { throw GigaAMError.invalidAudio }
        guard self.session != nil else { throw GigaAMError.notPrepared }
        let start = ProcessInfo.processInfo.systemUptime
        guard !samples.isEmpty else { return GigaAMTranscript(text: "", confidence: 0, words: [], endOfUtteranceProbability: nil, processingDuration: 0) }
        let coreSamples = 20 * GigaAMFrontend.sampleRate
        let overlapSamples = GigaAMFrontend.sampleRate
        var words: [GigaAMWordTiming] = []
        var finalProbability: Float?
        for coreStart in stride(from: 0, to: samples.count, by: coreSamples) {
            try Task.checkCancellation()
            let coreEnd = min(samples.count, coreStart + coreSamples)
            let windowStart = max(0, coreStart - overlapSamples)
            let windowEnd = min(samples.count, coreEnd + overlapSamples)
            let output = try self.infer(Array(samples[windowStart..<windowEnd]))
            let offset = Double(windowStart) / Double(GigaAMFrontend.sampleRate)
            let lower = Double(coreStart) / Double(GigaAMFrontend.sampleRate)
            let upper = Double(coreEnd) / Double(GigaAMFrontend.sampleRate)
            for word in output.words {
                let midpoint = (word.start + word.end) / 2 + offset
                guard midpoint >= lower, midpoint < upper else { continue }
                words.append(GigaAMWordTiming(text: word.text, start: word.start + offset, end: word.end + offset, confidence: word.confidence))
            }
            finalProbability = output.endOfUtteranceProbability
        }
        try Task.checkCancellation()
        return GigaAMTranscript(
            text: words.map(\.text).joined(separator: " "),
            confidence: words.isEmpty ? 0 : words.map(\.confidence).reduce(0, +) / Float(words.count),
            words: words,
            // EOU is meaningful for an isolated current utterance, not long meeting audio.
            endOfUtteranceProbability: samples.count <= 8 * GigaAMFrontend.sampleRate ? finalProbability : nil,
            processingDuration: ProcessInfo.processInfo.systemUptime - start
        )
    }

    private func infer(_ samples: [Float]) throws -> GigaAMTranscript {
        guard let session = self.session, let vocabulary = self.vocabulary else { throw GigaAMError.notPrepared }
        let start = ProcessInfo.processInfo.systemUptime
        let features = self.frontend.features(samples)
        let featureData = features.values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
        var length = Int64(features.frameCount)
        let lengthData = NSMutableData(bytes: &length, length: MemoryLayout<Int64>.size)
        let inputs = [
            "features": try ORTValue(tensorData: featureData, elementType: .float, shape: [1, NSNumber(value: GigaAMFrontend.melCount), NSNumber(value: features.frameCount)]),
            "feature_lengths": try ORTValue(tensorData: lengthData, elementType: .int64, shape: [1]),
        ]
        var outputNames: Set<String> = ["log_probs"]
        if self.descriptor?.endOfUtteranceThreshold != nil { outputNames.insert("eou_prob") }
        let outputs = try session.run(withInputs: inputs, outputNames: outputNames, runOptions: nil)
        try Task.checkCancellation()
        guard let logits = outputs["log_probs"] else { throw GigaAMError.invalidOutput }
        let shape = try logits.tensorTypeAndShapeInfo().shape.map(\.intValue)
        guard shape.count == 3, shape[0] == 1, shape[2] == vocabulary.tokens.count else { throw GigaAMError.invalidOutput }
        let frameCount = min(shape[1], (features.frameCount - 1) / 4 + 1)
        let allValues = try Self.floatValues(logits)
        let values = Array(allValues.prefix(frameCount * vocabulary.tokens.count))
        let duration = Double(samples.count) / Double(GigaAMFrontend.sampleRate)
        let words = try GigaAMCTC.decode(logProbabilities: values, frameCount: frameCount, vocabulary: vocabulary, audioDuration: duration)
        var probability: Float?
        if let output = outputs["eou_prob"], let threshold = self.descriptor?.endOfUtteranceThreshold, let raw = try Self.floatValues(output).first {
            let clipped = min(1 - 1e-6, max(1e-6, raw))
            let calibratedLogit = (log(clipped / (1 - clipped)) - log(threshold / (1 - threshold))) * 2
            probability = 1 / (1 + exp(-calibratedLogit))
        }
        return GigaAMTranscript(text: words.map(\.text).joined(separator: " "), confidence: words.isEmpty ? 0 : words.map(\.confidence).reduce(0, +) / Float(words.count), words: words, endOfUtteranceProbability: probability, processingDuration: ProcessInfo.processInfo.systemUptime - start)
    }

    private static func floatValues(_ value: ORTValue) throws -> [Float] {
        let type = try value.tensorTypeAndShapeInfo().elementType
        let data = try value.tensorData() as Data
        if type == .float {
            return data.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        throw GigaAMError.invalidOutput
    }
}
