import Foundation

/// Eligibility for automatic learning only. Manual dictionary entries remain unrestricted.
/// Keep this separate from observing edits and from acoustic matching so it can be replaced.
nonisolated enum DictionaryCorrectionEditPolicy {
    static func allows(heard: String, corrected: String) -> Bool {
        guard self.isTerm(heard), self.isTerm(corrected) else { return false }
        let before = heard.lowercased()
        let after = corrected.lowercased()
        // Preserve deliberate brand capitalization. Negative learning separately rejects it.
        guard before != after else { return heard != corrected }
        if heard.split(whereSeparator: \.isWhitespace).count > 1 || corrected.split(whereSeparator: \.isWhitespace).count > 1 {
            // An edit may repair a name split into several tokens. Do not turn a
            // short inserted/reworded sentence into an automatic dictionary rule.
            let compactBefore = before.filter { !$0.isWhitespace }
            let compactAfter = after.filter { !$0.isWhitespace }
            let longest = max(compactBefore.count, compactAfter.count)
            guard self.editDistance(compactBefore, compactAfter) <= max(2, Int((Double(longest) * 0.4).rounded(.up))) else { return false }
        }
        return !self.isInflection(base: before, changed: after) &&
            !self.isInflection(base: after, changed: before)
    }

    /// Explicit user selection may contain a short term, never punctuation or a paragraph.
    static func isTerm(_ text: String) -> Bool {
        guard !text.isEmpty, text.count <= 80, text.rangeOfCharacter(from: .newlines) == nil else { return false }
        let words = text.split(whereSeparator: \.isWhitespace)
        guard (1...4).contains(words.count), words.allSatisfy({ $0.count <= 40 }) else { return false }
        // Apostrophes and hyphens remain valid within names; punctuation cannot join phrases.
        let connectors = CharacterSet(charactersIn: "'-’")
        return text.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) ||
                CharacterSet.nonBaseCharacters.contains($0) || connectors.contains($0) || CharacterSet.whitespaces.contains($0)
        }
    }

    private static func editDistance(_ first: String, _ second: String) -> Int {
        let left = Array(first), right = Array(second)
        var previous = Array(0...right.count)
        for (i, character) in left.enumerated() {
            var current = [i + 1]
            for (j, other) in right.enumerated() {
                current.append(min(current[j] + 1, previous[j + 1] + 1, previous[j] + (character == other ? 0 : 1)))
            }
            previous = current
        }
        return previous[right.count]
    }

    private static func isInflection(base: String, changed: String) -> Bool {
        // These are narrow English spelling patterns, not arbitrary suffix/substring matching.
        // Do not apply English suffix rules to other scripts or short names such as Jo → Jos.
        guard base.count >= 3, base.utf8.allSatisfy({ (97...122).contains($0) }) else { return false }
        if changed == base + "'s" || changed == base + "’s" { return true }
        if !base.hasSuffix("s"), changed == base + "s" { return true }
        if ["s", "x", "z", "ch", "sh"].contains(where: base.hasSuffix), changed == base + "es" { return true }
        if base.hasSuffix("y"), let preceding = base.dropLast().last,
           !"aeiou".contains(preceding), changed == String(base.dropLast()) + "ies" { return true }
        // Require a longer stem for tense changes to preserve short spelling repairs.
        guard base.count >= 4 else { return false }
        if changed == base + "ed" || changed == base + "ing" { return true }
        if base.hasSuffix("e") {
            return changed == base + "d" || changed == String(base.dropLast()) + "ing"
        }
        return false
    }
}

/// Correcting one spoken occurrence does not authorize replacing that spelling
/// everywhere. Acoustic correction handoffs require an explicit text-rule choice.
nonisolated enum DictionaryTrainingSpellingPolicy {
    static func exactTriggers(accepted: [String], manuallyConfirmed: Set<String>, acousticCorrection: Bool) -> [String] {
        guard acousticCorrection else { return accepted }
        return accepted.filter { manuallyConfirmed.contains($0) }
    }
}
