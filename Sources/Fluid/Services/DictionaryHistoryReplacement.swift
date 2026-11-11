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
