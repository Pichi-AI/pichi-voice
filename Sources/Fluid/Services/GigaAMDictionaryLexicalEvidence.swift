import Foundation

/// Comparison keys never replace, translate or persist a user's spelling. This
/// supplies bounded lexical evidence; the inference adapter still owns all sound
/// thresholds, reference provenance, competition checks and the final decision.
nonisolated enum GigaAMDictionaryLexicalEvidence {
    // Foundation regex instances are immutable. Keep patterns, rather than user
    // text or decisions, shared across the independent matching requests.
    private static let tokenExpression = try? NSRegularExpression(pattern: #"[\p{L}\p{M}\p{N}]+(?:['’][\p{L}\p{M}\p{N}]+)*"#)
    private static let camelBoundary = try? NSRegularExpression(pattern: #"([\p{Ll}\p{N}])(\p{Lu})"#)
    private static let acronymBoundary = try? NSRegularExpression(pattern: #"(\p{Lu})(\p{Lu}\p{Ll})"#)

    enum Reason: String, Sendable {
        case invalidTerm, protectedContent, noObservedVariant, formattingOnly
        case unknownChangedComponents, knownChangedComponent, lexiconUnavailable
    }

    struct Comparison: Sendable {
        let changedSourceComponents: [String]
        let changedTargetComponents: [String]
        let canonicalSimilarity: Double
        let observedSimilarity: Double
        let phoneticSimilarity: Double
        let hasObservedVariants: Bool
        let matchesObservedVariant: Bool
        let protectsContent: Bool
    }

    struct Assessment: Sendable {
        let comparison: Comparison?
        let reason: Reason
        var allowsWeakCorrection: Bool { reason == .unknownChangedComponents }
        var requiresStrictAcousticEvidence: Bool { reason == .knownChangedComponent }
    }

    private struct Token {
        let text: String
        let key: String
        let lexicalText: String
        let component: Int
    }

    static func compare(heard: String, canonical: String, observedVariants: [String]) -> Comparison? {
        guard let source = self.tokens(heard), let target = self.tokens(canonical) else { return nil }
        let sourceKey = self.phoneticKey(heard), targetKey = self.phoneticKey(canonical)
        guard !sourceKey.isEmpty, !targetKey.isEmpty else { return nil }
        let variants = observedVariants.prefix(20).filter { self.tokens($0) != nil }
        let observed = variants.map { self.similarity(heard, $0) }.max() ?? 0
        let canonicalScore = self.similarity(heard, canonical)
        let equivalent = source.map(\.key).joined() == target.map(\.key).joined()
        let common = self.unchanged(source.map(\.key), target.map(\.key))
        let changedSource = equivalent ? [] : self.changedComponents(source, unchanged: common.source)
        let changedTarget = equivalent ? [] : self.changedComponents(target, unchanged: common.target)
        return Comparison(
            changedSourceComponents: changedSource, changedTargetComponents: changedTarget,
            canonicalSimilarity: canonicalScore, observedSimilarity: observed,
            phoneticSimilarity: max(canonicalScore, observed), hasObservedVariants: !variants.isEmpty,
            matchesObservedVariant: variants.contains { self.literalKey($0) == self.literalKey(heard) },
            protectsContent: self.numberMarkers(heard) != self.numberMarkers(canonical) ||
                self.roleMarkers(heard) != self.roleMarkers(canonical)
        )
    }

    /// An enrolled whole spelling may represent the terminal component of an
    /// uppercase acronym as its spoken transliteration. Keep the existing ASCII
    /// letter rule and require matching token boundaries for the new form. Every
    /// other role and number is rechecked; the caller still requires ordinary,
    /// calibrated two-reference audio and its negative and competitor vetoes.
    static func recordedTerminalLetterI(heard: String, canonical: String, observedVariants: [String]) -> Bool {
        guard let original = self.compare(heard: heard, canonical: canonical, observedVariants: observedVariants),
              original.protectsContent, original.matchesObservedVariant,
              let component = canonical.split(whereSeparator: \.isWhitespace).last,
              (2...5).contains(component.count), component.last == "I",
              component.unicodeScalars.allSatisfy({ (65...90).contains($0.value) }),
              let finalLetter = heard.range(of: #"(?<![\p{L}\p{N}])[\p{L}]+(?=[^\p{L}\p{N}]*$)"#, options: .regularExpression) else { return false }
        let token = String(heard[finalLetter])
        let transliterated = self.literalKey(token)
        let normalized = transliterated.hasSuffix("j") ? String(transliterated.dropLast()) + "i" : transliterated
        guard token == "I" || normalized == self.literalKey(String(component)) else { return false }
        if token != "I" {
            guard let sourceTokens = self.tokens(heard),
                  observedVariants.contains(where: { self.tokens($0)?.map(\.key) == sourceTokens.map(\.key) }) else { return false }
        }
        let terminalPair = heard.range(of: #"(?<![\p{L}\p{N}])и\s+[\p{L}]+(?=[^\p{L}\p{N}]*$)"#, options: .regularExpression)
        var adjusted = heard
        adjusted.replaceSubrange(terminalPair ?? finalLetter, with: component)
        guard let comparison = self.compare(heard: adjusted, canonical: canonical, observedVariants: []) else { return false }
        return !comparison.protectsContent
    }

    @MainActor static func assess(heard: String, canonical: String, observedVariants: [String], requiredLanguages: [String]) -> Assessment {
        guard !Task.isCancelled, let comparison = self.compare(heard: heard, canonical: canonical, observedVariants: observedVariants) else {
            return Assessment(comparison: nil, reason: .invalidTerm)
        }
        if comparison.protectsContent { return Assessment(comparison: comparison, reason: .protectedContent) }
        if comparison.changedSourceComponents.isEmpty && comparison.changedTargetComponents.isEmpty {
            return Assessment(comparison: comparison, reason: .formattingOnly)
        }
        guard comparison.hasObservedVariants else { return Assessment(comparison: comparison, reason: .noObservedVariant) }
        guard DictionaryLexicalEvidence.hasRequiredLexicons(requiredLanguages) else {
            return Assessment(comparison: comparison, reason: .lexiconUnavailable)
        }
        // Only changed components are questioned. A correctly recognized shared
        // suffix such as "Voice" is not evidence against repairing another token.
        guard !comparison.changedSourceComponents.isEmpty else { return Assessment(comparison: comparison, reason: .protectedContent) }
        for component in comparison.changedSourceComponents {
            guard !Task.isCancelled else { return Assessment(comparison: comparison, reason: .invalidTerm) }
            if !DictionaryLexicalEvidence.isUnknownTerm(component, requiredLanguages: requiredLanguages) {
                // Homophones and real ordinary words need stronger acoustic
                // evidence. Lexical resemblance alone never admits them here.
                return Assessment(comparison: comparison, reason: .knownChangedComponent)
            }
        }
        return Assessment(comparison: comparison, reason: .unknownChangedComponents)
    }

    static func phoneticKey(_ text: String) -> String {
        guard let tokens = self.tokens(text) else { return "" }
        let result = tokens.map { self.soundKey($0.text) }.joined()
        return result.count <= 160 ? result : ""
    }

    /// Component boundaries are required for registered compound relationships;
    /// a scalar spelling prefix does not make two different words a compound.
    static func componentKeys(_ text: String) -> [String]? {
        self.tokens(text)?.map(\.key)
    }

    /// A recorded spelling may corroborate a grammatical ending, but cannot
    /// authorize a correction by itself. Keep all vowels and component boundaries
    /// here: consonant-only similarity would confuse ordinary words and names.
    static func observedStemSupport(heard: String, canonical: String, observedVariants: [String]) -> Bool {
        guard observedVariants.count <= 20,
              let source = self.tokens(heard), let target = self.tokens(canonical),
              let canonicalComparison = self.compare(heard: heard, canonical: canonical, observedVariants: []),
              !canonicalComparison.protectsContent else { return false }
        // The current source must still contain every part of a compound. A
        // truncated recorded alias is never proof of an additional component.
        guard target.count == 1 || self.supportsCanonicalComponents(heard: heard, canonical: canonical) else { return false }
        let sourceKeys = source.map { self.soundKey($0.text, preservingVowels: true) }
        let endings: Set<String> = ["", "e", "a", "u", "om", "em"]
        for variant in observedVariants {
            guard let recorded = self.tokens(variant), recorded.count == source.count,
                  let comparison = self.compare(heard: heard, canonical: variant, observedVariants: []),
                  !comparison.protectsContent else { continue }
            let recordedKeys = recorded.map { self.soundKey($0.text, preservingVowels: true) }
            guard sourceKeys.dropLast().elementsEqual(recordedKeys.dropLast()),
                  let stem = recordedKeys.last, let inflected = sourceKeys.last,
                  stem.count >= 4, inflected.hasPrefix(stem) else { continue }
            let ending = String(inflected.dropFirst(stem.count))
            if endings.contains(ending) { return true }
        }
        return false
    }

    /// A sound hit inside one CTC word still replaces that entire word. Do not
    /// erase an extra word or a material fused component when only its prefix
    /// resembles the canonical label. This is a veto, never admission evidence.
    static func dropsSourceComponents(heard: String, canonical: String) -> Bool {
        guard let sourceTokens = self.tokens(heard), let target = self.tokens(canonical) else { return true }
        let source = Array(self.phoneticKey(heard))
        let sourceComponents = sourceTokens.enumerated().flatMap { index, token in
            Array(repeating: index, count: self.soundKey(token.text).count)
        }
        var position = 0
        for token in target {
            guard position < source.count else { return false }
            let component = self.soundKey(token.text)
            var bestEnd = position, bestScore = -Double.infinity
            for end in (position + 1)...source.count {
                let score = self.editSimilarity(String(source[position..<end]), component)
                if score > bestScore + 1e-9 || (abs(score - bestScore) <= 1e-9 && end > bestEnd) {
                    bestEnd = end; bestScore = score
                }
            }
            guard bestScore >= 2.0 / 3.0 else { return false }
            position = bestEnd
        }
        let residual = String(source.dropFirst(position))
        guard !residual.isEmpty else { return false }
        guard ["e", "a", "u", "om", "em"].contains(residual), position > 0,
              sourceComponents.count == source.count else { return true }
        // CamelCase and ASR word splits are harmless when all their letters are
        // covered. An ignored ending must stay inside the matched source
        // component, without crossing whitespace or a CamelCase boundary.
        return !sourceComponents.dropFirst(position).allSatisfy { $0 == sourceComponents[position - 1] }
    }

    /// Every canonical component needs actual current-source letters. The best
    /// prefix is consumed greedily, including the whole remaining source as a
    /// possibility, so a shorter prefix cannot fabricate an unspoken suffix.
    /// This deliberately uses no consonant-only score and no saved aliases.
    static func supportsCanonicalComponents(heard: String, canonical: String) -> Bool {
        guard let target = self.tokens(canonical) else { return false }
        let components = target.map { self.soundKey($0.text) }
        let source = Array(self.phoneticKey(heard))
        guard !source.isEmpty, components.allSatisfy({ !$0.isEmpty }) else { return false }
        if String(source) == components.joined() { return true }
        var position = 0
        for (index, component) in components.enumerated() {
            guard position < source.count else { return false }
            let remainder = String(source[position...])
            if index == components.count - 1 {
                return self.editSimilarity(remainder, component) >= 2.0 / 3.0
            }
            var bestEnd = position, bestScore = -Double.infinity
            for end in (position + 1)...source.count {
                let score = self.editSimilarity(String(source[position..<end]), component)
                if score > bestScore + 1e-9 || (abs(score - bestScore) <= 1e-9 && end > bestEnd) {
                    bestEnd = end; bestScore = score
                }
            }
            guard bestScore >= 2.0 / 3.0, bestEnd < source.count else { return false }
            position = bestEnd
        }
        return false
    }

    private static func tokens(_ text: String) -> [Token]? {
        guard !text.isEmpty, text.count <= 80, text.rangeOfCharacter(from: .newlines) == nil else { return nil }
        guard let regex = self.tokenExpression, let camelBoundary = self.camelBoundary,
              let acronymBoundary = self.acronymBoundary else { return nil }
        let value = text as NSString
        let parts = regex.matches(in: text, range: NSRange(location: 0, length: value.length)).map { value.substring(with: $0.range) }
        guard (1...4).contains(parts.count), parts.allSatisfy({ $0.count <= 80 }) else { return nil }
        let tokens = parts.enumerated().flatMap { index, original in
            let camelSplit = camelBoundary.stringByReplacingMatches(in: original,
                range: NSRange(location: 0, length: (original as NSString).length), withTemplate: "$1 $2")
            let split = acronymBoundary.stringByReplacingMatches(in: camelSplit,
                range: NSRange(location: 0, length: (camelSplit as NSString).length), withTemplate: "$1 $2")
            return split.split(whereSeparator: \.isWhitespace).map {
                Token(text: String($0), key: self.literalKey(String($0)), lexicalText: original, component: index)
            }
        }
        return tokens.count <= 16 ? tokens : nil
    }

    private static func changedComponents(_ tokens: [Token], unchanged: Set<Int>) -> [String] {
        var seen = Set<Int>()
        return tokens.indices.compactMap { index in
            guard !unchanged.contains(index), seen.insert(tokens[index].component).inserted else { return nil }
            return tokens[index].lexicalText
        }
    }

    private static func literalKey(_ text: String) -> String {
        let latin = text.applyingTransform(.toLatin, reverse: false) ?? text
        return (latin.applyingTransform(.stripCombiningMarks, reverse: false) ?? latin)
            .lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func soundKey(_ text: String, preservingVowels: Bool = false) -> String {
        var value = (text.applyingTransform(.toLatin, reverse: false) ?? text).lowercased()
        // Standard transliteration marks are expanded before diacritic removal.
        for (before, after) in [("č", "ch"), ("š", "sh"), ("ž", "zh"), ("ŝ", "sh"), ("ǰ", "j")] {
            value = value.replacingOccurrences(of: before, with: after)
        }
        value = (value.applyingTransform(.stripCombiningMarks, reverse: false) ?? value).filter { $0.isLetter || $0.isNumber }
        for (before, after) in [("ph", "f"), ("ck", "k")] {
            value = value.replacingOccurrences(of: before, with: after)
        }
        if !preservingVowels {
            for (before, after) in [("qu", "k"), ("au", "o"), ("aw", "o"), ("ou", "o"), ("ow", "o"),
                                    ("ee", "i"), ("ea", "i"), ("oo", "u")] {
                value = value.replacingOccurrences(of: before, with: after)
            }
        }
        value = value.replacingOccurrences(of: "c(?=[eiy])", with: "s", options: .regularExpression)
            .replacingOccurrences(of: "c", with: "k").replacingOccurrences(of: "j", with: "y")
        if !preservingVowels, value.count >= 4, value.hasSuffix("e") { value.removeLast() }
        return value
    }

    private static func similarity(_ first: String, _ second: String) -> Double {
        let a = self.phoneticKey(first), b = self.phoneticKey(second)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let direct = self.editSimilarity(a, b)
        let vowels = Set("aeiouy")
        let ac = a.filter { !vowels.contains($0) }, bc = b.filter { !vowels.contains($0) }
        return max(direct, ac.isEmpty || bc.isEmpty ? 0 : self.editSimilarity(ac, bc))
    }

    private static func editSimilarity(_ first: String, _ second: String) -> Double {
        let a = Array(first), b = Array(second)
        var previous = Array(0...b.count)
        for (i, character) in a.enumerated() {
            var current = [i + 1]
            for (j, other) in b.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1)))
            }
            previous = current
        }
        return 1 - Double(previous[b.count]) / Double(max(1, max(a.count, b.count)))
    }

    private static func unchanged(_ source: [String], _ target: [String]) -> (source: Set<Int>, target: Set<Int>) {
        var lengths = Array(repeating: Array(repeating: 0, count: target.count + 1), count: source.count + 1)
        for i in source.indices.reversed() {
            for j in target.indices.reversed() {
                lengths[i][j] = source[i] == target[j] ? lengths[i + 1][j + 1] + 1 : max(lengths[i + 1][j], lengths[i][j + 1])
            }
        }
        var i = 0, j = 0, si = Set<Int>(), ti = Set<Int>()
        while i < source.count && j < target.count {
            if source[i] == target[j] { si.insert(i); ti.insert(j); i += 1; j += 1 }
            else if lengths[i + 1][j] >= lengths[i][j + 1] { i += 1 }
            else { j += 1 }
        }
        return (si, ti)
    }

    private static func numberMarkers(_ text: String) -> [String] {
        text.components(separatedBy: CharacterSet.decimalDigits.inverted).filter { !$0.isEmpty }
    }

    private static func roleMarkers(_ text: String) -> [String] {
        text.lowercased().replacingOccurrences(of: "’", with: "'")
            .components(separatedBy: CharacterSet.letters.union(CharacterSet(charactersIn: "'")).inverted)
            .filter { self.protectedWords.contains($0) || $0.hasSuffix("n't") }
    }

    // Closed-class safety data, not product terms or locale-dependent behavior.
    private static let protectedWords: Set<String> = [
        "no", "not", "never", "without", "none", "nothing", "nobody", "neither", "nor", "cannot",
        "i", "you", "he", "she", "we", "they", "me", "him", "her", "us", "them", "my", "your", "our", "their",
        "не", "ни", "нет", "без", "я", "ты", "он", "она", "мы", "вы", "они", "мне", "тебе", "ему", "ей",
        "нам", "вам", "им", "меня", "тебя", "нас", "вас", "его", "ее", "её", "их", "мой", "твой", "наш", "ваш",
        "to", "of", "in", "on", "at", "for", "with", "from", "by", "and", "or", "but", "a", "an", "the",
        "в", "во", "на", "с", "со", "к", "ко", "от", "до", "из", "у", "за", "по", "и", "или", "а", "но", "для",
        "при", "о", "об", "обо", "под", "над", "между", "через",
    ]
}
