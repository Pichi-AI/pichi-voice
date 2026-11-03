import Foundation

/// Exact displayed text and UTF-16 occurrence owned by one temporary word editor.
/// The history store remains responsible for checking the profile and persistence.
nonisolated struct DictionaryInlineTextEdit: Equatable {
    let sourceText: String
    let range: NSRange

    init?(sourceText: String, range: NSRange) {
        guard range.location != NSNotFound, range.location >= 0, range.length > 0,
              range.length <= 320, let swiftRange = Range(range, in: sourceText),
              sourceText.indices.contains(swiftRange.lowerBound),
              swiftRange.upperBound == sourceText.endIndex || sourceText.indices.contains(swiftRange.upperBound) else { return nil }
        let selected = (sourceText as NSString).substring(with: range)
        guard selected.rangeOfCharacter(from: .alphanumerics) != nil,
              selected.rangeOfCharacter(from: .newlines) == nil else { return nil }
        self.sourceText = sourceText
        self.range = range
    }

    var heardText: String { (self.sourceText as NSString).substring(with: self.range) }

    func replacing(with replacement: String) -> String? {
        guard replacement.utf16.count <= 320,
              replacement.rangeOfCharacter(from: .newlines) == nil else { return nil }
        return (self.sourceText as NSString).replacingCharacters(in: self.range, with: replacement)
    }

    static func wordRanges(in text: String) -> [NSRange] {
        guard let regex = try? NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’\-][\p{L}\p{M}\p{N}]+)*"#) else { return [] }
        return regex.matches(in: text, range: NSRange(location: 0, length: (text as NSString).length))
            .map(\.range)
    }

    static func wordRange(at location: Int, in ranges: [NSRange]) -> NSRange? {
        guard location >= 0 else { return nil }
        var lower = 0
        var upper = ranges.count
        while lower < upper {
            let middle = lower + (upper - lower) / 2
            let range = ranges[middle]
            if location < range.location { upper = middle }
            else if location >= NSMaxRange(range) { lower = middle + 1 }
            else { return range }
        }
        return nil
    }

    /// Dragging across part of several words selects their complete contiguous
    /// phrase, so a compound term reaches the editor and dictionary as one value.
    static func phraseRange(for selection: NSRange, in ranges: [NSRange]) -> NSRange? {
        guard selection.location != NSNotFound, selection.location >= 0, selection.length > 0,
              selection.length <= Int.max - selection.location else { return nil }
        let selected = ranges.filter { NSIntersectionRange($0, selection).length > 0 }
        guard let first = selected.first, let last = selected.last else { return nil }
        return NSRange(location: first.location, length: NSMaxRange(last) - first.location)
    }
}
