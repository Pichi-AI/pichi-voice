import Foundation

public struct GigaAMWordTiming: Sendable, Equatable {
    public let text: String
    public let start: TimeInterval
    public let end: TimeInterval
    public let confidence: Float

    public init(text: String, start: TimeInterval, end: TimeInterval, confidence: Float) {
        self.text = text
        self.start = start
        self.end = end
        self.confidence = confidence
    }
}

public struct GigaAMTranscript: Sendable {
    public let text: String
    public let confidence: Float
    /// Approximate lexical CTC emission spans at 40 ms resolution, not forced alignment.
    /// Separate punctuation emissions do not extend a word containing letters or digits.
    public let words: [GigaAMWordTiming]
    public let endOfUtteranceProbability: Float?
    public let processingDuration: TimeInterval

    public init(text: String, confidence: Float, words: [GigaAMWordTiming], endOfUtteranceProbability: Float?, processingDuration: TimeInterval) {
        self.text = text
        self.confidence = confidence
        self.words = words
        self.endOfUtteranceProbability = endOfUtteranceProbability
        self.processingDuration = processingDuration
    }
}

struct GigaAMVocabulary: Sendable {
    let tokens: [String]
    let blankID: Int
    let unknownID: Int?
    let subword: Bool

    static let russianCharacters = GigaAMVocabulary(
        tokens: [" "] + (0..<32).map { String(UnicodeScalar(0x0430 + $0)!) } + ["<blk>"],
        blankID: 33,
        unknownID: nil,
        subword: false
    )

    init(tokens: [String], blankID: Int, unknownID: Int?, subword: Bool) {
        self.tokens = tokens
        self.blankID = blankID
        self.unknownID = unknownID
        self.subword = subword
    }

    init(contents: String) throws {
        var entries: [Int: String] = [:]
        for line in contents.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let separator = line.lastIndex(of: " "),
                  let id = Int(line[line.index(after: separator)...]),
                  id >= 0, id < 65_536, entries[id] == nil else {
                throw GigaAMError.invalidVocabulary
            }
            entries[id] = String(line[..<separator])
        }
        guard !entries.isEmpty,
              let maximum = entries.keys.max(), entries.count == maximum + 1 else {
            throw GigaAMError.invalidVocabulary
        }
        let tokens = (0...maximum).map { entries[$0]! }
        guard let blank = tokens.firstIndex(of: "<blk>") else { throw GigaAMError.invalidVocabulary }
        self.init(tokens: tokens, blankID: blank, unknownID: tokens.firstIndex(of: "<unk>"), subword: tokens.contains { $0.contains("▁") })
    }
}

/// Already-collapsed native CTC evidence, independent of its inference backend.
struct GigaAMCTCEmission: Sendable {
    let piece: String
    let start: TimeInterval
    let end: TimeInterval
    let confidence: Float

    init(piece: String, start: TimeInterval, end: TimeInterval, confidence: Float) {
        self.piece = piece
        self.start = start
        self.end = end
        // Some runtimes do not provide calibrated token probabilities. Preserve
        // their text while using finite zero for the existing unknown-score slot.
        self.confidence = confidence.isFinite && (0...1).contains(confidence) ? confidence : 0
    }
}

struct GigaAMCTC {
    static let frameDuration: TimeInterval = 0.04

    static func decode(logProbabilities: [Float], frameCount: Int, vocabulary: GigaAMVocabulary, audioDuration: TimeInterval) throws -> [GigaAMWordTiming] {
        let width = vocabulary.tokens.count
        guard frameCount >= 0, logProbabilities.count == frameCount * width else { throw GigaAMError.invalidOutput }
        struct Token {
            let piece: String
            let startFrame: Int
            var endFrame: Int
            var probability: Float
        }
        var tokens: [Token] = []
        var previous = -1
        for frame in 0..<frameCount {
            let offset = frame * width
            var best = 0
            for index in 1..<width where logProbabilities[offset + index] > logProbabilities[offset + best] {
                best = index
            }
            let probability = min(1, max(0, exp(logProbabilities[offset + best])))
            if best != vocabulary.blankID && best != vocabulary.unknownID {
                if best != previous {
                    tokens.append(Token(piece: vocabulary.tokens[best], startFrame: frame, endFrame: frame, probability: probability))
                } else if !tokens.isEmpty {
                    tokens[tokens.count - 1].endFrame = frame
                    tokens[tokens.count - 1].probability = max(tokens[tokens.count - 1].probability, probability)
                }
            }
            previous = best
        }
        let emissions = tokens.map {
            GigaAMCTCEmission(piece: $0.piece,
                             start: Double($0.startFrame) * Self.frameDuration,
                             end: Double($0.endFrame + 1) * Self.frameDuration,
                             confidence: $0.probability)
        }
        return try Self.words(emissions: emissions, subword: vocabulary.subword, audioDuration: audioDuration)
    }

    /// Both ONNX logits and native GGUF tokens use the same lexical envelope.
    static func words(emissions: [GigaAMCTCEmission], subword: Bool,
                      audioDuration: TimeInterval) throws -> [GigaAMWordTiming] {
        guard audioDuration.isFinite, audioDuration >= 0,
              emissions.allSatisfy({ $0.start.isFinite && $0.end.isFinite && $0.start >= 0 && $0.end >= $0.start }),
              zip(emissions, emissions.dropFirst()).allSatisfy({ $0.start <= $1.start }) else {
            throw GigaAMError.invalidOutput
        }
        var words: [GigaAMWordTiming] = []
        var currentText = ""
        var start = 0.0
        var end = 0.0
        var probabilities: [Float] = []
        var lexicalStart: TimeInterval?
        var lexicalEnd: TimeInterval?
        func flush() {
            guard !currentText.isEmpty else { return }
            // A punctuation token can be emitted much later than the spoken word, or
            // remain selected through a pause. Preserve its text and confidence, but
            // do not use that separate emission as acoustic evidence for the word.
            // Punctuation-only units retain their original complete emission span.
            let wordStart = lexicalStart ?? start
            let wordEnd = lexicalEnd ?? end
            words.append(GigaAMWordTiming(text: currentText, start: min(wordStart, audioDuration), end: min(max(wordStart + Self.frameDuration, wordEnd), audioDuration), confidence: probabilities.reduce(0, +) / Float(max(1, probabilities.count))))
            currentText = ""
            probabilities = []
            lexicalStart = nil
            lexicalEnd = nil
        }
        for token in emissions {
            let wordBoundary = subword ? token.piece.hasPrefix("▁") : token.piece == " "
            if wordBoundary { flush() }
            let piece = subword ? token.piece.replacingOccurrences(of: "▁", with: " ") : token.piece
            let body = piece.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !body.isEmpty else { continue }
            if currentText.isEmpty { start = token.start }
            currentText += body
            end = token.end
            if body.unicodeScalars.contains(where: { CharacterSet.alphanumerics.contains($0) }) {
                if lexicalStart == nil { lexicalStart = token.start }
                lexicalEnd = end
            }
            probabilities.append(token.confidence)
        }
        flush()
        return words
    }
}

public enum GigaAMError: LocalizedError {
    case frontendInitialization
    case invalidVocabulary
    case invalidOutput
    case invalidAudio
    case missingModels(URL)
    case checksumMismatch(String)
    case notPrepared
    case incompatibleModel
    case memoryBudgetExceeded

    public var errorDescription: String? {
        switch self {
        case .frontendInitialization: return "GigaAM audio frontend could not initialize."
        case .invalidVocabulary: return "GigaAM vocabulary is invalid or incomplete."
        case .invalidOutput: return "GigaAM returned an incompatible tensor."
        case .invalidAudio: return "GigaAM expects finite 16 kHz mono PCM samples."
        case .missingModels(let directory): return "Import the GigaAM model folder in Settings. Expected model files in \(directory.path)."
        case .checksumMismatch(let file): return "GigaAM checksum verification failed for \(file)."
        case .notPrepared: return "GigaAM is not loaded."
        case .incompatibleModel: return "This export is not a supported GigaAM v3 CTC model."
        case .memoryBudgetExceeded: return "Not enough memory is available for this GigaAM export. Select the compact model."
        }
    }
}
