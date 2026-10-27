import Foundation

extension AdmittedHistoryWritesTests {
    static func testDirectCaptureOwner(root: URL, profile: PrivateProfileSnapshot) async throws {
        PrivateProfileStorage.select(profile)
        let writer = TranscriptionHistoryWriter(defaults: try defaults(),
            url: root.appendingPathComponent("direct-capture.sqlite3"), profile: profile)
        let history = TranscriptionHistoryStore(writer: writer, profile: profile,
            audioStore: DictationAudioHistoryStore(rootDirectory: root, profile: profile))
        try await history.waitUntilLoaded()
        let asr = ASRService()
        asr.audio = DictationAudioSnapshot(samples: [0.01, -0.01], sampleRate: 16_000, channels: 1)
        let startGate = DirectCaptureSignal(); asr.startGate = startGate
        let capture = try PrivateDirectDictationCapture(asr: asr, savesHistory: true,
            savesAudio: true, transcriptionModel: "synthetic", history: history)
        expect(PrivateProfileService.shared.hasRetainedCaptureStopHandler,
            "Direct record button owns root Stop before the first await")
        do {
            _ = try PrivateDirectDictationCapture(asr: ASRService(), savesHistory: true,
                savesAudio: true, transcriptionModel: "synthetic", history: history)
            preconditionFailure("A pending owner must not be overwritten")
        } catch { checks += 1 }
        expect(history.admittedRecordingWriteCount == 1, "Rejected competing start leaks no write admission")
        let start = Task { await capture.start() }
        while asr.starts == 0 { await Task.yield() }
        PrivateProfileStorage.conceal(generation: UUID())
        expect(asr.stops == 0, "Concealment does not stop an admitted recording")
        let rootStop = Task { await PrivateProfileService.shared.requestCaptureStop() }
        let viewStop = Task { await capture.stop() }
        await Task.yield()
        expect(asr.stops == 0, "Root Stop joins pending start before its single finalization")
        startGate.signal()
        expect(await start.value == .started, "Original admitted start finishes without retargeting")
        await rootStop.value
        expect(await viewStop.value == asr.text, "Concurrent view Stop joins the root result")
        expect(asr.stops == 1 && capture.isFinished, "Concurrent stops run ASR finalization once")
        expect(!capture.isVisible && history.entries.isEmpty, "Concealed text cannot repopulate private presentation")
        expect(!PrivateProfileService.shared.hasRetainedCaptureStopHandler,
            "Stop callback releases only after admitted audio and history finish")
        expect(history.admittedRecordingWriteCount == 0, "Direct output joins its original writer")
        PrivateProfileStorage.select(profile)
        let rows = try await writer.load()
        expect(rows.count == 1 && rows[0].rawText == asr.text && rows[0].audio != nil,
            "Hidden direct input and audio persist under the original writer")

        let emptyASR = ASRService(); emptyASR.text = ""
        emptyASR.audio = DictationAudioSnapshot(samples: [0.125, -0.125], sampleRate: 16_000, channels: 1)
        let empty = try PrivateDirectDictationCapture(asr: emptyASR, savesHistory: true,
            savesAudio: true, transcriptionModel: "synthetic", history: history)
        _ = await empty.start()
        PrivateProfileStorage.conceal(generation: UUID())
        await PrivateProfileService.shared.requestCaptureStop()
        expect(empty.isFinished && history.admittedRecordingWriteCount == 0,
            "Concealed empty or failed direct ASR joins its approved audio-only recovery")
        PrivateProfileStorage.select(profile)
        let emptyRows = try await writer.load()
        expect(emptyRows.count == 2 && emptyRows.filter { $0.rawText.isEmpty && $0.processedText.isEmpty && $0.audio != nil }.count == 1,
            "Empty direct ASR retains original audio without inventing text")

        let visible = try PrivateDirectDictationCapture(asr: ASRService(), savesHistory: true,
            savesAudio: true, transcriptionModel: "synthetic", history: history)
        _ = await visible.start(); _ = await visible.stop()
        visible.acknowledgeVisibleResult(); await visible.complete()
        expect(try await writer.load().count == 2, "Visible direct commands keep their existing no-dictation-history behavior")

        let handoffASR = ASRService()
        let handoff = try PrivateDirectDictationCapture(asr: handoffASR, savesHistory: true,
            savesAudio: false, transcriptionModel: "synthetic", history: history)
        _ = await handoff.start(); _ = await handoff.stop()
        expect(!handoff.isFinished && history.admittedRecordingWriteCount == 1,
            "ASR return retains output until an explicit visible handoff")
        PrivateProfileStorage.conceal(generation: UUID())
        expect(!handoff.acknowledgeVisibleResult(), "Conceal wins a held visible-result handoff")
        await PrivateProfileService.shared.requestCaptureStop()
        PrivateProfileStorage.select(profile)
        expect(try await writer.load().count == 3,
            "Root Stop preserves input when logout follows ASR return before visible handoff")

        let trainingASR = ASRService()
        trainingASR.audio = DictationAudioSnapshot(samples: [0.01, -0.01], sampleRate: 16_000, channels: 1)
        let training = try PrivateDirectDictationCapture(asr: trainingASR, savesHistory: false,
            savesAudio: true, transcriptionModel: "synthetic", forDictionaryTraining: true,
            requiresPronunciation: false, captureDictionaryPronunciation: true, history: history)
        _ = await training.start()
        PrivateProfileStorage.conceal(generation: UUID())
        await PrivateProfileService.shared.requestCaptureStop()
        expect(trainingASR.trainingStarts == [true] && trainingASR.trainingStops == [true],
            "Training keeps the existing isolated ASR path")
        expect(!training.isVisible && training.output.admission == nil,
            "Hidden training respects the frozen history-disabled choice")
        PrivateProfileStorage.select(profile)
        expect(try await writer.load().count == 3, "Disabled hidden training creates no text or audio record")

        let fallbackASR = ASRService()
        let fallback = try PrivateDirectDictationCapture(asr: fallbackASR, savesHistory: true,
            savesAudio: false, transcriptionModel: "synthetic", history: history)
        _ = await fallback.start()
        let hotkey = DirectHotkeyStopHarness(asr: fallbackASR, capture: fallback)
        await hotkey.stopRecordingInternal()
        expect(fallback.isFinished && hotkey.fallbackCapture == nil && !PrivateProfileService.shared.hasRetainedCaptureStopHandler,
            "Production callback-less hotkey Stop joins and releases the retained capture owner")
        expect(history.admittedRecordingWriteCount == 0,
            "Normal fallback Stop releases its admitted history output")

        let failedASR = ASRService(); failedASR.outcome = .failed
        let failed = try PrivateDirectDictationCapture(asr: failedASR, savesHistory: true,
            savesAudio: true, transcriptionModel: "synthetic", history: history)
        expect(await failed.start() == .failed, "Failed direct capture reports its original result")
        expect(!PrivateProfileService.shared.hasRetainedCaptureStopHandler && history.admittedRecordingWriteCount == 0,
            "Failed start joins and releases its callback and unused output")
        try await history.prepareForProfileTransition()

        let blockedRoot = root.appendingPathComponent("direct-retry-audio")
        try Data("synthetic blocker".utf8).write(to: blockedRoot)
        let retryWriter = TranscriptionHistoryWriter(defaults: try defaults(),
            url: root.appendingPathComponent("direct-retry.sqlite3"), profile: profile)
        let retryHistory = TranscriptionHistoryStore(writer: retryWriter, profile: profile,
            audioStore: DictationAudioHistoryStore(rootDirectory: blockedRoot, profile: profile))
        try await retryHistory.waitUntilLoaded()
        let retryASR = ASRService(); retryASR.text = ""
        retryASR.audio = DictationAudioSnapshot(samples: [0.125, -0.125], sampleRate: 16_000, channels: 1)
        let retryCapture = try PrivateDirectDictationCapture(asr: retryASR, savesHistory: true,
            savesAudio: true, transcriptionModel: "synthetic", history: retryHistory)
        _ = await retryCapture.start()
        PrivateProfileStorage.conceal(generation: UUID())
        await PrivateProfileService.shared.requestCaptureStop()
        expect(!retryCapture.isFinished && PrivateProfileService.shared.hasRetainedCaptureStopHandler
            && retryHistory.admittedRecordingWriteCount == 1,
            "WAV failure keeps the original Stop owner and its single retained PCM payload")
        PrivateProfileStorage.select(profile)
        do {
            _ = try PrivateDirectDictationCapture(asr: ASRService(), savesHistory: true,
                savesAudio: true, transcriptionModel: "synthetic", history: retryHistory)
            preconditionFailure("A retained failed capture must reject another recording")
        } catch { checks += 1 }
        expect(retryHistory.admittedRecordingWriteCount == 1,
            "Rejected rerecording cannot accumulate retained failed PCM")
        PrivateProfileStorage.conceal(generation: UUID())
        try FileManager.default.removeItem(at: blockedRoot)
        await PrivateProfileService.shared.requestCaptureStop()
        expect(retryCapture.isFinished && !PrivateProfileService.shared.hasRetainedCaptureStopHandler
            && retryHistory.admittedRecordingWriteCount == 0,
            "Repeated explicit Stop retries the same PCM and releases ownership only after durability")
        PrivateProfileStorage.select(profile)
        let recoveredRows = try await retryWriter.load()
        expect(retryASR.stops == 1 && recoveredRows.count == 1 && recoveredRows[0].rawText.isEmpty
            && recoveredRows[0].audio != nil,
            "Explicit recovery retries no hardware and creates one audio-only original row")
        try await retryHistory.prepareForProfileTransition()
    }
}
