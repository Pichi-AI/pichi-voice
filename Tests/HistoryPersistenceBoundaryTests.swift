import Combine
import Foundation
import SQLite3

// These doubles prevent the standalone test executable from touching app audio or settings.
struct DictationAudioMetadata: Codable, Equatable, Sendable {
    let fileName: String
    let durationMilliseconds: Int
    let byteCount: Int
    let sampleRate: Int
    let channels: Int
    let model: String?
}

final class DictationAudioSaveAdmission {
    func save(snapshot: DictationAudioSnapshot, model: String?) throws -> DictationAudioMetadata {
        fatalError("Audio recovery is covered by the actual admitted history/audio probe")
    }
    func complete() {}
    func abortIfUnstarted() {}
    func discardUnattached() {}
    func waitUntilCompleted() async {}
}

final class DictationAudioHistoryStore {
    static let shared = DictationAudioHistoryStore()
    static func scoped(to profile: PrivateProfileSnapshot) -> DictationAudioHistoryStore { self.shared }
    func admitSave(for admission: TranscriptionHistoryWriteAdmission, timestamp: Date) throws -> DictationAudioSaveAdmission {
        fatalError("Recording admission is outside this persistence-only probe")
    }
    func claimMetadata(_ metadata: DictationAudioMetadata, from audio: DictationAudioSaveAdmission,
                       history: TranscriptionHistoryWriteAdmission) -> Bool { false }
    @discardableResult func deleteAudio(fileName: String) -> Int64 { 0 }
    func deleteAllAudioFiles() {}
    func audioUsageBytes() -> Int64 { 0 }
    func deleteUnreferencedAudioFiles(referencedFileNames: Set<String>) -> (fileCount: Int, byteCount: Int64) { (0, 0) }
}

@MainActor final class SettingsStore {
    static let shared = SettingsStore()
    var audioHistoryBudgetBytes: Int64 { 1_000_000 }
    var weekendsDontBreakStreak: Bool { false }
}

final class DebugLogger {
    static let shared = DebugLogger()
    func info(_ message: String, source: String) {}
    func debug(_ message: String, source: String) {}
}

@main struct HistoryPersistenceBoundaryTests {
    @MainActor static func main() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("fluid-history-tests-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let suite = "fluid-history-tests-\(UUID())"
        guard let defaults = UserDefaults(suiteName: suite) else {
            fatalError("Unable to create isolated history defaults")
        }
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = "TranscriptionHistoryEntries"
        let audio = DictationAudioMetadata(
            fileName: "test.wav",
            durationMilliseconds: 1000,
            byteCount: 32_000,
            sampleRate: 16_000,
            channels: 1,
            model: "test"
        )
        let legacy = (0..<8400).map { index in
            TranscriptionHistoryEntry(
                timestamp: Date(timeIntervalSince1970: Double(index)),
                rawText: "Raw \(index)",
                processedText: String(repeating: "Test dictation \(index). ", count: 12),
                appName: "Test",
                windowTitle: "Test",
                wasAIProcessed: true,
                processingModel: "test",
                transcriptionDurationMilliseconds: 50,
                aiProcessingDurationMilliseconds: 100,
                aiTokensPerSecond: 500,
                audio: index == 0 ? audio : nil
            )
        }
        // Simulate history written before stars existed, including legacy backups.
        guard var legacyJSON = try JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [[String: Any]] else {
            preconditionFailure("Expected legacy history to encode as an array of objects")
        }
        for index in legacyJSON.indices {
            legacyJSON[index].removeValue(forKey: "isStarred")
        }
        try defaults.set(JSONSerialization.data(withJSONObject: legacyJSON), forKey: key)
        let url = root.appendingPathComponent("history.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = TranscriptionHistoryStore(writer: writer)
        // No actor suspension: these mutations necessarily precede startup loading.
        let newID = UUID()
        store.addEntry(id: newID, rawText: "new", processedText: "New dictation", appName: "Test", windowTitle: "Test")
        store.toggleStar(id: newID)
        store.attachAudio(audio, to: newID)
        store.deleteEntry(id: legacy[1].id)
        try await store.waitUntilLoaded()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1), "Startup stats must include merged pending edits")
        await store.finishPendingWrites()
        precondition(defaults.data(forKey: key) == nil, "Retire legacy only after successful import")
        precondition(store.entries.count == 8400)
        precondition(store.entries.first(where: { $0.id == newID })?.audio == audio)
        precondition(store.entries.first(where: { $0.id == newID })?.isStarred == true)
        precondition(store.entries.filter(\.isStarred).count == 1, "Legacy entries must default to unstarred")
        precondition(!store.entries.contains(where: { $0.id == legacy[1].id }))
        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(reloaded == store.entries, "Migration, metadata and concurrent startup edits must round-trip")
        print("PASS: 8,400-entry migration, exact round-trip, startup insert/audio/delete")

        // Reject a write touching any old entry. A new dictation and its audio must only update their row.
        try self.sql(url, "CREATE TRIGGER reject_old BEFORE INSERT ON history WHEN NEW.id != '\(newID.uuidString)' BEGIN SELECT RAISE(FAIL, 'unrelated row rewritten'); END")
        let enqueueStart = ProcessInfo.processInfo.systemUptime
        store.attachAudio(audio, to: newID)
        store.toggleStar(id: newID)
        store.toggleStar(id: newID)
        let enqueueMs = (ProcessInfo.processInfo.systemUptime - enqueueStart) * 1000
        await store.finishPendingWrites()
        await Task.yield()
        precondition(store.persistenceError == nil, "Updating one row must not rewrite unrelated history")
        let afterStar = try await writer.load()
        precondition(afterStar == store.entries, "Rapid star toggles and audio updates must persist in order")
        print("PASS: single-row audio update; main actor enqueue \(enqueueMs) ms")
        try self.sql(url, "DROP TRIGGER reject_old")

        try self.sql(url, "CREATE TRIGGER reject_all BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'test disk failure'); END")
        let failedID = UUID()
        store.addEntry(id: failedID, rawText: "pending", processedText: "Unsaved", appName: "Test", windowTitle: "Test")
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        precondition(store.persistenceError != nil)
        precondition(store.entries.contains(where: { $0.id == failedID }))
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 3, transcriptions: 2), "A disk error must not drop in-memory stats")
        let afterFailure = try await writer.load()
        precondition(!afterFailure.contains(where: { $0.id == failedID }))
        store.retryPersistence()
        await store.finishPendingWrites()
        let afterFailedReplacement = try await writer.load()
        precondition(afterFailedReplacement == afterFailure, "Failed replacement must roll back its initial DELETE")
        try self.sql(url, "DROP TRIGGER reject_all")
        store.retryPersistence()
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        precondition(store.persistenceError == nil)
        let afterRetry = try await writer.load()
        precondition(afterRetry.contains(where: { $0.id == failedID }))
        print("PASS: failed write stays in memory, surfaces error, retry restores complete snapshot")

        store.clearAllHistory()
        store.attachAudio(audio, to: newID)
        await store.finishPendingWrites()
        let afterClear = try await writer.load()
        precondition(afterClear.isEmpty, "Late audio must not resurrect deleted entries")
        try defaults.set(JSONEncoder().encode(legacy), forKey: key)
        let afterRestart = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRestart.isEmpty, "Migration marker must prevent old history resurrection")
        print("PASS: clear, late audio, restart and stale legacy cannot resurrect history")

        let badURL = root.appendingPathComponent("bad.sqlite3")
        let badData = Data("invalid JSON".utf8)
        defaults.set(badData, forKey: key)
        let badStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: badURL))
        do {
            try await badStore.waitUntilLoaded()
            preconditionFailure("Corrupt legacy must fail visibly")
        } catch {}
        precondition(!badStore.isLoading && badStore.persistenceError != nil)
        precondition(defaults.data(forKey: key) == badData)
        try defaults.set(JSONEncoder().encode([legacy[0]]), forKey: key)
        badStore.retryPersistence()
        try await badStore.waitUntilLoaded()
        precondition(badStore.entries == [legacy[0]])
        print("PASS: corrupt migration preserves source, exits loading and supports retry")

        let restoreStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url))
        restoreStore.restore(from: [legacy[3]])
        try await restoreStore.waitUntilLoaded()
        await restoreStore.finishPendingWrites()
        guard let restored = restoreStore.entries.first,
              let revision = restored.searchRevision
        else { preconditionFailure("Restore must set a search revision") }
        precondition(revision > (legacy[3].searchRevision ?? 1), "Restore must invalidate the previous search record")
        var expectedRestore = legacy[3]
        expectedRestore.searchRevision = revision
        precondition(restoreStore.entries == [expectedRestore], "Restore must preserve every field except the search revision")
        let afterRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRestore == [expectedRestore], "The new search revision and original content must round-trip")
        restoreStore.restore(from: [legacy[3]])
        await restoreStore.finishPendingWrites()
        guard let nextRevision = restoreStore.entries.first?.searchRevision else {
            preconditionFailure("Repeated restore must preserve a search revision")
        }
        precondition(nextRevision > revision, "Restoring an older backup must advance past the currently indexed revision")
        expectedRestore.searchRevision = nextRevision
        let afterRepeatedRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(afterRepeatedRestore == [expectedRestore], "Repeated restore changes only the persisted search revision")
        print("PASS: restore during loading replaces both memory and disk")
        try await self.testTodaySummary(root: root, defaults: defaults, audio: audio)
        try await self.testStars(root: root, defaults: defaults, audio: audio)
        try await self.testWordCorrections(root: root, defaults: defaults, audio: audio)
    }

    @MainActor static func testWordCorrections(root: URL, defaults: UserDefaults, audio: DictationAudioMetadata) async throws {
        let url = root.appendingPathComponent("word-corrections.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = TranscriptionHistoryStore(writer: writer)
        try await store.waitUntilLoaded()
        let profile = PrivateProfileStorage.current
        let original = TranscriptionHistoryEntry(timestamp: Date(timeIntervalSince1970: 500),
            rawText: "Model ASR bytes", processedText: "Ёжик 🦔 Pech Voice и Pech Voice.",
            appName: "Synthetic", windowTitle: "Synthetic window", wasAIProcessed: true,
            processingModel: "synthetic-ai", transcriptionDurationMilliseconds: 37,
            parakeetProcessingDurationMilliseconds: 25, aiProcessingDurationMilliseconds: 40,
            aiTokensPerSecond: 120, aiProcessingError: "retained diagnostic", audio: audio,
            isStarred: true)
        store.restore(from: [original])
        let before = store.entries[0]
        let displayed = before.clipboardText!
        let lastWord = (displayed as NSString).range(of: "Pech", options: .backwards)
        precondition(store.applyWordCorrection(entryID: original.id, expectedText: displayed,
            range: lastWord, replacement: "Pichi", profile: profile))
        let first = store.entries[0]
        precondition(first.processedText == "Ёжик 🦔 Pech Voice и Pichi Voice.", "Only the selected repeated occurrence changes")
        precondition(first.rawText == original.rawText && first.originalProcessedText == original.processedText,
            "Original ASR and model output remain exact")
        precondition(first.id == original.id && first.timestamp == original.timestamp && first.audio == original.audio && first.isStarred,
            "Manual edits retain identity, chronology, audio and star")
        precondition(first.processingModel == original.processingModel && first.wasAIProcessed == original.wasAIProcessed &&
            first.aiProcessingError == original.aiProcessingError && first.aiTokensPerSecond == original.aiTokensPerSecond &&
            first.transcriptionDurationMilliseconds == original.transcriptionDurationMilliseconds &&
            first.parakeetProcessingDurationMilliseconds == original.parakeetProcessingDurationMilliseconds &&
            first.aiProcessingDurationMilliseconds == original.aiProcessingDurationMilliseconds,
            "Manual edits do not rewrite inference provenance")
        precondition(first.characterCount == first.processedText.count && first.previewText == first.processedText &&
            first.clipboardText == first.processedText, "Every display/copy path uses corrected final text")
        precondition(first.searchRecord.revision > before.searchRecord.revision && first.searchRecord.text.contains("Pichi Voice"),
            "A correction advances the existing search revision")
        precondition(store.search(query: "Pichi").map(\.id) == [original.id], "Corrected text is searchable")
        precondition(!store.applyWordCorrection(entryID: original.id, expectedText: displayed,
            range: lastWord, replacement: "Stale", profile: profile), "Stale text cannot change a newer correction")
        let firstWord = (first.processedText as NSString).range(of: "Pech")
        precondition(store.applyWordCorrection(entryID: original.id, expectedText: first.processedText,
            range: firstWord, replacement: "Pichi", profile: profile))
        let second = store.entries[0]
        precondition(second.originalProcessedText == original.processedText && second.searchRecord.revision > first.searchRecord.revision,
            "Later edits preserve the first model bytes and advance revision again")
        let emoji = (second.processedText as NSString).range(of: "🦔")
        for invalid in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1),
                        NSRange(location: Int.max - 1, length: Int.max - 1),
                        NSRange(location: emoji.location, length: 1)] {
            precondition(!store.applyWordCorrection(entryID: original.id, expectedText: second.processedText,
                range: invalid, replacement: "invalid", profile: profile), "Malformed UTF16 ranges are rejected")
        }
        precondition(!store.applyWordCorrection(entryID: original.id, expectedText: second.processedText,
            range: NSRange(location: 0, length: 1), replacement: "bad\nline", profile: profile), "Word edits cannot inject control characters")
        precondition(!store.applyWordCorrection(entryID: original.id, expectedText: second.processedText,
            range: NSRange(location: 0, length: second.processedText.utf16.count), replacement: "", profile: profile),
            "Empty final text cannot silently fall back to the uncorrected raw text")
        precondition(store.entries[0] == second, "Rejected edits leave all metadata unchanged")
        store.attachAudio(laterAudioMetadata(), to: original.id)
        let attached = store.entries[0]
        precondition(attached.originalProcessedText == original.processedText && attached.processedText == second.processedText,
            "Later audio metadata updates preserve manual corrections")
        await store.finishPendingWrites()
        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(reloaded == store.entries, "Edited text and exact original output survive SQLite reload")
        let backup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        precondition(backup == store.entries, "Backup export keeps both current final and original model output")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "originalProcessedText")
        let legacyEntry = try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        precondition(legacyEntry.originalProcessedText == nil && legacyEntry == original, "Legacy entries decode without a manual correction field")
        let sourceOriginal = TranscriptionHistoryEntry(rawText: "Ёжик 🦔 Pech и Pech.",
            processedText: "AI formatted result.", appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: true, audio: audio)
        store.restore(from: [sourceOriginal])
        let sourceRange = (sourceOriginal.rawText as NSString).range(of: "Pech", options: .backwards)
        precondition(store.applyWordCorrection(entryID: sourceOriginal.id, expectedText: sourceOriginal.rawText,
            range: sourceRange, replacement: "Pichi", profile: profile, isOriginal: true))
        let sourceEdited = store.entries[0]
        precondition(sourceEdited.sourceTranscriptText == "Ёжик 🦔 Pech и Pichi." && sourceEdited.rawText == sourceOriginal.rawText,
            "Source edits preserve exact immutable ASR bytes and the selected repeated occurrence")
        precondition(sourceEdited.processedText.contains("Pichi") && sourceEdited.originalProcessedText == sourceOriginal.processedText,
            "Explicit source corrections override divergent AI output and preserve its original bytes")
        precondition(store.search(query: "Pichi").map(\.id) == [sourceOriginal.id] && sourceEdited.searchRecord.text.contains("Pichi"))
        precondition(!store.applyWordCorrection(entryID: sourceOriginal.id, expectedText: sourceOriginal.rawText,
            range: sourceRange, replacement: "Stale", profile: profile, isOriginal: true))
        store.attachAudio(laterAudioMetadata(), to: sourceOriginal.id)
        await store.finishPendingWrites()
        let sourceReloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(sourceReloaded == store.entries && sourceReloaded[0].correctedRawText == sourceEdited.correctedRawText,
            "Corrected source survives audio attachment and SQLite reload")
        let sourceBackup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        precondition(sourceBackup == store.entries)
        let identical = TranscriptionHistoryEntry(rawText: "Приложение PGI.", processedText: "Приложение PGI.",
            appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: false)
        store.restore(from: [identical])
        precondition(store.applyWordCorrection(entryID: identical.id, expectedText: identical.rawText,
            range: (identical.rawText as NSString).range(of: "PGI"), replacement: "Pichi AI", profile: profile, isOriginal: true))
        precondition(store.entries[0].sourceTranscriptText == "Приложение Pichi AI." &&
            store.entries[0].clipboardText == "Приложение Pichi AI." && store.entries[0].rawText == identical.rawText &&
            store.entries[0].originalProcessedText == identical.processedText,
            "Identical source/final text shares the exact user correction while preserving both model outputs")
        let correctionCases:[(String,String,String,String)] = [
   ("Итак, проверим Peachi AI, Newo и Asprity.", "Итак, проверим Pichi AI, Newo и Asprity.", "Итак, проверим Peach I, Newa и aspirity.", "Итак, проверим Pichi AI, Newa и aspirity."),
   ("Проверь Peachi AI, потом Asprity и Arcody.","Проверь Pichi AI, потом Aspirity и Aircody.","Проверь Peach I,\nпотом aspirity и Arcodi!","Проверь Pichi AI,\nпотом Aspirity и Aircody!"),
   ("Сначала Pech AI, потом Pech AI.","Сначала Pech AI, потом Pichi AI.","Сначала Peach I,\nпотом Peach I.","Сначала Peach I,\nпотом Pichi AI."),
   ("Тут Pech.","Тут Pichi AI.","Тут Peach!","Тут Pichi AI!"),
   ("Тут старый термин.","Тут термин.","Тут старый, термин!","Тут термин!"),
   ("Hello world","Hello friend","Hello,\nworld!","Hello,\nfriend!"),
   ("Ёжик 🦔 Pech AI.","Ёжик 🦔 Pichi AI.","Ёжик 🦔 Peach I!","Ёжик 🦔 Pichi AI!"),
   ("Тут модель.","Тут Pichi AI модель.","Тут модель!","Тут Pichi AI модель!"),
   ("тут Pech.","тут Pichi.","Тут Pichi!","Тут Pichi!"),
   ("Слово.","Термин.","","Термин.")
  ]
        for (raw, corrected, formatted, expected) in correctionCases {
            let result = SourceTranscriptCorrection.apply(original: raw, corrected: corrected, to: formatted)
            precondition(result == expected, "Source correction must reach the selected final span: \(result)")
            precondition(SourceTranscriptCorrection.apply(original: raw, corrected: corrected, to: result) == result,
                "Repeated reconciliation cannot duplicate an inserted compound")
        }
        let repeatedSource = "Проверь Alfa AI, или, например, Beta Voice, или другое, например, Game и Testo."
        let repeatedCorrected = "Проверь Alpha AI, или, например, Beta Voice, или другое, например, Gamma и Test."
        let repeatedFormatted = "Проверь Alf I, например, Beta Voice, или другое, например, Gama и testo."
        let settled = SourceTranscriptCorrection.apply(original: repeatedSource, corrected: repeatedCorrected, to: repeatedFormatted)
        precondition(settled.contains("Alpha AI") && settled.contains("Gamma") && settled.contains("Test"))
        precondition(SourceTranscriptCorrection.apply(original: repeatedSource, corrected: repeatedCorrected, to: settled) == settled,
            "Repeated context and punctuation must settle before a correction is persisted")
        let reverted = TranscriptionHistoryEntry(rawText: "Тут Pech AI.", processedText: "Тут Pichi AI!",
            appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: true,
            originalProcessedText: "Тут Peach I!", correctedRawText: "Тут Pichi AI.").replacingSourceText("Тут Pech AI.")
        precondition(reverted.processedText == "Тут Pech AI!", "Reverting a source correction also changes its final occurrence")
        let large = String(repeating: "one two ", count: 3000)
        precondition(SourceTranscriptCorrection.apply(original: large, corrected: large + "Pichi AI", to: "AI rewrite") == large + "Pichi AI",
            "Oversized alignment falls back to authoritative corrected source within a bounded token budget")
        let legacyCorrected = TranscriptionHistoryEntry(rawText: "Тут Peachi AI.", processedText: "Тут Peach I!",
            appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: true, audio: audio,
            correctedRawText: "Тут Pichi AI.")
        let legacyURL = root.appendingPathComponent("source-reconciliation.sqlite3")
        let legacyWriter = TranscriptionHistoryWriter(defaults: defaults, url: legacyURL)
        let legacyStore = TranscriptionHistoryStore(writer: legacyWriter)
        try await legacyStore.waitUntilLoaded()
        legacyStore.restore(from: [legacyCorrected])
        await legacyStore.finishPendingWrites()
        precondition(legacyStore.entries[0].processedText == "Тут Pichi AI!")
        // Seed a genuinely old, mismatched row directly through the real writer.
        legacyWriter.write(upserts: [legacyCorrected], deletes: [], replacing: true) { _ in }
        let migrationWriteError = await legacyWriter.drain()
        precondition(migrationWriteError == nil)
        let repairedStore = TranscriptionHistoryStore(writer: legacyWriter)
        try await repairedStore.waitUntilLoaded()
        await repairedStore.finishPendingWrites()
        let repaired = repairedStore.entries[0]
        precondition(repaired.processedText == "Тут Pichi AI!" && repaired.rawText == legacyCorrected.rawText &&
            repaired.audio == legacyCorrected.audio && repaired.originalProcessedText == legacyCorrected.processedText &&
            repaired.searchRevision != nil, "Existing manual source edits reconcile on load without changing provenance")
        let stableStore = TranscriptionHistoryStore(writer: legacyWriter)
        try await stableStore.waitUntilLoaded()
        precondition(stableStore.entries[0] == repaired, "Reopening an already-repaired entry is a no-op")
        let groupedOriginal = TranscriptionHistoryEntry(rawText: "Ёжик 🦔 Pichi AI и Term.", processedText: "Ёжик 🦔 Peach I, и Term!",
            appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: true, audio: audio)
        store.restore(from: [groupedOriginal])
        let compoundRange = (groupedOriginal.rawText as NSString).range(of: "Pichi AI")
        precondition(store.applyWordCorrection(entryID: groupedOriginal.id, expectedText: groupedOriginal.rawText,
            range: compoundRange, replacement: "Pichi AI", profile: profile, isOriginal: true),
            "Saving an unchanged multiword selection confirms one persistent fragment")
        let grouped = store.entries[0]
        precondition(grouped.sourceFragments.count == 1 && grouped.sourceFragments[0].range == compoundRange &&
            grouped.sourceFragments[0].text == "Pichi AI" && grouped.processedText == "Ёжик 🦔 Pichi AI, и Term!",
            "The grouped range includes its space and overrides a divergent formatted compound")
        precondition(!store.applyWordCorrection(entryID: grouped.id, expectedText: grouped.sourceTranscriptText,
            range: compoundRange, replacement: "Pichi AI", profile: profile, isOriginal: true), "Repeated grouping is a no-op")
        let prefixRange = (grouped.sourceTranscriptText as NSString).range(of: "Ёжик")
        precondition(store.applyWordCorrection(entryID: grouped.id, expectedText: grouped.sourceTranscriptText,
            range: prefixRange, replacement: "Большой Ёжик", profile: profile, isOriginal: true))
        let shifted = store.entries[0]
        precondition(shifted.sourceFragments.first { $0.text == "Pichi AI" }?.range == (shifted.sourceTranscriptText as NSString).range(of: "Pichi AI"),
            "Editing before a group shifts its UTF16 range across a Unicode prefix")
        let component = (shifted.sourceTranscriptText as NSString).range(of: "AI")
        precondition(store.applyWordCorrection(entryID: grouped.id, expectedText: shifted.sourceTranscriptText,
            range: component, replacement: "Enablement", profile: profile, isOriginal: true))
        let changedGroup = store.entries[0]
        precondition(changedGroup.sourceFragments.contains { $0.text == "Pichi Enablement" && $0.isValid(in: changedGroup.sourceTranscriptText) },
            "Editing a component keeps the full group together")
        store.attachAudio(laterAudioMetadata(), to: grouped.id)
        await store.finishPendingWrites()
        let groupReload = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        precondition(groupReload == store.entries && groupReload[0].sourceFragments == changedGroup.sourceFragments,
            "Grouped terms survive audio attachment and persistence")
        let groupBackup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        precondition(groupBackup == store.entries)
        let entireGroup = (store.entries[0].sourceTranscriptText as NSString).range(of: "Pichi Enablement")
        precondition(store.applyWordCorrection(entryID: grouped.id, expectedText: store.entries[0].sourceTranscriptText,
            range: entireGroup, replacement: "", profile: profile, isOriginal: true))
        precondition(!store.entries[0].sourceFragments.contains { $0.text.contains("Pichi") }, "Deleting a group removes its metadata")
        let invalidGroup = TranscriptionHistoryEntry.SourceFragment(location: 0, length: 5, text: "wrong")
        let sanitized = TranscriptionHistoryEntry(rawText: "hello", processedText: "hello", appName: "Synthetic", windowTitle: "Synthetic",
            wasAIProcessed: false, sourceFragments: [invalidGroup])
        precondition(sanitized.sourceFragments.isEmpty, "A stale fragment cannot highlight unrelated text")
        print("PASS: grouped fragments, source and final corrections, exact UTF16 occurrence, provenance, search, persistence, audio, backup and legacy decoding")
    }

    static func laterAudioMetadata() -> DictationAudioMetadata {
        DictationAudioMetadata(fileName: "later.wav", durationMilliseconds: 2000, byteCount: 64_000,
            sampleRate: 16_000, channels: 1, model: "synthetic")
    }

    @MainActor static func testStars(root: URL, defaults: UserDefaults, audio: DictationAudioMetadata) async throws {
        let url = root.appendingPathComponent("stars.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: url)
        let store = TranscriptionHistoryStore(writer: writer)
        try await store.waitUntilLoaded()
        let older = TranscriptionHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 1),
            rawText: "Original phrasing",
            processedText: "Reusable prompt",
            appName: "Editor",
            windowTitle: "Reference",
            wasAIProcessed: true,
            audio: audio,
            isStarred: true
        )
        let newer = TranscriptionHistoryEntry(
            timestamp: Date(timeIntervalSince1970: 2),
            rawText: "Another prompt",
            processedText: "Another prompt",
            appName: "Test",
            windowTitle: "Test",
            wasAIProcessed: false
        )
        store.restore(from: [older, newer])
        precondition(store.search(query: "").map(\.id) == [newer.id, older.id], "Stars must preserve chronological order")
        precondition(store.search(query: "", pinnedFirst: true).map(\.id) == [older.id, newer.id], "History displays pins first")
        precondition(store.search(query: "prompt", pinnedFirst: true).map(\.id) == [older.id, newer.id], "Pin ordering applies after text filtering")
        precondition(store.search(query: "Another", pinnedFirst: true).map(\.id) == [newer.id], "Pins must not bypass the search filter")
        let storedOrder = store.entries
        let selectedID = store.selectedEntryID
        store.toggleStar(id: newer.id)
        precondition(store.search(query: "", pinnedFirst: true).map(\.id) == [newer.id, older.id], "Multiple pins retain newest-first order")
        store.toggleStar(id: older.id)
        precondition(store.search(query: "", pinnedFirst: true).map(\.id) == [newer.id, older.id], "Unpin returns the entry to its date position")
        store.toggleStar(id: newer.id)
        store.toggleStar(id: older.id)
        precondition(store.entries == storedOrder && store.selectedEntryID == selectedID, "Pinning must preserve persisted chronology, all metadata, and selection")
        precondition(store.search(query: " ", starredOnly: true).map(\.id) == [older.id])
        for query in ["PROMPT", "Original", "Editor", "Reference"] {
            precondition(store.search(query: query, starredOnly: true).map(\.id) == [older.id], "Search must intersect with stars across every field")
        }
        precondition(store.search(query: "Another", starredOnly: true).isEmpty)
        precondition(older.replacingAudio(nil).isStarred, "Audio removal must preserve the star")
        let backup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        store.toggleStar(id: older.id)
        await store.finishPendingWrites()
        let unstarred = try await writer.load()
        precondition(!unstarred.contains(where: \.isStarred), "Removing a star must survive restart")
        store.restore(from: backup)
        await store.finishPendingWrites()
        let restored = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        let normalizedRestore = restored.map { entry in
            var entry = entry
            entry.searchRevision = backup.first(where: { $0.id == entry.id })?.searchRevision
            return entry
        }
        precondition(normalizedRestore == backup, "Backup restore must retain stars and metadata while refreshing search revisions")
        store.selectEntryFromSearch(id: older.id)
        guard let firstRequest = store.searchSelectionRequest else {
            preconditionFailure("Selecting a search result must create a request")
        }
        store.selectEntryFromSearch(id: older.id)
        guard let repeatedRequest = store.searchSelectionRequest else {
            preconditionFailure("Selecting the same result again must create a request")
        }
        precondition(firstRequest != repeatedRequest, "Repeated clicks on the same result must create a fresh bounded request")
        store.consumeSearchSelectionRequest(firstRequest)
        precondition(store.searchSelectionRequest == repeatedRequest, "A stale consumer must not clear the latest search request")
        store.consumeSearchSelectionRequest(repeatedRequest)
        precondition(store.searchSelectionRequest == nil, "The active consumer clears its request")
        store.selectedEntryID = older.id
        store.toggleStar(id: older.id)
        precondition(store.searchSelectionRequest == nil, "Unstar is a local edit, not a sidebar reveal")
        store.deleteEntry(id: older.id)
        precondition(store.selectedEntryID == newer.id, "Deleting the selected row retains the existing store fallback")
        precondition(store.searchSelectionRequest == nil, "Delete fallback must not reset History filters")
        store.toggleStar(id: older.id)
        await store.finishPendingWrites()
        let afterDelete = try await writer.load()
        precondition(afterDelete == restored.filter { $0.id == newer.id }, "A stale star action must not resurrect a deleted entry")
        print("PASS: star filtering/search, chronology, audio preservation, unstar/restart, backup restore, deletion and bounded explicit search requests")
    }

    @MainActor static func testTodaySummary(root: URL, defaults: UserDefaults, audio: DictationAudioMetadata) async throws {
        let formatter = ISO8601DateFormatter()
        guard var now = formatter.date(from: "2026-03-08T18:00:00Z"),
              let losAngeles = TimeZone(identifier: "America/Los_Angeles"),
              let plusFourteen = TimeZone(secondsFromGMT: 14 * 3600)
        else { preconditionFailure("Invalid calendar fixtures") }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = losAngeles
        var clockReads = 0
        let writer = TranscriptionHistoryWriter(defaults: defaults, url: root.appendingPathComponent("summary.sqlite3"))
        let store = TranscriptionHistoryStore(
            writer: writer,
            summaryNow: {
                clockReads += 1
                return now
            },
            summaryCalendar: { calendar }
        )
        try await store.waitUntilLoaded()
        await store.waitForTodaySummary()
        guard let day = calendar.dateInterval(of: .day, for: now) else {
            preconditionFailure("Missing fixture day")
        }
        precondition(day.duration == 23 * 3600, "Fixture must exercise a DST-shortened day")
        func entry(_ timestamp: Date, _ text: String) -> TranscriptionHistoryEntry {
            TranscriptionHistoryEntry(
                timestamp: timestamp,
                rawText: text,
                processedText: text,
                appName: "Test",
                windowTitle: "Test",
                wasAIProcessed: false
            )
        }
        let yesterday = entry(day.start.addingTimeInterval(-1), "not today")
        let first = entry(day.start, "  one\t two\nthree  ")
        let last = entry(day.end.addingTimeInterval(-1), "four")
        let tomorrow = entry(day.end, "next day")
        store.restore(from: [yesterday, first, last, tomorrow])
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 4, transcriptions: 2), "Preserve word splitting and half-open local-day boundaries")
        let reads = clockReads
        let unchangedEntries = store.entries
        for _ in 0..<10_000 {
            precondition(store.todaySummary.words == 4)
        }
        precondition(clockReads == reads, "Rendering must not query clock or schedule a recount")
        store.attachAudio(audio, to: first.id)
        await store.waitForTodaySummary()
        precondition(clockReads == reads, "Audio-only metadata must not invalidate text stats")
        precondition(store.entries.map(\.processedText) == unchangedEntries.map(\.processedText))
        precondition(store.selectedEntryID == unchangedEntries.first?.id, "Summary work must not change selection")
        store.deleteEntry(id: UUID())
        store.deleteEntries(ids: [])
        await store.waitForTodaySummary()
        precondition(clockReads == reads, "No-op deletions must not schedule work")
        print("PASS: constant-time stats reads, exact whitespace/DST boundaries, audio-only non-effects")

        let additionID = UUID()
        store.addEntry(id: additionID, timestamp: now, rawText: "new text", processedText: "new text", appName: "Test", windowTitle: "Test")
        store.deleteEntry(id: first.id)
        store.deleteEntries(ids: [last.id])
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1))
        store.addEntry(timestamp: now, rawText: "", processedText: " \n ", appName: "Test", windowTitle: "Test")
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1))

        // Bulk replacement followed by rapid changes must only publish the latest history.
        store.restore(from: Array(repeating: first, count: 10_000))
        await Task.yield()
        store.restore(from: [yesterday, first, last, tomorrow])
        store.deleteEntries(ids: [first.id, last.id])
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 0, transcriptions: 0), "Never apply a stale bulk-rebuild result")
        var replacedFromSubscriber = false
        let subscription = store.todaySummaryPublisher.sink { summary in
            guard summary.words == 3, !replacedFromSubscriber else { return }
            replacedFromSubscriber = true
            store.restore(from: [yesterday, tomorrow])
        }
        store.restore(from: [first])
        await store.waitForTodaySummary()
        precondition(replacedFromSubscriber && store.todaySummary == .init(words: 0, transcriptions: 0), "Reentrant changes must not be lost during publication")
        subscription.cancel()
        print("PASS: insert/delete/bulk-delete/empty input and rapid replacement converge to latest snapshot")

        now = day.end.addingTimeInterval(1)
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1), "Midnight must refresh without a dictation")
        now = day.end.addingTimeInterval(12 * 3600)
        calendar.timeZone = plusFourteen
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 0, transcriptions: 0), "Timezone changes must redefine today")
        now = yesterday.timestamp
        calendar.timeZone = losAngeles
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 2, transcriptions: 1), "Clock moving backward must refresh")
        let settledReads = clockReads
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        precondition(clockReads == settledReads + 1, "Activation within same day must not rebuild")
        store.clearAllHistory()
        await store.waitForTodaySummary()
        precondition(store.todaySummary == .init(words: 0, transcriptions: 0))
        await store.finishPendingWrites()
        print("PASS: day/timezone/backward-clock changes, unchanged-day no-op, and clear")
    }

    static func sql(_ url: URL, _ command: String) throws {
        var handle: OpaquePointer?
        precondition(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        precondition(sqlite3_exec(handle, command, nil, nil, nil) == SQLITE_OK)
    }
}
