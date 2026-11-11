import Foundation

/// A text rule has no acoustic evidence. Reject its exact observed spelling
/// without deleting the dictionary word, its manual triggers or good recordings.
@MainActor
final class DictionaryTextRejectionStore {
    static var shared: DictionaryTextRejectionStore {
        PrivateProfileObjectCache.value(key: "DictionaryTextRejectionStore") {
            DictionaryTextRejectionStore(defaults: PrivateProfileDefaults.shared)
        }
    }
    private struct Rejection: Codable {
        let entryID: UUID
        let label: String
        let heard: String
    }
    private let defaults: UserDefaults
    private static let key = "DictionaryRejectedSpellingsV1"
    init(defaults: UserDefaults) { self.defaults = defaults }

    func rejects(entryID: UUID, label: String, heard: String) -> Bool {
        self.load().contains { $0.entryID == entryID && $0.label == label &&
            DictionaryCorrectionEditPolicy.feedbackIdentity($0.heard) == DictionaryCorrectionEditPolicy.feedbackIdentity(heard) }
    }

    func remember(entryID: UUID, label: String, heard: String) -> Bool {
        guard !heard.isEmpty, heard.utf16.count <= 320, label.utf16.count <= 320 else { return false }
        var entries = self.load()
        entries.removeAll { $0.entryID == entryID && ($0.label != label || $0.heard == heard) }
        entries.append(Rejection(entryID: entryID, label: label, heard: heard))
        guard let data = try? JSONEncoder().encode(Array(entries.suffix(200))) else { return false }
        self.defaults.set(data, forKey: Self.key)
        return true
    }

    private func load() -> [Rejection] {
        guard let data = self.defaults.data(forKey: Self.key), data.count <= 512 * 1024 else { return [] }
        return Array(((try? JSONDecoder().decode([Rejection].self, from: data)) ?? []).prefix(200))
    }
}

/// One explicit rejection feeds the existing negative matcher store. Its original
/// accepted features are persisted with bounded provenance, never re-decoded or
/// fabricated from the newly typed spelling. This does not retrain ASR weights.
@MainActor
final class DictionaryRejectionService {
    static var shared: DictionaryRejectionService {
        PrivateProfileObjectCache.value(key: "DictionaryRejectionService") { DictionaryRejectionService() }
    }
    private let negatives: DictionaryNegativeExampleStore
    private let profiles: @MainActor () async -> [PronunciationDictionaryProfile]
    private let entries: @MainActor () -> [SettingsStore.CustomDictionaryEntry]
    private let textRejections: DictionaryTextRejectionStore
    private let enabled: @MainActor () -> Bool
    private var retired = false
    private struct PendingFeedback {
        let generation: UUID
        let task: Task<Bool, Never>
    }
    private var pendingFeedback: [UUID: PendingFeedback] = [:]
    var pendingFeedbackCount: Int { self.pendingFeedback.count }

    init(negatives: DictionaryNegativeExampleStore = .shared,
         profiles: (@MainActor () async -> [PronunciationDictionaryProfile])? = nil,
         entries: @escaping @MainActor () -> [SettingsStore.CustomDictionaryEntry] = { SettingsStore.shared.customDictionaryEntries + BuiltInDictionary.entries },
         textRejections: DictionaryTextRejectionStore? = nil,
         enabled: @escaping @MainActor () -> Bool = { DictionaryMatcherExperiment.collectTextNegatives }) {
        self.negatives = negatives; self.entries = entries
        if let profiles { self.profiles = profiles }
        else {
            let pronunciation = PronunciationDictionaryStore.shared
            self.profiles = { await pronunciation.allProfiles() }
        }
        self.textRejections = textRejections ?? .shared; self.enabled = enabled
    }

    /// Feedback is owned by its profile service, independent from presentation
    /// tasks and other occurrences. A newer version joins retirement of its own
    /// predecessor before writing the same evidence identity again.
    func enqueue(_ hit: DictionaryHistoryReplacement, corrected: String, profile: PrivateProfileSnapshot,
                 isValid: @escaping @MainActor () -> Bool = { true }) -> Task<Bool, Never>? {
        guard !self.retired, PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              self.pendingFeedback.count < 32 || self.pendingFeedback[hit.id] != nil else { return nil }
        let previous = self.pendingFeedback[hit.id]?.task
        previous?.cancel()
        let generation = UUID()
        let task = Task { @MainActor [weak self] in
            if let previous { _ = await previous.value }
            guard let self else { return false }
            defer {
                if self.pendingFeedback[hit.id]?.generation == generation { self.pendingFeedback.removeValue(forKey: hit.id) }
            }
            guard !Task.isCancelled, !self.retired else { return false }
            return await self.remember(hit, corrected: corrected, profile: profile, isValid: isValid)
        }
        self.pendingFeedback[hit.id] = PendingFeedback(generation: generation, task: task)
        return task
    }

    func prepareForPrivateProfileTransition() async {
        self.retired = true
        let jobs = self.pendingFeedback.values.map(\.task)
        jobs.forEach { $0.cancel() }
        for job in jobs { _ = await job.value }
        self.pendingFeedback.removeAll()
    }

    @discardableResult
    func remember(_ hit: DictionaryHistoryReplacement, corrected: String, profile: PrivateProfileSnapshot,
                  isValid: @escaping @MainActor () -> Bool = { true }) async -> Bool {
        let generation = DictionaryMatcherExperiment.generation
        func current() -> Bool {
            !self.retired && PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork && self.enabled() &&
                generation == DictionaryMatcherExperiment.generation && isValid() && self.entries().contains {
                    $0.id == hit.entryID && $0.replacement == hit.label
                }
        }
        guard !Task.isCancelled, current(), DictionaryCorrectionEditPolicy.feedbackIdentity(corrected) != DictionaryCorrectionEditPolicy.feedbackIdentity(hit.label) else { return false }
        if hit.kind == .textRule {
            return self.textRejections.remember(entryID: hit.entryID, label: hit.label, heard: hit.ruleInput ?? hit.heard)
        }
        guard DictionaryMatcherExperiment.sharedFeaturesEnabled else { return false }
        var retained = hit.evidence
        if retained == nil, let id = hit.evidenceID { retained = await self.negatives.retainedEvidence(id: id) }
        guard !Task.isCancelled, current(), let evidence = retained, evidence.entryID == hit.entryID, evidence.label == hit.label,
              evidence.frames.isValid else { return false }
        func profileMatches(_ profiles: [PronunciationDictionaryProfile]) -> Bool {
            profiles.contains { item in
                let suffix = item.modelKey == evidence.modelKey ? "" : ":" + evidence.modelKey
                return item.dictionaryEntryID == evidence.entryID &&
                    DictionaryNegativeEvidenceResolver.profileKey(item) + ":shared-features-v1" + suffix == evidence.profileKey
            }
        }
        let revision = await self.negatives.revision()
        let before = await self.profiles()
        guard !Task.isCancelled, current(), profileMatches(before) else { return false }
        let correction = DictionaryNegativeCorrection(evidence: evidence, correctedText: corrected,
            expiresAt: Date().addingTimeInterval(DictionaryLearningRecording.lifetime))
        do {
            let inserted = try await self.negatives.save(correction, expectedRevision: revision)
            let after = await self.profiles()
            let latestRevision = await self.negatives.revision()
            guard !Task.isCancelled, current(), profileMatches(after), latestRevision == revision else {
                if inserted, latestRevision == revision { try? await self.negatives.remove(id: evidence.id) }
                return false
            }
            return true
        } catch { return false }
    }

    /// The selected occurrence alone is restored. Identical labels elsewhere may
    /// be genuine dictionary matches or literal speech and are left intact.
    func restore(entryID: UUID, replacementID: UUID, expectedSource: String, history: TranscriptionHistoryStore,
                 profile: PrivateProfileSnapshot) async -> (restored: Bool, negativeSaved: Bool) {
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              let before = history.entries.first(where: { $0.id == entryID }), before.sourceTranscriptText == expectedSource,
              let hit = before.currentDictionaryReplacements.first(where: { $0.id == replacementID }),
              history.applyWordCorrection(entryID: entryID, expectedText: expectedSource, range: hit.range,
                replacement: hit.heard, profile: profile, isOriginal: true, replacesAllOccurrences: false),
              history.entries.contains(where: { $0.id == entryID }) else { return (false, false) }
        DictionaryVoiceSpellingLearner.shared.reject(editedText: hit.label)
        let pending = self.enqueue(hit, corrected: hit.heard, profile: profile, isValid: {
            history.entries.first(where: { $0.id == entryID })?.rejectionRemainsValid(hit.id) == true
        })
        let saved = await pending?.value ?? false
        return (true, saved)
    }
}
