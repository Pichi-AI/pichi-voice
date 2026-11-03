import Foundation
import CryptoKit
import PichiRussianMorphology

nonisolated enum SensitiveDictionaryMatchMode: String, Codable, CaseIterable, Sendable {
    case exact, wordForms
}

nonisolated struct SensitiveDataDictionaryEntry: Codable, Identifiable, Equatable, Sendable {
    let id: UUID
    var phrase: String
    var matchMode: SensitiveDictionaryMatchMode

    init(id: UUID = UUID(), phrase: String, matchMode: SensitiveDictionaryMatchMode = .wordForms) {
        self.id = id; self.phrase = phrase; self.matchMode = matchMode
    }
    private enum CodingKeys: String, CodingKey { case id, phrase, matchMode }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        phrase = try container.decode(String.self, forKey: .phrase)
        // Existing rules gain the requested word-form behavior. The new fingerprint
        // prevents restoration under a previous literal-only policy.
        matchMode = try container.decodeIfPresent(SensitiveDictionaryMatchMode.self, forKey: .matchMode) ?? .wordForms
    }
}

nonisolated enum SensitiveDataDictionaryError: Error, Equatable {
    case emptyPhrase, phraseTooLong, tooManyWords, tooManyEntries, duplicatePhrase, invalidPhrase, entryNotFound, invalidStoredData, invalidRedaction, compiledRulesTooLarge
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
    private let topicClassifier: SensitiveTopicClassifierSnapshot?
    private struct Rule: Sendable {
        let phrase: String
        let forms: [Set<String>]?
        let expression: NSRegularExpression
    }

    init(entries: [SensitiveDataDictionaryEntry], selectedGroupIDs: Set<String> = [],
         groupTermOverrides: [String: [String]] = [:],
         topicClassifier: SensitiveTopicClassifierSnapshot? = nil) throws {
        guard entries.count <= Self.maximumEntries else { throw SensitiveDataDictionaryError.tooManyEntries }
        var seen: Set<String> = []
        var ids: Set<UUID> = []
        var sanitized: [SensitiveDataDictionaryEntry] = []
        var rules: [Rule] = []
        let morphology = SensitiveDictionaryMorphologySnapshot()
        var compiledBytes = 0
        func compile(_ phrase: String, mode: SensitiveDictionaryMatchMode) throws -> Rule {
            let normalized = Normalized(phrase).text
            var forms: [Set<String>]? = nil
            if mode == .wordForms {
                forms = try normalized.split(separator: " ").map { token in
                    let word = String(token)
                    let alternatives = try morphology.forms(for: word) ?? [word]
                    guard alternatives.count <= 256 else { throw SensitiveDataDictionaryError.compiledRulesTooLarge }
                    return Set(alternatives.map { Normalized($0).text.replacingOccurrences(of: "ё", with: "е") })
                        .union([word.replacingOccurrences(of: "ё", with: "е")])
                }
            }
            let body = forms.map { tokens in
                tokens.map { alternatives in
                    "(?:" + alternatives.sorted().map { word in
                        word.map { character in
                            character == "е" ? "[её]" : NSRegularExpression.escapedPattern(for: String(character))
                        }.joined()
                    }.joined(separator: "|") + ")"
                }.joined(separator: " ")
            } ?? NSRegularExpression.escapedPattern(for: normalized)
            compiledBytes += body.utf8.count
            guard compiledBytes <= 2_097_152 else { throw SensitiveDataDictionaryError.compiledRulesTooLarge }
            let pattern = #"(?<![\p{L}\p{N}\p{M}_])"# + body + #"(?![\p{L}\p{N}\p{M}_])"#
            return .init(phrase: normalized, forms: forms, expression: try NSRegularExpression(pattern: pattern))
        }
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
            rules.append(try compile(phrase, mode: entry.matchMode))
            sanitized.append(.init(id: entry.id, phrase: phrase, matchMode: entry.matchMode))
        }
        guard selectedGroupIDs.isSubset(of: Set(SensitiveBusinessGroupCatalog.groups.map(\.id))) else {
            throw SensitiveDataDictionaryError.invalidStoredData
        }
        guard Set(groupTermOverrides.keys).isSubset(of: Set(SensitiveBusinessGroupCatalog.groups.map(\.id))) else {
            throw SensitiveDataDictionaryError.invalidStoredData
        }
        for terms in groupTermOverrides.values {
            guard terms.count <= 128 else { throw SensitiveDataDictionaryError.tooManyEntries }
            // Reuse the user phrase validation without including private override
            // text in public capability names or changing the selected groups.
            _ = try TranscriptSensitiveDictionarySnapshot(entries: terms.map { .init(phrase: $0) })
        }
        let groups = SensitiveBusinessGroupCatalog.groups.filter { selectedGroupIDs.contains($0.id) }
        let groupTerms = Set(groups.flatMap { groupTermOverrides[$0.id] ?? $0.terms })
        guard groupTerms.count <= 128 else { throw SensitiveDataDictionaryError.tooManyEntries }
        for phrase in groupTerms.sorted() { rules.append(try compile(phrase, mode: .wordForms)) }
        self.entries = sanitized
        self.rules = rules.sorted { $0.phrase < $1.phrase }
        self.topicClassifier = topicClassifier
        struct Identity: Encodable {
            struct Entry: Encodable { let phrase: String; let mode: SensitiveDictionaryMatchMode }
            let entries: [Entry]
            let groups: [String]
            let catalog: String
            let morphology: String
            let classifier: String?
            let compiledRuleDigest: String
        }
        let identityEncoder = JSONEncoder()
        identityEncoder.outputFormatting = [.sortedKeys]
        let identity = try identityEncoder.encode(Identity(
            entries: sanitized.map { .init(phrase: Normalized($0.phrase).text, mode: $0.matchMode) }
                .sorted { $0.phrase < $1.phrase }, groups: selectedGroupIDs.sorted(),
            catalog: SensitiveBusinessGroupCatalog.version,
            morphology: SensitiveDictionaryMorphologySnapshot.resourceIdentity,
            classifier: topicClassifier?.identity,
            compiledRuleDigest: SHA256.hash(data: try JSONEncoder().encode(self.rules.map { $0.expression.pattern }))
                .map { String(format: "%02x", $0) }.joined()))
        self.fingerprint = "sensitive-dictionary-v2/" + SHA256.hash(data: identity).map { String(format: "%02x", $0) }.joined()
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

    var isEmpty: Bool { rules.isEmpty && topicClassifier == nil }

    /// Only an explicitly selected group or a complete recognized dictionary seed
    /// opts its supported topic into semantic masking. Substrings such as "ТЗ" or
    /// "компания" cannot activate every topic whose phrases happen to contain them.
    func inferredTopicIDs(selectedGroupIDs: Set<String>) throws -> Set<String> {
        var topics = selectedGroupIDs.intersection(SensitiveTopicClassifierSnapshot.supportedTopicIDs)
        for group in SensitiveBusinessGroupCatalog.groups
            where SensitiveTopicClassifierSnapshot.supportedTopicIDs.contains(group.id) && !topics.contains(group.id) {
            let seeds = SensitiveBusinessGroupCatalog.semanticSeeds(for: group)
            for seed in seeds {
                let entire = NSRange(location: 0, length: seed.utf16.count)
                if try spans(in: seed).contains(where: { $0.range == entire }) {
                    topics.insert(group.id)
                    break
                }
            }
        }
        return topics
    }

    var selectedTopicIDs: Set<String> { topicClassifier?.selectedTopicIDs ?? [] }

    func spans(in text: String) throws -> [TranscriptRedactedSpan] {
        let normalized = Normalized(text)
        let lexical: [TranscriptRedactedSpan] = rules.flatMap { rule in
            rule.expression.matches(in: normalized.text, range: NSRange(location: 0, length: normalized.ranges.count)).map {
                .init(range: normalized.sourceRange($0.range), replacement: Self.replacement)
            }
        }
        return try lexical + (topicClassifier?.detect(in: text, complete: true).spans ?? [])
    }

    func durablePublicationLimit(in text: String) throws -> Int? {
        guard topicClassifier != nil else { return nil }
        return try SensitiveTopicClassifierSnapshot.completedPrefixUTF16(in: text)
    }

    /// A stable ASR edge can still be the start of a multiword user rule. Keep that
    /// original suffix behind the detector's display approval until it completes.
    func provisionalLimit(in text: String, maximum: Int) throws -> Int {
        let normalized = Normalized(text)
        let value = normalized.text as NSString
        var limit = try min(maximum, topicClassifier?.detect(in: text, complete: false).safeUTF16 ?? maximum)
        let lowerBound = max(0, value.length - Self.maximumPhraseUTF16 * 3)
        for start in lowerBound..<value.length {
            guard start == 0 || !Self.isWord(value, before: start),
                  !(0xDC00...0xDFFF).contains(value.character(at: start)) else { continue }
            let suffix = value.substring(from: start).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !suffix.isEmpty, rules.contains(where: { Self.isIncompletePrefix(suffix, of: $0) }) else { continue }
            limit = min(limit, normalized.ranges[start].location)
        }
        return limit
    }

    private static func isIncompletePrefix(_ suffix: String, of rule: Rule) -> Bool {
        guard let forms = rule.forms else { return rule.phrase.hasPrefix(suffix) && rule.phrase != suffix }
        let words = suffix.split(separator: " ").map { String($0).replacingOccurrences(of: "ё", with: "е") }
        guard !words.isEmpty, words.count <= forms.count else { return false }
        for i in words.indices.dropLast() where !forms[i].contains(words[i]) { return false }
        let last = words.count - 1
        guard forms[last].contains(where: { $0.hasPrefix(words[last]) }) else { return false }
        return words.count < forms.count || !forms[last].contains(words[last])
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
    func durablePublicationLimit(in text: String) throws -> Int? {
        let own = try dictionary.durablePublicationLimit(in: text)
        let base = try wrapped.durablePublicationLimit(in: text)
        if let own, let base { return min(own, base) }
        return own ?? base
    }
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
        let ordered = (base.spans + (try dictionary.spans(in: input))).sorted {
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
        var limit = try base.provisionalSafeUTF16.map { try dictionary.provisionalLimit(in: input, maximum: $0) }
        if var safe = limit {
            for span in spans where span.range.location < safe && NSMaxRange(span.range) > safe { safe = span.range.location }
            limit = safe
        }
        return .init(text: result as String, spans: spans, provisionalSafeUTF16: limit)
    }
}
