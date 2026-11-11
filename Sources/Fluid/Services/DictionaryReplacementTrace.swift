import Foundation

/// Tracks the actual replacement stages through their existing callbacks. Only
/// exact surviving spans are published; formatting ambiguity drops provenance.
nonisolated struct DictionaryReplacementTrace {
    private(set) var text: String
    private var map: DictionaryCorrectionTextMap
    private(set) var replacements: [DictionaryHistoryReplacement] = []
    private var remainingEvidenceBytes = 512 * 1024
    private var hasOriginalMap = true

    init(text: String) { self.text = text; self.map = DictionaryCorrectionTextMap(originalText: text) }

    static func rejection(in hits: [DictionaryHistoryReplacement], originalRange: NSRange, replacement: String) -> DictionaryHistoryReplacement? {
        hits.first { $0.range == originalRange &&
            DictionaryNegativeEvidenceResolver.normalized($0.label) != DictionaryNegativeEvidenceResolver.normalized(replacement) }
    }

    static func acoustic(output: String, alignment: DictionaryLearningAlignment?) -> Self {
        guard let alignment, let original = alignment.originalText, original.utf16.count <= 100_000,
              let ranges = DictionaryTranscriptReplacement.wordRanges(in: original, wordTexts: alignment.words.map(\.text))
        else { return Self(text: output) }
        var result = Self(text: original)
        var edits: [(NSRange, DictionaryAcousticEvidence)] = []
        for evidence in alignment.acousticEvidence.prefix(64) {
            let words = evidence.sourceWordRange
            guard !words.isEmpty, words.lowerBound >= 0, words.upperBound <= ranges.count else { continue }
            let range = NSUnionRange(ranges[words.lowerBound], ranges[words.upperBound - 1])
            guard edits.allSatisfy({ NSIntersectionRange($0.0, range).length == 0 }) else { continue }
            edits.append((range, evidence))
        }
        for (range, evidence) in edits.sorted(by: { $0.0.location > $1.0.location }) {
            result.replace(range: range, entryID: evidence.entryID, label: evidence.label, kind: .acoustic, evidence: evidence)
        }
        return result.text == output ? result : Self(text: output)
    }

    mutating func replace(range: NSRange, entryID: UUID, label: String,
                          kind: DictionaryHistoryReplacement.Kind, evidence: DictionaryAcousticEvidence? = nil) {
        guard DictionaryCorrectionReplacementPlan.isValid(range, in: self.text), label.utf16.count <= 100_000 else { return }
        let ruleInput = (self.text as NSString).substring(with: range)
        let original = self.hasOriginalMap ? self.map.originalRange(for: range) : nil
        let heard = original.map { (self.map.originalText as NSString).substring(with: $0) }
        let updated = (self.text as NSString).replacingCharacters(in: range, with: label)
        if !self.map.replace(range: range, replacement: label) {
            self.hasOriginalMap = false
            self.map = DictionaryCorrectionTextMap(originalText: updated)
        }
        self.replacements = self.replacements.compactMap { hit in
            guard NSIntersectionRange(hit.range, range).length == 0,
                  let moved = DictionaryCorrectionReplacementPlan.project(hit.range, replacing: range, withLength: label.utf16.count) else { return nil }
            var hit = hit; hit.location = moved.location; return hit
        }
        var retained: DictionaryAcousticEvidence?
        if let evidence, evidence.frames.isValid,
           evidence.frames.values.count <= self.remainingEvidenceBytes / MemoryLayout<Float>.size {
            retained = evidence
            self.remainingEvidenceBytes -= evidence.frames.values.count * MemoryLayout<Float>.size
        }
        self.text = updated
        guard let heard, label.utf16.count <= 320, self.replacements.count < 64 else { return }
        let hit = DictionaryHistoryReplacement(id: UUID(), entryID: entryID, label: label, heard: heard,
            location: range.location, length: label.utf16.count, kind: kind, evidenceID: retained?.id,
            ruleInput: kind == .textRule ? ruleInput : nil, evidence: retained)
        if hit.isValid(in: self.text) { self.replacements.append(hit) }
    }

    mutating func remap(to text: String) {
        guard text != self.text else { return }
        if let edits = self.map.remap(to: text) {
            var stage = self.text
            for edit in edits.reversed() {
                stage = (stage as NSString).replacingCharacters(in: edit.range, with: edit.replacement)
                self.replacements = self.replacements.compactMap { hit in
                    guard let mapped = DictionaryCorrectionReplacementPlan.project(hit.range, replacing: edit.range, withLength: edit.replacement.utf16.count) else { return nil }
                    var hit = hit; hit.location = mapped.location; hit.length = mapped.length
                    return hit.isValid(in: stage) ? hit : nil
                }
            }
        } else {
            let before = self.text
            self.replacements = self.replacements.compactMap { hit in
                guard let mapped = DictionaryLearningAlignmentResolver.textRange(in: text, delivered: before, selected: hit.range) else { return nil }
                var hit = hit; hit.location = mapped.location; hit.length = mapped.length
                return hit.isValid(in: text) ? hit : nil
            }
            self.hasOriginalMap = false
            self.map = DictionaryCorrectionTextMap(originalText: text)
        }
        self.text = text
    }
}

