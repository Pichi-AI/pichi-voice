import Foundation
import CryptoKit

nonisolated struct SensitiveDataDictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var phrase: String

    init(id: UUID = UUID(), phrase: String) { self.id = id; self.phrase = phrase }
}

nonisolated enum SensitiveDataDictionaryError: Error, Equatable {
    case emptyPhrase, phraseTooLong, tooManyWords, tooManyEntries, duplicatePhrase, invalidPhrase, entryNotFound, invalidStoredData, invalidRedaction
}

/// Bounded user rules, frozen alongside the model/rules capability for one attempt.
/// The fingerprint serializes a rules digest, never phrase text or persistent user identifiers.
nonisolated struct TranscriptSensitiveDictionarySnapshot: Sendable {
    static let maximumEntries = 128
    static let maximumPhraseUTF16 = 256
    // Fits within the publication owner's existing 32-token/1024-UTF16 context.
    static let maximumPhraseWords = 16
    static let maximumStoredBytes = 262_144
    static let replacement = "[СКРЫТО]"
    let entries: [SensitiveDataDictionaryEntry]
    let fingerprint: String
    private let rules: [Rule]
    private struct Rule: Sendable { let phrase: String; let expression: NSRegularExpression }

    init(entries: [SensitiveDataDictionaryEntry]) throws {
        guard entries.count <= Self.maximumEntries else { throw SensitiveDataDictionaryError.tooManyEntries }
        var seen: Set<String> = []
        var ids: Set<UUID> = []
        var sanitized: [SensitiveDataDictionaryEntry] = []
        var rules: [Rule] = []
        for entry in entries {
            let phrase = entry.phrase.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping
            guard !phrase.isEmpty else { throw SensitiveDataDictionaryError.emptyPhrase }
            guard phrase.utf16.count <= Self.maximumPhraseUTF16 else { throw SensitiveDataDictionaryError.phraseTooLong }
            guard phrase.split(whereSeparator: { $0.isWhitespace }).count <= Self.maximumPhraseWords else { throw SensitiveDataDictionaryError.tooManyWords }
            guard phrase.contains(where: { $0.isLetter || $0.isNumber }),
                  !phrase.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && !$0.properties.isWhitespace }),
                  !phrase.contains("["), !phrase.contains("]"), ids.insert(entry.id).inserted else { throw SensitiveDataDictionaryError.invalidPhrase }
            let normalized = Normalized(phrase).text
            guard seen.insert(normalized).inserted else { throw SensitiveDataDictionaryError.duplicatePhrase }
            let pattern = #"(?<![\p{L}\p{N}\p{M}_])"# + NSRegularExpression.escapedPattern(for: normalized) + #"(?![\p{L}\p{N}\p{M}_])"#
            rules.append(.init(phrase: normalized, expression: try NSRegularExpression(pattern: pattern)))
            sanitized.append(.init(id: entry.id, phrase: phrase))
        }
        self.entries = sanitized
        self.rules = rules.sorted { $0.phrase < $1.phrase }
        // JSON framing prevents collisions between a phrase containing separators and two rules.
        let identity = try JSONEncoder().encode(self.rules.map(\.phrase))
        self.fingerprint = "sensitive-dictionary-v1/" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
    }

    static func read(from defaults: UserDefaults, key: String) throws -> Self {
        guard let object = defaults.object(forKey: key) else { return try .init(entries: []) }
        guard let data = object as? Data, data.count <= maximumStoredBytes,
              let entries = try? JSONDecoder().decode([SensitiveDataDictionaryEntry].self, from: data) else {
            throw SensitiveDataDictionaryError.invalidStoredData
        }
        return try .init(entries: entries)
    }

    func persist(in defaults: UserDefaults, key: String) throws {
        let data = try JSONEncoder().encode(entries)
        guard data.count <= Self.maximumStoredBytes else { throw SensitiveDataDictionaryError.invalidStoredData }
        defaults.set(data, forKey: key)
    }

    var isEmpty: Bool { rules.isEmpty }

    func spans(in text: String) -> [TranscriptRedactedSpan] {
        guard !rules.isEmpty else { return [] }
        let normalized = Normalized(text)
        return rules.flatMap { rule in
            rule.expression.matches(in: normalized.text, range: NSRange(location: 0, length: normalized.ranges.count)).map {
                .init(range: normalized.sourceRange($0.range), replacement: Self.replacement)
            }
        }
    }

    /// A stable ASR edge can still be the start of a multiword user rule. Keep that
    /// original suffix behind the detector's display approval until it completes.
    func provisionalLimit(in text: String, maximum: Int) -> Int {
        guard !rules.isEmpty else { return maximum }
        let normalized = Normalized(text)
        let value = normalized.text as NSString
        var limit = maximum
        let lowerBound = max(0, value.length - Self.maximumPhraseUTF16 * 3)
        for start in lowerBound..<value.length {
            guard start == 0 || !Self.isWord(value, before: start),
                  !(0xDC00...0xDFFF).contains(value.character(at: start)) else { continue }
            let suffix = value.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suffix.isEmpty, rules.contains(where: { $0.phrase.hasPrefix(suffix) && $0.phrase != suffix }) else { continue }
            limit = min(limit, normalized.ranges[start].location)
        }
        return limit
    }

    private static func isWord(_ source: NSString, before offset: Int) -> Bool {
        let character = source.substring(with: source.rangeOfComposedCharacterSequence(at: offset - 1))
        guard let scalar = character.unicodeScalars.last else { return false }
        return CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar) || scalar == "_"
    }

    /// Canonical/case folding never changes source offsets. Every folded UTF16 unit
    /// maps to its complete original grapheme; whitespace runs map to their union.
    private struct Normalized {
        var text = ""
        var ranges: [NSRange] = []
        init(_ source: String) {
            var offset = 0
            for character in source {
                let raw = String(character)
                let range = NSRange(location: offset, length: raw.utf16.count)
                offset += range.length
                if character.isWhitespace {
                    if text.last == " " { ranges[ranges.count - 1] = NSUnionRange(ranges[ranges.count - 1], range) }
                    else { text += " "; ranges.append(range) }
                } else {
                    let folded = raw.precomposedStringWithCanonicalMapping
                        .folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
                        .precomposedStringWithCanonicalMapping
                    text += folded
                    ranges.append(contentsOf: repeatElement(range, count: folded.utf16.count))
                }
            }
        }
        func sourceRange(_ match: NSRange) -> NSRange {
            NSUnionRange(ranges[match.location], ranges[NSMaxRange(match) - 1])
        }
    }
}

/// Composes model spans with immutable local rules before the existing publication
/// projection. It owns no model resources, inference pipeline or UI-only masks.
nonisolated struct TranscriptDictionaryRedactor: TranscriptTextRedacting {
    let wrapped: any TranscriptTextRedacting
    let dictionary: TranscriptSensitiveDictionarySnapshot
    var checkpointIdentity: String? {
        guard let identity = wrapped.checkpointIdentity else { return nil }
        return dictionary.isEmpty ? identity : identity + "/" + dictionary.fingerprint
    }
    // VAD silence is not a phrase boundary. Keep the existing bounded lexical tail
    // when rules are active; normal provisional display and final flush still work.
    var supportsSpeechBoundaryAdmission: Bool { dictionary.isEmpty && wrapped.supportsSpeechBoundaryAdmission }
    func prepareForMeeting() async throws { try await wrapped.prepareForMeeting() }
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        try Task.checkCancellation()
        let base = try await wrapped.redactWithSpans(text)
        try Task.checkCancellation()
        return try merged(base, input: text)
    }
    func redactSpeechBoundaryWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        guard supportsSpeechBoundaryAdmission else { throw TranscriptTextRedactionError.unsupportedSpeechBoundary }
        return try await wrapped.redactSpeechBoundaryWithSpans(text)
    }
    private func merged(_ base: TranscriptTextRedaction, input: String) throws -> TranscriptTextRedaction {
        let baseOutput = NSMutableString(string: input)
        let baseSpans = base.spans.sorted { $0.range.location < $1.range.location }
        var previousEnd = 0
        for span in baseSpans {
            guard span.range.location >= previousEnd, span.range.length > 0,
                  span.range.location <= input.utf16.count, span.range.length <= input.utf16.count - span.range.location,
                  Range(span.range, in: input) != nil, !span.replacement.isEmpty else { throw SensitiveDataDictionaryError.invalidRedaction }
            previousEnd = NSMaxRange(span.range)
        }
        for span in baseSpans.reversed() { baseOutput.replaceCharacters(in: span.range, with: span.replacement) }
        guard baseOutput as String == base.text else { throw SensitiveDataDictionaryError.invalidRedaction }
        if let limit = base.provisionalSafeUTF16 {
            guard limit >= 0, limit <= input.utf16.count,
                  Range(NSRange(location: 0, length: limit), in: input) != nil,
                  !baseSpans.contains(where: { $0.range.location < limit && NSMaxRange($0.range) > limit }) else {
                throw SensitiveDataDictionaryError.invalidRedaction
            }
        }
        let ordered = (base.spans + dictionary.spans(in: input)).sorted {
            $0.range.location == $1.range.location ? $0.range.length > $1.range.length : $0.range.location < $1.range.location
        }
        var spans: [TranscriptRedactedSpan] = []
        for span in ordered {
            guard span.range.location >= 0, span.range.length > 0,
                  span.range.location <= input.utf16.count, span.range.length <= input.utf16.count - span.range.location,
                  Range(span.range, in: input) != nil, !span.replacement.isEmpty else { throw SensitiveDataDictionaryError.invalidPhrase }
            if let prior = spans.last, NSIntersectionRange(prior.range, span.range).length > 0 {
                spans[spans.count - 1] = .init(range: NSUnionRange(prior.range, span.range), replacement: prior.replacement)
            } else { spans.append(span) }
        }
        let result = NSMutableString(string: input)
        for span in spans.reversed() { result.replaceCharacters(in: span.range, with: span.replacement) }
        var limit = base.provisionalSafeUTF16.map { dictionary.provisionalLimit(in: input, maximum: $0) }
        if var safe = limit {
            for span in spans where span.range.location < safe && NSMaxRange(span.range) > safe { safe = span.range.location }
            limit = safe
        }
        return .init(text: result as String, spans: spans, provisionalSafeUTF16: limit)
    }
}
