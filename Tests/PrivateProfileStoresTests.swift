import Foundation

@main @MainActor struct PrivateProfileStoresTests {
    static var checks = 0
    static func expect(_ condition: Bool, _ message: String) {
        checks += 1
        precondition(condition, message)
    }

    static func main() async throws {
        let original = PrivateProfileStorage.current
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("synthetic-profile-stores-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        let fixtureID = UUID().uuidString
        func account(_ subject: String) throws -> PrivateProfileSnapshot {
            let subject = "synthetic-\(fixtureID)-\(subject)"
            let generation = UUID()
            let context = AccountContext(identity: .init(issuer: "https://synthetic.invalid", subject: subject,
                internalUserID: "user-\(subject)"), organizationID: "org", workspaceID: "workspace", generation: generation)
            return try PrivateProfileStorage.proposed(context: context, generation: generation, legacyRootDirectory: root)
        }
        let a = try account("A"), b = try account("B")
        var suites = [a, b].map { AppBrand.storageNamespace + ".private-profile." + $0.id }
        func defaults(_ profile: PrivateProfileSnapshot) -> UserDefaults {
            let suite = "synthetic.profile-stores.\(UUID())"
            suites.append(suite)
            return UserDefaults(suiteName: suite)!
        }
        defer {
            for suite in suites {
                let defaults = UserDefaults(suiteName: suite)!
                defaults.removePersistentDomain(forName: suite)
                precondition(defaults.synchronize(), "Synthetic preference cleanup must reach disk")
                precondition(defaults.persistentDomain(forName: suite)?.isEmpty != false)
            }
            PrivateProfileStorage.select(original)
            PrivateProfileStorage.clearStoreCaches()
            PrivateProfileObjectCache.removeAll()
            try? FileManager.default.removeItem(at: root)
        }
        PrivateProfileStorage.select(guest)
        let guestDefaults = defaults(guest)
        let guestWriter = TranscriptionHistoryWriter(defaults: guestDefaults,
            url: root.appendingPathComponent("TranscriptionHistory.sqlite3"), profile: guest)
        let guestHistory = TranscriptionHistoryStore(writer: guestWriter, profile: guest)
        try await guestHistory.waitUntilLoaded()
        guestHistory.addEntry(rawText: "guest text", processedText: "guest private", appName: "test", windowTitle: "test")
        await guestHistory.finishPendingWrites()
        let legacyDatabase = try Data(contentsOf: root.appendingPathComponent("TranscriptionHistory.sqlite3"))

        let guestVocabulary = ParakeetVocabularyStore.shared
        try guestVocabulary.saveUserBoostTerms([.init(text: "guest secret", weight: nil)])
        let guestDictionaryURL = root.appendingPathComponent("parakeet_custom_vocabulary.json")
        let guestDictionaryBytes = try Data(contentsOf: guestDictionaryURL)
        let guestPronunciation = PronunciationDictionaryStore.shared
        let entryID = UUID()
        let capture = PronunciationEnrollmentCapture(values: [1, 0], sourceFrameCount: 2, modelKey: "synthetic")
        try await guestPronunciation.upsert(dictionaryEntryID: entryID, label: "guest label", modelKey: "synthetic", enrollments: [capture])
        let guestPronunciationURL = root.appendingPathComponent("pronunciation-dictionary-v1.json")
        let guestPronunciationBytes = try Data(contentsOf: guestPronunciationURL)
        let negatives = DictionaryNegativeExampleStore(url: root.appendingPathComponent("dictionary-negative-examples-v1.plist"),
            profile: guest, collectionEnabled: { true })
        let negativeFrames = DictionaryMatchFrames(hiddenSize: 2, values: [1, 0, 1, 0])
        let negative = DictionaryNegativeCorrection(evidence: .init(id: UUID(), entryID: entryID, label: "guest label",
            profileKey: "synthetic-profile", modelKey: "synthetic", sourceWordRange: 0..<1, frames: negativeFrames),
            correctedText: "synthetic correction", expiresAt: Date().addingTimeInterval(60))
        try await negatives.save(negative, expectedRevision: negatives.revision())
        let guestNegativeBytes = try Data(contentsOf: root.appendingPathComponent("dictionary-negative-examples-v1.plist"))
        let guestNegativeFrames = await negatives.frames(entryID: entryID, profileKey: "synthetic-profile", modelKey: "synthetic")
        expect(guestNegativeFrames == [negativeFrames], "Guest negative evidence round trips")

        let guestChat = ChatHistoryStore(defaults: guestDefaults, profile: guest)
        guestChat.updateCurrentChat(messages: [.init(role: .user, content: "guest conversation")])
        let guestFile = FileTranscriptionHistoryStore(defaults: guestDefaults, profile: guest)
        guestFile.addEntry(result("guest transcript"))
        let guestPolicy = AutomaticDictionarySuggestionPolicy(defaults: guestDefaults, profile: guest)
        let candidate = AutomaticDictionaryCorrectionCandidate(heardText: "guest heard", correctedText: "guest corrected")
        expect(!guestPolicy.shouldShow(candidate), "Guest first occurrence remains below threshold")
        expect(guestPolicy.shouldShow(candidate), "Guest policy accumulates only guest corrections")

        let guestAudio = DictationAudioHistoryStore.shared
        let audio = try guestAudio.save(snapshot: .init(samples: [0.01, -0.01], sampleRate: 16_000, channels: 1),
            entryID: UUID(), timestamp: Date(), model: "synthetic")
        let audioBytes = try Data(contentsOf: root.appendingPathComponent("DictationAudioHistory/\(audio.fileName)"))
        let joiningAudio = Task { await guestAudio.prepareForProfileTransition() }
        await Task.yield()
        guestAudio.completePendingSave(fileName: audio.fileName)
        await joiningAudio.value
        expect(guestAudio.audioFileExists(fileName: audio.fileName) == false, "Retired audio handles hide private files")
        let blockedParent = root.appendingPathComponent("synthetic-not-a-directory")
        try Data("synthetic failure fixture".utf8).write(to: blockedParent)
        let failedHistory = TranscriptionHistoryStore(writer: TranscriptionHistoryWriter(defaults: guestDefaults,
            url: blockedParent.appendingPathComponent("history.sqlite3"), profile: guest), profile: guest)
        do { try await failedHistory.waitUntilLoaded(); preconditionFailure("Blocked storage must fail loading") } catch {}
        failedHistory.addEntry(rawText: "unsaved", processedText: "unsaved", appName: "test", windowTitle: "test")
        do {
            try await failedHistory.prepareForProfileTransition()
            preconditionFailure("Unsaved data must reject a transition")
        } catch AccountError.busy { checks += 1 }
        expect(failedHistory.entries.map(\.processedText) == ["unsaved"], "Rejected transition preserves pending history")
        expect(guestAudio.resumeAfterFailedProfileTransition(), "Rejected transition reopens the current audio source")
        let resumed = try guestAudio.save(snapshot: .init(samples: [0.02], sampleRate: 16_000, channels: 1),
            entryID: UUID(), timestamp: Date(), model: "synthetic")
        guestAudio.completePendingSave(fileName: resumed.fileName)
        expect(guestAudio.audioFileExists(fileName: resumed.fileName), "Audio works after persistence rejection rollback")
        await guestAudio.prepareForProfileTransition()

        let guestOwner = MeetingOwnerVoiceProfileStore()
        let owner = MeetingOwnerVoiceProfileSnapshot(metadata: .init(generation: UUID(), enrolledAt: Date()),
            encoderFingerprint: MeetingOwnerVoiceProfileStore.encoderFingerprint,
            embeddings: [[Float](repeating: 1, count: 256), [Float](repeating: 1, count: 256)])
        try guestOwner.save(owner)
        let ownerBytes = try Data(contentsOf: guestOwner.fileURL)
        let ownerService = MeetingOwnerVoiceProfileService.shared
        await ownerService.prepareForProfileTransition()
        // A cancellation-ignoring preparation dependency must still be joined before retirement.
        let gate = SyntheticPreparationGate()
        let preparingService = MeetingOwnerVoiceProfileService(store: guestOwner,
            prepareResources: { await gate.waitForRelease() }, encode: { _ in fatalError("Cancelled preparation must not infer") })
        let preparing = Task {
            try await preparingService.prepare(samples: (0..<100_000).map { $0.isMultiple(of: 2) ? 0.05 : -0.05 })
        }
        await gate.waitUntilEntered()
        preparing.cancel()
        let joined = SyntheticJoinFlag()
        let retirement = Task { await preparingService.prepareForProfileTransition(); await joined.mark() }
        var retirementEntered = false
        for _ in 0..<1000 {
            do { _ = try await preparingService.metadata() }
            catch MeetingOwnerVoiceProfileError.staleDraft { retirementEntered = true; break }
            await Task.yield()
        }
        expect(retirementEntered, "OwnerVoice retirement has closed admission before checking its join")
        expect(!(await joined.value), "OwnerVoice retirement waits for the admitted preparation")
        await gate.release()
        _ = await preparing.result
        await retirement.value
        expect(await joined.value, "OwnerVoice retirement finishes only after preparation exits")
        try await guestHistory.prepareForProfileTransition()
        guestChat.prepareForProfileTransition()
        try await guestFile.prepareForProfileTransition()
        guestPolicy.prepareForProfileTransition()
        await guestPronunciation.prepareForProfileTransition()
        await negatives.prepareForProfileTransition()
        PrivateProfileStorage.select(a)
        PrivateProfileStorage.clearStoreCaches()
        PrivateProfileObjectCache.removeAll()

        expect(guestHistory.entries.isEmpty && guestChat.sessions.isEmpty && guestFile.entries.isEmpty,
            "Transition clears all retained history projections")
        expect(guestChat.currentChatID == nil && guestFile.selectedEntryID == nil, "Transition clears selections")
        expect(!guestAudio.resumeAfterFailedProfileTransition(), "A former profile cannot reopen its audio source")
        expect((try? guestVocabulary.loadUserBoostTerms()) == nil, "Stale vocabulary cannot read guest data")
        expect((try? guestOwner.load()) == nil, "Stale owner signature cannot load guest data")
        let stalePronunciations = await guestPronunciation.allProfiles()
        expect(stalePronunciations.isEmpty, "Retired pronunciation actor returns no private profiles")
        let retiredNegatives = await negatives.frames(entryID: entryID, profileKey: "synthetic-profile", modelKey: "synthetic")
        expect(retiredNegatives.isEmpty, "Retired negative evidence cannot be read")
        do {
            try await negatives.clear()
            preconditionFailure("Retired negative actor must reject deletion")
        } catch PronunciationDictionaryStoreError.staleEvidence { checks += 1 }
        guestHistory.addEntry(rawText: "foreign", processedText: "foreign", appName: "test", windowTitle: "test")
        guestChat.saveChat(ChatSession(title: "foreign"))
        expect(guestHistory.entries.isEmpty && guestChat.sessions.isEmpty, "Stale handles reject writes")
        let aChat = ChatHistoryStore.shared
        let aFile = FileTranscriptionHistoryStore.shared
        let aPolicy = AutomaticDictionarySuggestionPolicy.shared
        let aHistory = TranscriptionHistoryStore.shared
        try await aHistory.waitUntilLoaded()
        expect(aHistory.entries.isEmpty, "A SQLite factory starts empty without guest migration")
        aHistory.addEntry(rawText: "A private", processedText: "A private", appName: "test", windowTitle: "test")
        await aHistory.finishPendingWrites()
        expect(aChat.sessions.allSatisfy(\.messages.isEmpty) && aFile.entries.isEmpty, "A never inherits guest history")
        expect(!aPolicy.shouldShow(candidate), "A never inherits guest correction policy")
        let aPronunciation = PronunciationDictionaryStore.shared
        let emptyAProfiles = await aPronunciation.allProfiles()
        expect(emptyAProfiles.isEmpty, "A never inherits guest pronunciation")
        let aNegatives = await DictionaryNegativeExampleStore.shared.frames(entryID: entryID, profileKey: "synthetic-profile", modelKey: "synthetic")
        expect(aNegatives.isEmpty, "A never inherits guest negative evidence")
        expect(try MeetingOwnerVoiceProfileStore().load() == nil, "A never inherits guest OwnerVoice")
        expect(try await ParakeetVocabularyStore.readSearchTerms().isEmpty, "Search uses A root without copying guest vocabulary")
        try ParakeetVocabularyStore.shared.saveUserBoostTerms([.init(text: "A secret", weight: nil)])
        expect(try await ParakeetVocabularyStore.readSearchTerms().map(\.text) == ["A secret"], "Search reads only active A vocabulary")
        aChat.updateCurrentChat(messages: [.init(role: .user, content: "A conversation")])
        aFile.addEntry(result("A transcript"))
        try await aHistory.prepareForProfileTransition()
        aChat.prepareForProfileTransition()
        try await aFile.prepareForProfileTransition()
        aPolicy.prepareForProfileTransition()
        await aPronunciation.prepareForProfileTransition()
        PrivateProfileStorage.select(b)
        PrivateProfileStorage.clearStoreCaches()
        PrivateProfileObjectCache.removeAll()
        expect(try await ParakeetVocabularyStore.readSearchTerms().isEmpty, "B search cannot see A vocabulary")
        let bHistory = TranscriptionHistoryStore.shared
        try await bHistory.waitUntilLoaded()
        expect(bHistory.entries.isEmpty, "B cannot read A SQLite history")
        expect(ChatHistoryStore.shared.sessions.allSatisfy(\.messages.isEmpty), "B cannot read A chat messages")
        expect(FileTranscriptionHistoryStore.shared.entries.isEmpty, "B cannot read A file transcripts")
        try await bHistory.prepareForProfileTransition()
        ChatHistoryStore.shared.prepareForProfileTransition()
        try await FileTranscriptionHistoryStore.shared.prepareForProfileTransition()
        let bDictionary = PronunciationDictionaryStore.shared
        try await bDictionary.upsert(dictionaryEntryID: UUID(), label: "B label", modelKey: "synthetic", enrollments: [capture])
        expect(try Data(contentsOf: guestDictionaryURL) == guestDictionaryBytes, "Guest vocabulary bytes stay unchanged")
        expect(try Data(contentsOf: guestPronunciationURL) == guestPronunciationBytes, "Account pronunciation cleanup never touches guest siblings")
        expect(try Data(contentsOf: guestOwner.fileURL) == ownerBytes, "Guest signature bytes stay unchanged")
        expect(try Data(contentsOf: root.appendingPathComponent("dictionary-negative-examples-v1.plist")) == guestNegativeBytes,
            "Guest negative evidence bytes stay unchanged")
        expect(try Data(contentsOf: root.appendingPathComponent("DictationAudioHistory/\(audio.fileName)")) == audioBytes,
            "Guest original audio survives profile transitions")
        expect(try Data(contentsOf: root.appendingPathComponent("TranscriptionHistory.sqlite3")) == legacyDatabase,
            "Guest SQLite database survives account activity")
        // ABA: an old handle must remain invalid even if the same stable owner is selected again.
        let aAgain = try account("A")
        expect(aAgain.id == a.id && aAgain.generation != a.generation, "Stable profile identity has a new admission generation")
        PrivateProfileStorage.select(aAgain)
        expect(!PrivateProfileStorage.isReadable(a), "Generation rejects a stale same-account source")
        expect(aChat.currentSession == nil, "A cached presentation never revives across generations")
        PrivateProfileStorage.clearStoreCaches()
        PrivateProfileObjectCache.removeAll()
        expect(ChatHistoryStore.shared.currentSession?.messages.map(\.content) == ["A conversation"],
            "Returning A recovers only A chat history from real profile defaults")
        expect(FileTranscriptionHistoryStore.shared.entries.map(\.text) == ["A transcript"],
            "Returning A recovers only A file history from real profile defaults")
        let returnedHistory = TranscriptionHistoryStore.shared
        try await returnedHistory.waitUntilLoaded()
        expect(returnedHistory.entries.map(\.processedText) == ["A private"], "Returning A recovers only A SQLite history")
        try await returnedHistory.prepareForProfileTransition()
        ChatHistoryStore.shared.prepareForProfileTransition()
        try await FileTranscriptionHistoryStore.shared.prepareForProfileTransition()
        PrivateProfileStorage.select(guest)
        let restoredGuest = try await TranscriptionHistoryWriter(defaults: guestDefaults,
            url: root.appendingPathComponent("TranscriptionHistory.sqlite3"), profile: guest).load()
        expect(restoredGuest.map(\.processedText) == ["guest private"], "Guest history remains recoverable in its original namespace")
        print("PASS: \(checks) synthetic private store isolation, guest preservation and stale-generation assertions")
    }

    static func result(_ text: String) -> TranscriptionResult {
        .init(id: UUID(), text: text, confidence: 1, duration: 1, processingTime: 1, fileName: "synthetic.wav",
            timestamp: Date(), speakerSegments: [], speakerLabelingNotice: nil, speakerLabelingGaps: [])
    }
}

private actor SyntheticPreparationGate {
    private var entered = false
    private var entryWaiters: [CheckedContinuation<Void, Never>] = []
    private var releaseWaiter: CheckedContinuation<Void, Never>?
    func waitForRelease() async {
        self.entered = true
        for waiter in self.entryWaiters { waiter.resume() }
        self.entryWaiters = []
        await withCheckedContinuation { self.releaseWaiter = $0 }
    }
    func waitUntilEntered() async {
        if !self.entered { await withCheckedContinuation { self.entryWaiters.append($0) } }
    }
    func release() { self.releaseWaiter?.resume(); self.releaseWaiter = nil }
}
private actor SyntheticJoinFlag {
    private(set) var value = false
    func mark() { self.value = true }
}
