import Foundation

struct PIITokenWindow: Sendable {
    let ids: [Int64]
    let offsets: [NSRange]
}

/// A1 uses token-level independent BIO heads, rather than tiny-news word votes.
/// This adapter preserves the author's BERT offsets and 256/64 sliding windows;
/// neither partial WordPieces nor overlap predictions are discarded.
extension PIIWordPieceTokenizer {
    init(tokenizerJSON: Data) throws {
        struct Configuration: Decodable {
            struct Model: Decodable {
                let type: String
                let unk_token: String
                let continuing_subword_prefix: String
                let max_input_chars_per_word: Int
                let vocab: [String: Int64]
            }
            struct Normalizer: Decodable {
                let type: String
                let clean_text: Bool
                let handle_chinese_chars: Bool
                let strip_accents: Bool?
                let lowercase: Bool
            }
            struct PreTokenizer: Decodable { let type: String }
            let model: Model
            let normalizer: Normalizer
            let pre_tokenizer: PreTokenizer
        }
        let config = try JSONDecoder().decode(Configuration.self, from: tokenizerJSON)
        guard config.model.type == "WordPiece", config.model.unk_token == "[UNK]",
              config.model.continuing_subword_prefix == "##", config.model.max_input_chars_per_word == 100,
              config.normalizer.type == "BertNormalizer", config.normalizer.clean_text,
              config.normalizer.handle_chinese_chars, config.normalizer.strip_accents != true,
              !config.normalizer.lowercase, config.pre_tokenizer.type == "BertPreTokenizer",
              let cls = config.model.vocab["[CLS]"], let sep = config.model.vocab["[SEP]"],
              let unknown = config.model.vocab["[UNK]"] else { throw TextPrivacyError.incompatibleModel }
        self.vocabulary = config.model.vocab
        self.cls = cls; self.sep = sep; self.unknown = unknown
    }

    func independentWindows(_ text: String) throws -> [PIITokenWindow] {
        guard text.utf16.count <= Self.maximumInputUTF16 else { throw TextPrivacyError.inputTooLong }
        // BERT normalizes control characters away without changing source offsets.
        var scalars: [(value: Unicode.Scalar, offset: Int, width: Int)] = []
        var offset = 0
        for scalar in text.unicodeScalars {
            defer { offset += scalar.utf16.count }
            let category = scalar.properties.generalCategory
            if scalar.value == 0 || scalar.value == 0xFFFD { continue }
            if (category == .control || category == .format), scalar != "\t", scalar != "\n", scalar != "\r" { continue }
            scalars.append((scalar, offset, scalar.utf16.count))
        }
        var tokens: [(id: Int64, range: NSRange)] = []
        var cursor = 0
        let special = ["[PAD]", "[UNK]", "[CLS]", "[SEP]", "[MASK]"]
        while cursor < scalars.count {
            try Task.checkCancellation()
            if CharacterSet.whitespacesAndNewlines.contains(scalars[cursor].value) { cursor += 1; continue }
            // Added special tokens are recognized even when touching ordinary text.
            var matchedSpecial = false
            for token in special {
                let chars = Array(token.unicodeScalars)
                if cursor + chars.count <= scalars.count,
                   zip(scalars[cursor..<(cursor + chars.count)], chars).allSatisfy({ $0.0.value == $0.1 }),
                   scalars[cursor + chars.count - 1].offset + scalars[cursor + chars.count - 1].width - scalars[cursor].offset == token.utf16.count,
                   let id = vocabulary[token] {
                    let last = scalars[cursor + chars.count - 1]
                    tokens.append((id, NSRange(location: scalars[cursor].offset, length: last.offset + last.width - scalars[cursor].offset)))
                    cursor += chars.count; matchedSpecial = true; break
                }
            }
            if matchedSpecial { continue }
            let start = cursor
            cursor += 1
            if !Self.isBERTBoundary(scalars[start].value) {
                while cursor < scalars.count,
                      !CharacterSet.whitespacesAndNewlines.contains(scalars[cursor].value),
                      !Self.isBERTBoundary(scalars[cursor].value) { cursor += 1 }
            }
            var pieces: [(id: Int64, range: NSRange)] = []
            var pieceStart = start
            if cursor - start <= 100 {
                while pieceStart < cursor {
                    var end = cursor
                    var found: Int64?
                    while end > pieceStart {
                        let part = String(String.UnicodeScalarView(scalars[pieceStart..<end].map(\.value)))
                        if let id = exactTokenID((pieceStart == start ? "" : "##") + part) { found = id; break }
                        end -= 1
                    }
                    guard let found else { pieces = []; break }
                    let last = scalars[end - 1]
                    pieces.append((found, NSRange(location: scalars[pieceStart].offset, length: last.offset + last.width - scalars[pieceStart].offset)))
                    pieceStart = end
                }
            }
            let last = scalars[cursor - 1]
            tokens += pieces.isEmpty ? [(unknown, NSRange(location: scalars[start].offset, length: last.offset + last.width - scalars[start].offset))] : pieces
        }
        var windows: [PIITokenWindow] = []
        var start = 0
        while start < tokens.count {
            let end = min(start + Self.maximumTokens - 2, tokens.count)
            windows.append(.init(ids: [cls] + tokens[start..<end].map(\.id) + [sep],
                                 offsets: [.init(location: 0, length: 0)] + tokens[start..<end].map(\.range) + [.init(location: 0, length: 0)]))
            if end == tokens.count { break }
            start = end - 64
        }
        return windows
    }

    private func exactTokenID(_ token: String) -> Int64? {
        // Swift strings compare canonically equivalent Unicode sequences. The
        // published Rust tokenizer compares vocabulary bytes, so decomposed Ё
        // must not silently match precomposed Ё (or change a source boundary).
        guard let index = vocabulary.index(forKey: token),
              vocabulary[index].key.utf8.elementsEqual(token.utf8) else { return nil }
        return vocabulary[index].value
    }

    private static func isBERTBoundary(_ scalar: Unicode.Scalar) -> Bool {
        // BertPreTokenizer splits Unicode punctuation and ASCII punctuation,
        // including ASCII symbols. Other symbols such as emoji remain word data.
        let v = scalar.value
        return CharacterSet.punctuationCharacters.contains(scalar) || (33...47).contains(v) || (58...64).contains(v)
            || (91...96).contains(v) || (123...126).contains(v)
            || (0x4E00...0x9FFF).contains(v) || (0x3400...0x4DBF).contains(v)
            || (0x20000...0x2A6DF).contains(v) || (0x2A700...0x2B73F).contains(v)
            || (0x2B740...0x2B81F).contains(v) || (0x2B820...0x2CEAF).contains(v)
            || (0xF900...0xFAFF).contains(v) || (0x2F800...0x2FA1F).contains(v)
    }
}

extension PIINERRuntime {
    static func decodeIndependent(logits: [Float], labels: [String], window: PIITokenWindow) throws -> [PIINERSpan] {
        guard !labels.isEmpty, window.ids.count == window.offsets.count,
              logits.count == window.ids.count * labels.count * 3, logits.allSatisfy(\.isFinite) else {
            throw TextPrivacyError.invalidOutput
        }
        var spans: [PIINERSpan] = []
        for (head, label) in labels.enumerated() {
            var current: NSRange?
            func flush() {
                if let current {
                    // A1 publishes discrete decisions, not calibrated confidence.
                    spans.append(.init(range: current, label: Self.privacyLabel(for: label), score: 1))
                }
                current = nil
            }
            for (token, range) in window.offsets.enumerated() {
                let base = (token * labels.count + head) * 3
                // numpy.argmax resolves ties to the first BIO class.
                var tag = 0
                for candidate in 1..<3 where logits[base + candidate] > logits[base + tag] { tag = candidate }
                guard range.length > 0, tag != 0 else { flush(); continue }
                if tag == 1 || current == nil { flush(); current = range }
                else if let previous = current { current = NSUnionRange(previous, range) }
            }
            flush()
        }
        return spans
    }

    private static func privacyLabel(for head: String) -> String {
        // Translate inference heads once into the existing product policy labels.
        switch head {
        case "FULL_NAME", "CARDHOLDER_NAME": return "PER"
        case "DATE_OF_BIRTH": return "DOB"
        case "CARD_NUMBER": return "CARD"
        case "CVV", "PIN": return "SECRET"
        case "DRIVER_LICENSE": return "NUMBER"
        default: return head
        }
    }

    static func mergeIndependent(_ spans: [PIINERSpan]) -> [PIINERSpan] {
        let sorted = spans.sorted {
            if $0.label != $1.label { return $0.label < $1.label }
            if $0.range.location != $1.range.location { return $0.range.location < $1.range.location }
            return $0.range.length < $1.range.length
        }
        var merged: [PIINERSpan] = []
        for span in sorted {
            if let last = merged.last, last.label == span.label, span.range.location < NSMaxRange(last.range) {
                merged[merged.count - 1] = .init(range: NSUnionRange(last.range, span.range), label: span.label, score: 1)
            } else { merged.append(span) }
        }
        return merged
    }
}
