import Foundation

struct PIIWord: Sendable, Equatable {
    let text: String
    let range: NSRange
    let ids: [Int64]
}

struct PIIEncodedWindow: Sendable {
    let ids: [Int64]
    let wordOf: [Int]
    let words: [PIIWord]
    let core: Range<Int>
}

/// Cased BERT WordPiece with UTF-16 offsets, matching Foundation/NSRegularExpression
/// and Pichi Transcribe's JS spans. Work is bounded and long text is windowed,
/// rather than silently truncating at the first 256 tokens.
struct PIIWordPieceTokenizer: Sendable {
    let vocabulary: [String: Int64]
    let cls: Int64
    let sep: Int64
    let unknown: Int64
    static let maximumInputUTF16 = 65_536
    static let maximumTokens = 256

    init(vocabulary contents: String) throws {
        var vocabulary: [String: Int64] = [:]
        for (i, line) in contents.components(separatedBy: "\n").enumerated() {
            let token = line.trimmingCharacters(in: .newlines)
            if !token.isEmpty { vocabulary[token] = Int64(i) }
        }
        guard let cls = vocabulary["[CLS]"], let sep = vocabulary["[SEP]"], let unknown = vocabulary["[UNK]"] else {
            throw TextPrivacyError.incompatibleModel
        }
        self.vocabulary = vocabulary
        self.cls = cls
        self.sep = sep
        self.unknown = unknown
    }

    func words(_ text: String) throws -> [PIIWord] {
        guard text.utf16.count <= Self.maximumInputUTF16 else { throw TextPrivacyError.inputTooLong }
        var result: [PIIWord] = []
        var current = ""
        var begin = 0
        var offset = 0
        func appendWord(_ word: String, _ start: Int, _ length: Int) {
            guard !word.isEmpty else { return }
            result.append(.init(text: word, range: NSRange(location: start, length: length), ids: pieces(word)))
        }
        // Scalar iteration preserves surrogate-pair lengths and combining marks.
        for scalar in text.unicodeScalars {
            let width = scalar.utf16.count
            let whitespace = CharacterSet.whitespacesAndNewlines.contains(scalar)
            let punctuation = CharacterSet.punctuationCharacters.contains(scalar) || CharacterSet.symbols.contains(scalar)
            let cjk = (0x4E00...0x9FFF).contains(scalar.value)
            if whitespace || punctuation || cjk {
                appendWord(current, begin, offset - begin)
                current = ""
                if punctuation || cjk { appendWord(String(scalar), offset, width) }
                begin = offset + width
            } else if !CharacterSet.controlCharacters.contains(scalar) {
                if current.isEmpty { begin = offset }
                current.unicodeScalars.append(scalar)
            }
            offset += width
        }
        appendWord(current, begin, offset - begin)
        return result
    }

    private func pieces(_ word: String) -> [Int64] {
        let chars = Array(word.unicodeScalars)
        guard chars.count <= 100 else { return [unknown] }
        var start = 0
        var ids: [Int64] = []
        while start < chars.count {
            var end = chars.count
            var found: Int64?
            while end > start {
                let part = String(String.UnicodeScalarView(chars[start..<end]))
                if let id = vocabulary[(start == 0 ? "" : "##") + part] { found = id; break }
                end -= 1
            }
            guard let found else { return [unknown] }
            ids.append(found)
            start = end
        }
        return ids
    }

    func windows(_ words: [PIIWord]) -> [PIIEncodedWindow] {
        guard !words.isEmpty else { return [] }
        let capacity = Self.maximumTokens - 2
        var windows: [PIIEncodedWindow] = []
        var coreStart = 0
        while coreStart < words.count {
            // 190 owned tokens plus bounded left/right context. The first window
            // still owns all words when it contains no preceding context.
            var coreEnd = coreStart
            var coreTokens = 0
            while coreEnd < words.count, coreTokens + words[coreEnd].ids.count <= 190 {
                coreTokens += words[coreEnd].ids.count; coreEnd += 1
            }
            if coreEnd == coreStart { coreEnd += 1; coreTokens = words[coreStart].ids.count }
            var lo = coreStart
            var count = coreTokens
            while lo > 0, count + words[lo - 1].ids.count <= min(capacity, coreTokens + 32) {
                lo -= 1; count += words[lo].ids.count
            }
            var hi = coreEnd
            while hi < words.count, count + words[hi].ids.count <= capacity {
                count += words[hi].ids.count; hi += 1
            }
            var ids = [cls]
            var wordOf = [-1]
            for i in lo..<hi {
                ids += words[i].ids
                wordOf += Array(repeating: i - lo, count: words[i].ids.count)
            }
            ids.append(sep); wordOf.append(-1)
            windows.append(.init(ids: ids, wordOf: wordOf, words: Array(words[lo..<hi]), core: (coreStart - lo)..<(coreEnd - lo)))
            coreStart = coreEnd
        }
        return windows
    }
}
