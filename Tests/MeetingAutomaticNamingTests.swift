import Foundation

extension MeetingSessionStoreCheckpointTests {
    /// Real session codecs, reading projection, filesystem store and synthetic encryption key.
    /// This fixture performs no inference, audio access, network access or account lookup.
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
        check(named.displayTitle(language: .english).hasPrefix(named.automaticTitle!.localizationKey + " · "),
              "Generated titles take precedence over location while preserving recording dates")
        let decoder = JSONDecoder(), encoder = JSONEncoder()
        check(try decoder.decode(MeetingSession.self, from: encoder.encode(named)) == named,
              "Generated metadata and original names survive the existing schema-1 codec")
        var legacyObject = try JSONSerialization.jsonObject(with: encoder.encode(original)) as! [String: Any]
        legacyObject.removeValue(forKey: "automaticTitle")
        let legacy = try decoder.decode(MeetingSession.self, from: JSONSerialization.data(withJSONObject: legacyObject))
        check(legacy == original, "Old recordings decode without inventing automatic-title provenance")

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
