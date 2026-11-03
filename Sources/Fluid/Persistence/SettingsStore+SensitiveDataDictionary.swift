import Foundation
#if canImport(Combine)
import Combine
#endif

extension SettingsStore {
    private static let sensitiveDataDictionaryDefaultsKey = "SensitiveDataDictionaryEntries"
    private static let sensitiveBusinessGroupsKey = "SensitiveBusinessGroupIDs"
    private static let sensitiveBusinessGroupOverridesKey = "SensitiveBusinessGroupOverrides"

    private func requireSensitivePolicyMutationAdmission() throws {
        if let scoped = defaults as? PrivateProfileDefaults {
            guard PrivateProfileStorage.acceptsNewWork,
                  PrivateProfileStorage.isReadable(scoped.selectedProfile) else { throw CancellationError() }
        }
    }

    /// The app has one matching policy. Legacy exact entries remain readable, but
    /// presentation and attempt admission normalize them without mutating storage.
    private func admittedSensitiveDictionary() throws -> TranscriptSensitiveDictionarySnapshot {
        let stored = try TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: Self.sensitiveDataDictionaryDefaultsKey)
        guard stored.entries.contains(where: { $0.matchMode != .wordForms }) else { return stored }
        return try .init(entries: stored.entries.map { .init(id: $0.id, phrase: $0.phrase, matchMode: .wordForms) })
    }

    /// Presentation reads cannot erase malformed saved data. Attempt admission uses
    /// the throwing snapshot below so invalid rules never silently disable protection.
    var sensitiveDataDictionaryEntries: [SensitiveDataDictionaryEntry] {
        (try? admittedSensitiveDictionary().entries) ?? []
    }

    func sensitiveDataDictionarySnapshot() throws -> TranscriptSensitiveDictionarySnapshot {
        let stored = try admittedSensitiveDictionary()
        let groups = try admittedBusinessGroups()
        let topics = try stored.inferredTopicIDs(selectedGroupIDs: groups)
        let classifier = try topics.isEmpty ? nil : SensitiveTopicClassifierSnapshot.bundled(selectedTopicIDs: topics)
        return try .init(entries: stored.entries, selectedGroupIDs: groups,
            groupTermOverrides: admittedGroupOverrides(), topicClassifier: classifier)
    }

    func replaceSensitiveDataDictionaryEntries(_ entries: [SensitiveDataDictionaryEntry]) throws {
        try requireSensitivePolicyMutationAdmission()
        let snapshot = try TranscriptSensitiveDictionarySnapshot(entries: entries.map {
            .init(id: $0.id, phrase: $0.phrase, matchMode: .wordForms)
        })
        objectWillChange.send()
        try snapshot.persist(in: defaults, key: Self.sensitiveDataDictionaryDefaultsKey)
    }

    @discardableResult
    func addSensitiveDataDictionaryPhrase(_ phrase: String) throws -> SensitiveDataDictionaryEntry {
        try requireSensitivePolicyMutationAdmission()
        let entry = SensitiveDataDictionaryEntry(phrase: phrase, matchMode: .wordForms)
        try replaceSensitiveDataDictionaryEntries(sensitiveDataDictionarySnapshot().entries + [entry])
        return entry
    }

    func updateSensitiveDataDictionaryPhrase(id: UUID, phrase: String) throws {
        try requireSensitivePolicyMutationAdmission()
        var entries = try sensitiveDataDictionarySnapshot().entries
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw SensitiveDataDictionaryError.entryNotFound }
        entries[index].phrase = phrase
        entries[index].matchMode = .wordForms
        try replaceSensitiveDataDictionaryEntries(entries)
    }

    func removeSensitiveDataDictionaryPhrase(id: UUID) throws {
        try requireSensitivePolicyMutationAdmission()
        let entries = try sensitiveDataDictionarySnapshot().entries
        guard entries.contains(where: { $0.id == id }) else { throw SensitiveDataDictionaryError.entryNotFound }
        try replaceSensitiveDataDictionaryEntries(entries.filter { $0.id != id })
    }

    var sensitiveBusinessGroupIDs: Set<String> { (try? admittedBusinessGroups()) ?? [] }

    private func admittedBusinessGroups() throws -> Set<String> {
        guard let object = defaults.object(forKey: Self.sensitiveBusinessGroupsKey) else { return [] }
        guard let ids = object as? [String], ids.count <= SensitiveBusinessGroupCatalog.groups.count,
              Set(ids).count == ids.count,
              Set(ids).isSubset(of: Set(SensitiveBusinessGroupCatalog.groups.map(\.id))) else {
            throw SensitiveDataDictionaryError.invalidStoredData
        }
        return Set(ids)
    }

    func setSensitiveBusinessGroup(id: String, enabled: Bool) throws {
        try requireSensitivePolicyMutationAdmission()
        var ids = try admittedBusinessGroups()
        if enabled { ids.insert(id) } else { ids.remove(id) }
        let entries = try admittedSensitiveDictionary().entries
        _ = try TranscriptSensitiveDictionarySnapshot(entries: entries, selectedGroupIDs: ids,
            groupTermOverrides: admittedGroupOverrides())
        objectWillChange.send()
        defaults.set(ids.sorted(), forKey: Self.sensitiveBusinessGroupsKey)
    }

    private func admittedGroupOverrides() throws -> [String: [String]] {
        guard let value = defaults.object(forKey: Self.sensitiveBusinessGroupOverridesKey) else { return [:] }
        guard let data = value as? Data, data.count <= TranscriptSensitiveDictionarySnapshot.maximumStoredBytes,
              let overrides = try? JSONDecoder().decode([String: [String]].self, from: data) else {
            throw SensitiveDataDictionaryError.invalidStoredData
        }
        return overrides
    }

    func sensitiveBusinessGroupTerms(id: String) -> [String] {
        (try? admittedGroupOverrides()[id]) ?? SensitiveBusinessGroupCatalog.groups.first(where: { $0.id == id })?.terms ?? []
    }

    func replaceSensitiveBusinessGroupTerms(id: String, terms: [String]) throws {
        try requireSensitivePolicyMutationAdmission()
        guard SensitiveBusinessGroupCatalog.groups.contains(where: { $0.id == id }) else {
            throw SensitiveDataDictionaryError.invalidStoredData
        }
        var overrides = try admittedGroupOverrides()
        overrides[id] = terms
        let entries = try admittedSensitiveDictionary().entries
        _ = try TranscriptSensitiveDictionarySnapshot(entries: entries, selectedGroupIDs: admittedBusinessGroups(),
            groupTermOverrides: overrides)
        let data = try JSONEncoder().encode(overrides)
        guard data.count <= TranscriptSensitiveDictionarySnapshot.maximumStoredBytes else {
            throw SensitiveDataDictionaryError.invalidStoredData
        }
        objectWillChange.send()
        defaults.set(data, forKey: Self.sensitiveBusinessGroupOverridesKey)
    }

    func resetSensitiveBusinessGroupTerms(id: String) throws {
        try requireSensitivePolicyMutationAdmission()
        var overrides = try admittedGroupOverrides()
        overrides[id] = nil
        let entries = try admittedSensitiveDictionary().entries
        _ = try TranscriptSensitiveDictionarySnapshot(entries: entries, selectedGroupIDs: admittedBusinessGroups(),
            groupTermOverrides: overrides)
        objectWillChange.send()
        defaults.set(try JSONEncoder().encode(overrides), forKey: Self.sensitiveBusinessGroupOverridesKey)
    }

    /// Call only at an existing attempt/export/correction admission boundary. The
    /// caller retains this value, never rereads mutable Settings for live updates.
    func transcriptPrivacyRedactor(wrapping redactor: any TranscriptTextRedacting) throws -> any TranscriptTextRedacting {
        let dictionary = try sensitiveDataDictionarySnapshot()
        return dictionary.isEmpty ? redactor : TranscriptDictionaryRedactor(wrapped: redactor, dictionary: dictionary)
    }
}
