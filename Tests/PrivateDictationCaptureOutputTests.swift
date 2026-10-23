import Foundation

extension AdmittedHistoryWritesTests {
    static func testCaptureOutputOwner(root: URL, profile: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profile)
        let writer = TranscriptionHistoryWriter(defaults: try defaults(),
            url: root.appendingPathComponent("capture-output.sqlite3"), profile: profile)
        let history = TranscriptionHistoryStore(writer: writer, profile: profile,
            audioStore: DictationAudioHistoryStore(rootDirectory: root, profile: profile))
        try await history.waitUntilLoaded()
        let output = try PrivateDictationCaptureOutput(id: UUID(), savesHistory: true,
            savesAudio: true, transcriptionModel: "synthetic", history: history)
        expect(output.isVisible && output.admission != nil, "Capture owns its output before conceal")
        expect(history.admittedRecordingWriteCount == 1, "Controller admission keeps local durability busy")
        PrivateProfileStorage.conceal(generation: UUID())
        expect(!output.isVisible, "Conceal immediately fences external output")
        let timestamp = Date(timeIntervalSince1970: 200)
        history.addEntry(timestamp: timestamp, rawText: "retained capture", processedText: "retained capture",
            appName: "synthetic", windowTitle: "", admission: output.admission)
        let snapshot = DictationAudioSnapshot(samples: [Float](repeating: 0.01, count: 1600),
            sampleRate: 16000, channels: 1)
        output.saveAudio(snapshot, timestamp: timestamp, model: output.transcriptionModel)
        await output.finish()
        expect(history.admittedRecordingWriteCount == 0, "Controller joins audio, metadata and database completion")
        expect(history.entries.isEmpty, "Hidden completion cannot republish private history")
        PrivateProfileStorage.select(profile)
        let rows = try await writer.load()
        expect(rows.count == 1 && rows[0].processedText == "retained capture", "Capture output stays in its frozen source")
        expect(rows[0].audio != nil, "Reserved audio is attached before controller completion")
        let disabled = try PrivateDictationCaptureOutput(id: UUID(), savesHistory: false,
            savesAudio: true, transcriptionModel: "synthetic", history: history)
        expect(disabled.admission == nil && !disabled.savesAudio, "Capture privacy choice disables text and audio together")
        disabled.saveAudio(snapshot, timestamp: timestamp, model: "synthetic")
        await disabled.finish()
        expect(try await writer.load().count == 1, "Disabled capture creates no local output")
        try await history.prepareForProfileTransition()
    }
}

extension AdmittedHistoryWritesTests {
    static func testAudioOnlyRecovery(root: URL, profile: PrivateProfileSnapshot) async throws {
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(),
            legacyRootDirectory: root.appendingPathComponent("audio-only-guest"))
        for owner in [profile, guest] {
            PrivateProfileStorage.select(owner)
            let fixtureRoot = owner.rootDirectory.appendingPathComponent("audio-only-fixture")
            let disk = fixtureRoot.appendingPathComponent("history.sqlite3")
            let writer = TranscriptionHistoryWriter(defaults: try defaults(), url: disk, profile: owner)
            let audioStore = DictationAudioHistoryStore(rootDirectory: fixtureRoot, profile: owner)
            let history = TranscriptionHistoryStore(writer: writer, profile: owner, audioStore: audioStore)
            try await history.waitUntilLoaded()
            let pcm = DictationAudioSnapshot(samples: [0.125, -0.125], sampleRate: 16_000, channels: 1)
            let timestamp = Date(timeIntervalSince1970: 300)
            let output = try PrivateDictationCaptureOutput(id: UUID(), savesHistory: true,
                savesAudio: true, transcriptionModel: "synthetic", history: history)
            PrivateProfileStorage.conceal(generation: UUID())
            output.preserveLocalResult(text: " \n ", audio: pcm, timestamp: timestamp)
            await output.finish()
            expect(history.entries.isEmpty && history.admittedRecordingWriteCount == 0,
                "Empty concealed capture joins durable output without publishing private rows")
            PrivateProfileStorage.select(owner)
            let rows = try await writer.load()
            expect(rows.count == 1 && rows[0].rawText.isEmpty && rows[0].processedText.isEmpty
                && rows[0].characterCount == 0 && rows[0].clipboardText == nil && !rows[0].wasAIProcessed,
                "Audio-only recovery keeps real empty text and invents no transcript")
            expect(rows[0].timestamp == timestamp && rows[0].audio != nil,
                "Validated original audio remains reachable through existing history metadata")
            let wav = fixtureRoot.appendingPathComponent("DictationAudioHistory").appendingPathComponent(rows[0].audio!.fileName)
            expect(try Data(contentsOf: wav).count == rows[0].audio!.byteCount,
                "Recovery row references its exact reserved original WAV")

            for (savesHistory, savesAudio, snapshot) in [
                (false, true, Optional(pcm)), (true, false, Optional(pcm)),
                (true, true, Optional<DictationAudioSnapshot>.none),
                (true, true, Optional(DictationAudioSnapshot(samples: [], sampleRate: 16_000, channels: 1))),
                (true, true, Optional(DictationAudioSnapshot(samples: [0.1], sampleRate: 0, channels: 1))),
                (true, true, Optional(DictationAudioSnapshot(samples: [0.1], sampleRate: 16_000, channels: 0)))
            ] {
                let disabled = try PrivateDictationCaptureOutput(id: UUID(), savesHistory: savesHistory,
                    savesAudio: savesAudio, transcriptionModel: "synthetic", history: history)
                PrivateProfileStorage.conceal(generation: UUID())
                disabled.preserveLocalResult(text: "", audio: snapshot)
                await disabled.finish()
                PrivateProfileStorage.select(owner)
                expect(try await writer.load().count == 1,
                    "Disabled or missing original audio creates neither invented text nor an empty placeholder")
            }

            // An actual reserved WAV has completed, but its metadata handoff is deliberately held.
            let held = try history.admitRecordingWrite()
            let heldAudio = try held.admitAudioSave(timestamp: timestamp)
            let metadata = try heldAudio.save(snapshot: pcm, model: "synthetic")
            PrivateProfileStorage.conceal(generation: UUID())
            let finishingEntered = DirectCaptureSignal()
            var finished = false
            let finishing = Task { finishingEntered.signal(); try await held.finish(); finished = true }
            await finishingEntered.wait()
            expect(!finished && history.admittedRecordingWriteCount == 1,
                "Audio-only finish joins a completed WAV whose exact metadata handoff is still pending")
            try held.attachAudio(metadata, from: heldAudio, audioRecoveryTimestamp: timestamp)
            try await finishing.value
            expect(finished && history.admittedRecordingWriteCount == 0,
                "Audio-only finish releases only after exact metadata and database durability")
            PrivateProfileStorage.select(owner)
            expect(try await writer.load().count == 2, "Joined audio-only row persists in the original account or guest")

            let invalid = try history.admitRecordingWrite()
            let invalidAudio = try invalid.admitAudioSave(timestamp: timestamp)
            let validMetadata = try invalidAudio.save(snapshot: pcm, model: "synthetic")
            let forged = DictationAudioMetadata(fileName: validMetadata.fileName,
                durationMilliseconds: validMetadata.durationMilliseconds, byteCount: validMetadata.byteCount + 1,
                sampleRate: validMetadata.sampleRate, channels: validMetadata.channels, model: validMetadata.model)
            do {
                try invalid.attachAudio(forged, from: invalidAudio, audioRecoveryTimestamp: timestamp)
                preconditionFailure("Unvalidated metadata cannot create audio-only recovery")
            } catch { checks += 1 }
            try await invalid.finish()
            expect(try await writer.load().count == 2 && !audioStore.audioFileExists(fileName: invalidAudio.fileName),
                "Rejected metadata leaves no empty row and removes only its own unclaimed WAV")

            let revoked = try history.admitRecordingWrite()
            let revokedAudio = try revoked.admitAudioSave(timestamp: timestamp)
            let revokedMetadata = try revokedAudio.save(snapshot: pcm, model: "synthetic")
            history.deleteEntry(id: revoked.entryID)
            do {
                try revoked.attachAudio(revokedMetadata, from: revokedAudio, audioRecoveryTimestamp: timestamp)
                preconditionFailure("Revoked metadata cannot create recovery")
            } catch { checks += 1 }
            try await revoked.finish()
            expect(try await writer.load().count == 2, "Revoked audio-only admission cannot resurrect history")

            let foreign = try history.admitRecordingWrite()
            let foreignAudio = try foreign.admitAudioSave(timestamp: timestamp)
            let foreignMetadata = try foreignAudio.save(snapshot: pcm, model: "synthetic")
            let foreignGeneration = UUID()
            let other = try PrivateProfileStorage.proposed(context: AccountContext(identity: .init(
                issuer: "https://synthetic.invalid", subject: UUID().uuidString, internalUserID: "B"),
                organizationID: nil, workspaceID: nil, generation: foreignGeneration),
                generation: foreignGeneration, legacyRootDirectory: fixtureRoot.appendingPathComponent("foreign"))
            PrivateProfileStorage.select(other)
            do {
                try foreign.attachAudio(foreignMetadata, from: foreignAudio, audioRecoveryTimestamp: timestamp)
                preconditionFailure("Foreign owner cannot create audio-only recovery")
            } catch { checks += 1 }
            try await foreign.finish()
            expect(!FileManager.default.fileExists(atPath: other.rootDirectory.path),
                "Foreign recovery never creates or writes the next account root")
            PrivateProfileStorage.select(owner)
            expect(try await writer.load().count == 2, "Foreign completion cannot mutate original history")

            let failed = try PrivateDictationCaptureOutput(id: UUID(), savesHistory: true,
                savesAudio: true, transcriptionModel: "synthetic", history: history)
            try sql(disk, "CREATE TRIGGER reject_recovery BEFORE INSERT ON history BEGIN SELECT RAISE(FAIL, 'synthetic recovery failure'); END")
            history.addEntry(rawText: "visible before SQLite failure", processedText: "visible before SQLite failure",
                appName: "", windowTitle: "", admission: failed.admission)
            PrivateProfileStorage.conceal(generation: UUID())
            failed.preserveLocalResult(text: "", audio: pcm, timestamp: timestamp)
            await failed.finish()
            expect(history.admittedRecordingWriteCount == 1,
                "Failed audio-only durability retains the original payload and blocks profile retirement")
            try sql(disk, "DROP TRIGGER reject_recovery")
            try await history.retryAdmittedRecordingWrites()
            expect(history.admittedRecordingWriteCount == 0, "Hidden audio-only durability can retry the original writer")
            PrivateProfileStorage.select(owner)
            let retryRows = try await writer.load()
            expect(retryRows.count == 3 && retryRows.first(where: { $0.id == failed.admission!.entryID })?.audio != nil,
                "Hidden SQLite retry preserves newly attached metadata over an older visible text row")
            try await history.prepareForProfileTransition()

            let blockedRoot = fixtureRoot.appendingPathComponent("blocked-audio")
            try Data("synthetic path blocker".utf8).write(to: blockedRoot)
            let failedWriter = TranscriptionHistoryWriter(defaults: try defaults(),
                url: fixtureRoot.appendingPathComponent("failed-audio.sqlite3"), profile: owner)
            let failedHistory = TranscriptionHistoryStore(writer: failedWriter, profile: owner,
                audioStore: DictationAudioHistoryStore(rootDirectory: blockedRoot, profile: owner))
            try await failedHistory.waitUntilLoaded()
            let failedWAV = try PrivateDictationCaptureOutput(id: UUID(), savesHistory: true,
                savesAudio: true, transcriptionModel: "synthetic", history: failedHistory)
            failedHistory.addEntry(rawText: "original text", processedText: "original text",
                appName: "", windowTitle: "", admission: failedWAV.admission)
            failedHistory.toggleStar(id: failedWAV.admission!.entryID)
            PrivateProfileStorage.conceal(generation: UUID())
            failedWAV.preserveLocalResult(text: "", audio: pcm, timestamp: timestamp)
            await failedWAV.finish()
            expect(failedHistory.admittedRecordingWriteCount == 1,
                "WAV failure retains approved original PCM on its existing write admission")
            PrivateProfileStorage.select(owner)
            let withoutWAV = try await failedWriter.load()
            expect(withoutWAV.count == 1 && withoutWAV[0].audio == nil,
                "Failed WAV metadata creates no invented empty row or forged audio reference")
            PrivateProfileStorage.conceal(generation: UUID())
            try FileManager.default.removeItem(at: blockedRoot)
            try await failedHistory.retryAdmittedRecordingWrites()
            expect(failedHistory.admittedRecordingWriteCount == 0,
                "Repair retries the original admitted PCM without granting hidden read access")
            PrivateProfileStorage.select(owner)
            let repaired = try await failedWriter.load()
            expect(repaired.count == 1 && repaired[0].audio != nil && repaired[0].rawText == "original text"
                && repaired[0].isStarred,
                "Hidden WAV retry preserves original text, newly attached audio and a newer star")

            let audioDirectory = blockedRoot.appendingPathComponent("DictationAudioHistory")
            let existingFile = audioDirectory.appendingPathComponent(repaired[0].audio!.fileName)
            let preservedAudio = try Data(contentsOf: existingFile)
            let temporaryFile = blockedRoot.appendingPathComponent("preserved-existing.wav")
            try FileManager.default.moveItem(at: existingFile, to: temporaryFile)
            try FileManager.default.removeItem(at: audioDirectory)
            try Data("synthetic blocker".utf8).write(to: audioDirectory)
            let removed = try PrivateDictationCaptureOutput(id: UUID(), savesHistory: true,
                savesAudio: true, transcriptionModel: "synthetic", history: failedHistory)
            removed.preserveLocalResult(text: "", audio: pcm)
            await removed.finish()
            expect(failedHistory.admittedRecordingWriteCount == 1, "Second WAV failure remains admitted before explicit audio deletion")
            _ = failedHistory.deleteAllSavedAudio()
            try await failedHistory.retryAdmittedRecordingWrites()
            expect(failedHistory.admittedRecordingWriteCount == 0,
                "Explicit saved-audio deletion releases the exact pending PCM retry without resurrecting audio")
            expect(try Data(contentsOf: temporaryFile) == preservedAudio,
                "Deleting a failed reservation never deletes another preserved original fixture")
            try await failedHistory.prepareForProfileTransition()
        }
    }
}
