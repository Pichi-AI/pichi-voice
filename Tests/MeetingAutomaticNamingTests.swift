import Foundation

extension MeetingSessionStoreCheckpointTests {
    /// Real session codecs, reading projection, filesystem store and synthetic encryption key.
    /// This fixture performs no speech inference, audio access, network access or account lookup.
    static func checkAutomaticNaming(root: URL, check: (Bool, String) -> Void) async throws {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var original = MeetingSession(configuration: .init(mode: .inRoom, title: "Meeting",
            languageCode: "ru", microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"),
            timestampDefaultTitle: true), startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        original.state = .completed
        original.endedAt = original.startedAt.addingTimeInterval(1_800)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])
        original.audioTracks = [track]
        let people = (0..<2).map { index in
            MeetingSessionSpeaker(id: UUID(), displayName: "Synthetic \(index)", diarizationClusterID: "\(index)",
                trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        }
        original.speakers = people
        original.transcriptSegments = (0..<10).map { index in
            MeetingTranscriptSegment(id: UUID(), start: .init(value: Int64(index * 100), timescale: 1),
                end: .init(value: Int64(index * 100 + 90), timescale: 1), sourceTrackID: track.id,
                speakerID: people[index % 2].id,
                text: "Слушай, согласен, давай обсудим вопрос. Почему возникает этот вопрос? Подскажи, как проверить ответ. "
                    + String(repeating: "Это синтетический разговор для проверки сохранения названия. ", count: 3),
                revision: 0, status: .final, overlap: .none, completeness: .complete, attributionState: .assigned)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--write-title-fixture"),
           CommandLine.arguments.indices.contains(index + 1) {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let fixtureEncoder = JSONEncoder()
            fixtureEncoder.dateEncodingStrategy = MeetingSessionDateCodec.encodingStrategy
            fixtureEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try fixtureEncoder.encode(original).write(to: url, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        let named = MeetingAutomaticNaming.applying(to: original)
        let russian = "Мы обсуждаем планы на следующий месяц. Нужно определить задачи и договориться о следующих шагах. Давайте сначала ответим на вопросы, затем выберем подходящий вариант. "
        let english = "We are discussing plans for the next month. We need to define the tasks and agree on the next steps. Let us answer the questions first, then choose the best option. "
        for (text, expected) in [
            (String(repeating: russian, count: 40), "ru"),
            (String(repeating: english, count: 40), "en"),
            (String(repeating: english, count: 8) + String(repeating: russian, count: 32), "ru"),
            (String(repeating: russian, count: 8) + String(repeating: english, count: 32), "en"),
            (String(repeating: russian + " API GPU SQL CRM GitHub PostgreSQL. ", count: 40), "ru"),
            (String(repeating: english, count: 100) + String(repeating: russian, count: 4_000), "ru")
        ] {
            let analysis = MeetingTitleLanguage.analyze(text)
            check(analysis.languageCode == expected, "Dominant transcript language follows distributed content, not interface, greeting or technical abbreviations")
            check(analysis.sampleCount <= MeetingTitleLanguage.maximumSamples
                  && analysis.analyzedScalars <= MeetingTitleLanguage.maximumSamples * MeetingTitleLanguage.maximumSampleScalars,
                  "Language identification retains a bounded set of distributed samples")
        }
        check(MeetingTitleLanguage.analyze("123 456").languageCode == "und",
              "Unrecognized language remains explicit instead of borrowing an interface preference")
        check(named.automaticTitle?.languageCode == "ru", "The generated artifact stores the dominant Russian transcript language")

        // This resource fixture exercises actual Foundation lookup with both caller languages.
        let bundleRoot = root.appendingPathComponent("title-language.bundle")
        for (language, value, neutral) in [("en", "Discussion of questions", "Audio recording"), ("ru", "Обсуждение вопросов", "Аудиозапись")] {
            let folder = bundleRoot.appendingPathComponent(language + ".lproj")
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            try "\"Discussion of questions\" = \"\(value)\";\n\"Audio recording\" = \"\(neutral)\";\n".write(to: folder.appendingPathComponent("Localizable.strings"), atomically: true, encoding: .utf8)
        }
        let info: [String: Any] = ["CFBundleIdentifier": "invalid.synthetic.title-language", "CFBundleDevelopmentRegion": "en", "CFBundleLocalizations": ["en", "ru"]]
        try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0).write(to: bundleRoot.appendingPathComponent("Info.plist"))
        let bundle = Bundle(path: bundleRoot.path)!
        var located = original
        located.location = .init(latitude: 37.3317, longitude: -122.0301, horizontalAccuracy: 12,
            capturedAt: original.startedAt, addresses: ["en": "1 Example Street, Example City",
                "ru": "ул. Примерная, 1, Примерск"])
        let locatedNamed = MeetingAutomaticNaming.applying(to: located)
        check(locatedNamed.automaticTitle == named.automaticTitle && locatedNamed.location == located.location,
              "Current-record location neither changes title ranking/language nor loses its saved evidence")
        check(locatedNamed.displayTitle(language: .english, bundle: bundle) == "Обсуждение вопросов"
              && locatedNamed.savedLocationLabel(language: .english) == "1 Example Street, Example City",
              "The Russian semantic title and separately localized saved place coexist under English UI")
        check(located.displayTitle(language: .english, bundle: bundle) == "In-room meeting"
              && located.savedLocationLabel(language: .russian) == "ул. Примерная, 1, Примерск",
              "A generic default title does not repeat the separate place label")
        check(original.savedLocationLabel(language: .english) == nil,
              "No saved location adds no place metadata and never inherits a previous recording")
        var missingPlace = located
        missingPlace.location?.addresses = ["en": "   "]
        check(missingPlace.savedLocationLabel(language: .russian) == nil
              && missingPlace.savedLocationLabel(language: .english) == nil,
              "Missing or blank address data never becomes a guessed or cross-language place")
        var concealedPlace = located
        concealedPlace.requiresEncryptedPersistence = true
        check(concealedPlace.isLocalContentConcealed && concealedPlace.savedLocationLabel(language: .english) == nil,
              "Concealed protected metadata cannot expose its saved place")
        concealedPlace.profileOwnership = .guest
        check(!concealedPlace.isLocalContentConcealed
              && concealedPlace.savedLocationLabel(language: .english) == "1 Example Street, Example City",
              "Visible encrypted device-guest recordings preserve their own place label")
        var customPlace = located
        customPlace.defaultTitleBase = nil
        customPlace.title = "Мой план Ёё / My plan"
        check(customPlace.displayTitle(language: .english, bundle: bundle) == customPlace.title
              && customPlace.savedLocationLabel(language: .russian) == "ул. Примерная, 1, Примерск",
              "A manually chosen title stays verbatim alongside the independent saved place")
        check(named.displayTitle(language: .english, bundle: bundle) == "Обсуждение вопросов"
              && named.displayTitle(language: .russian, bundle: bundle) == "Обсуждение вопросов",
              "Russian recording titles remain Russian when the interface language changes")
        var englishRecording = original
        englishRecording.languageCode = "ru"
        for index in englishRecording.transcriptSegments.indices {
            englishRecording.transcriptSegments[index].text = "I agree, let me answer, what do you think about this question? This question is important. We should answer the question before choosing a solution. " + String(repeating: english, count: 3)
        }
        let englishNamed = MeetingAutomaticNaming.applying(to: englishRecording)
        check(englishNamed.automaticTitle?.languageCode == "en", "Recognition settings cannot replace the actual majority language")
        let englishKey = englishNamed.automaticTitle!.localizationKey
        check(englishNamed.displayTitle(language: .russian, bundle: bundle) == englishKey
              && englishNamed.displayTitle(language: .english, bundle: bundle) == englishKey,
              "English recording titles remain English in either interface language")
        for (text, code, expected, opposite) in [
            ("Небо голубое, трава зеленая. Дорога проходит через лес. Деревья растут около реки. Вода течет между камнями. ", "ru", "Аудиозапись", PichiInterfaceLanguage.english),
            ("The sky is blue and the grass is green. A path runs through the forest. Trees grow beside the river. Water flows between the stones. ", "en", "Audio recording", PichiInterfaceLanguage.russian)
        ] {
            var neutral = original
            for index in neutral.transcriptSegments.indices { neutral.transcriptSegments[index].text = String(repeating: text, count: 4) }
            let result = MeetingAutomaticNaming.applying(to: neutral)
            check(result.automaticTitle?.candidateID == "recording" && result.automaticTitle?.languageCode == code
                  && result.displayTitle(language: opposite, bundle: bundle) == expected,
                  "A long neutral fallback retains its content language without inventing conversational claims")
            let neutralStore = MeetingSessionStore(rootDirectory: root.appendingPathComponent("neutral-" + code))
            try await neutralStore.create(neutral)
            let persisted = try await neutralStore.loadTranscript(id: neutral.id)!
            let neutralManifest = root.appendingPathComponent("neutral-" + code).appendingPathComponent(neutral.id.uuidString).appendingPathComponent("session.json")
            let neutralBytes = try Data(contentsOf: neutralManifest)
            let reloaded = try await neutralStore.loadTranscript(id: neutral.id)
            let repeatedNeutralBytes = try Data(contentsOf: neutralManifest)
            check(persisted.automaticTitle?.candidateID == "recording" && persisted.automaticTitle?.languageCode == code
                  && reloaded == persisted && neutralBytes == repeatedNeutralBytes,
                  "Actual store reads persist and preserve a neutral language-frozen title")
        }
        let background = await MeetingAutomaticNaming.applyingInBackground(to: original)
        check(background == named, "Joined utility naming produces the same immutable result as the pure engine")
        check(named.automaticTitle != nil, "A completed long default-named recording receives an automatic title")
        check(named.automaticTitle?.previousTitle == original.title
              && named.automaticTitle?.previousDefaultTitleBase == original.defaultTitleBase,
              "The original naming fields remain available for rollback inside the manifest")
        check(named.automaticTitle?.candidateID.contains("dialogue") == false
              && named.automaticTitle?.candidateID.contains("group") == false,
              "Two native diarization labels cannot establish exact attendance or a group")
        check(MeetingAutomaticNaming.applying(to: named) == named, "The generated-title migration is idempotent")
        check(MeetingAutomaticTitle.supportedAlgorithmVersion == MeetingUniversalTitleEngine.algorithmVersion,
              "Persisted presentation and naming engine versions agree")
        var future = named
        future.automaticTitle = .init(algorithmVersion: "unknown-future-version", candidateID: "unknown",
            localizationKey: "This is not a UI key", previousTitle: original.title, previousDefaultTitleBase: original.defaultTitleBase)
        check(future.displayTitle(language: .english) == future.title
              && MeetingAutomaticNaming.validatingMetadata(in: future) == future,
              "Unknown naming metadata preserves the saved title without reinterpretation")
        var damaged = named
        damaged.automaticTitle = .init(algorithmVersion: MeetingUniversalTitleEngine.algorithmVersion,
            candidateID: named.automaticTitle!.candidateID, localizationKey: "This is not a UI key",
            previousTitle: original.title, previousDefaultTitleBase: original.defaultTitleBase)
        let normalized = MeetingAutomaticNaming.validatingMetadata(in: damaged)
        check(normalized.automaticTitle == nil && normalized.defaultTitleBase == nil && normalized.title == damaged.title,
              "A supported candidate cannot introduce an arbitrary localization key")
        var unchanged = named
        unchanged.title = original.title; unchanged.automaticTitle = nil
        check(unchanged == original, "Automatic naming changes no transcript, speaker, timing, location or privacy evidence")
        check(!named.displayTitle(language: .english).contains(" · "),
              "Generated names contain no recording date or time; separate metadata owns the start")
        check(!original.displayTitle(language: .english).contains(" · "),
              "Default automatic names also leave their start out of the visible title")
        var online = original
        online.mode = .onlineCall; online.defaultTitleBase = "Synthetic call"
        check(online.displayTitle(language: .english) == "Synthetic call",
              "Default online call names retain their bare base without a timestamp")
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        check(try decoder.decode(MeetingSession.self, from: encoder.encode(named)) == named,
              "Generated metadata and original names survive the existing schema-1 codec")
        var legacyObject = try JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
        legacyObject.removeValue(forKey: "automaticTitle")
        let legacy = try decoder.decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(legacy == original, "Old recordings decode without inventing automatic-title provenance")
        var oldArtifactObject = try JSONSerialization.jsonObject(with: encoder.encode(named)) as! [String: Any]
        var oldArtifact = oldArtifactObject["automaticTitle"] as! [String: Any]
        oldArtifact.removeValue(forKey: "languageCode"); oldArtifactObject["automaticTitle"] = oldArtifact
        var oldGenerated = try decoder.decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: oldArtifactObject))
        oldGenerated.title = "Обсуждение вопросов · old generated start"
        check(oldGenerated.automaticTitle?.languageCode == nil
              && oldGenerated.displayTitle(language: .english, bundle: bundle) == "Обсуждение вопросов",
              "Earlier generated snapshots retain their stored language while dropping only their known date suffix")
        let backfilled = MeetingAutomaticNaming.applying(to: oldGenerated)
        check(backfilled.automaticTitle?.languageCode == "ru"
              && backfilled.automaticTitle?.candidateID == oldGenerated.automaticTitle?.candidateID
              && backfilled.automaticTitle?.previousTitle == oldGenerated.automaticTitle?.previousTitle
              && backfilled.automaticTitle?.previousDefaultTitleBase == oldGenerated.automaticTitle?.previousDefaultTitleBase,
              "Language backfill preserves the prior candidate and original-title rollback metadata")
        check(MeetingAutomaticNaming.applying(to: backfilled) == backfilled,
              "An already frozen recording title never follows later interface changes")
        let oldRoot = root.appendingPathComponent("old-generated-language")
        let oldStore = MeetingSessionStore(rootDirectory: oldRoot)
        oldGenerated.id = UUID()
        oldGenerated.title = "Discussion of questions · old generated start"
        try await oldStore.create(oldGenerated)
        let oldLoaded = try await oldStore.loadTranscript(id: oldGenerated.id)!
        check(oldLoaded.automaticTitle?.languageCode == "ru"
              && oldLoaded.automaticTitle?.candidateID == oldGenerated.automaticTitle?.candidateID
              && oldLoaded.automaticTitle?.previousTitle == oldGenerated.automaticTitle?.previousTitle
              && oldLoaded.automaticTitle?.previousDefaultTitleBase == oldGenerated.automaticTitle?.previousDefaultTitleBase,
              "An actual store read backfills the old artifact without changing candidate or original backup")
        check(oldLoaded.title == "Обсуждение вопросов"
              && oldLoaded.displayTitle(language: .english, bundle: bundle) == "Обсуждение вопросов",
              "An actual store read persists a bare Russian snapshot over the earlier English timestamped snapshot")
        let oldManifest = oldRoot.appendingPathComponent(oldGenerated.id.uuidString).appendingPathComponent("session.json")
        let oldBytes = try Data(contentsOf: oldManifest)
        let oldAgain = try await oldStore.loadTranscript(id: oldGenerated.id)
        let oldRepeatedBytes = try Data(contentsOf: oldManifest)
        check(oldAgain == oldLoaded && oldRepeatedBytes == oldBytes,
              "Repeated actual store reads preserve a backfilled title manifest byte for byte")

        var partial = original
        partial.transcriptIsComplete = false
        partial.transcriptCoverageGaps = [.init(trackID: track.id, start: 1, end: 2, reason: .processingFailed)]
        let partialNamed = MeetingAutomaticNaming.applying(to: partial)
        check(partialNamed.automaticTitle != nil && partialNamed.transcriptIsComplete == false
              && partialNamed.transcriptCoverageGaps == partial.transcriptCoverageGaps,
              "A completed partial recording can be named without claiming complete transcript coverage")
        for state: MeetingSessionState in [.preparing, .recording, .recordingDegraded, .stopping, .processing, .interrupted, .failed] {
            var active = original; active.state = state
            check(MeetingAutomaticNaming.applying(to: active) == active, "Active or recoverable recordings are never renamed")
        }
        var short = original; short.endedAt = short.startedAt.addingTimeInterval(1_799)
        check(MeetingAutomaticNaming.applying(to: short) == short, "Short recordings are outside title generation")
        var sparse = original; sparse.transcriptSegments = [sparse.transcriptSegments[0]]
        check(MeetingAutomaticNaming.applying(to: sparse) == sparse, "A long duration cannot turn a short dictation into a naming input")
        var unended = original; unended.endedAt = nil
        check(MeetingAutomaticNaming.applying(to: unended) == unended, "An absent end time cannot use the wall clock to qualify")
        var custom = original; custom.title = "Manual synthetic name"; custom.defaultTitleBase = nil
        check(MeetingAutomaticNaming.applying(to: custom) == custom, "Explicit custom titles remain untouched")
        var concealed = original; concealed.requiresEncryptedPersistence = true
        concealed.profileOwnership = .init(profileID: "synthetic-account", issuer: nil, subject: nil,
            internalUserID: nil, organizationID: nil, workspaceID: nil)
        check(MeetingAutomaticNaming.applying(to: concealed) == concealed, "Concealed account content is not an automatic naming input")
        var oversized = original
        oversized.transcriptSegments[0].text = String(repeating: "x", count: MeetingAutomaticNaming.maximumTextBytes + 1)
        check(MeetingAutomaticNaming.applying(to: oversized) == oversized, "Additional naming work is bounded before projection")

        let store = MeetingSessionStore(rootDirectory: root)
        try await store.create(original)
        let directory = root.appendingPathComponent(original.id.uuidString)
        let summaryURL = directory.appendingPathComponent("manual-summary-executive.json")
        let legacySummary: [String: Any] = ["transcriptHash": MeetingSummaryInput.fingerprint(MeetingSummaryInput.transcript(for: original)),
            "modelID": "synthetic", "text": "Synthetic retained summary", "providerID": "synthetic",
            "promptVersion": MeetingSummaryInput.currentPromptVersion]
        try JSONSerialization.data(withJSONObject: legacySummary).write(to: summaryURL, options: .atomic)
        let loaded = try await store.loadTranscript(id: original.id)!
        check(loaded.automaticTitle?.previousTitle == original.title, "History upgrades default titles using the ordinary store read")
        let summary = try decoder.decode(MeetingSavedSummary.self, from: Data(contentsOf: summaryURL))
        check(summary.isCurrent(session: loaded, promptHash: nil), "A title migration preserves a valid legacy saved summary")
        let manifestURL = directory.appendingPathComponent("session.json")
        let firstBytes = try Data(contentsOf: manifestURL)
        let again = try await store.loadTranscript(id: original.id)
        let repeatedBytes = try Data(contentsOf: manifestURL)
        check(again == loaded && repeatedBytes == firstBytes,
              "Repeated history reads do not rewrite already migrated manifests")

        let cipher = try MeetingRecordingCipher(profileID: MeetingProfileOwnership.guest.profileID,
            key: Data(repeating: 0x41, count: 32))
        let encryptedRoot = root.appendingPathComponent("encrypted-guest")
        let encryptedStore = MeetingSessionStore(rootDirectory: encryptedRoot, encryptionCipher: cipher)
        var encrypted = original; encrypted.id = UUID(); encrypted.profileOwnership = .guest
        encrypted.requiresEncryptedPersistence = true; encrypted.audioStorageMode = .memoryOnly
        try await encryptedStore.create(encrypted)
        let encryptedNamed = try await encryptedStore.loadTranscript(id: encrypted.id)!
        let encryptedURL = encryptedRoot.appendingPathComponent(encrypted.id.uuidString).appendingPathComponent("session.json")
        let envelope = try Data(contentsOf: encryptedURL)
        check(encryptedNamed.automaticTitle?.previousTitle == encrypted.title
              && MeetingRecordingCipher.isEncryptedEnvelope(envelope)
              && envelope.range(of: Data(encrypted.title.utf8)) == nil,
              "Guest title migration and its backup stay under the original recording encryption")
    }
}
