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

        let visible = try PrivateDirectDictationCapture(asr: ASRService(), savesHistory: true,
            savesAudio: true, transcriptionModel: "synthetic", history: history)
        _ = await visible.start(); _ = await visible.stop()
        visible.acknowledgeVisibleResult(); await visible.complete()
        expect(try await writer.load().count == 1, "Visible direct commands keep their existing no-dictation-history behavior")

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
        expect(try await writer.load().count == 2,
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
        expect(try await writer.load().count == 2, "Disabled hidden training creates no text or audio record")

        let failedASR = ASRService(); failedASR.outcome = .failed
        let failed = try PrivateDirectDictationCapture(asr: failedASR, savesHistory: true,
            savesAudio: true, transcriptionModel: "synthetic", history: history)
        expect(await failed.start() == .failed, "Failed direct capture reports its original result")
        expect(!PrivateProfileService.shared.hasRetainedCaptureStopHandler && history.admittedRecordingWriteCount == 0,
            "Failed start joins and releases its callback and unused output")
        try await history.prepareForProfileTransition()
    }
}
