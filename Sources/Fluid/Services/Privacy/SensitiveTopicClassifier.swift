import Foundation
import CryptoKit

nonisolated enum SensitiveTopicClassifierError: Error, Equatable {
    case invalidArtifact, checksumMismatch, unsupportedTopic, inputTooLong, sentenceTooLong
}

nonisolated struct SensitiveTopicDecision: Sendable, Equatable {
    let range: NSRange
    let topicID: String
    /// A classifier score, not a calibrated probability or evidence of wrongdoing.
    let score: Double
}

nonisolated struct SensitiveTopicDetection: Sendable {
    let spans: [TranscriptRedactedSpan]
    /// In incomplete input, the entire undecided trailing sentence stays private.
    let safeUTF16: Int
    let decisions: [SensitiveTopicDecision]
}

/// Immutable, CPU-only optional detector. This does not own installation, settings,
/// a network transport, or an inference server. The existing privacy resource owner
/// admits a verified local artifact and retains this value for one attempt.
nonisolated struct SensitiveTopicClassifierSnapshot: Sendable {
    static let maximumArtifactBytes = 2_097_152
    static let maximumInputUTF16 = 65_536
    static let maximumSentenceUTF16 = 2_048
    static let featureIdentity = "unicode-nfc-lower-alnum-fnv1a64-word12-char345-set-l2-v1"
    static let supportedTopicIDs: Set<String> = ["illicit-remuneration", "procurement-collusion", "commercial-metrics"]

    struct Topic: Codable, Sendable {
        let id: String
        let bias: Double
        let threshold: Double
        let weights: [String: Double]
    }
    struct Artifact: Codable, Sendable {
        let formatVersion: Int
        let featureIdentity: String
        let dimensions: Int
        let trainingDigest: String
        let topics: [Topic]
    }
    private struct CompiledTopic: Sendable {
        let id: String
        let bias: Double
        let threshold: Double
        let weights: [Int: Double]
    }
    let artifactSHA256: String
    let selectedTopicIDs: Set<String>
    let availableTopicIDs: Set<String>
    let trainingDigest: String
    private let dimensions: Int
    private let topics: [CompiledTopic]
    var identity: String {
        "sensitive-topics-v1/" + artifactSHA256 + "/" + selectedTopicIDs.sorted().joined(separator: ",")
    }

    static func load(artifactURL: URL, expectedSHA256: String, selectedTopicIDs: Set<String>) throws -> Self {
        let values = try artifactURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let count = values.fileSize, count > 0, count <= maximumArtifactBytes else {
            throw SensitiveTopicClassifierError.invalidArtifact
        }
        let data = try Data(contentsOf: artifactURL)
        guard data.count == count, data.count <= maximumArtifactBytes else { throw SensitiveTopicClassifierError.invalidArtifact }
        return try .init(data: data, expectedSHA256: expectedSHA256, selectedTopicIDs: selectedTopicIDs)
    }

    init(data: Data, expectedSHA256: String, selectedTopicIDs: Set<String>) throws {
        guard !data.isEmpty, data.count <= Self.maximumArtifactBytes,
              Self.isDigest(expectedSHA256) else { throw SensitiveTopicClassifierError.invalidArtifact }
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        guard digest == expectedSHA256 else { throw SensitiveTopicClassifierError.checksumMismatch }
        let artifact = try JSONDecoder().decode(Artifact.self, from: data)
        guard artifact.formatVersion == 1, artifact.featureIdentity == Self.featureIdentity,
              artifact.dimensions >= 1_024, artifact.dimensions <= 65_536,
              artifact.dimensions.nonzeroBitCount == 1, Self.isDigest(artifact.trainingDigest),
              !artifact.topics.isEmpty, artifact.topics.count <= Self.supportedTopicIDs.count,
              Set(artifact.topics.map(\.id)).count == artifact.topics.count,
              Set(artifact.topics.map(\.id)).isSubset(of: Self.supportedTopicIDs) else {
            throw SensitiveTopicClassifierError.invalidArtifact
        }
        guard selectedTopicIDs.isSubset(of: Set(artifact.topics.map(\.id))) else {
            throw SensitiveTopicClassifierError.unsupportedTopic
        }
        var compiled: [CompiledTopic] = []
        for topic in artifact.topics {
            guard topic.bias.isFinite, abs(topic.bias) <= 100,
                  topic.threshold.isFinite, topic.threshold > 0, topic.threshold < 1,
                  topic.weights.count <= artifact.dimensions else { throw SensitiveTopicClassifierError.invalidArtifact }
            var weights: [Int: Double] = [:]
            for (key, weight) in topic.weights {
                guard let index = Int(key), String(index) == key, index >= 0, index < artifact.dimensions,
                      weight.isFinite, abs(weight) <= 100 else { throw SensitiveTopicClassifierError.invalidArtifact }
                weights[index] = weight
            }
            if selectedTopicIDs.contains(topic.id) {
                compiled.append(.init(id: topic.id, bias: topic.bias, threshold: topic.threshold, weights: weights))
            }
        }
        self.artifactSHA256 = digest
        self.selectedTopicIDs = selectedTopicIDs
        self.availableTopicIDs = Set(artifact.topics.map(\.id))
        self.trainingDigest = artifact.trainingDigest
        self.dimensions = artifact.dimensions
        self.topics = compiled.sorted { $0.id < $1.id }
    }

    func detect(in text: String, complete: Bool) throws -> SensitiveTopicDetection {
        try Task.checkCancellation()
        guard text.utf16.count <= Self.maximumInputUTF16 else { throw SensitiveTopicClassifierError.inputTooLong }
        let fragments = try Self.sentences(in: text, complete: complete)
        var spans: [TranscriptRedactedSpan] = []
        var decisions: [SensitiveTopicDecision] = []
        let source = text as NSString
        for range in fragments.ranges {
            try Task.checkCancellation()
            let features = Self.features(in: source.substring(with: range), dimensions: dimensions)
            guard !features.isEmpty else { continue }
            let scale = 1 / sqrt(Double(features.count))
            var sensitive = false
            for topic in topics {
                let value = topic.bias + features.reduce(0) { $0 + (topic.weights[$1] ?? 0) * scale }
                let score = 1 / (1 + exp(-max(-40, min(40, value))))
                decisions.append(.init(range: range, topicID: topic.id, score: score))
                if score >= topic.threshold { sensitive = true }
            }
            if sensitive { spans.append(.init(range: range, replacement: "[СКРЫТО]")) }
        }
        return .init(spans: spans, safeUTF16: fragments.safeUTF16, decisions: decisions)
    }

    static func completedPrefixUTF16(in text: String) throws -> Int {
        guard text.utf16.count <= maximumInputUTF16 else { throw SensitiveTopicClassifierError.inputTooLong }
        return try sentences(in: text, complete: false).safeUTF16
    }

    static func features(in text: String, dimensions: Int) -> Set<Int> {
        let normalized = text.precomposedStringWithCanonicalMapping.lowercased()
        var words: [String] = []
        var word = ""
        for scalar in normalized.unicodeScalars {
            let alphanumeric: Bool
            switch scalar.properties.generalCategory {
            case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
                 .decimalNumber, .letterNumber, .otherNumber: alphanumeric = true
            default: alphanumeric = false
            }
            if alphanumeric { word.unicodeScalars.append(scalar) }
            else if !word.isEmpty { words.append(word); word = "" }
        }
        if !word.isEmpty { words.append(word) }
        var features: Set<Int> = []
        func add(_ value: String) {
            var hash: UInt64 = 14_695_981_039_346_656_037
            for byte in value.utf8 { hash = (hash ^ UInt64(byte)) &* 1_099_511_628_211 }
            features.insert(Int(hash % UInt64(dimensions)))
        }
        for (index, word) in words.enumerated() {
            add("w:" + word)
            if index > 0 { add("b:" + words[index - 1] + " " + word) }
            let characters = Array(("^" + word + "$").unicodeScalars)
            for length in 3...5 where characters.count >= length {
                for start in 0...(characters.count - length) {
                    add("c:" + String(String.UnicodeScalarView(characters[start..<(start + length)])))
                }
            }
        }
        return features
    }

    /// Punctuation is a textual boundary, not VAD silence. A decimal point between
    /// digits does not seal a sentence. The owner must supply the original bounded
    /// context; arbitrary ASR chunk endings cannot be declared complete.
    private static func sentences(in text: String, complete: Bool) throws -> (ranges: [NSRange], safeUTF16: Int) {
        var ranges: [NSRange] = []
        var start = text.startIndex
        var safe = 0
        var index = start
        var sentenceUTF16 = 0
        while index < text.endIndex {
            let character = text[index]
            let next = text.index(after: index)
            sentenceUTF16 += String(character).utf16.count
            guard sentenceUTF16 <= maximumSentenceUTF16 else { throw SensitiveTopicClassifierError.sentenceTooLong }
            let decimal = character == "." && index > text.startIndex && next < text.endIndex
                && text[text.index(before: index)].isNumber && text[next].isNumber
            // Newlines can be inserted at arbitrary ASR window boundaries. A short
            // dot-delimited token can be an initial or abbreviation, so hold it.
            var abbreviated = false
            if character == "." {
                let before = text[start..<index].split(whereSeparator: { $0.isWhitespace }).last.map(String.init) ?? ""
                abbreviated = before.count <= 2 || before.contains(".")
                    || ["млн", "млрд", "тыс", "руб", "коп", "стр", "рис", "проч"].contains(before.lowercased())
            }
            if !decimal && !abbreviated && (character == "." || character == "!" || character == "?") {
                let range = NSRange(start..<next, in: text)
                guard range.length <= maximumSentenceUTF16 else { throw SensitiveTopicClassifierError.sentenceTooLong }
                ranges.append(range); safe = NSMaxRange(range); start = next; sentenceUTF16 = 0
            }
            index = next
        }
        let tail = NSRange(start..<text.endIndex, in: text)
        guard tail.length <= maximumSentenceUTF16 else { throw SensitiveTopicClassifierError.sentenceTooLong }
        if complete {
            if tail.length > 0 { ranges.append(tail) }
            safe = text.utf16.count
        }
        return (ranges, safe)
    }

    private static func isDigest(_ value: String) -> Bool {
        value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
    }
}
