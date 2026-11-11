import Foundation

/// A recorded substitution, never inferred from membership in the dictionary.
nonisolated struct DictionaryHistoryReplacement: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case acoustic, textRule }
    let id: UUID
    let entryID: UUID
    let label: String
    let heard: String
    var location: Int
    let length: Int
    let kind: Kind
    var evidence: DictionaryAcousticEvidence?
    var range: NSRange { NSRange(location: self.location, length: self.length) }

    func isValid(in text: String) -> Bool {
        self.label.utf16.count <= 320 && self.heard.utf16.count <= 320 && !self.heard.isEmpty &&
            DictionaryCorrectionReplacementPlan.isValid(self.range, in: text) &&
            (text as NSString).substring(with: self.range) == self.label && self.heard != self.label
    }

    static func sanitized(_ hits: [Self], in text: String) -> [Self] {
        var remainingBytes = 512 * 1024
        var identities = Set<UUID>()
        return hits.prefix(64).compactMap { hit in
            guard hit.isValid(in: text), identities.insert(hit.id).inserted else { return nil }
            var hit = hit
            if let evidence = hit.evidence {
                if evidence.entryID == hit.entryID, evidence.label == hit.label, evidence.frames.isValid,
                   evidence.modelKey.utf8.count <= 1024, evidence.profileKey.utf8.count <= 2048,
                   evidence.frames.values.count <= remainingBytes / MemoryLayout<Float>.size {
                    remainingBytes -= evidence.frames.values.count * MemoryLayout<Float>.size
                } else { hit.evidence = nil }
            }
            return hit
        }
    }
}

/// Tracks the actual replacement stages through their existing callbacks. Only
/// exact surviving spans are published; formatting ambiguity drops provenance.
nonisolated struct DictionaryReplacementTrace {
    private(set) var text: String
    private var map: DictionaryCorrectionTextMap
    private(set) var replacements: [DictionaryHistoryReplacement] = []
    private var remainingEvidenceBytes = 512 * 1024

    init(text: String) { self.text = text; self.map = DictionaryCorrectionTextMap(originalText: text) }

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
        guard DictionaryCorrectionReplacementPlan.isValid(range, in: self.text), self.replacements.count < 64,
              label.utf16.count <= 320, let original = self.map.originalRange(for: range) else { return }
        let previous = self.replacements.first { $0.range == range }
        let heard = previous?.heard ?? (self.map.originalText as NSString).substring(with: original)
        guard self.map.replace(range: range, replacement: label) else { return }
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
        self.text = self.map.text
        let hit = DictionaryHistoryReplacement(id: UUID(), entryID: entryID, label: label, heard: heard,
            location: range.location, length: label.utf16.count, kind: kind, evidence: retained)
        if hit.isValid(in: self.text) { self.replacements.append(hit) }
    }

    mutating func remap(to text: String) {
        guard text != self.text else { return }
        let before = self.text
        self.replacements = self.replacements.compactMap { hit in
            guard let mapped = DictionaryLearningAlignmentResolver.textRange(in: text, delivered: before, selected: hit.range) else { return nil }
            var hit = hit; hit.location = mapped.location
            return hit.isValid(in: text) ? hit : nil
        }
        // Subsequent text rules refer to this stage. Retained hits already carry
        // the exact original spelling even if filler removal changed other words.
        self.map = DictionaryCorrectionTextMap(originalText: text)
        self.text = text
    }
}

extension TranscriptionHistoryEntry {
    /// Manual edits supersede only the overlapping substitution, preserving all
    /// other occurrence identities and shifting them through confirmed edits.
    var currentDictionaryReplacements: [DictionaryHistoryReplacement] {
        self.dictionaryReplacements.compactMap { hit in
            guard hit.isValid(in: self.rawText) else { return nil }
            var range = hit.range
            var shift = 0
            for fragment in self.sourceFragments.sorted(by: { $0.location < $1.location }) {
                guard let original = fragment.originalRange else { return nil }
                let edit = NSRange(location: original.location + shift, length: original.length)
                guard NSIntersectionRange(range, edit).length == 0,
                      let mapped = DictionaryCorrectionReplacementPlan.project(range, replacing: edit, withLength: fragment.length) else { return nil }
                range = mapped
                shift += fragment.length - original.length
            }
            var hit = hit; hit.location = range.location
            return hit.isValid(in: self.sourceTranscriptText) ? hit : nil
        }.sorted { $0.location < $1.location }
    }
}
