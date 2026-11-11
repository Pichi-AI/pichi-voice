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

    /// Native ASR may attach terminal punctuation or spell a compound with &.
    /// Only explicitly selected acoustic evidence uses this comparison spelling;
    /// it grants no permission to create a permanent text replacement.
    static func acousticSpelling(_ text: String) -> String? {
        guard !text.isEmpty, text.count <= 80,
              text.rangeOfCharacter(from: .controlCharacters) == nil else { return nil }
        let value = text.replacingOccurrences(of: "&", with: " ")
            .trimmingCharacters(in: .whitespaces.union(.punctuationCharacters))
        return self.isTerm(value) ? value : nil
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

/// One user correction propagates only to identical complete terms in this text.
/// This does not create a permanent dictionary replacement rule.
nonisolated struct DictionaryCorrectionReplacementPlan {
    let sourceText: String
    let ranges: [NSRange]
    let text: String
    let replacement: String

    init?(sourceText: String, range: NSRange, replacement: String, scope: NSRange? = nil, protectedRanges: [NSRange] = []) {
        let source = sourceText as NSString
        let scope = scope ?? NSRange(location: 0, length: source.length)
        guard source.length <= 100_000, replacement.utf16.count <= 320,
              Self.isValid(scope, in: sourceText), range.length > 0,
              Self.isValid(range, in: sourceText),
              range.location >= scope.location, NSMaxRange(range) <= NSMaxRange(scope) else { return nil }
        let heard = source.substring(with: range)
        var matches = [range]
        if DictionaryCorrectionEditPolicy.isTerm(heard), DictionaryCorrectionEditPolicy.isTerm(replacement) {
            matches += Self.exactTermRanges(of: heard, in: sourceText, scope: scope).filter { candidate in
                candidate != range && NSIntersectionRange(candidate, range).length == 0 &&
                    protectedRanges.allSatisfy { NSIntersectionRange($0, candidate).length == 0 }
            }
        }
        self.ranges = matches.sorted { $0.location < $1.location }
        self.sourceText = sourceText
        self.replacement = replacement
        var result = sourceText
        for match in self.ranges.reversed() {
            result = (result as NSString).replacingCharacters(in: match, with: replacement)
        }
        guard result.utf16.count <= 100_000 else { return nil }
        self.text = result
    }

    /// Editors differ in which AX write attribute they expose. Use the full
    /// planned value only when selected-text writing is unavailable. A failed
    /// attempted write may be uncertain even while AX still returns old text.
    @MainActor
    static func dispatchReplacement(isCurrent: () -> Bool,
                                    writeSelectedText: (() -> Bool)?,
                                    writeValue: (() -> Bool)?) -> Bool {
        guard isCurrent() else { return false }
        if let writeSelectedText { return writeSelectedText() }
        guard isCurrent(), let writeValue else { return false }
        return writeValue()
    }

    func mappedRange(_ range: NSRange) -> NSRange? {
        var result = range
        for edit in self.ranges.reversed() {
            guard let mapped = Self.project(result, replacing: edit, withLength: self.replacement.utf16.count) else { return nil }
            result = mapped
        }
        return result
    }

    /// An editor may acknowledge a selected-text write after another keystroke.
    /// Accept only a full echo, an unchanged written occurrence outside that edit,
    /// or an edit wholly inside the single occurrence we replaced.
    func confirmsAppliedText(_ observed: String, differenceFromExpected: NSRange?) -> Bool {
        if observed == self.text { return true }
        if observed == self.sourceText { return false }
        guard let differenceFromExpected else { return false }
        let written = self.ranges.compactMap { self.mappedRange($0) }
        if written.contains(where: { NSIntersectionRange($0, differenceFromExpected).length == 0 }) { return true }
        return written.count == 1 && differenceFromExpected.location >= written[0].location &&
            NSMaxRange(differenceFromExpected) <= NSMaxRange(written[0])
    }

    static func exactTermRanges(of term: String, in text: String, scope: NSRange) -> [NSRange] {
        guard !term.isEmpty, Self.isValid(scope, in: text) else { return [] }
        let source = text as NSString
        var search = scope
        var ranges: [NSRange] = []
        while search.length > 0 {
            let found = source.range(of: term, options: .literal, range: search)
            guard found.location != NSNotFound else { break }
            if Self.hasTermBoundaries(found, in: text) { ranges.append(found) }
            let next = NSMaxRange(found)
            search = NSRange(location: next, length: NSMaxRange(scope) - next)
        }
        return ranges
    }

    static func isValid(_ range: NSRange, in text: String) -> Bool {
        guard let span = Range(range, in: text) else { return false }
        return (span.lowerBound == text.endIndex || text.indices.contains(span.lowerBound)) &&
            (span.upperBound == text.endIndex || text.indices.contains(span.upperBound))
    }

    static func confirmedRange(_ range: NSRange, text: String, replacing edit: NSRange,
                               withLength length: Int, in updatedText: String) -> NSRange? {
        guard NSIntersectionRange(range, edit).length == 0,
              let moved = Self.project(range, replacing: edit, withLength: length),
              Self.exactTermRanges(of: text, in: updatedText, scope: NSRange(location: 0, length: updatedText.utf16.count)).contains(moved)
        else { return nil }
        return moved
    }

    /// A partial overlap cannot identify the same occurrence after replacement.
    static func project(_ range: NSRange, replacing edit: NSRange, withLength length: Int) -> NSRange? {
        guard range.location >= 0, range.location != NSNotFound, range.length >= 0,
              range.length <= Int.max - range.location else { return nil }
        let delta = length - edit.length
        if range.location >= NSMaxRange(edit) {
            return NSRange(location: range.location + delta, length: range.length)
        }
        if NSMaxRange(range) <= edit.location { return range }
        if range.location <= edit.location, NSMaxRange(range) >= NSMaxRange(edit) {
            return NSRange(location: range.location, length: range.length + delta)
        }
        return nil
    }

    private static func hasTermBoundaries(_ range: NSRange, in text: String) -> Bool {
        guard let span = Range(range, in: text) else { return false }
        func isTerm(_ character: Character) -> Bool {
            character.unicodeScalars.contains {
                CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0) ||
                    CharacterSet(charactersIn: "'-’").contains($0)
            }
        }
        return (span.lowerBound == text.startIndex || !isTerm(text[text.index(before: span.lowerBound)])) &&
            (span.upperBound == text.endIndex || !isTerm(text[span.upperBound]))
    }
}

/// Keeps edits tied to the immutable delivered text while the observer is alive.
/// Ranges are projected backwards through actual edits, never estimated from time.
nonisolated struct DictionaryCorrectionTextMap {
    let originalText: String
    private(set) var text: String
    private var edits: [(range: NSRange, length: Int, deletedLetters: Bool)] = []

    init(originalText: String) { self.originalText = originalText; self.text = originalText }

    /// Applies exact character edits from a formatting stage while preserving
    /// immutable origin coordinates. Large unrelated rewrites have no mapping.
    mutating func remap(to text: String) -> [(range: NSRange, replacement: String)]? {
        if text == self.text { return [] }
        let before = Array(self.text), after = Array(text)
        guard before.count + after.count <= 16_384 else { return nil }
        var removed = Set<Int>(), added = Set<Int>()
        for change in after.difference(from: before) {
            switch change {
            case let .remove(offset, _, _): removed.insert(offset)
            case let .insert(offset, _, _): added.insert(offset)
            }
        }
        var offsets = [0]
        for character in before { offsets.append(offsets[offsets.count - 1] + String(character).utf16.count) }
        var pairs: [(Int, Int)] = [], source = 0, target = 0
        while source < before.count, target < after.count {
            if removed.contains(source) { source += 1 }
            else if added.contains(target) { target += 1 }
            else { pairs.append((source, target)); source += 1; target += 1 }
        }
        pairs.append((before.count, after.count))
        var edits: [(range: NSRange, replacement: String)] = []
        var sourceStart = 0, targetStart = 0
        for (sourceEnd, targetEnd) in pairs {
            if sourceStart != sourceEnd || targetStart != targetEnd {
                edits.append((NSRange(location: offsets[sourceStart], length: offsets[sourceEnd] - offsets[sourceStart]),
                    String(after[targetStart..<targetEnd])))
            }
            sourceStart = sourceEnd + 1; targetStart = targetEnd + 1
        }
        guard edits.count <= 256 else { return nil }
        var updated = self
        for edit in edits.reversed() {
            guard updated.replace(range: edit.range, replacement: edit.replacement) else { return nil }
        }
        guard updated.text == text else { return nil }
        self = updated
        return edits
    }

    /// Maps an immutable delivered span through confirmed edits. Partial overlap
    /// is ambiguous and cannot authorize a later write to another word.
    func currentRange(forOriginal range: NSRange) -> NSRange? {
        guard DictionaryCorrectionReplacementPlan.isValid(range, in: self.originalText) else { return nil }
        var result = range
        for edit in self.edits {
            guard let next = DictionaryCorrectionReplacementPlan.project(result, replacing: edit.range, withLength: edit.length) else { return nil }
            result = next
        }
        return DictionaryCorrectionReplacementPlan.isValid(result, in: self.text) ? result : nil
    }

    mutating func replace(range: NSRange, replacement: String) -> Bool {
        guard self.edits.count < 4096, DictionaryCorrectionReplacementPlan.isValid(range, in: self.text),
              let span = Range(range, in: self.text) else { return false }
        let updated = self.text.replacingCharacters(in: span, with: replacement)
        guard updated.utf16.count <= 100_000 else { return false }
        let removed = self.text[span]
        let deletedLetters = !removed.isEmpty && removed.unicodeScalars.allSatisfy {
            CharacterSet.alphanumerics.contains($0) || CharacterSet.nonBaseCharacters.contains($0)
        }
        self.edits.append((range, replacement.utf16.count, deletedLetters))
        self.text = updated
        return true
    }

    func originalRange(for range: NSRange) -> NSRange? {
        guard DictionaryCorrectionReplacementPlan.isValid(range, in: self.text) else { return nil }
        var result = range
        for edit in self.edits.reversed() {
            let replaced = NSRange(location: edit.range.location, length: edit.length)
            if edit.length == 0, edit.deletedLetters,
               result.location == edit.range.location || NSMaxRange(result) == edit.range.location {
                // A removed trailing/leading letter still belongs to this spoken
                // token. Whitespace at an edge does not authorize joining words.
                result.length += edit.range.length
                continue
            }
            guard let previous = DictionaryCorrectionReplacementPlan.project(result, replacing: replaced, withLength: edit.range.length) else { return nil }
            result = previous
        }
        return result.length > 0 && Range(result, in: self.originalText) != nil ? result : nil
    }
}
