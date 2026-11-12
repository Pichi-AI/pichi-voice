#if os(macOS)
import Foundation

/// Freezes the existing dictation history destination and privacy choices at capture start.
/// The retained controller can finish this one output while its private interface is concealed.
@MainActor final class PrivateDictationCaptureOutput {
    let id: UUID
    let profile: PrivateProfileSnapshot
    let history: TranscriptionHistoryStore
    let admission: DictationHistoryWriteAdmission?
    let savesAudio: Bool
    let transcriptionModel: String
    private var audioWrites: [Task<Void, Never>] = []
    private var dictionaryEvidenceWrites: [Task<Void, Never>] = []
    private let dictionaryEvidence: DictionaryNegativeExampleStore
    private var requiresPersistenceRetry = false
    var hasPendingPersistenceRetry: Bool { requiresPersistenceRetry }

    init(id: UUID, savesHistory: Bool, savesAudio: Bool, transcriptionModel: String,
         history: TranscriptionHistoryStore? = nil, dictionaryEvidence: DictionaryNegativeExampleStore? = nil) throws {
        self.id = id
        self.profile = PrivateProfileStorage.current
        self.history = history ?? TranscriptionHistoryStore.shared
        self.dictionaryEvidence = dictionaryEvidence ?? DictionaryNegativeExampleStore.scoped(to: self.profile)
        self.savesAudio = savesHistory && savesAudio
        self.transcriptionModel = transcriptionModel
        self.admission = savesHistory ? try self.history.admitRecordingWrite() : nil
    }

    var isVisible: Bool {
        PrivateProfileStorage.isReadable(profile) && PrivateProfileStorage.acceptsNewWork
    }

    /// Preserve the original local result when private presentation has been concealed.
    /// Empty ASR remains empty; an approved successful WAV supplies the recoverable entry.
    func preserveLocalResult(text: String, audio: DictationAudioSnapshot?, timestamp: Date = Date()) {
        guard let admission else { return }
        if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            history.addEntry(timestamp: timestamp, rawText: text, processedText: text,
                appName: "", windowTitle: "", wasAIProcessed: false, admission: admission)
        }
        saveAudio(audio, timestamp: timestamp, model: transcriptionModel)
    }

    func saveAudio(_ snapshot: DictationAudioSnapshot?, timestamp: Date, model: String) {
        guard savesAudio, let snapshot, !snapshot.samples.isEmpty,
              snapshot.sampleRate > 0, snapshot.channels > 0,
              snapshot.samples.count % snapshot.channels == 0, let admission else { return }
        let audio: DictationAudioSaveAdmission
        do { audio = try admission.admitAudioSave(timestamp: timestamp) }
        catch { return }
        let worker = Task.detached(priority: .utility) {
            defer { audio.complete() }
            do {
                let metadata = try audio.save(snapshot: snapshot, model: model)
                try await admission.attachAudio(metadata, from: audio, audioRecoveryTimestamp: timestamp)
            } catch {
                await admission.retainFailedAudioSave(snapshot, timestamp: timestamp, model: model,
                    from: audio, error: error)
                audio.discardUnattached()
                // A concealed capture must not repopulate the next profile's logger/UI.
                await MainActor.run {
                    if self.isVisible {
                        DebugLogger.shared.error("Failed to save dictation audio", source: "ContentView")
                    }
                }
            }
        }
        audioWrites.append(worker)
    }

    /// Features for a later explicit rejection follow the same capture/history
    /// authority and deletion generation as retained audio, with a global cap.
    func saveDictionaryEvidence(_ replacements: [DictionaryHistoryReplacement]) {
        guard self.savesAudio, self.isVisible, DictionaryMatcherExperiment.collectNegatives,
              let admission, admission.acceptsDictionaryEvidence else { return }
        let evidence = replacements.compactMap(\.evidence)
        guard !evidence.isEmpty else { return }
        let ids = Set(evidence.map(\.id)), store = self.dictionaryEvidence
        func current() -> Bool {
            self.isVisible && admission.acceptsDictionaryEvidence &&
                self.history.entries.first(where: { $0.id == admission.entryID }).map { entry in
                    ids.isSubset(of: Set(entry.dictionaryReplacements.compactMap(\.evidenceID)))
                } == true
        }
        self.dictionaryEvidenceWrites.append(Task { @MainActor in
            guard current() else { return }
            do {
                try await store.retainEvidence(evidence)
                if !current() { try await store.removeRetainedEvidence(ids: ids) }
            } catch {
                if self.isVisible { DebugLogger.shared.error("Dictionary rejection evidence could not be retained", source: "DictionaryLearning") }
            }
        })
    }

    /// False keeps the original capture owner alive until the same payload can be retried.
    @discardableResult func finish() async -> Bool {
        for worker in audioWrites { await worker.value }
        audioWrites.removeAll()
        for worker in dictionaryEvidenceWrites { await worker.value }
        dictionaryEvidenceWrites.removeAll()
        do {
            if requiresPersistenceRetry { try await admission?.retryPersistence() }
            else { try await admission?.finish() }
            requiresPersistenceRetry = false
            return true
        } catch {
            requiresPersistenceRetry = true
            // The history store retains the admitted payload for an explicit cleanup retry.
            if isVisible {
                DebugLogger.shared.error("Dictation history requires a persistence retry", source: "ContentView")
            }
            return false
        }
    }
}
#endif
