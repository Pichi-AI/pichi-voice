import Foundation

/// A recorded substitution, never inferred from membership in the dictionary.
nonisolated struct DictionaryHistoryReplacement: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable { case acoustic, textRule }
    let id: UUID
    let entryID: UUID
    let label: String
    let heard: String
    var location: Int
    var length: Int
    let kind: Kind
    var evidenceID: UUID? = nil
    /// Exact input to this rule, which can differ from the original model text in a chain.
    var ruleInput: String? = nil
    /// Transient only. History retains an ID into the bounded evidence archive.
    var evidence: DictionaryAcousticEvidence? = nil
    private enum CodingKeys: String, CodingKey {
        case id, entryID, label, heard, location, length, kind, evidenceID, ruleInput
    }
    var range: NSRange { NSRange(location: self.location, length: self.length) }

    func isValid(in text: String) -> Bool {
        self.label.utf16.count <= 320 && self.heard.utf16.count <= 320 && !self.heard.isEmpty &&
            DictionaryCorrectionReplacementPlan.isValid(self.range, in: text) &&
            (text as NSString).substring(with: self.range).caseInsensitiveCompare(self.label) == .orderedSame && self.heard != self.label
    }

    static func sanitized(_ hits: [Self], in text: String) -> [Self] {
        var identities = Set<UUID>()
        return hits.prefix(64).compactMap { hit in
            guard hit.isValid(in: text), identities.insert(hit.id).inserted else { return nil }
            var hit = hit
            if let evidence = hit.evidence {
                hit.evidenceID = evidence.entryID == hit.entryID && evidence.label == hit.label && evidence.frames.isValid ? evidence.id : nil
            }
            hit.evidence = nil
            if hit.ruleInput?.utf16.count ?? 0 > 320 { hit.ruleInput = nil }
            return hit
        }
    }
}

extension TranscriptionHistoryEntry {
    func rejectedDictionaryReplacement(at range: NSRange, replacement: String) -> DictionaryHistoryReplacement? {
        guard let original = self.originalSourceRange(for: range) else { return nil }
        return self.dictionaryReplacements.first { $0.range == original &&
            DictionaryCorrectionEditPolicy.feedbackIdentity($0.label) != DictionaryCorrectionEditPolicy.feedbackIdentity(replacement) }
    }
    func rejectionRemainsValid(_ replacementID: UUID) -> Bool {
        guard let hit = self.dictionaryReplacements.first(where: { $0.id == replacementID }) else { return false }
        return self.sourceFragments.contains { fragment in
            return fragment.originalRange == hit.range && fragment.isValid(in: self.sourceTranscriptText) &&
                DictionaryCorrectionEditPolicy.feedbackIdentity(fragment.text) != DictionaryCorrectionEditPolicy.feedbackIdentity(hit.label)
        }
    }
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
