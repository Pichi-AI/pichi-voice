import Foundation
import CryptoKit
#if canImport(Combine)
import Combine
#endif

extension SettingsStore {
    private static let sensitiveDataDictionaryDefaultsKey = "SensitiveDataDictionaryEntries"
    private static let sensitiveBusinessGroupsKey = "SensitiveBusinessGroupIDs"
    private static let sensitiveBusinessGroupOverridesKey = "SensitiveBusinessGroupOverrides"
    private static let sensitiveTopicConfigurationKey = "SensitiveTopicClassifierConfiguration"

    private func requireSensitivePolicyMutationAdmission() throws {
        if let scoped = defaults as? PrivateProfileDefaults {
            guard PrivateProfileStorage.acceptsNewWork,
                  PrivateProfileStorage.isReadable(scoped.selectedProfile) else { throw CancellationError() }
        }
    }

    private struct TopicConfiguration: Codable {
        let artifact: Data
        let digest: String
        let availableIDs: Set<String>
        var selectedIDs: Set<String>
    }

    /// Presentation reads cannot erase malformed saved data. Attempt admission uses
    /// the throwing snapshot below so invalid rules never silently disable protection.
    var sensitiveDataDictionaryEntries: [SensitiveDataDictionaryEntry] {
        (try? TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: Self.sensitiveDataDictionaryDefaultsKey).entries) ?? []
    }

    func sensitiveDataDictionarySnapshot() throws -> TranscriptSensitiveDictionarySnapshot {
        let stored = try TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: Self.sensitiveDataDictionaryDefaultsKey)
        let groups = try admittedBusinessGroups()
        let configuration = try topicConfiguration()
        let classifier = try configuration.flatMap { config in
            config.selectedIDs.isEmpty ? nil : try SensitiveTopicClassifierSnapshot(
                data: config.artifact, expectedSHA256: config.digest, selectedTopicIDs: config.selectedIDs)
        }
        return try .init(entries: stored.entries, selectedGroupIDs: groups,
            groupTermOverrides: admittedGroupOverrides(), topicClassifier: classifier)
    }

    func replaceSensitiveDataDictionaryEntries(_ entries: [SensitiveDataDictionaryEntry]) throws {
        try requireSensitivePolicyMutationAdmission()
        let snapshot = try TranscriptSensitiveDictionarySnapshot(entries: entries)
        objectWillChange.send()
        try snapshot.persist(in: defaults, key: Self.sensitiveDataDictionaryDefaultsKey)
    }

    @discardableResult
    func addSensitiveDataDictionaryPhrase(_ phrase: String, matchMode: SensitiveDictionaryMatchMode = .wordForms) throws -> SensitiveDataDictionaryEntry {
        let entry = SensitiveDataDictionaryEntry(phrase: phrase, matchMode: matchMode)
        try replaceSensitiveDataDictionaryEntries(sensitiveDataDictionarySnapshot().entries + [entry])
        return entry
    }

    func updateSensitiveDataDictionaryPhrase(id: UUID, phrase: String, matchMode: SensitiveDictionaryMatchMode = .wordForms) throws {
        var entries = try sensitiveDataDictionarySnapshot().entries
        guard let index = entries.firstIndex(where: { $0.id == id }) else { throw SensitiveDataDictionaryError.entryNotFound }
        entries[index].phrase = phrase
        entries[index].matchMode = matchMode
        try replaceSensitiveDataDictionaryEntries(entries)
    }

    func removeSensitiveDataDictionaryPhrase(id: UUID) throws {
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
        let entries = try TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: Self.sensitiveDataDictionaryDefaultsKey).entries
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
        let entries = try TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: Self.sensitiveDataDictionaryDefaultsKey).entries
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
        let entries = try TranscriptSensitiveDictionarySnapshot.read(from: defaults, key: Self.sensitiveDataDictionaryDefaultsKey).entries
        _ = try TranscriptSensitiveDictionarySnapshot(entries: entries, selectedGroupIDs: admittedBusinessGroups(),
            groupTermOverrides: overrides)
        objectWillChange.send()
        defaults.set(try JSONEncoder().encode(overrides), forKey: Self.sensitiveBusinessGroupOverridesKey)
    }

    var sensitiveTopicClassifierInstalled: Bool { (try? topicConfiguration()) != nil }
    var sensitiveTopicClassifierIDs: Set<String> { (try? topicConfiguration()?.selectedIDs) ?? [] }
    var sensitiveTopicClassifierAvailableIDs: Set<String> { (try? topicConfiguration()?.availableIDs) ?? [] }

    private func topicConfiguration() throws -> TopicConfiguration? {
        guard let object = defaults.object(forKey: Self.sensitiveTopicConfigurationKey) else { return nil }
        guard let data = object as? Data, data.count <= 3_000_000,
              let config = try? JSONDecoder().decode(TopicConfiguration.self, from: data),
              config.selectedIDs.isSubset(of: config.availableIDs) else {
            throw SensitiveTopicClassifierError.invalidArtifact
        }
        // Validate even when disabled; corrupt saved protection cannot silently vanish.
        let model = try SensitiveTopicClassifierSnapshot(data: config.artifact,
            expectedSHA256: config.digest, selectedTopicIDs: config.selectedIDs)
        guard model.availableTopicIDs == config.availableIDs else { throw SensitiveTopicClassifierError.invalidArtifact }
        return config
    }

    func importSensitiveTopicClassifier(from url: URL) throws {
        try requireSensitivePolicyMutationAdmission()
        let data = try SensitiveTopicClassifierSnapshot.readArtifact(at: url)
        let digest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        let model = try SensitiveTopicClassifierSnapshot(data: data, expectedSHA256: digest, selectedTopicIDs: [])
        // Import does not opt the user into sentence masking. One profile-scoped
        // encoded value atomically binds bytes, digest, capabilities and selection.
        let configuration = TopicConfiguration(artifact: data, digest: digest,
            availableIDs: model.availableTopicIDs, selectedIDs: [])
        objectWillChange.send()
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.sensitiveTopicConfigurationKey)
    }

    func setSensitiveTopicClassifier(id: String, enabled: Bool) throws {
        try requireSensitivePolicyMutationAdmission()
        guard var configuration = try topicConfiguration(), configuration.availableIDs.contains(id) else {
            throw SensitiveTopicClassifierError.unsupportedTopic
        }
        if enabled { configuration.selectedIDs.insert(id) } else { configuration.selectedIDs.remove(id) }
        _ = try SensitiveTopicClassifierSnapshot(data: configuration.artifact,
            expectedSHA256: configuration.digest, selectedTopicIDs: configuration.selectedIDs)
        objectWillChange.send()
        defaults.set(try JSONEncoder().encode(configuration), forKey: Self.sensitiveTopicConfigurationKey)
    }

    /// Call only at an existing attempt/export/correction admission boundary. The
    /// caller retains this value, never rereads mutable Settings for live updates.
    func transcriptPrivacyRedactor(wrapping redactor: any TranscriptTextRedacting) throws -> any TranscriptTextRedacting {
        let dictionary = try sensitiveDataDictionarySnapshot()
        return dictionary.isEmpty ? redactor : TranscriptDictionaryRedactor(wrapped: redactor, dictionary: dictionary)
    }
}
