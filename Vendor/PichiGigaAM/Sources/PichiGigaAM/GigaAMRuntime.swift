import Foundation
import Metal
import OnnxRuntimeBindings
import TranscribeCpp

public enum GigaAMExecutionProvider: String, Sendable {
    case automatic
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
    private var frontend: GigaAMFrontend
    private var coreML: GigaAMCoreMLInference?
    private var gguf: GigaAMGGUFInference?
    private var loadedIdentity: String?
    private let resources: @Sendable () -> GigaAMResourcePolicy
    public private(set) var executionStatus: GigaAMExecutionStatus?
    public private(set) var lastTranscriptionWork = GigaAMTranscriptionWork()
    private var windowReuse = GigaAMWindowReuse()
    #if DEBUG
    private var windowInferenceForTesting: (@Sendable ([Float], Bool) throws -> GigaAMTranscript)?

    init(windowInferenceForTesting: @escaping @Sendable ([Float], Bool) throws -> GigaAMTranscript) throws {
        self.resources = { .current }
        self.frontend = try GigaAMFrontend()
        self.windowInferenceForTesting = windowInferenceForTesting
    }
    #endif

    public init(resources: @escaping @Sendable () -> GigaAMResourcePolicy = { .current }) throws {
        self.resources = resources
        self.frontend = try GigaAMFrontend()
    }

    public var isReady: Bool {
        #if DEBUG
        if self.windowInferenceForTesting != nil { return true }
        #endif
        return self.session != nil || self.coreML?.isLoaded == true || self.gguf?.isLoaded == true
    }
    public static var encoderFeatureAPIAvailable: Bool { TranscribeCpp.Session.nativeEncoderFeatureAPIAvailable }
    public var supportsEncoderFeatureCapture: Bool { self.gguf?.supportsEncoderFeatures == true }

    public func load(descriptor: GigaAMModelDescriptor, directory: URL, executionProvider: GigaAMExecutionProvider = .automatic) throws {
        try autoreleasepool {
            try Task.checkCancellation()
            let modelURL = directory.appendingPathComponent(descriptor.modelFile)
            let identity = descriptor.fingerprint + "/" + modelURL.path + "/" + executionProvider.rawValue
            if self.loadedIdentity == identity, self.isReady { return }
            self.unload()
            do {
                // Integrity and vocabulary errors are outside execution fallback.
                try descriptor.verify(in: directory)
                switch descriptor.format {
                case .gguf:
                    let native = GigaAMGGUFInference(modelURL: modelURL, modelSHA256: descriptor.modelSHA256)
                    self.gguf = native
                    if executionProvider == .cpu {
                        try self.loadGGUFCPU(native, reason: .explicitCPU)
                    } else if let reason = self.resources().gpuAdmissionReason {
                        try self.loadGGUFCPU(native, reason: reason)
                    } else {
                        try self.loadGGUFGPUOrFallback(native)
                    }
                case .onnx:
                    if let file = descriptor.vocabularyFile {
                        self.vocabulary = try GigaAMVocabulary(contents: String(contentsOf: directory.appendingPathComponent(file), encoding: .utf8))
                    } else { self.vocabulary = .russianCharacters }
                    self.frontend = try GigaAMFrontend()
                    let backgroundReason: GigaAMExecutionStatus.FallbackReason? = self.resources().requiresBackgroundExecution ? .backgroundExecution : nil
                    let useGPU = executionProvider == .coreML && backgroundReason == nil
                    try self.loadONNX(modelURL: modelURL, useGPU: useGPU)
                    self.executionStatus = useGPU
                        ? .init(backend: .gpu, fallbackReason: nil)
                        : .init(backend: .cpu, fallbackReason: executionProvider == .cpu ? .explicitCPU : (backgroundReason ?? .incompatibleExport))
                case .coreML(let configuration):
                    // Explicit legacy imports do not bypass capacity admission.
                    // In particular, do not compile the FP16 package on a 4 GB
                    // device before finding out that its GPU route is unsuitable.
                    try self.requireCoreMLCapacity()
                    guard let vocabularyFile = descriptor.vocabularyFile else { throw GigaAMError.invalidVocabulary }
                    let pieces = try String(contentsOf: directory.appendingPathComponent(vocabularyFile), encoding: .utf8)
                        .split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                    var tokens = pieces
                    if tokens.last == "" { tokens.removeLast() }
                    guard !tokens.isEmpty, tokens.count <= 65_535, tokens.first == "<unk>",
                          !tokens.contains("<blk>") else { throw GigaAMError.invalidVocabulary }
                    self.vocabulary = GigaAMVocabulary(tokens: tokens + ["<blk>"], blankID: tokens.count, unknownID: 0, subword: true)
                    self.frontend = try GigaAMFrontend(windowURL: directory.appendingPathComponent(configuration.windowFile),
                                                       melFilterbankURL: directory.appendingPathComponent(configuration.melFilterbankFile))
                    let native = try GigaAMCoreMLInference(packageURL: modelURL, featureFrameCount: configuration.featureFrameCount)
                    self.coreML = native
                    try self.requireCoreMLCapacity()
                    if executionProvider == .cpu {
                        try native.load(gpu: false)
                        self.executionStatus = .init(backend: .cpu, fallbackReason: .explicitCPU)
                    } else if self.resources().requiresBackgroundExecution || !self.resources().hasGPU {
                        try native.load(gpu: false)
                        self.executionStatus = .init(backend: .cpu, fallbackReason: self.resources().requiresBackgroundExecution ? .backgroundExecution : .gpuUnavailable)
                    } else {
                        do {
                            try native.load(gpu: true)
                            let smoke = self.frontend.features([Float](repeating: 0, count: GigaAMFrontend.fftSize))
                            _ = try native.predict(features: smoke.values, frameCount: smoke.frameCount)
                            self.executionStatus = .init(backend: .gpu, fallbackReason: nil)
                        } catch {
                            try Task.checkCancellation()
                            guard Self.permitsExecutionFallback(error) else { throw error }
                            native.unloadModel()
                            try self.requireCoreMLCapacity()
                            try native.load(gpu: false)
                            self.executionStatus = .init(backend: .cpu, fallbackReason: .acceleratorLoadFailed)
                        }
                    }
                }
                try Task.checkCancellation()
                self.descriptor = descriptor
                self.loadedURL = modelURL
                self.loadedIdentity = identity
            } catch {
                self.unload()
                throw error
            }
        }
    }

    private func loadONNX(modelURL: URL, useGPU: Bool) throws {
        let environment = try ORTEnv(loggingLevel: .warning)
        let options = try ORTSessionOptions()
        try options.setIntraOpNumThreads(Int32(min(4, max(1, ProcessInfo.processInfo.activeProcessorCount))))
        #if os(iOS)
        try options.addConfigEntry(withKey: "session.intra_op.allow_spinning", value: "0")
        try options.addConfigEntry(withKey: "session.inter_op.allow_spinning", value: "0")
        #endif
        try options.setGraphOptimizationLevel(.all)
        if useGPU {
            let optionsCoreML = ORTCoreMLExecutionProviderOptions()
            optionsCoreML.createMLProgram = true
            optionsCoreML.useCPUAndGPU = true
            try options.appendCoreMLExecutionProvider(with: optionsCoreML)
        }
        let session = try ORTSession(env: environment, modelPath: modelURL.path, sessionOptions: options)
        guard Set(try session.inputNames()).isSuperset(of: ["features", "feature_lengths"]),
              Set(try session.outputNames()).contains("log_probs") else { throw GigaAMError.incompatibleModel }
        try Task.checkCancellation()
        self.environment = environment
        self.session = session
    }

    private static func permitsExecutionFallback(_ error: Error) -> Bool {
        if error is CancellationError { return false }
        if let error = error as? GigaAMError {
            if case .invalidOutput = error { return true }
            return false
        }
        if let error = error as? TranscribeError {
            switch error {
            case .backend, .outOfMemory, .notImplemented: return true
            default: return false
            }
        }
        return true
    }

    private func loadGGUFCPU(_ native: GigaAMGGUFInference, reason: GigaAMExecutionStatus.FallbackReason) throws {
        if let bytes = self.resources().availableProcessMemory, bytes < 512 * 1_024 * 1_024 {
            throw GigaAMError.memoryBudgetExceeded
        }
        try native.load(gpu: false)
        self.executionStatus = .init(backend: .cpu, fallbackReason: reason)
    }

    private func requireCoreMLCapacity() throws {
        let resources = self.resources()
        guard resources.physicalMemory >= 8_000_000_000,
              resources.availableProcessMemory.map({ $0 >= 1_536 * 1_024 * 1_024 }) ?? true else {
            throw GigaAMError.memoryBudgetExceeded
        }
    }

    private func loadGGUFGPUOrFallback(_ native: GigaAMGGUFInference) throws {
        do {
            try native.load(gpu: true)
            _ = try native.predict([Float](repeating: 0, count: 16_000))
            self.executionStatus = .init(backend: .gpu, fallbackReason: nil)
        } catch {
            try Task.checkCancellation()
            guard Self.permitsExecutionFallback(error) else { throw error }
            native.unload()
            try self.loadGGUFCPU(native, reason: .acceleratorLoadFailed)
        }
    }

    /// A transient fallback is sticky within an admitted operation. A later
    /// operation tries GPU again using the same frozen compilation derivative.
    public func beginAttempt() throws {
        self.windowReuse.removeAll()
        try autoreleasepool {
            try Task.checkCancellation()
            if let native = self.gguf {
                guard self.executionStatus?.backend == .cpu,
                      let reason = self.executionStatus?.fallbackReason,
                      [.gpuUnavailable, .memoryBudget, .acceleratorLoadFailed, .acceleratorInferenceFailed].contains(reason),
                      self.resources().gpuAdmissionReason == nil else { return }
                try self.loadGGUFGPUOrFallback(native)
                return
            }
            guard let native = self.coreML, native.isLoaded, self.executionStatus?.backend == .cpu,
                  let reason = self.executionStatus?.fallbackReason,
                  [.gpuUnavailable, .memoryBudget, .acceleratorLoadFailed, .acceleratorInferenceFailed].contains(reason),
                  self.resources().hasGPU else { return }
            do { try self.requireCoreMLCapacity() }
            catch GigaAMError.memoryBudgetExceeded {
                self.executionStatus = .init(backend: .cpu, fallbackReason: .memoryBudget)
                return
            }
            do {
                try native.load(gpu: true)
                let smoke = self.frontend.features([Float](repeating: 0, count: GigaAMFrontend.fftSize))
                _ = try native.predict(features: smoke.values, frameCount: smoke.frameCount)
                self.executionStatus = .init(backend: .gpu, fallbackReason: nil)
            } catch {
                try Task.checkCancellation()
                guard Self.permitsExecutionFallback(error) else { throw error }
                native.unloadModel()
                do { try self.requireCoreMLCapacity(); try native.load(gpu: false) }
                catch { self.unload(); throw error }
                self.executionStatus = .init(backend: .cpu, fallbackReason: .acceleratorLoadFailed)
            }
        }
    }

    public func unload() {
        self.windowReuse.removeAll()
        #if DEBUG
        self.windowInferenceForTesting = nil
        #endif
        autoreleasepool {
            self.gguf?.unload()
            self.gguf = nil
            self.coreML?.unloadModel()
            self.coreML = nil
            self.session = nil
            self.environment = nil
            self.vocabulary = nil
            self.descriptor = nil
            self.loadedURL = nil
            self.loadedIdentity = nil
            self.executionStatus = nil
        }
    }

    /// Audio is 16 kHz mono float PCM. Long inputs use overlapping, bounded windows.
    /// Every word keeps its CTC-derived timing; midpoint ownership avoids duplicated overlap.
    public func transcribe(_ samples: [Float], captureEncoderFeatures: Bool = false,
                           reusingWindowsFor session: GigaAMWindowReuseSession? = nil) async throws -> GigaAMTranscript {
        self.lastTranscriptionWork = GigaAMTranscriptionWork()
        let cancellation = TranscribeCpp.CancellationToken()
        do {
            try Task.checkCancellation()
            self.windowReuse.prepare(session: session, sampleCount: samples.count)
            return try await withTaskCancellationHandler {
                let result = try self.transcribeWithFallback(samples, cancellation: cancellation, captureEncoderFeatures: captureEncoderFeatures)
                return GigaAMTranscript(text: result.text, confidence: result.confidence, words: result.words,
                    endOfUtteranceProbability: result.endOfUtteranceProbability, processingDuration: result.processingDuration,
                    encoderWindows: result.encoderWindows, inferenceWork: self.lastTranscriptionWork)
            } onCancel: { cancellation.cancel() }
        } catch {
            self.windowReuse.removeAll()
            throw error
        }
    }

    public func discardWindowReuse(for sessionID: UUID) {
        self.windowReuse.discard(for: sessionID)
    }

    private func transcribeWithFallback(_ samples: [Float], cancellation: TranscribeCpp.CancellationToken, captureEncoderFeatures: Bool) throws -> GigaAMTranscript {
        let start = ProcessInfo.processInfo.systemUptime
        do { return try self.transcribeAttempt(samples, cancellation: cancellation, captureEncoderFeatures: captureEncoderFeatures) }
        catch {
            try Task.checkCancellation()
            // A fallback result must contain only the replacement backend's work.
            let reuseSession = self.windowReuse.session
            self.windowReuse.removeAll()
            self.windowReuse.prepare(session: reuseSession, sampleCount: samples.count)
            if samples.allSatisfy(\.isFinite), Self.permitsExecutionFallback(error),
               self.executionStatus?.backend == .gpu, let native = self.gguf {
                do {
                    try autoreleasepool {
                        native.unload()
                        try self.loadGGUFCPU(native, reason: .acceleratorInferenceFailed)
                    }
                } catch { self.unload(); throw error }
                let result = try self.transcribeAttempt(samples, cancellation: cancellation, captureEncoderFeatures: captureEncoderFeatures)
                return GigaAMTranscript(text: result.text, confidence: result.confidence, words: result.words,
                                        endOfUtteranceProbability: result.endOfUtteranceProbability,
                                        processingDuration: ProcessInfo.processInfo.systemUptime - start, encoderWindows: result.encoderWindows)
            }
            guard samples.allSatisfy(\.isFinite), Self.permitsExecutionFallback(error),
                  self.executionStatus?.backend == .gpu, let native = self.coreML else { throw error }
            // The failed synchronous prediction has joined. Retire its GPU model
            // before loading CPU from the same frozen compilation derivative.
            do {
                try autoreleasepool {
                    native.unloadModel()
                    try self.requireCoreMLCapacity()
                    try native.load(gpu: false)
                }
            }
            catch {
                self.unload()
                throw error
            }
            self.executionStatus = .init(backend: .cpu, fallbackReason: .acceleratorInferenceFailed)
            // Re-run the complete input to avoid mixing internal window backends.
            let result = try self.transcribeAttempt(samples, cancellation: cancellation, captureEncoderFeatures: captureEncoderFeatures)
            return GigaAMTranscript(text: result.text, confidence: result.confidence, words: result.words,
                                    endOfUtteranceProbability: result.endOfUtteranceProbability,
                                    processingDuration: ProcessInfo.processInfo.systemUptime - start, encoderWindows: result.encoderWindows)
        }
    }

    private func transcribeAttempt(_ samples: [Float], cancellation: TranscribeCpp.CancellationToken, captureEncoderFeatures: Bool) throws -> GigaAMTranscript {
        try Task.checkCancellation()
        guard samples.allSatisfy(\.isFinite) else { throw GigaAMError.invalidAudio }
        guard self.isReady else { throw GigaAMError.notPrepared }
        let start = ProcessInfo.processInfo.systemUptime
        guard !samples.isEmpty else { return GigaAMTranscript(text: "", confidence: 0, words: [], endOfUtteranceProbability: nil, processingDuration: 0) }
        let coreSamples = 20 * GigaAMFrontend.sampleRate
        let overlapSamples = GigaAMFrontend.sampleRate
        var words: [GigaAMWordTiming] = []
        var encoderWindows: [GigaAMEncoderWindow] = []
        var featureBytes = 0
        // Optional correction/learning keeps the existing fifteen-minute bound.
        var capture = captureEncoderFeatures && samples.count <= 900 * GigaAMFrontend.sampleRate
        var finalProbability: Float?
        for coreStart in stride(from: 0, to: samples.count, by: coreSamples) {
            try Task.checkCancellation()
            let coreEnd = min(samples.count, coreStart + coreSamples)
            let windowStart = max(0, coreStart - overlapSamples)
            let windowEnd = min(samples.count, coreEnd + overlapSamples)
            let windowSamples = Array(samples[windowStart..<windowEnd])
            let digest = self.windowReuse.sessionID.map { _ in GigaAMWindowReuse.digest(windowSamples) }
            let output: GigaAMTranscript
            if let digest, let reused = self.windowReuse.output(coreStart: coreStart, sampleRange: windowStart..<windowEnd,
                                                    digest: digest, captureFeatures: capture) {
                output = reused
                self.lastTranscriptionWork.reusedWindows += 1
            } else {
                self.lastTranscriptionWork.inferredWindows += 1
                self.lastTranscriptionWork.inferredSamples += windowSamples.count
                output = try self.infer(windowSamples, cancellation: cancellation, captureEncoderFeatures: capture)
                try Task.checkCancellation()
                if let digest {
                    self.windowReuse.store(output, coreStart: coreStart, sampleRange: windowStart..<windowEnd,
                                           digest: digest, capturedFeatures: capture && !output.encoderWindows.isEmpty)
                }
            }
            let offset = Double(windowStart) / Double(GigaAMFrontend.sampleRate)
            let lower = Double(coreStart) / Double(GigaAMFrontend.sampleRate)
            let upper = Double(coreEnd) / Double(GigaAMFrontend.sampleRate)
            words.append(contentsOf: try Self.ownedWords(output.words,
                windowSampleRange: windowStart..<windowEnd, coreSampleRange: coreStart..<coreEnd))
            for window in output.encoderWindows {
                let ownLower = max(lower, window.ownership.lowerBound + offset)
                let ownUpper = min(upper, window.ownership.upperBound + offset)
                guard ownLower < ownUpper else { continue }
                let bytes = window.features.values.count * MemoryLayout<Float>.size
                guard bytes <= 128 * 1_024 * 1_024 - featureBytes, encoderWindows.count < 256 else {
                    encoderWindows.removeAll()
                    featureBytes = 0
                    capture = false
                    break
                }
                encoderWindows.append(try GigaAMEncoderWindow(offset: window.offset + offset,
                    ownership: ownLower..<ownUpper, features: window.features))
                featureBytes += bytes
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
            processingDuration: ProcessInfo.processInfo.systemUptime - start, encoderWindows: encoderWindows
        )
    }

    /// Midpoint ownership changes neither the native word position nor its inference window.
    /// Enumerate before filtering: after an empty core, the first retained word may be native
    /// word one or later from the overlapping context of the following inference call.
    nonisolated static func ownedWords(_ words: [GigaAMWordTiming],
                                      windowSampleRange: Range<Int>, coreSampleRange: Range<Int>) throws -> [GigaAMWordTiming] {
        guard windowSampleRange.lowerBound >= 0, !windowSampleRange.isEmpty,
              !coreSampleRange.isEmpty, coreSampleRange.lowerBound >= windowSampleRange.lowerBound,
              coreSampleRange.upperBound <= windowSampleRange.upperBound else { throw GigaAMError.invalidAudio }
        let sampleRate = Double(GigaAMFrontend.sampleRate)
        let offset = Double(windowSampleRange.lowerBound) / sampleRate
        let lower = Double(coreSampleRange.lowerBound) / sampleRate
        let upper = Double(coreSampleRange.upperBound) / sampleRate
        return try words.enumerated().compactMap { index, word in
            try Task.checkCancellation()
            let midpoint = (word.start + word.end) / 2 + offset
            guard midpoint >= lower, midpoint < upper else { return nil }
            return GigaAMWordTiming(text: word.text, start: word.start + offset, end: word.end + offset,
                confidence: word.confidence,
                sourceContext: .init(sampleRange: windowSampleRange, wordIndex: index))
        }
    }

    private static func encoderWindows(_ snapshot: TranscribeCpp.EncoderFeatureSnapshot?, duration: Double) throws -> [GigaAMEncoderWindow] {
        guard let snapshot else { return [] }
        guard snapshot.dimension == GigaAMEncoderFeatures.dimension, snapshot.sampleRate == 16_000,
              snapshot.frameHopSamples == 640, snapshot.recipeVersion == 1,
              snapshot.values.count == snapshot.frameCount * snapshot.dimension,
              snapshot.frameCount <= 600,
              abs(snapshot.frameCount - Int(ceil(duration / 0.04))) <= 1 else { throw GigaAMError.invalidOutput }
        var windows: [GigaAMEncoderWindow] = []
        for coreStart in stride(from: 0, to: snapshot.frameCount, by: 250) {
            try Task.checkCancellation()
            let lower = max(0, coreStart - 62), upper = min(snapshot.frameCount, coreStart + 312)
            let ownStart = Double(coreStart) * 0.04
            let ownEnd = min(duration, Double(min(snapshot.frameCount, coreStart + 250)) * 0.04)
            guard ownStart < ownEnd else { continue }
            let features = try GigaAMEncoderFeatures(values: Array(snapshot.values[(lower * 768)..<(upper * 768)]))
            windows.append(try GigaAMEncoderWindow(offset: Double(lower) * 0.04,
                ownership: ownStart..<ownEnd, features: features))
        }
        return windows
    }

    private func infer(_ samples: [Float], cancellation: TranscribeCpp.CancellationToken, captureEncoderFeatures: Bool) throws -> GigaAMTranscript {
        #if DEBUG
        if let infer = self.windowInferenceForTesting { return try infer(samples, captureEncoderFeatures) }
        #endif
        // A model call can create autoreleased Objective-C tensors and backing buffers.
        // Only the Swift transcript escapes this bounded window.
        return try autoreleasepool {
            guard self.isReady else { throw GigaAMError.notPrepared }
            let start = ProcessInfo.processInfo.systemUptime
            if let native = self.gguf {
                let output = try native.predictDetailed(samples, cancellationToken: cancellation,
                    captureEncoderFeatures: captureEncoderFeatures)
                try Task.checkCancellation()
                let windows: [GigaAMEncoderWindow]
                do { windows = try Self.encoderWindows(output.encoderFeatures, duration: Double(samples.count) / 16_000) }
                catch is CancellationError { throw CancellationError() }
                catch { windows = [] } // Optional features cannot invalidate usable ASR.
                return GigaAMTranscript(text: output.words.map(\.text).joined(separator: " "), confidence: 0,
                                        words: output.words, endOfUtteranceProbability: nil,
                                        processingDuration: ProcessInfo.processInfo.systemUptime - start,
                                        encoderWindows: windows)
            }
            guard let vocabulary = self.vocabulary else { throw GigaAMError.notPrepared }
            let features = self.frontend.features(samples)
            let values: [Float]
            let frameCount: Int
            var probability: Float?
            if let native = self.coreML {
                let output = try native.predict(features: features.values, frameCount: features.frameCount)
                guard output.vocabularySize == vocabulary.tokens.count else { throw GigaAMError.invalidOutput }
                values = output.values
                frameCount = output.frameCount
            } else {
                guard let session = self.session else { throw GigaAMError.notPrepared }
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
                frameCount = min(shape[1], (features.frameCount - 1) / 4 + 1)
                let allValues = try Self.floatValues(logits)
                values = Array(allValues.prefix(frameCount * vocabulary.tokens.count))
                if let output = outputs["eou_prob"], let threshold = self.descriptor?.endOfUtteranceThreshold, let raw = try Self.floatValues(output).first {
                    let clipped = min(1 - 1e-6, max(1e-6, raw))
                    let calibratedLogit = (log(clipped / (1 - clipped)) - log(threshold / (1 - threshold))) * 2
                    probability = 1 / (1 + exp(-calibratedLogit))
                }
            }
            let duration = Double(samples.count) / Double(GigaAMFrontend.sampleRate)
            let words = try GigaAMCTC.decode(logProbabilities: values, frameCount: frameCount, vocabulary: vocabulary, audioDuration: duration)
            return GigaAMTranscript(text: words.map(\.text).joined(separator: " "), confidence: words.isEmpty ? 0 : words.map(\.confidence).reduce(0, +) / Float(words.count), words: words, endOfUtteranceProbability: probability, processingDuration: ProcessInfo.processInfo.systemUptime - start)
        }
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
