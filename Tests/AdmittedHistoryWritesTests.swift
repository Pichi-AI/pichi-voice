import Combine
import Foundation
import SQLite3

@main @MainActor struct AdmittedHistoryWritesTests {
    static var checks = 0
    static var domains: [String] = []
    static var manifest: URL!
    static func expect(_ value: Bool, _ message: String) {
        checks += 1
        precondition(value, message)
    }
    static func defaults() throws -> UserDefaults {
        let name = "synthetic.admitted-history.\(UUID())"
        domains.append(name)
        try JSONEncoder().encode(domains).write(to: manifest, options: .atomic)
        return UserDefaults(suiteName: name)!
    }
    static func main() async throws {
        let original = PrivateProfileStorage.current
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        manifest = URL(fileURLWithPath: CommandLine.arguments[2])
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer {
            for domain in domains {
                let defaults = UserDefaults(suiteName: domain)!
                defaults.removePersistentDomain(forName: domain)
                precondition(defaults.synchronize())
                precondition(defaults.persistentDomain(forName: domain)?.isEmpty != false)
            }
            PrivateProfileStorage.select(original)
            PrivateProfileStorage.clearStoreCaches()
            PrivateProfileObjectCache.removeAll()
        }
        let fixture = UUID().uuidString
        func profile(_ name: String, generation: UUID = UUID()) throws -> PrivateProfileSnapshot {
            let context = AccountContext(identity: .init(issuer: "https://synthetic.invalid", subject: fixture + name,
                internalUserID: fixture + name), organizationID: "org", workspaceID: "workspace", generation: generation)
            return try PrivateProfileStorage.proposed(context: context, generation: generation, legacyRootDirectory: root)
        }
        let a = try profile("A"), b = try profile("B")
        PrivateProfileStorage.select(a)
        let disk = a.rootDirectory.appendingPathComponent("history.sqlite3")
        let writer = TranscriptionHistoryWriter(defaults: try defaults(), url: disk, profile: a)
        let audioStore = DictationAudioHistoryStore(rootDirectory: a.rootDirectory, profile: a)
        let history = TranscriptionHistoryStore(writer: writer, profile: a, audioStore: audioStore)
        try await history.waitUntilLoaded()
        let output = try history.admitRecordingWrite()
        let audio = try output.admitAudioSave(timestamp: Date(timeIntervalSince1970: 100))
        expect(history.admittedRecordingWriteCount == 1, "Capture admission blocks a profile switch")
        do { try await history.prepareForProfileTransition(); preconditionFailure("Active output must block retirement") }
        catch AccountError.busy { checks += 1 }
        PrivateProfileStorage.closeAdmission()
        PrivateProfileStorage.conceal(generation: UUID())
        history.concealPrivateProjections()
        expect(history.entries.isEmpty && history.latestClipboardText == nil, "Conceal denies public history reads")
        expect(history.todaySummary == .init(words: 0, transcriptions: 0), "Conceal denies private aggregates")
        do { _ = try history.admitRecordingWrite(); preconditionFailure("Concealed profile cannot admit capture") }
        catch { checks += 1 }
        do { _ = try await writer.load(); preconditionFailure("Concealed profile cannot read the database") }
        catch { checks += 1 }
        var published: [[TranscriptionHistoryEntry]] = []
        var loadedEmissions = 0
        let subscription = history.entriesPublisher.sink { published.append($0) }
        let loadedSubscription = history.loadedEntriesPublisher.sink { _ in loadedEmissions += 1 }
        history.addEntry(id: output.entryID, rawText: "frozen raw", processedText: "frozen processed",
            appName: "synthetic", windowTitle: "synthetic", admission: output)
        let metadata = try await Task.detached { try audio.save(snapshot: syntheticPCM(), model: "synthetic") }.value
        try output.attachAudio(metadata, from: audio)
        try await output.finish()
        expect(history.admittedRecordingWriteCount == 0, "Finished output releases its admission")
        expect(history.entries.isEmpty && published.allSatisfy(\.isEmpty), "Hidden completion never publishes private rows")
        expect(loadedEmissions == 0, "Hidden completion never publishes a loaded snapshot")
        expect(!audioStore.audioFileExists(fileName: metadata.fileName),
            "Hidden completion does not grant audio read access")
        history.addEntry(id: output.entryID, rawText: "late", processedText: "late",
            appName: "synthetic", windowTitle: "synthetic", admission: output)
        PrivateProfileStorage.select(a)
        let completed = try await writer.load()
        expect(completed.count == 1 && completed[0].rawText == "frozen raw" && completed[0].processedText == "frozen processed",
            "Already admitted text survives conceal under its original writer")
        expect(completed[0].audio == metadata, "Hidden audio completion attaches to the same entry")
        let wav = a.directory("DictationAudioHistory").appendingPathComponent(metadata.fileName)
        expect(try Data(contentsOf: wav).count == metadata.byteCount, "Reserved worker writes its original PCM destination")
        subscription.cancel(); loadedSubscription.cancel()

        let canceled = try history.admitRecordingWrite()
        let unusedAudio = try canceled.admitAudioSave(timestamp: Date(timeIntervalSince1970: 101))
        try await canceled.finish()
        expect(history.admittedRecordingWriteCount == 0, "Canceled capture releases an unused audio reservation")
        do { _ = try unusedAudio.save(snapshot: syntheticPCM(), model: nil); preconditionFailure("Canceled reservation cannot write") }
        catch { checks += 1 }
        expect(!FileManager.default.fileExists(atPath: a.directory("DictationAudioHistory").appendingPathComponent(unusedAudio.fileName).path),
            "A canceled worker creates no file")

        let foreign = try history.admitRecordingWrite()
        let foreignAudio = try foreign.admitAudioSave(timestamp: Date(timeIntervalSince1970: 102))
        PrivateProfileStorage.select(b)
        history.addEntry(id: foreign.entryID, rawText: "foreign", processedText: "foreign",
            appName: "synthetic", windowTitle: "synthetic", admission: foreign)
        do { _ = try foreignAudio.save(snapshot: syntheticPCM(), model: nil); preconditionFailure("Foreign generation cannot write") }
        catch { checks += 1 }
        try await foreign.finish()
        expect(!FileManager.default.fileExists(atPath: b.rootDirectory.path), "A stale capability never creates B storage")
        PrivateProfileStorage.select(a)
        expect(try await writer.load().count == 1, "Foreign output never mutates the original history")
        let stale = try history.admitRecordingWrite()
        let aAgain = try profile("A")
        PrivateProfileStorage.select(aAgain)
        history.addEntry(id: stale.entryID, rawText: "ABA", processedText: "ABA",
            appName: "synthetic", windowTitle: "synthetic", admission: stale)
        try await stale.finish()
        expect(history.entries.isEmpty, "Same-account generation changes reject old source projections")
        PrivateProfileStorage.select(a)
        expect(try await writer.load().count == 1, "Same-account stale output never writes")

        try await testWordCorrectionAdmission(root: root, profile: a, foreign: b)
        try await testStartupAndAudio(root: root, profile: a)
        try await testConcurrentFinish(root: root, profile: a)
        try await testLegacyMigration(root: root)
        try await testFailedStores(root: root, profile: a)
        try await testCaptureOutputOwner(root: root, profile: a)
        try await testAudioOnlyRecovery(root: root, profile: a)
        try await testDirectCaptureOwner(root: root, profile: a)
        print("PASS: \(checks) admitted history/audio conceal, cancellation, generation, migration and retry assertions")
    }

    static func testWordCorrectionAdmission(root: URL, profile: PrivateProfileSnapshot, foreign: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profile)
        let writer = TranscriptionHistoryWriter(defaults: try defaults(), url: root.appendingPathComponent("word-edit-audio.sqlite3"), profile: profile)
        let audioRoot = root.appendingPathComponent("word-edit-audio")
        let audioStore = DictationAudioHistoryStore(rootDirectory: audioRoot, profile: profile)
        let history = TranscriptionHistoryStore(writer: writer, profile: profile, audioStore: audioStore)
        try await history.waitUntilLoaded()
        let output = try history.admitRecordingWrite()
        let audio = try output.admitAudioSave(timestamp: Date(timeIntervalSince1970: 450))
        let initial = "Ёжик 🦔 Pech Voice"
        history.addEntry(id: output.entryID, rawText: "exact ASR bytes", processedText: initial,
            appName: "synthetic", windowTitle: "synthetic", wasAIProcessed: true,
            processingModel: "synthetic-ai", admission: output)
        expect(history.applyWordCorrection(entryID: output.entryID, expectedText: initial,
            range: (initial as NSString).range(of: "Pech"), replacement: "Pichi", profile: profile),
            "A visible entry can be corrected while its original audio worker is pending")
        expect(history.applyWordCorrection(entryID: output.entryID, expectedText: "exact ASR bytes",
            range: NSRange(location: 6, length: 3), replacement: "speech", profile: profile, isOriginal: true),
            "A source correction uses the same pending recording admission")
        let metadata = try await Task.detached { try audio.save(snapshot: syntheticPCM(), model: "synthetic") }.value
        try output.attachAudio(metadata, from: audio)
        try await output.finish()
        await history.finishPendingWrites()
        let corrected = try await writer.load()[0]
        expect(corrected.sourceTranscriptText == "exact speech bytes", "Late audio retains the corrected source")
        expect(corrected.processedText == "Ёжик 🦔 Pichi Voice" && corrected.originalProcessedText == initial && corrected.rawText == "exact ASR bytes",
            "Audio attachment and recording finish do not revert the corrected final or first source bytes")
        expect(corrected.audio == metadata && audioStore.audioFileExists(fileName: metadata.fileName),
            "Manual correction does not revoke or replace the original audio admission")
        expect(corrected.searchRevision != nil && corrected.characterCount == corrected.processedText.count,
            "Admitted text correction carries updated display and search metadata")
        PrivateProfileStorage.select(foreign)
        expect(!history.applyWordCorrection(entryID: output.entryID, expectedText: corrected.processedText,
            range: NSRange(location: 0, length: 4), replacement: "foreign", profile: profile),
            "A concealed source profile cannot apply a stale correction")
        expect(!history.applyWordCorrection(entryID: output.entryID, expectedText: corrected.processedText,
            range: NSRange(location: 0, length: 4), replacement: "foreign", profile: foreign),
            "The current foreign profile cannot edit a store owned by the previous profile")
        PrivateProfileStorage.select(profile)
        PrivateProfileStorage.closeAdmission()
        expect(!history.applyWordCorrection(entryID: output.entryID, expectedText: corrected.processedText,
            range: NSRange(location: 0, length: 4), replacement: "late", profile: profile),
            "Correction rejects closed new-work admission")
        PrivateProfileStorage.select(profile)
        expect(try await writer.load() == [corrected], "Rejected hidden and closed edits leave persisted source unchanged")
        history.deleteEntry(id: output.entryID)
        expect(!history.applyWordCorrection(entryID: output.entryID, expectedText: corrected.processedText,
            range: NSRange(location: 0, length: 4), replacement: "stale", profile: profile),
            "A stale editor cannot resurrect a deleted entry")
        print("PASS: explicit final edit preserves pending audio and rejects foreign/closed/deleted profile work")
    }

    static func testLegacyMigration(root: URL) async throws {
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        let legacy = [TranscriptionHistoryEntry(rawText: "legacy raw", processedText: "legacy preserved",
            appName: "synthetic", windowTitle: "synthetic", wasAIProcessed: false)]
        let bytes = try JSONEncoder().encode(legacy)
        let signal = ReadSignal()
        let backing = SignallingDefaults(bytes: bytes, signal: signal)
        let bound = PrivateProfileDefaults(profile: guest, guestDefaults: backing)
        let queue = DispatchQueue(label: "synthetic.legacy.blocked")
        queue.suspend()
        let writer = TranscriptionHistoryWriter(defaults: bound, url: root.appendingPathComponent("queued-legacy.sqlite3"),
            profile: guest, queue: queue)
        let loading = Task { try await writer.load() }
        await signal.wait()
        PrivateProfileStorage.conceal(generation: UUID())
        queue.resume()
        do { _ = try await loading.value; preconditionFailure("Queued hidden load cannot return private records") }
        catch { checks += 1 }
        expect(backing.legacyBytes == bytes, "Concealed migration preserves the legacy defaults source")
        PrivateProfileStorage.select(guest)
        expect(try await writer.load() == legacy, "Migration uses visible admission bytes even when its queue ran hidden")
        expect(backing.legacyBytes == nil, "Committed readable migration retires exactly the frozen legacy source")

        let changedSignal = ReadSignal()
        let changing = SignallingDefaults(bytes: bytes, signal: changedSignal)
        let changedQueue = DispatchQueue(label: "synthetic.legacy.changed")
        changedQueue.suspend()
        let changedWriter = TranscriptionHistoryWriter(defaults: changing, url: root.appendingPathComponent("changed-legacy.sqlite3"),
            profile: guest, queue: changedQueue)
        let changedLoading = Task { try await changedWriter.load() }
        await changedSignal.wait()
        let newer = try JSONEncoder().encode(legacy + legacy)
        changing.legacyBytes = newer
        changedQueue.resume()
        expect(try await changedLoading.value == legacy, "Queued migration keeps its immutable captured source")
        expect(changing.legacyBytes == newer, "Queued migration never deletes a changed legacy source")
        _ = try await changedWriter.load()
        expect(changing.legacyBytes == newer, "A later load never retires bytes whose digest was not imported")

        let racing = ConcealingDefaults(profile: guest, bytes: bytes)
        let racingURL = root.appendingPathComponent("conceal-during-snapshot.sqlite3")
        let racingWriter = TranscriptionHistoryWriter(defaults: racing, url: racingURL, profile: guest)
        do { _ = try await racingWriter.load(); preconditionFailure("Conceal during snapshot must reject admission") }
        catch { checks += 1 }
        expect(!FileManager.default.fileExists(atPath: racingURL.path), "Lost snapshot admission cannot mark an empty database migrated")
        PrivateProfileStorage.select(guest)
        do { _ = try racingWriter.admitRecordingWrite(entryID: UUID(), saveGeneration: 0); preconditionFailure("Lost recording snapshot must reject admission") }
        catch { checks += 1 }
    }

    static func testStartupAndAudio(root: URL, profile: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profile)
        let reached = ReadSignal(), once = OnceFlag()
        let release = DispatchSemaphore(value: 0)
        let startupWriter = TranscriptionHistoryWriter(defaults: try defaults(), url: root.appendingPathComponent("startup.sqlite3"),
            profile: profile, didReadSnapshot: {
                if once.claim() { reached.signal(); release.wait() }
            })
        let startupAudioRoot = root.appendingPathComponent("startup-audio-root")
        let startupAudio = DictationAudioHistoryStore(rootDirectory: startupAudioRoot, profile: profile)
        let startup = TranscriptionHistoryStore(writer: startupWriter, profile: profile, audioStore: startupAudio)
        await reached.wait()
        let started = try startup.admitRecordingWrite()
        startup.addEntry(id: started.entryID, rawText: "startup raw", processedText: "startup preserved",
            appName: "synthetic", windowTitle: "synthetic", admission: started)
        startup.toggleStar(id: started.entryID)
        release.signal()
        try await startup.waitUntilLoaded()
        expect(startup.entries.map(\.processedText) == ["startup preserved"], "An older load snapshot merges an admitted recording")
        expect(startup.entries.first?.isStarred == true, "Startup merge preserves a newer pending star over its capsule")
        try await started.finish()
        startup.retryPersistence()
        await startup.finishPendingWrites()
        expect(try await startupWriter.load().map(\.processedText) == ["startup preserved"], "Replacement retry cannot erase an admitted startup row")

        let retained = try startup.admitRecordingWrite()
        let retainedAudio = try retained.admitAudioSave(timestamp: Date(timeIntervalSince1970: 200))
        startup.addEntry(id: retained.entryID, rawText: "budget", processedText: "budget",
            appName: "synthetic", windowTitle: "synthetic", admission: retained)
        let large = DictationAudioSnapshot(samples: [Float](repeating: 0.01, count: 600_000), sampleRate: 16_000, channels: 1)
        let largeMetadata = try retainedAudio.save(snapshot: large, model: "synthetic")
        try retained.attachAudio(largeMetadata, from: retainedAudio)
        try await retained.finish()
        await startup.finishPendingWrites()
        expect(startupAudio.audioUsageBytes() <= SettingsStore.shared.audioHistoryBudgetBytes,
            "Visible admitted audio uses the existing automatic retention budget")

        let first = try startup.admitRecordingWrite(), second = try startup.admitRecordingWrite()
        let firstAudio = try first.admitAudioSave(timestamp: Date(timeIntervalSince1970: 202))
        let secondAudio = try second.admitAudioSave(timestamp: Date(timeIntervalSince1970: 202))
        startup.addEntry(rawText: "first", processedText: "first", appName: "synthetic", windowTitle: "synthetic", admission: first)
        startup.addEntry(rawText: "second", processedText: "second", appName: "synthetic", windowTitle: "synthetic", admission: second)
        let firstMetadata = try firstAudio.save(snapshot: syntheticPCM(), model: nil)
        let secondMetadata = try secondAudio.save(snapshot: syntheticPCM(), model: nil)
        do { try first.attachAudio(secondMetadata, from: secondAudio); preconditionFailure("Another capability's metadata must be rejected") }
        catch { checks += 1 }
        expect(startupAudio.audioFileExists(fileName: secondAudio.fileName), "Rejected foreign metadata leaves the other reservation's PCM intact")
        try second.attachAudio(secondMetadata, from: secondAudio)
        try first.attachAudio(firstMetadata, from: firstAudio)
        try await first.finish(); try await second.finish()
        await startup.finishPendingWrites()
        expect(try await startupWriter.load().filter { $0.audio != nil }.count == 2, "Both rightful capabilities can still attach their own metadata")

        let starred = try startup.admitRecordingWrite()
        let starredAudio = try starred.admitAudioSave(timestamp: Date(timeIntervalSince1970: 203))
        startup.addEntry(rawText: "starred", processedText: "starred", appName: "synthetic", windowTitle: "synthetic", admission: starred)
        startup.toggleStar(id: starred.entryID)
        let starredMetadata = try starredAudio.save(snapshot: syntheticPCM(), model: nil)
        try starred.attachAudio(starredMetadata, from: starredAudio)
        try await starred.finish()
        expect(try await startupWriter.load().first(where: { $0.id == starred.entryID })?.isStarred == true,
            "Admitted audio attachment preserves a newer star edit")

        for multiple in [false, true] {
            let deleted = try startup.admitRecordingWrite()
            let deletedAudio = try deleted.admitAudioSave(timestamp: Date(timeIntervalSince1970: 204))
            startup.addEntry(rawText: "deleted", processedText: "deleted", appName: "synthetic", windowTitle: "synthetic", admission: deleted)
            let deletedMetadata = try deletedAudio.save(snapshot: syntheticPCM(), model: nil)
            let deletedURL = startupAudioRoot.appendingPathComponent("DictationAudioHistory").appendingPathComponent(deletedAudio.fileName)
            if multiple { startup.deleteEntries(ids: [deleted.entryID]) }
            else { startup.deleteEntry(id: deleted.entryID) }
            do { try deleted.attachAudio(deletedMetadata, from: deletedAudio); preconditionFailure("Deleted recording cannot reattach") }
            catch { checks += 1 }
            try await deleted.finish()
            expect(!FileManager.default.fileExists(atPath: deletedURL.path), "Deleted entry revokes and removes only its own reserved PCM")
            expect(try await startupWriter.load().allSatisfy { $0.id != deleted.entryID }, "Late metadata cannot resurrect a deleted row")
            expect(startupAudio.audioFileExists(fileName: starredAudio.fileName), "Deleting one admitted entry preserves another recording's audio")
        }

        let textOnly = try startup.admitRecordingWrite()
        _ = startup.deleteAllSavedAudio()
        startup.addEntry(rawText: "audio removal", processedText: "text survives audio removal",
            appName: "synthetic", windowTitle: "synthetic", admission: textOnly)
        try await textOnly.finish()
        expect(try await startupWriter.load().contains { $0.id == textOnly.entryID },
            "Removing saved audio never revokes an already admitted transcript")

        let failed = try startup.admitRecordingWrite()
        try sql(root.appendingPathComponent("startup.sqlite3"), "CREATE TRIGGER reject_insert BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'synthetic upsert failure'); END")
        startup.addEntry(rawText: "failed", processedText: "failed", appName: "synthetic", windowTitle: "synthetic", admission: failed)
        do { try await failed.finish(); preconditionFailure("Synthetic upsert must fail") }
        catch { checks += 1 }
        try sql(root.appendingPathComponent("startup.sqlite3"), "DROP TRIGGER reject_insert")
        startup.deleteEntry(id: failed.entryID)
        try await startup.retryAdmittedRecordingWrites()
        expect(startup.admittedRecordingWriteCount == 0, "Deleting a failed entry retires its obsolete upsert failure")
        expect(await startupWriter.drain() == nil, "Deletion keeps the writer drain clean after storage repair")

        let failedDelete = try startup.admitRecordingWrite()
        startup.addEntry(rawText: "delete failure", processedText: "delete failure", appName: "synthetic", windowTitle: "synthetic", admission: failedDelete)
        _ = await startupWriter.drain()
        try sql(root.appendingPathComponent("startup.sqlite3"), "CREATE TRIGGER reject_delete BEFORE DELETE ON history BEGIN SELECT RAISE(FAIL, 'synthetic deletion failure'); END")
        startup.deleteEntry(id: failedDelete.entryID)
        try await failedDelete.finish()
        expect(await startupWriter.drain() != nil, "Revocation never hides an actual deletion persistence failure")
        try sql(root.appendingPathComponent("startup.sqlite3"), "DROP TRIGGER reject_delete")
        startup.retryPersistence()
        await startup.finishPendingWrites()
        expect(await startupWriter.drain() == nil, "Deletion failure remains recoverable through the existing replacement retry")

        let cleared = try startup.admitRecordingWrite()
        let clearedAudio = try cleared.admitAudioSave(timestamp: Date(timeIntervalSince1970: 201))
        startup.addEntry(id: cleared.entryID, rawText: "cleared", processedText: "cleared",
            appName: "synthetic", windowTitle: "synthetic", admission: cleared)
        let clearedMetadata = try clearedAudio.save(snapshot: syntheticPCM(), model: nil)
        let clearedURL = startupAudioRoot.appendingPathComponent("DictationAudioHistory").appendingPathComponent(clearedAudio.fileName)
        expect(FileManager.default.fileExists(atPath: clearedURL.path), "Fixture worker owns written PCM before metadata attachment")
        startup.clearAllHistory()
        do { try cleared.attachAudio(clearedMetadata, from: clearedAudio); preconditionFailure("Cleared save generation rejects metadata") }
        catch { checks += 1 }
        try await cleared.finish()
        expect(!FileManager.default.fileExists(atPath: clearedURL.path), "Rejected metadata discards only its exact reserved PCM file")
        expect(try await startupWriter.load().isEmpty, "Clear followed by admitted completion never resurrects history")
        let neverStarted = try startup.admitRecordingWrite()
        let neverStartedAudio = try neverStarted.admitAudioSave(timestamp: Date(timeIntervalSince1970: 205))
        startup.clearAllHistory()
        do { _ = try neverStartedAudio.save(snapshot: syntheticPCM(), model: nil); preconditionFailure("Clear revokes a scheduled worker that has not started") }
        catch { checks += 1 }
        try await neverStarted.finish()
        expect(!startupAudio.audioFileExists(fileName: neverStartedAudio.fileName), "A revoked scheduled worker leaves no PCM")
        try await startup.prepareForProfileTransition()
    }

    static func testConcurrentFinish(root: URL, profile: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profile)
        let queue = DispatchQueue(label: "synthetic.concurrent-finish")
        let firstDrainQueued = ReadSignal()
        let writer = TranscriptionHistoryWriter(defaults: try defaults(), url: root.appendingPathComponent("concurrent-finish.sqlite3"),
            profile: profile, queue: queue, didEnqueueDrain: { firstDrainQueued.signal() })
        let history = TranscriptionHistoryStore(writer: writer, profile: profile,
            audioStore: .init(rootDirectory: root.appendingPathComponent("concurrent-audio"), profile: profile))
        try await history.waitUntilLoaded()
        let old = try history.admitRecordingWrite()
        history.addEntry(rawText: "old", processedText: "old", appName: "synthetic", windowTitle: "synthetic", admission: old)
        queue.suspend()
        let firstEntered = ReadSignal(), secondEntered = ReadSignal(), gateReached = ReadSignal()
        let release = DispatchSemaphore(value: 0)
        let first = Task { firstEntered.signal(); try await old.finish() }
        await firstEntered.wait()
        await firstDrainQueued.wait()
        // A queue barrier separates the first finish receipt from the second one.
        queue.async { gateReached.signal(); release.wait() }
        let second = Task { secondEntered.signal(); try await history.retryAdmittedRecordingWrites() }
        await secondEntered.wait()
        queue.resume()
        await gateReached.wait()
        try await first.value
        let newer = try history.admitRecordingWrite(entryID: old.entryID)
        expect(history.admittedRecordingWriteCount == 1, "A newer capsule can be admitted after the first receipt completes")
        release.signal()
        try await second.value
        expect(history.admittedRecordingWriteCount == 1, "An old concurrent finisher cannot remove the newer capsule")
        try await newer.finish()
        expect(history.admittedRecordingWriteCount == 0, "Concurrent cleanup joins finish without leaving stale admissions")
        try await history.prepareForProfileTransition()
    }

    static func sql(_ url: URL, _ statement: String) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else { throw AccountError.busy }
        defer { sqlite3_close(handle) }
        guard sqlite3_exec(handle, statement, nil, nil, nil) == SQLITE_OK else { throw AccountError.busy }
    }

    static func testFailedStores(root: URL, profile: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profile)
        let blocked = root.appendingPathComponent("blocked-empty")
        try Data("synthetic".utf8).write(to: blocked)
        let emptyWriter = TranscriptionHistoryWriter(defaults: try defaults(), url: blocked.appendingPathComponent("history.sqlite3"), profile: profile)
        let empty = TranscriptionHistoryStore(writer: emptyWriter, profile: profile,
            audioStore: .init(rootDirectory: profile.rootDirectory, profile: profile))
        do { try await empty.waitUntilLoaded(); preconditionFailure("Fixture must fail loading") } catch {}
        PrivateProfileStorage.conceal(generation: UUID())
        try await empty.prepareForProfileTransition()
        expect(empty.entries.isEmpty, "Unloaded failed store with no pending changes can retire while hidden")

        PrivateProfileStorage.select(profile)
        let retryRoot = root.appendingPathComponent("blocked-recording")
        try Data("synthetic".utf8).write(to: retryRoot)
        let retryWriter = TranscriptionHistoryWriter(defaults: try defaults(), url: retryRoot.appendingPathComponent("history.sqlite3"), profile: profile)
        let retry = TranscriptionHistoryStore(writer: retryWriter, profile: profile,
            audioStore: .init(rootDirectory: profile.rootDirectory, profile: profile))
        do { try await retry.waitUntilLoaded(); preconditionFailure("Fixture must fail loading") } catch {}
        let output = try retry.admitRecordingWrite()
        PrivateProfileStorage.conceal(generation: UUID())
        retry.addEntry(id: output.entryID, rawText: "retry raw", processedText: "retry preserved",
            appName: "synthetic", windowTitle: "synthetic", admission: output)
        do { try await output.finish(); preconditionFailure("Broken storage must preserve admission for retry") }
        catch { checks += 1 }
        expect(retry.admittedRecordingWriteCount == 1, "Failed hidden output stays admitted and blocks transition")
        do { try await retry.prepareForProfileTransition(); preconditionFailure("Pending hidden output must block retirement") }
        catch AccountError.busy { checks += 1 }
        try FileManager.default.removeItem(at: retryRoot)
        try FileManager.default.createDirectory(at: retryRoot, withIntermediateDirectories: true)
        try await output.retryPersistence()
        expect(retry.admittedRecordingWriteCount == 0, "Exact retained output can retry while hidden")
        try await retry.prepareForProfileTransition()
        PrivateProfileStorage.select(profile)
        expect(try await retryWriter.load().map(\.processedText) == ["retry preserved"], "Retried payload stays recoverable in original storage")
    }
}

private nonisolated func syntheticPCM() -> DictationAudioSnapshot {
    .init(samples: [0.01, -0.01], sampleRate: 16_000, channels: 1)
}

private nonisolated final class ReadSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var signaled = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func signal() {
        lock.withLock {
            signaled = true
            let captured = waiters; waiters = []
            for waiter in captured { waiter.resume() }
        }
    }
    func wait() async {
        await withCheckedContinuation { continuation in
            lock.withLock { if signaled { continuation.resume() } else { waiters.append(continuation) } }
        }
    }
}

private nonisolated final class SignallingDefaults: UserDefaults, @unchecked Sendable {
    private let lock = NSLock()
    private let signal: ReadSignal
    private var bytes: Data?
    var legacyBytes: Data? {
        get { lock.withLock { bytes } }
        set { lock.withLock { bytes = newValue } }
    }
    init(bytes: Data, signal: ReadSignal) {
        self.bytes = bytes; self.signal = signal
        super.init(suiteName: nil)!
    }
    override func object(forKey key: String) -> Any? {
        guard key == "TranscriptionHistoryEntries" else { return nil }
        let captured = legacyBytes
        signal.signal()
        return captured
    }
    override func data(forKey key: String) -> Data? { object(forKey: key) as? Data }
    override func set(_ value: Any?, forKey key: String) {
        if key == "TranscriptionHistoryEntries" { legacyBytes = value as? Data }
    }
    override func removeObject(forKey key: String) { set(nil, forKey: key) }
}

private nonisolated final class OnceFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var claimed = false
    func claim() -> Bool { lock.withLock { if claimed { return false }; claimed = true; return true } }
}
private nonisolated final class ConcealingDefaults: UserDefaults, @unchecked Sendable {
    private let profile: PrivateProfileSnapshot
    private let bytes: Data
    init(profile: PrivateProfileSnapshot, bytes: Data) {
        self.profile = profile; self.bytes = bytes
        super.init(suiteName: nil)!
    }
    override func data(forKey key: String) -> Data? {
        PrivateProfileStorage.conceal(generation: UUID())
        return nil
    }
}
