import Foundation
#if canImport(Combine)
import Combine
#endif

extension SettingsStore {
    private static let sensitiveDataDictionaryDefaultsKey = "SensitiveDataDictionaryEntries"

    /// Presentation reads cannot erase malformed saved data. Attempt admission uses
    /// the throwing snapshot below so invalid rules never silently disable protection.
    var sensitiveDataDictionaryEntries: [SensitiveDataDictionaryEntry] {
        (try? sensitiveDataDictionarySnapshot().entries) ?? []
    }

    func sensitiveDataDictionarySnapshot() throws -> TranscriptSensitiveDictionarySnapshot {
        try .read(from: defaults, key: Self.sensitiveDataDictionaryDefaultsKey)
    }

    func replaceSensitiveDataDictionaryEntries(_ entries: [SensitiveDataDictionaryEntry]) throws {
        let snapshot = try TranscriptSensitiveDictionarySnapshot(entries: entries)
        objectWillChange.send()
        try snapshot.persist(in: defaults, key: Self.sensitiveDataDictionaryDefaultsKey)
    }

    @discardableResult
    func addSensitiveDataDictionaryPhrase(_ phrase: String) throws -> SensitiveDataDictionaryEntry {
        let entry = SensitiveDataDictionaryEntry(phrase: phrase)
        try replaceSensitiveDataDictionaryEntries(sensitiveDataDictionarySnapshot().entries + [entry])
        return entry
    }

    func updateSensitiveDataDictionaryPhrase(id: UUID, phrase: String) throws {
        var entries = try sensitiveDataDictionarySnapshot().entries
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw SensitiveDataDictionaryError.entryNotFound }
        entries[index].phrase = phrase
        try replaceSensitiveDataDictionaryEntries(entries)
    }

    func removeSensitiveDataDictionaryPhrase(id: UUID) throws {
        let entries = try sensitiveDataDictionarySnapshot().entries
        guard entries.contains(where: { $0.id == id }) else { throw SensitiveDataDictionaryError.entryNotFound }
        try replaceSensitiveDataDictionaryEntries(entries.filter { $0.id != id })
    }

    /// Call only at an existing attempt/export/correction admission boundary. The
    /// caller retains this value, never rereads mutable Settings for live updates.
    func transcriptPrivacyRedactor(wrapping redactor: any TranscriptTextRedacting) throws -> any TranscriptTextRedacting {
        let dictionary = try sensitiveDataDictionarySnapshot()
        return dictionary.isEmpty ? redactor : TranscriptDictionaryRedactor(wrapped: redactor, dictionary: dictionary)
    }
}
