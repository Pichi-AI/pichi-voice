import Foundation
import OnnxRuntimeBindings

public struct PIINERSpan: Sendable, Equatable {
    public let range: NSRange
    public let label: String
    public let score: Double
    public init(range: NSRange, label: String, score: Double) {
        self.range = range; self.label = label; self.score = score
    }
}

struct PIIWordPrediction: Sendable {
    let range: NSRange
    let label: String
    let startsEntity: Bool
    let score: Double
}

/// Serialized CPU inference over one bounded WordPiece window at a time. Releasing
/// or unloading the actor releases weights, and a cancelled run is joined before
/// its caller returns. No text, names, spans or logits are written or logged.
public actor PIINERRuntime {
    private var environment: ORTEnv?
    private var session: ORTSession?
    private var tokenizer: PIIWordPieceTokenizer?
    private var labels: [String] = []
    private var loadedFingerprint: String?
    public init() {}
    public var isReady: Bool { session != nil }

    public func load(descriptor: PIIModelDescriptor = .russianTiny, directory: URL) throws {
        // Retire Objective-C loader temporaries before the next model phase.
        try autoreleasepool {
            try Task.checkCancellation()
            // Always verify the immutable artifacts, even if this instance was used
            // before. A mutable external folder cannot silently change an attempt.
            try descriptor.verify(in: directory)
            if loadedFingerprint == descriptor.fingerprint, session != nil { return }
            unload()
            struct Config: Decodable { let id2label: [String: String] }
            let config = try JSONDecoder().decode(Config.self, from: Data(contentsOf: directory.appendingPathComponent("config.json")))
            let labels = try (0..<config.id2label.count).map { i -> String in
                guard let label = config.id2label[String(i)], label == "O" || label.hasPrefix("B-") || label.hasPrefix("I-") else {
                    throw TextPrivacyError.incompatibleModel
                }
                return label
            }
            guard labels.contains("B-PER"), labels.contains("I-PER") else { throw TextPrivacyError.incompatibleModel }
            let tokenizer = try PIIWordPieceTokenizer(vocabulary: String(contentsOf: directory.appendingPathComponent("vocab.txt"), encoding: .utf8))
            let environment = try ORTEnv(loggingLevel: .error)
            let options = try ORTSessionOptions()
            try options.setIntraOpNumThreads(1)
            try options.setGraphOptimizationLevel(.all)
            let session = try ORTSession(env: environment, modelPath: directory.appendingPathComponent("model_int8.onnx").path, sessionOptions: options)
            guard Set(try session.inputNames()) == Set(["input_ids", "attention_mask", "token_type_ids"]),
                  Set(try session.outputNames()).contains("logits") else { throw TextPrivacyError.incompatibleModel }
            try Task.checkCancellation()
            self.environment = environment; self.session = session; self.tokenizer = tokenizer
            self.labels = labels; self.loadedFingerprint = descriptor.fingerprint
        }
    }

    public func unload() {
        autoreleasepool {
            session = nil; environment = nil; tokenizer = nil; labels = []; loadedFingerprint = nil
        }
    }

    public func tag(_ text: String) throws -> [PIINERSpan] {
        try Task.checkCancellation()
        guard let session, let tokenizer else { throw TextPrivacyError.notPrepared }
        let words = try tokenizer.words(text)
        var predictions: [PIIWordPrediction] = []
        predictions.reserveCapacity(words.count)
        for window in tokenizer.windows(words) {
            try Task.checkCancellation()
            // Each WordPiece window owns and drains only its native tensors/logits.
            // The bounded decoded Swift predictions escape the pool.
            predictions += try autoreleasepool {
                func tensor(_ values: [Int64]) throws -> ORTValue {
                    let bytes = values.withUnsafeBytes { NSMutableData(bytes: $0.baseAddress!, length: $0.count) }
                    return try ORTValue(tensorData: bytes, elementType: .int64, shape: [1, NSNumber(value: values.count)])
                }
                let outputs = try session.run(withInputs: [
                    "input_ids": try tensor(window.ids),
                    "attention_mask": try tensor(Array(repeating: 1, count: window.ids.count)),
                    "token_type_ids": try tensor(Array(repeating: 0, count: window.ids.count)),
                ], outputNames: ["logits"], runOptions: nil)
                // ONNX run is synchronous. Cancellation is observed after completion,
                // so no native invocation is abandoned with live buffers or weights.
                try Task.checkCancellation()
                guard let output = outputs["logits"] else { throw TextPrivacyError.invalidOutput }
                let info = try output.tensorTypeAndShapeInfo()
                guard info.elementType == .float, info.shape.map(\.intValue) == [1, window.ids.count, labels.count] else {
                    throw TextPrivacyError.invalidOutput
                }
                let bytes = try output.tensorData() as Data
                let logits = bytes.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                return try Self.decode(logits: logits, labels: labels, window: window)
            }
        }
        try Task.checkCancellation()
        return Self.spans(predictions)
    }

    static func decode(logits: [Float], labels: [String], window: PIIEncodedWindow) throws -> [PIIWordPrediction] {
        guard logits.count == window.ids.count * labels.count, logits.allSatisfy(\.isFinite) else { throw TextPrivacyError.invalidOutput }
        var votes = Array(repeating: [String: Int](), count: window.words.count)
        var order = Array(repeating: [String](), count: window.words.count)
        var firstB = Array(repeating: false, count: window.words.count)
        var scores = Array(repeating: 0.0, count: window.words.count)
        var counts = Array(repeating: 0, count: window.words.count)
        for token in window.ids.indices {
            let word = window.wordOf[token]
            guard word >= 0 else { continue }
            let values = logits[(token * labels.count)..<((token + 1) * labels.count)]
            let winner = values.indices.max { logits[$0] < logits[$1] }!
            let rawLabel = labels[winner - token * labels.count]
            let entity = rawLabel == "O" ? "O" : String(rawLabel.dropFirst(2))
            if votes[word][entity] == nil { order[word].append(entity) }
            votes[word][entity, default: 0] += 1
            if counts[word] == 0 { firstB[word] = rawLabel.hasPrefix("B-") }
            let peak = Double(logits[winner])
            scores[word] += 1 / values.reduce(0.0) { $0 + exp(Double($1) - peak) }
            counts[word] += 1
        }
        return window.core.map { word in
            var entity = "O"
            var best = -1
            for candidate in order[word] {
                let count = votes[word][candidate] ?? 0
                if count > best || (count == best && entity == "O" && candidate != "O") { entity = candidate; best = count }
            }
            if window.words[word].text.unicodeScalars.count == 1,
               window.words[word].text.unicodeScalars.allSatisfy({ CharacterSet.letters.contains($0) }) { entity = "O" }
            return .init(range: window.words[word].range, label: entity, startsEntity: firstB[word], score: counts[word] > 0 ? scores[word] / Double(counts[word]) : 0)
        }
    }

    static func spans(_ predictions: [PIIWordPrediction]) -> [PIINERSpan] {
        var spans: [PIINERSpan] = []
        var current: (range: NSRange, label: String, sum: Double, count: Int)?
        func flush() {
            if let value = current { spans.append(.init(range: value.range, label: value.label, score: value.sum / Double(value.count))) }
            current = nil
        }
        for word in predictions {
            if word.label == "O" { flush(); continue }
            if word.startsEntity || current == nil || current?.label != word.label {
                flush(); current = (word.range, word.label, word.score, 1)
            } else if let previous = current {
                current = (NSUnionRange(previous.range, word.range), previous.label, previous.sum + word.score, previous.count + 1)
            }
        }
        flush()
        return spans
    }
}
