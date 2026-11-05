@testable import FluidVoice_Debug
import Combine
import Foundation
import SQLite3
import XCTest

struct HistoryXCFailure: Error { let message: String }

/// XCTest port of Tests/HistoryPersistenceBoundaryTests.swift. It exercises the real
/// TranscriptionHistoryStore/Writer against a temp SQLite file and a synthetic UserDefaults suite.
@MainActor
final class HistoryPersistenceXCTests: XCTestCase {
    static let audio = DictationAudioMetadata(fileName: "test.wav", durationMilliseconds: 1000, byteCount: 32_000,
        sampleRate: 16_000, channels: 1, model: "test")
    var root: URL!
    var defaults: UserDefaults!
    var suite: String!

    override func setUpWithError() throws {
        continueAfterFailure = false
        self.root = FileManager.default.temporaryDirectory.appendingPathComponent("fluid-history-xctest-\(UUID())")
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
        self.suite = "fluid-history-xctest-\(UUID())"
        self.defaults = try XCTUnwrap(UserDefaults(suiteName: self.suite))
    }

    override func tearDownWithError() throws {
        self.defaults.removePersistentDomain(forName: self.suite)
        try? FileManager.default.removeItem(at: self.root)
    }

    func expect(_ value: @autoclosure () -> Bool, _ message: @autoclosure () -> String = "", line: UInt = #line) {
        XCTAssertTrue(value(), message(), line: line)
    }

    func testMigrationAndWriteBoundary() async throws {
        let root = self.root, defaults = self.defaults
        let key = "TranscriptionHistoryEntries"
        let audio = Self.audio
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
            throw HistoryXCFailure(message: "Expected legacy history to encode as an array of objects")
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
        expect(store.todaySummary == .init(words: 2, transcriptions: 1), "Startup stats must include merged pending edits")
        await store.finishPendingWrites()
        expect(defaults.data(forKey: key) == nil, "Retire legacy only after successful import")
        expect(store.entries.count == 8400)
        expect(store.entries.first(where: { $0.id == newID })?.audio == audio)
        expect(store.entries.first(where: { $0.id == newID })?.isStarred == true)
        expect(store.entries.filter(\.isStarred).count == 1, "Legacy entries must default to unstarred")
        expect(!store.entries.contains(where: { $0.id == legacy[1].id }))
        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        expect(reloaded == store.entries, "Migration, metadata and concurrent startup edits must round-trip")
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
        expect(store.persistenceError == nil, "Updating one row must not rewrite unrelated history")
        let afterStar = try await writer.load()
        expect(afterStar == store.entries, "Rapid star toggles and audio updates must persist in order")
        print("PASS: single-row audio update; main actor enqueue \(enqueueMs) ms")
        try self.sql(url, "DROP TRIGGER reject_old")

        try self.sql(url, "CREATE TRIGGER reject_all BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'test disk failure'); END")
        let failedID = UUID()
        store.addEntry(id: failedID, rawText: "pending", processedText: "Unsaved", appName: "Test", windowTitle: "Test")
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        expect(store.persistenceError != nil)
        expect(store.entries.contains(where: { $0.id == failedID }))
        await store.waitForTodaySummary()
        expect(store.todaySummary == .init(words: 3, transcriptions: 2), "A disk error must not drop in-memory stats")
        let afterFailure = try await writer.load()
        expect(!afterFailure.contains(where: { $0.id == failedID }))
        store.retryPersistence()
        await store.finishPendingWrites()
        let afterFailedReplacement = try await writer.load()
        expect(afterFailedReplacement == afterFailure, "Failed replacement must roll back its initial DELETE")
        try self.sql(url, "DROP TRIGGER reject_all")
        store.retryPersistence()
        await store.finishPendingWrites()
        for _ in 0..<10 {
            await Task.yield()
        }
        expect(store.persistenceError == nil)
        let afterRetry = try await writer.load()
        expect(afterRetry.contains(where: { $0.id == failedID }))
        print("PASS: failed write stays in memory, surfaces error, retry restores complete snapshot")

        store.clearAllHistory()
        store.attachAudio(audio, to: newID)
        await store.finishPendingWrites()
        let afterClear = try await writer.load()
        expect(afterClear.isEmpty, "Late audio must not resurrect deleted entries")
        try defaults.set(JSONEncoder().encode(legacy), forKey: key)
        let afterRestart = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        expect(afterRestart.isEmpty, "Migration marker must prevent old history resurrection")
        print("PASS: clear, late audio, restart and stale legacy cannot resurrect history")

        let badURL = root.appendingPathComponent("bad.sqlite3")
        let badData = Data("invalid JSON".utf8)
        defaults.set(badData, forKey: key)
        let badStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: badURL))
        var corruptFailedVisibly = false
        do { try await badStore.waitUntilLoaded() } catch { corruptFailedVisibly = true }
        expect(corruptFailedVisibly, "Corrupt legacy must fail visibly")
        expect(!badStore.isLoading && badStore.persistenceError != nil)
        expect(defaults.data(forKey: key) == badData)
        try defaults.set(JSONEncoder().encode([legacy[0]]), forKey: key)
        badStore.retryPersistence()
        try await badStore.waitUntilLoaded()
        expect(badStore.entries == [legacy[0]])
        print("PASS: corrupt migration preserves source, exits loading and supports retry")

        let restoreStore = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: defaults, url: url))
        restoreStore.restore(from: [legacy[3]])
        try await restoreStore.waitUntilLoaded()
        await restoreStore.finishPendingWrites()
        guard let restored = restoreStore.entries.first,
              let revision = restored.searchRevision
        else { throw HistoryXCFailure(message: "Restore must set a search revision") }
        expect(revision > (legacy[3].searchRevision ?? 1), "Restore must invalidate the previous search record")
        var expectedRestore = legacy[3]
        expectedRestore.searchRevision = revision
        expect(restoreStore.entries == [expectedRestore], "Restore must preserve every field except the search revision")
        let afterRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        expect(afterRestore == [expectedRestore], "The new search revision and original content must round-trip")
        restoreStore.restore(from: [legacy[3]])
        await restoreStore.finishPendingWrites()
        guard let nextRevision = restoreStore.entries.first?.searchRevision else {
            throw HistoryXCFailure(message: "Repeated restore must preserve a search revision")
        }
        expect(nextRevision > revision, "Restoring an older backup must advance past the currently indexed revision")
        expectedRestore.searchRevision = nextRevision
        let afterRepeatedRestore = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        expect(afterRepeatedRestore == [expectedRestore], "Repeated restore changes only the persisted search revision")
        print("PASS: restore during loading replaces both memory and disk")
    }

    func testTodaySummaryXC() async throws { try await self.testTodaySummary(root: self.root, defaults: self.defaults, audio: Self.audio) }
    func testStarsXC() async throws { try await self.testStars(root: self.root, defaults: self.defaults, audio: Self.audio) }
    func testWordCorrectionsXC() async throws { try await self.testWordCorrections(root: self.root, defaults: self.defaults, audio: Self.audio) }

    func testWordCorrections(root: URL, defaults: UserDefaults, audio: DictationAudioMetadata) async throws {
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
        expect(store.applyWordCorrection(entryID: original.id, expectedText: displayed,
            range: lastWord, replacement: "Pichi", profile: profile))
        let first = store.entries[0]
        expect(first.processedText == "Ёжик 🦔 Pech Voice и Pichi Voice.", "Only the selected repeated occurrence changes")
        expect(first.rawText == original.rawText && first.originalProcessedText == original.processedText,
            "Original ASR and model output remain exact")
        expect(first.id == original.id && first.timestamp == original.timestamp && first.audio == original.audio && first.isStarred,
            "Manual edits retain identity, chronology, audio and star")
        expect(first.processingModel == original.processingModel && first.wasAIProcessed == original.wasAIProcessed &&
            first.aiProcessingError == original.aiProcessingError && first.aiTokensPerSecond == original.aiTokensPerSecond &&
            first.transcriptionDurationMilliseconds == original.transcriptionDurationMilliseconds &&
            first.parakeetProcessingDurationMilliseconds == original.parakeetProcessingDurationMilliseconds &&
            first.aiProcessingDurationMilliseconds == original.aiProcessingDurationMilliseconds,
            "Manual edits do not rewrite inference provenance")
        expect(first.characterCount == first.processedText.count && first.previewText == first.processedText &&
            first.clipboardText == first.processedText, "Every display/copy path uses corrected final text")
        expect(first.searchRecord.revision > before.searchRecord.revision && first.searchRecord.text.contains("Pichi Voice"),
            "A correction advances the existing search revision")
        expect(store.search(query: "Pichi").map(\.id) == [original.id], "Corrected text is searchable")
        expect(!store.applyWordCorrection(entryID: original.id, expectedText: displayed,
            range: lastWord, replacement: "Stale", profile: profile), "Stale text cannot change a newer correction")
        let firstWord = (first.processedText as NSString).range(of: "Pech")
        expect(store.applyWordCorrection(entryID: original.id, expectedText: first.processedText,
            range: firstWord, replacement: "Pichi", profile: profile))
        let second = store.entries[0]
        expect(second.originalProcessedText == original.processedText && second.searchRecord.revision > first.searchRecord.revision,
            "Later edits preserve the first model bytes and advance revision again")
        let emoji = (second.processedText as NSString).range(of: "🦔")
        for invalid in [NSRange(location: NSNotFound, length: 1), NSRange(location: -1, length: 1),
                        NSRange(location: Int.max - 1, length: Int.max - 1),
                        NSRange(location: emoji.location, length: 1)] {
            expect(!store.applyWordCorrection(entryID: original.id, expectedText: second.processedText,
                range: invalid, replacement: "invalid", profile: profile), "Malformed UTF16 ranges are rejected")
        }
        expect(!store.applyWordCorrection(entryID: original.id, expectedText: second.processedText,
            range: NSRange(location: 0, length: 1), replacement: "bad\nline", profile: profile), "Word edits cannot inject control characters")
        expect(!store.applyWordCorrection(entryID: original.id, expectedText: second.processedText,
            range: NSRange(location: 0, length: second.processedText.utf16.count), replacement: "", profile: profile),
            "Empty final text cannot silently fall back to the uncorrected raw text")
        expect(store.entries[0] == second, "Rejected edits leave all metadata unchanged")
        store.attachAudio(laterAudioMetadata(), to: original.id)
        let attached = store.entries[0]
        expect(attached.originalProcessedText == original.processedText && attached.processedText == second.processedText,
            "Later audio metadata updates preserve manual corrections")
        await store.finishPendingWrites()
        let reloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        expect(reloaded == store.entries, "Edited text and exact original output survive SQLite reload")
        let backup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        expect(backup == store.entries, "Backup export keeps both current final and original model output")
        var legacy = try JSONSerialization.jsonObject(with: JSONEncoder().encode(original)) as! [String: Any]
        legacy.removeValue(forKey: "originalProcessedText")
        let legacyEntry = try JSONDecoder().decode(TranscriptionHistoryEntry.self, from: JSONSerialization.data(withJSONObject: legacy))
        expect(legacyEntry.originalProcessedText == nil && legacyEntry == original, "Legacy entries decode without a manual correction field")
        let sourceOriginal = TranscriptionHistoryEntry(rawText: "Ёжик 🦔 Pech и Pech.",
            processedText: "AI formatted result.", appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: true, audio: audio)
        store.restore(from: [sourceOriginal])
        let sourceRange = (sourceOriginal.rawText as NSString).range(of: "Pech", options: .backwards)
        expect(store.applyWordCorrection(entryID: sourceOriginal.id, expectedText: sourceOriginal.rawText,
            range: sourceRange, replacement: "Pichi", profile: profile, isOriginal: true))
        let sourceEdited = store.entries[0]
        expect(sourceEdited.sourceTranscriptText == "Ёжик 🦔 Pech и Pichi." && sourceEdited.rawText == sourceOriginal.rawText,
            "Source edits preserve exact immutable ASR bytes and the selected repeated occurrence")
        expect(sourceEdited.processedText.contains("Pichi") && sourceEdited.originalProcessedText == sourceOriginal.processedText,
            "Explicit source corrections override divergent AI output and preserve its original bytes")
        expect(store.search(query: "Pichi").map(\.id) == [sourceOriginal.id] && sourceEdited.searchRecord.text.contains("Pichi"))
        expect(!store.applyWordCorrection(entryID: sourceOriginal.id, expectedText: sourceOriginal.rawText,
            range: sourceRange, replacement: "Stale", profile: profile, isOriginal: true))
        store.attachAudio(laterAudioMetadata(), to: sourceOriginal.id)
        await store.finishPendingWrites()
        let sourceReloaded = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        expect(sourceReloaded == store.entries && sourceReloaded[0].correctedRawText == sourceEdited.correctedRawText,
            "Corrected source survives audio attachment and SQLite reload")
        let sourceBackup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        expect(sourceBackup == store.entries)
        let identical = TranscriptionHistoryEntry(rawText: "Приложение PGI.", processedText: "Приложение PGI.",
            appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: false)
        store.restore(from: [identical])
        expect(store.applyWordCorrection(entryID: identical.id, expectedText: identical.rawText,
            range: (identical.rawText as NSString).range(of: "PGI"), replacement: "Pichi AI", profile: profile, isOriginal: true))
        expect(store.entries[0].sourceTranscriptText == "Приложение Pichi AI." &&
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
            expect(result == expected, "Source correction must reach the selected final span: \(result)")
            expect(SourceTranscriptCorrection.apply(original: raw, corrected: corrected, to: result) == result,
                "Repeated reconciliation cannot duplicate an inserted compound")
        }
        let repeatedSource = "Проверь Alfa AI, или, например, Beta Voice, или другое, например, Game и Testo."
        let repeatedCorrected = "Проверь Alpha AI, или, например, Beta Voice, или другое, например, Gamma и Test."
        let repeatedFormatted = "Проверь Alf I, например, Beta Voice, или другое, например, Gama и testo."
        let settled = SourceTranscriptCorrection.apply(original: repeatedSource, corrected: repeatedCorrected, to: repeatedFormatted)
        expect(settled.contains("Alpha AI") && settled.contains("Gamma") && settled.contains("Test"))
        expect(SourceTranscriptCorrection.apply(original: repeatedSource, corrected: repeatedCorrected, to: settled) == settled,
            "Repeated context and punctuation must settle before a correction is persisted")
        let reverted = TranscriptionHistoryEntry(rawText: "Тут Pech AI.", processedText: "Тут Pichi AI!",
            appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: true,
            originalProcessedText: "Тут Peach I!", correctedRawText: "Тут Pichi AI.").replacingSourceText("Тут Pech AI.")
        expect(reverted.processedText == "Тут Pech AI!", "Reverting a source correction also changes its final occurrence")
        let large = String(repeating: "one two ", count: 3000)
        expect(SourceTranscriptCorrection.apply(original: large, corrected: large + "Pichi AI", to: "AI rewrite") == large + "Pichi AI",
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
        expect(legacyStore.entries[0].processedText == "Тут Pichi AI!")
        // Seed a genuinely old, mismatched row directly through the real writer.
        legacyWriter.write(upserts: [legacyCorrected], deletes: [], replacing: true) { _ in }
        let migrationWriteError = await legacyWriter.drain()
        expect(migrationWriteError == nil)
        let repairedStore = TranscriptionHistoryStore(writer: legacyWriter)
        try await repairedStore.waitUntilLoaded()
        await repairedStore.finishPendingWrites()
        let repaired = repairedStore.entries[0]
        expect(repaired.processedText == "Тут Pichi AI!" && repaired.rawText == legacyCorrected.rawText &&
            repaired.audio == legacyCorrected.audio && repaired.originalProcessedText == legacyCorrected.processedText &&
            repaired.searchRevision != nil, "Existing manual source edits reconcile on load without changing provenance")
        let stableStore = TranscriptionHistoryStore(writer: legacyWriter)
        try await stableStore.waitUntilLoaded()
        expect(stableStore.entries[0] == repaired, "Reopening an already-repaired entry is a no-op")
        let groupedOriginal = TranscriptionHistoryEntry(rawText: "Ёжик 🦔 Pichi AI и Term.", processedText: "Ёжик 🦔 Peach I, и Term!",
            appName: "Synthetic", windowTitle: "Synthetic", wasAIProcessed: true, audio: audio)
        store.restore(from: [groupedOriginal])
        let compoundRange = (groupedOriginal.rawText as NSString).range(of: "Pichi AI")
        expect(store.applyWordCorrection(entryID: groupedOriginal.id, expectedText: groupedOriginal.rawText,
            range: compoundRange, replacement: "Pichi AI", profile: profile, isOriginal: true),
            "Saving an unchanged multiword selection confirms one persistent fragment")
        let grouped = store.entries[0]
        expect(grouped.sourceFragments.count == 1 && grouped.sourceFragments[0].range == compoundRange &&
            grouped.sourceFragments[0].text == "Pichi AI" && grouped.processedText == "Ёжик 🦔 Pichi AI, и Term!",
            "The grouped range includes its space and overrides a divergent formatted compound")
        expect(!store.applyWordCorrection(entryID: grouped.id, expectedText: grouped.sourceTranscriptText,
            range: compoundRange, replacement: "Pichi AI", profile: profile, isOriginal: true), "Repeated grouping is a no-op")
        let prefixRange = (grouped.sourceTranscriptText as NSString).range(of: "Ёжик")
        expect(store.applyWordCorrection(entryID: grouped.id, expectedText: grouped.sourceTranscriptText,
            range: prefixRange, replacement: "Большой Ёжик", profile: profile, isOriginal: true))
        let shifted = store.entries[0]
        expect(shifted.sourceFragments.first { $0.text == "Pichi AI" }?.range == (shifted.sourceTranscriptText as NSString).range(of: "Pichi AI"),
            "Editing before a group shifts its UTF16 range across a Unicode prefix")
        let component = (shifted.sourceTranscriptText as NSString).range(of: "AI")
        expect(store.applyWordCorrection(entryID: grouped.id, expectedText: shifted.sourceTranscriptText,
            range: component, replacement: "Enablement", profile: profile, isOriginal: true))
        let changedGroup = store.entries[0]
        expect(changedGroup.sourceFragments.contains { $0.text == "Pichi Enablement" && $0.isValid(in: changedGroup.sourceTranscriptText) },
            "Editing a component keeps the full group together")
        store.attachAudio(laterAudioMetadata(), to: grouped.id)
        await store.finishPendingWrites()
        let groupReload = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        expect(groupReload == store.entries && groupReload[0].sourceFragments == changedGroup.sourceFragments,
            "Grouped terms survive audio attachment and persistence")
        let groupBackup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        expect(groupBackup == store.entries)
        let entireGroup = (store.entries[0].sourceTranscriptText as NSString).range(of: "Pichi Enablement")
        expect(store.applyWordCorrection(entryID: grouped.id, expectedText: store.entries[0].sourceTranscriptText,
            range: entireGroup, replacement: "", profile: profile, isOriginal: true))
        expect(!store.entries[0].sourceFragments.contains { $0.text.contains("Pichi") }, "Deleting a group removes its metadata")
        let invalidGroup = TranscriptionHistoryEntry.SourceFragment(location: 0, length: 5, text: "wrong")
        let sanitized = TranscriptionHistoryEntry(rawText: "hello", processedText: "hello", appName: "Synthetic", windowTitle: "Synthetic",
            wasAIProcessed: false, sourceFragments: [invalidGroup])
        expect(sanitized.sourceFragments.isEmpty, "A stale fragment cannot highlight unrelated text")
        print("PASS: grouped fragments, source and final corrections, exact UTF16 occurrence, provenance, search, persistence, audio, backup and legacy decoding")
    }

    func laterAudioMetadata() -> DictationAudioMetadata {
        DictationAudioMetadata(fileName: "later.wav", durationMilliseconds: 2000, byteCount: 64_000,
            sampleRate: 16_000, channels: 1, model: "synthetic")
    }

    func testStars(root: URL, defaults: UserDefaults, audio: DictationAudioMetadata) async throws {
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
        expect(store.search(query: "").map(\.id) == [newer.id, older.id], "Stars must preserve chronological order")
        expect(store.search(query: "", pinnedFirst: true).map(\.id) == [older.id, newer.id], "History displays pins first")
        expect(store.search(query: "prompt", pinnedFirst: true).map(\.id) == [older.id, newer.id], "Pin ordering applies after text filtering")
        expect(store.search(query: "Another", pinnedFirst: true).map(\.id) == [newer.id], "Pins must not bypass the search filter")
        let storedOrder = store.entries
        let selectedID = store.selectedEntryID
        store.toggleStar(id: newer.id)
        expect(store.search(query: "", pinnedFirst: true).map(\.id) == [newer.id, older.id], "Multiple pins retain newest-first order")
        store.toggleStar(id: older.id)
        expect(store.search(query: "", pinnedFirst: true).map(\.id) == [newer.id, older.id], "Unpin returns the entry to its date position")
        store.toggleStar(id: newer.id)
        store.toggleStar(id: older.id)
        expect(store.entries == storedOrder && store.selectedEntryID == selectedID, "Pinning must preserve persisted chronology, all metadata, and selection")
        expect(store.search(query: " ", starredOnly: true).map(\.id) == [older.id])
        for query in ["PROMPT", "Original", "Editor", "Reference"] {
            expect(store.search(query: query, starredOnly: true).map(\.id) == [older.id], "Search must intersect with stars across every field")
        }
        expect(store.search(query: "Another", starredOnly: true).isEmpty)
        expect(older.replacingAudio(nil).isStarred, "Audio removal must preserve the star")
        let backup = try JSONDecoder().decode([TranscriptionHistoryEntry].self, from: JSONEncoder().encode(store.makeBackupPayload()))
        store.toggleStar(id: older.id)
        await store.finishPendingWrites()
        let unstarred = try await writer.load()
        expect(!unstarred.contains(where: \.isStarred), "Removing a star must survive restart")
        store.restore(from: backup)
        await store.finishPendingWrites()
        let restored = try await TranscriptionHistoryWriter(defaults: defaults, url: url).load()
        let normalizedRestore = restored.map { entry in
            var entry = entry
            entry.searchRevision = backup.first(where: { $0.id == entry.id })?.searchRevision
            return entry
        }
        expect(normalizedRestore == backup, "Backup restore must retain stars and metadata while refreshing search revisions")
        store.selectEntryFromSearch(id: older.id)
        guard let firstRequest = store.searchSelectionRequest else {
            throw HistoryXCFailure(message: "Selecting a search result must create a request")
        }
        store.selectEntryFromSearch(id: older.id)
        guard let repeatedRequest = store.searchSelectionRequest else {
            throw HistoryXCFailure(message: "Selecting the same result again must create a request")
        }
        expect(firstRequest != repeatedRequest, "Repeated clicks on the same result must create a fresh bounded request")
        store.consumeSearchSelectionRequest(firstRequest)
        expect(store.searchSelectionRequest == repeatedRequest, "A stale consumer must not clear the latest search request")
        store.consumeSearchSelectionRequest(repeatedRequest)
        expect(store.searchSelectionRequest == nil, "The active consumer clears its request")
        store.selectedEntryID = older.id
        store.toggleStar(id: older.id)
        expect(store.searchSelectionRequest == nil, "Unstar is a local edit, not a sidebar reveal")
        store.deleteEntry(id: older.id)
        expect(store.selectedEntryID == newer.id, "Deleting the selected row retains the existing store fallback")
        expect(store.searchSelectionRequest == nil, "Delete fallback must not reset History filters")
        store.toggleStar(id: older.id)
        await store.finishPendingWrites()
        let afterDelete = try await writer.load()
        expect(afterDelete == restored.filter { $0.id == newer.id }, "A stale star action must not resurrect a deleted entry")
        print("PASS: star filtering/search, chronology, audio preservation, unstar/restart, backup restore, deletion and bounded explicit search requests")
    }

    func testTodaySummary(root: URL, defaults: UserDefaults, audio: DictationAudioMetadata) async throws {
        let formatter = ISO8601DateFormatter()
        guard var now = formatter.date(from: "2026-03-08T18:00:00Z"),
              let losAngeles = TimeZone(identifier: "America/Los_Angeles"),
              let plusFourteen = TimeZone(secondsFromGMT: 14 * 3600)
        else { throw HistoryXCFailure(message: "Invalid calendar fixtures") }
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
            throw HistoryXCFailure(message: "Missing fixture day")
        }
        expect(day.duration == 23 * 3600, "Fixture must exercise a DST-shortened day")
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
        expect(store.todaySummary == .init(words: 4, transcriptions: 2), "Preserve word splitting and half-open local-day boundaries")
        let reads = clockReads
        let unchangedEntries = store.entries
        for _ in 0..<10_000 {
            expect(store.todaySummary.words == 4)
        }
        expect(clockReads == reads, "Rendering must not query clock or schedule a recount")
        store.attachAudio(audio, to: first.id)
        await store.waitForTodaySummary()
        expect(clockReads == reads, "Audio-only metadata must not invalidate text stats")
        expect(store.entries.map(\.processedText) == unchangedEntries.map(\.processedText))
        expect(store.selectedEntryID == unchangedEntries.first?.id, "Summary work must not change selection")
        store.deleteEntry(id: UUID())
        store.deleteEntries(ids: [])
        await store.waitForTodaySummary()
        expect(clockReads == reads, "No-op deletions must not schedule work")
        print("PASS: constant-time stats reads, exact whitespace/DST boundaries, audio-only non-effects")

        let additionID = UUID()
        store.addEntry(id: additionID, timestamp: now, rawText: "new text", processedText: "new text", appName: "Test", windowTitle: "Test")
        store.deleteEntry(id: first.id)
        store.deleteEntries(ids: [last.id])
        await store.waitForTodaySummary()
        expect(store.todaySummary == .init(words: 2, transcriptions: 1))
        store.addEntry(timestamp: now, rawText: "", processedText: " \n ", appName: "Test", windowTitle: "Test")
        await store.waitForTodaySummary()
        expect(store.todaySummary == .init(words: 2, transcriptions: 1))

        // Bulk replacement followed by rapid changes must only publish the latest history.
        store.restore(from: Array(repeating: first, count: 10_000))
        await Task.yield()
        store.restore(from: [yesterday, first, last, tomorrow])
        store.deleteEntries(ids: [first.id, last.id])
        await store.waitForTodaySummary()
        expect(store.todaySummary == .init(words: 0, transcriptions: 0), "Never apply a stale bulk-rebuild result")
        var replacedFromSubscriber = false
        let subscription = store.todaySummaryPublisher.sink { summary in
            guard summary.words == 3, !replacedFromSubscriber else { return }
            replacedFromSubscriber = true
            store.restore(from: [yesterday, tomorrow])
        }
        store.restore(from: [first])
        await store.waitForTodaySummary()
        expect(replacedFromSubscriber && store.todaySummary == .init(words: 0, transcriptions: 0), "Reentrant changes must not be lost during publication")
        subscription.cancel()
        print("PASS: insert/delete/bulk-delete/empty input and rapid replacement converge to latest snapshot")

        now = day.end.addingTimeInterval(1)
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        expect(store.todaySummary == .init(words: 2, transcriptions: 1), "Midnight must refresh without a dictation")
        now = day.end.addingTimeInterval(12 * 3600)
        calendar.timeZone = plusFourteen
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        expect(store.todaySummary == .init(words: 0, transcriptions: 0), "Timezone changes must redefine today")
        now = yesterday.timestamp
        calendar.timeZone = losAngeles
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        expect(store.todaySummary == .init(words: 2, transcriptions: 1), "Clock moving backward must refresh")
        let settledReads = clockReads
        store.refreshTodaySummaryForCalendarChange()
        await store.waitForTodaySummary()
        expect(clockReads == settledReads + 1, "Activation within same day must not rebuild")
        store.clearAllHistory()
        await store.waitForTodaySummary()
        expect(store.todaySummary == .init(words: 0, transcriptions: 0))
        await store.finishPendingWrites()
        print("PASS: day/timezone/backward-clock changes, unchanged-day no-op, and clear")
    }

    func sql(_ url: URL, _ command: String) throws {
        var handle: OpaquePointer?
        expect(sqlite3_open(url.path, &handle) == SQLITE_OK)
        defer { sqlite3_close(handle) }
        expect(sqlite3_exec(handle, command, nil, nil, nil) == SQLITE_OK)
    }
}
