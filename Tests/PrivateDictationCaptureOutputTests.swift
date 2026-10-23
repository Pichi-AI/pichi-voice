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
