import Foundation

struct AutomaticDictionaryCorrectionCandidate: Equatable, Identifiable {
    let id = UUID()
    let heardText: String
    let correctedText: String
    var sourceUTF16Range: NSRange?
    var audioEvidence: DictionaryLearningAudioEvidence?
    var negativeCorrection: DictionaryNegativeCorrection?

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.heardText == rhs.heardText && lhs.correctedText == rhs.correctedText
            && lhs.sourceUTF16Range == rhs.sourceUTF16Range
    }
}

struct AutomaticDictionaryTextChange: Equatable {
    let oldRange: NSRange
    let newRange: NSRange
}

enum AutomaticDictionaryCorrectionDetector {
    static func confirmedCandidate(_ candidate: AutomaticDictionaryCorrectionCandidate?,
                                   in plan: DictionaryCorrectionReplacementPlan) -> AutomaticDictionaryCorrectionCandidate? {
        guard let candidate, let range = candidate.sourceUTF16Range, let mapped = plan.mappedRange(range),
              DictionaryCorrectionReplacementPlan.isValid(mapped, in: plan.text),
              (plan.text as NSString).substring(with: mapped) == candidate.correctedText else { return nil }
        return candidate
    }

    private static let edgeCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ".,!?;:\"“”‘’()[]{}")
    )
    private static let boundaryCharacters = CharacterSet.whitespacesAndNewlines.union(
        CharacterSet(charactersIn: ",!?;:\"“”()[]{}<>")
    )
    private static let maxCandidateLength = 80
    private static let maxCombinedLength = 160

    static func textChange(before: String, after: String) -> AutomaticDictionaryTextChange? {
        guard before != after else { return nil }

        let oldText = before as NSString
        let newText = after as NSString
        let sharedLength = min(oldText.length, newText.length)
        var prefixLength = 0

        while prefixLength < sharedLength,
              oldText.character(at: prefixLength) == newText.character(at: prefixLength)
        {
            prefixLength += 1
        }

        var suffixLength = 0
        let oldRemaining = oldText.length - prefixLength
        let newRemaining = newText.length - prefixLength
        while suffixLength < min(oldRemaining, newRemaining),
              oldText.character(at: oldText.length - suffixLength - 1) ==
              newText.character(at: newText.length - suffixLength - 1)
        {
            suffixLength += 1
        }

        return AutomaticDictionaryTextChange(
            oldRange: NSRange(
                location: prefixLength,
                length: oldText.length - prefixLength - suffixLength
            ),
            newRange: NSRange(
                location: prefixLength,
                length: newText.length - prefixLength - suffixLength
            )
        )
    }

    static func isChangeInsideInsertedRange(
        _ change: AutomaticDictionaryTextChange,
        insertedRange: NSRange,
        allowsInsertionAtEnd: Bool = false
    ) -> Bool {
        guard insertedRange.location != NSNotFound, insertedRange.length > 0 else { return false }
        let insertedEnd = NSMaxRange(insertedRange)

        if change.oldRange.length == 0 {
            return change.oldRange.location >= insertedRange.location &&
                (change.oldRange.location < insertedEnd ||
                    (allowsInsertionAtEnd && change.oldRange.location == insertedEnd))
        }

        return change.oldRange.location >= insertedRange.location &&
            NSMaxRange(change.oldRange) <= insertedEnd
    }

    static func candidate(
        before: String,
        after: String,
        insertedRange: NSRange,
        allowsInsertionAtEnd: Bool = false,
        knownCanonicalTerms: [String] = []
    ) -> AutomaticDictionaryCorrectionCandidate? {
        guard let change = self.textChange(before: before, after: after),
              self.isChangeInsideInsertedRange(
                  change,
                  insertedRange: insertedRange,
                  allowsInsertionAtEnd: allowsInsertionAtEnd
              )
        else {
            return nil
        }

        let oldTokenRange = self.expandedTokenRange(in: before, around: change.oldRange)
        let newTokenRange = self.expandedTokenRange(in: after, around: change.newRange)
        guard oldTokenRange.location >= insertedRange.location,
              NSMaxRange(oldTokenRange) <= NSMaxRange(insertedRange)
        else {
            return nil
        }

        var sourceRange = oldTokenRange
        var heard = self.cleanedCandidate((before as NSString).substring(with: oldTokenRange))
        var corrected = self.cleanedCandidate((after as NSString).substring(with: newTokenRange))
        guard self.isValidCandidate(heard),
              self.isValidCandidate(corrected),
              self.isMeaningfulCorrection(heard: heard, corrected: corrected),
              DictionaryCorrectionEditPolicy.allows(heard: heard, corrected: corrected),
              heard != corrected,
              heard.count + corrected.count <= self.maxCombinedLength
        else {
            return nil
        }
        // The audio/approval range must describe the spelling, excluding sentence
        // punctuation trimmed from heardText. History follows this exact span.
        sourceRange = (before as NSString).range(of: heard, options: .literal, range: oldTokenRange)

        // A spelling repair may leave part of a saved compound term unchanged.
        // Keep that exact occurrence together, including its original audio range.
        let knownRanges = self.canonicalTermRanges(
            in: after, change: change, insertedRange: insertedRange, terms: knownCanonicalTerms
        )
        guard knownRanges.count <= 1 else { return nil }
        if let range = knownRanges.first {
            let originalRange = NSRange(
                location: range.location,
                length: range.length - change.newRange.length + change.oldRange.length
            )
            guard originalRange.location >= insertedRange.location,
                  NSMaxRange(originalRange) <= NSMaxRange(insertedRange),
                  originalRange.location <= change.oldRange.location,
                  NSMaxRange(originalRange) >= NSMaxRange(change.oldRange)
            else { return nil }
            heard = (before as NSString).substring(with: originalRange)
            corrected = (after as NSString).substring(with: range)
            guard self.isValidCandidate(heard), self.isValidCandidate(corrected),
                  self.isMeaningfulCorrection(heard: heard, corrected: corrected),
                  DictionaryCorrectionEditPolicy.allows(heard: heard, corrected: corrected),
                  heard.count + corrected.count <= self.maxCombinedLength
            else { return nil }
            sourceRange = originalRange
        }

        return AutomaticDictionaryCorrectionCandidate(
            heardText: heard,
            correctedText: corrected,
            sourceUTF16Range: NSRange(location: sourceRange.location - insertedRange.location, length: sourceRange.length)
        )
    }

    private static func canonicalTermRanges(
        in text: String,
        change: AutomaticDictionaryTextChange,
        insertedRange: NSRange,
        terms: [String]
    ) -> [NSRange] {
        let text = text as NSString
        let newInsertedEnd = NSMaxRange(insertedRange) + change.newRange.length - change.oldRange.length
        guard insertedRange.location >= 0, newInsertedEnd >= insertedRange.location,
              newInsertedEnd <= text.length else { return [] }
        var ranges: [NSRange] = []
        for term in Set(terms) where self.isValidCandidate(term) {
            // Only occurrences touching the edit can qualify. Keep this main-actor
            // work bounded even when a large editor field repeats a saved name.
            let contextLength = (term as NSString).length
            let searchStart = max(insertedRange.location, change.newRange.location - contextLength)
            let searchEnd = min(newInsertedEnd, NSMaxRange(change.newRange) + contextLength)
            var searchRange = NSRange(location: searchStart, length: searchEnd - searchStart)
            while searchRange.length > 0 {
                let range = text.range(of: term, options: .caseInsensitive, range: searchRange)
                guard range.location != NSNotFound else { break }
                let end = NSMaxRange(range)
                if range.location <= change.newRange.location, end >= NSMaxRange(change.newRange),
                   (range.location == 0 || !self.isTermCharacter(text.character(at: range.location - 1))),
                   (end == text.length || !self.isTermCharacter(text.character(at: end))),
                   !ranges.contains(range)
                {
                    ranges.append(range)
                    if ranges.count > 1 { return ranges }
                }
                let next = range.location + 1
                searchRange = NSRange(location: next, length: searchEnd - next)
            }
        }
        return ranges
    }

    private static func isTermCharacter(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return true }
        return CharacterSet.alphanumerics.contains(scalar) || CharacterSet.nonBaseCharacters.contains(scalar)
            || CharacterSet(charactersIn: "'-’").contains(scalar)
    }

    static func isWordContinuationAtInsertedRangeEnd(
        _ change: AutomaticDictionaryTextChange,
        after: String,
        insertedRange: NSRange
    ) -> Bool {
        guard change.oldRange.length == 0,
              change.oldRange.location == NSMaxRange(insertedRange),
              NSMaxRange(change.newRange) <= (after as NSString).length
        else { return false }
        let insertedText = (after as NSString).substring(with: change.newRange)
        return !insertedText.isEmpty && insertedText.unicodeScalars.allSatisfy {
            !self.boundaryCharacters.contains($0)
        }
    }

    static func correctedTokenRange(before: String, after: String) -> NSRange? {
        guard let change = self.textChange(before: before, after: after) else { return nil }
        return self.expandedTokenRange(in: after, around: change.newRange)
    }

    static func selectionTouchesCandidate(_ selection: NSRange, candidateRange: NSRange) -> Bool {
        guard selection.location != NSNotFound, candidateRange.location != NSNotFound else { return false }
        if selection.length == 0 {
            return selection.location >= candidateRange.location &&
                selection.location <= NSMaxRange(candidateRange)
        }
        return NSIntersectionRange(selection, candidateRange).length > 0
    }

    static func changeContinuesCandidate(
        _ change: AutomaticDictionaryTextChange,
        after: String,
        candidateRange: NSRange
    ) -> Bool {
        if change.oldRange.length > 0 {
            return NSIntersectionRange(change.oldRange, candidateRange).length > 0
        }

        guard change.oldRange.location >= candidateRange.location,
              change.oldRange.location <= NSMaxRange(candidateRange)
        else {
            return false
        }

        guard change.oldRange.location == NSMaxRange(candidateRange) else { return true }
        let text = after as NSString
        guard change.newRange.location != NSNotFound,
              NSMaxRange(change.newRange) <= text.length
        else {
            return false
        }
        let insertedText = text.substring(with: change.newRange)
        return insertedText.unicodeScalars.allSatisfy { !self.boundaryCharacters.contains($0) }
    }

    private static func expandedTokenRange(in text: String, around range: NSRange) -> NSRange {
        let nsText = text as NSString
        let safeLocation = max(0, min(range.location, nsText.length))
        let safeEnd = max(safeLocation, min(NSMaxRange(range), nsText.length))
        var start = safeLocation
        var end = safeEnd

        while start > 0, !self.isBoundary(nsText.character(at: start - 1)) {
            start -= 1
        }
        while end < nsText.length, !self.isBoundary(nsText.character(at: end)) {
            end += 1
        }

        return NSRange(location: start, length: end - start)
    }

    private static func isBoundary(_ character: unichar) -> Bool {
        guard let scalar = Unicode.Scalar(character) else { return false }
        return self.boundaryCharacters.contains(scalar)
    }

    private static func cleanedCandidate(_ value: String) -> String {
        value.trimmingCharacters(in: self.edgeCharacters)
    }

    private static func isValidCandidate(_ value: String) -> Bool {
        guard !value.isEmpty,
              value.count <= self.maxCandidateLength,
              value.rangeOfCharacter(from: .alphanumerics) != nil
        else {
            return false
        }

        return DictionaryCorrectionEditPolicy.isTerm(value)
    }

    private static func isMeaningfulCorrection(heard: String, corrected: String) -> Bool {
        let heardCharacters = heard.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        let correctedCharacters = corrected.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard heardCharacters.count >= 2,
              correctedCharacters.count >= 2,
              heardCharacters.contains(where: { CharacterSet.letters.contains($0) }),
              correctedCharacters.contains(where: { CharacterSet.letters.contains($0) })
        else {
            return false
        }

        let heardSemantic = String(String.UnicodeScalarView(heardCharacters))
        let correctedSemantic = String(String.UnicodeScalarView(correctedCharacters))
        return heardSemantic != correctedSemantic
    }
}
