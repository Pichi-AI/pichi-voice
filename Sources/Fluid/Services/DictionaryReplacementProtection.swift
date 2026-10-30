import Foundation

/// Replaces already-resolved acoustic word spans while preserving the surrounding transcript.
/// Providers decide which non-overlapping spans are accepted; this layer owns UTF-16 text edits.
nonisolated enum DictionaryTranscriptReplacement {
    struct Replacement: Sendable {
        let wordRange: ClosedRange<Int>
        let label: String
    }

    static func apply(to text: String, wordTexts: [String], replacements: [Replacement]) -> String {
        let source = text as NSString
        var searchLocation = 0
        var ranges: [NSRange] = []
        let trimSet = CharacterSet.whitespacesAndNewlines.union(.punctuationCharacters)

        for wordText in wordTexts {
            let lexicalWord = wordText.trimmingCharacters(in: trimSet)
            // Native CTC may emit punctuation as its own timed token. Preserve
            // that token's index and require its exact surface as an anchor.
            let searchableWord = lexicalWord.isEmpty
                ? wordText.trimmingCharacters(in: .whitespacesAndNewlines) : lexicalWord
            guard !searchableWord.isEmpty, searchLocation <= source.length else { return text }
            let searchRange = NSRange(location: searchLocation, length: source.length - searchLocation)
            let range = source.range(of: searchableWord, options: .caseInsensitive, range: searchRange)
            guard range.location != NSNotFound else { return text }
            ranges.append(range)
            searchLocation = NSMaxRange(range)
        }

        let edits = replacements.compactMap { replacement -> (NSRange, String)? in
            guard ranges.indices.contains(replacement.wordRange.lowerBound),
                  ranges.indices.contains(replacement.wordRange.upperBound)
            else { return nil }
            let start = ranges[replacement.wordRange.lowerBound].location
            let end = NSMaxRange(ranges[replacement.wordRange.upperBound])
            return (NSRange(location: start, length: end - start), replacement.label)
        }.sorted { $0.0.location > $1.0.location }

        let output = NSMutableString(string: text)
        for (range, label) in edits {
            output.replaceCharacters(in: range, with: label)
        }
        return output as String
    }
}

/// Prevents a rule from expanding a completed occurrence of its own replacement.
/// Only rules whose output contains a partial trigger need this extra scan.
nonisolated enum DictionaryReplacementProtection {
    static func replacingMatches(
        in text: String,
        regex: NSRegularExpression,
        template: String,
        canonical: NSRegularExpression?,
        onReplacement: ((NSRange, String, String) -> Void)? = nil
    ) -> String {
        let fullRange = NSRange(text.startIndex..., in: text)
        guard canonical != nil || onReplacement != nil else {
            return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: template)
        }
        let completed = canonical?.matches(in: text, range: fullRange).map(\.range) ?? []
        guard !completed.isEmpty || onReplacement != nil else {
            return regex.stringByReplacingMatches(in: text, range: fullRange, withTemplate: template)
        }

        var completedIndex = 0
        let matches = regex.matches(in: text, range: fullRange).filter { match in
            while completedIndex < completed.count, NSMaxRange(completed[completedIndex]) <= match.range.location {
                completedIndex += 1
            }
            guard completedIndex < completed.count else { return true }
            let range = completed[completedIndex]
            let isPartialTriggerInsideCompletedOutput = range.location <= match.range.location &&
                NSMaxRange(match.range) <= NSMaxRange(range) && match.range.length < range.length
            return !isPartialTriggerInsideCompletedOutput
        }
        guard !matches.isEmpty else { return text }
        let output = NSMutableString(string: text)
        for match in matches.reversed() {
            let replacement = regex.replacementString(for: match, in: text, offset: 0, template: template)
            if let onReplacement {
                let heard = (text as NSString).substring(with: match.range)
                if heard != replacement {
                    onReplacement(match.range, heard, replacement)
                }
            }
            output.replaceCharacters(
                in: match.range,
                with: replacement
            )
        }
        return output as String
    }
}

/// Keep support logs bounded and on one line, including unusual user-defined rules.
nonisolated enum DictionaryReplacementDiagnostics {
    static let maximumEvents = 16

    static func quoted(_ text: String) -> String {
        let bounded = text.prefix(161)
        return (String(bounded.prefix(160)) + (bounded.count > 160 ? "…" : "")).debugDescription
    }
}
