import Foundation

// Standalone store tests use the production codecs and filesystem store. Only unrelated
// application logging/branding and canonical-sidecar migration are isolated in the runner.
@main
struct MeetingSessionStoreCheckpointTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let manager = FileManager.default
        defer { try? manager.removeItem(at: root) }
        let store = MeetingSessionStore(rootDirectory: root)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic long checkpoint",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture microphone")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        session.state = .recording
        session.audioStorageMode = .memoryOnly
        session.piiRedactionEnabled = true
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "fixture",
            sourceDisplayName: "Fixture microphone", format: nil, timebase: timebase, health: .waiting, chunks: [])
        session.audioTracks = [track]
        let speaker = MeetingSessionSpeaker(id: UUID(), displayName: "Fixture speaker", diarizationClusterID: "fixture",
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        session.speakers = [speaker]
        session.transcriptTimeDomain = .meetingRelative
        session.transcriptIsComplete = false
        session.transcriptCoverageGaps = [.init(trackID: track.id, start: 10, end: 11, reason: .processingFailed)]
        let segmentCount = 20_000
        session.transcriptSegments = (0..<segmentCount).map { index in
            MeetingTranscriptSegment(id: UUID(), start: .init(value: Int64(index * 2), timescale: 1),
                end: .init(value: Int64(index * 2 + 1), timescale: 1), sourceTrackID: track.id,
                speakerID: speaker.id, text: "Synthetic \(index) Ёё: escaped \"quote\", slash / and newline\nnext line",
                originalText: index % 2 == 0 ? "Original \(index)" : nil, revision: index % 3, status: .final,
                overlap: .none, completeness: .complete, attributionState: .assigned)
        }
        let indexURL = root.appendingPathComponent("index.json")
        let directory = root.appendingPathComponent(session.id.uuidString, isDirectory: true)
        let manifestURL = directory.appendingPathComponent("session.json")
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            if !value { FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8)) }
            precondition(value, message)
            checks += 1
        }
        var generated = speaker
        generated.displayName = "Speaker 1"
        generated.generatedParticipantNumber = 1
        var named = session
        named.speakers = [generated]
        try named.renameSpeaker(id: generated.id, to: "Ручное имя Ёё")
        check(named.speakers[0].usesCustomDisplayName == true, "Renaming records explicit alias provenance")
        check(named.speakers[0].generatedParticipantNumber == nil,
              "An explicit alias must leave automatic participant numbering")
        let alias = MeetingSessionSpeaker.numberingGeneratedParticipants(named.speakers, speakerNameFormat: "Speaker %lld")
        check(alias[0].displayName == "Ручное имя Ёё", "Numbering replaced a manual alias")
        let speakerCodec = JSONEncoder()
        let numberedData = try speakerCodec.encode(generated)
        let decodedNumbered = try JSONDecoder().decode(MeetingSessionSpeaker.self, from: numberedData)
        check(decodedNumbered == generated, "Generated participant metadata failed to survive the saved-data codec")
        var legacyObject = try JSONSerialization.jsonObject(with: numberedData) as! [String: Any]
        legacyObject.removeValue(forKey: "generatedParticipantNumber")
        legacyObject.removeValue(forKey: "usesCustomDisplayName")
        let decodedLegacy = try JSONDecoder().decode(MeetingSessionSpeaker.self,
            from: JSONSerialization.data(withJSONObject: legacyObject))
        check(decodedLegacy.usesCustomDisplayName == nil, "An older speaker cannot invent explicit alias provenance")
        check(decodedLegacy.generatedParticipantNumber == nil && decodedLegacy.displayName == generated.displayName,
              "An older saved speaker must decode as a preserved alias")
        for flag: Bool? in [nil, false, true] {
            var alias = named.speakers[0]
            alias.usesCustomDisplayName = flag
            let decoded = try JSONDecoder().decode(MeetingSessionSpeaker.self, from: JSONEncoder().encode(alias))
            check(decoded == alias, "Alias provenance must survive the production codec exactly")
            var word = session.transcriptSegments[0]
            word.isUserSpeakerAssigned = flag
            let decodedWord = try JSONDecoder().decode(MeetingTranscriptSegment.self, from: JSONEncoder().encode(word))
            check(decodedWord == word, "Manual participant provenance must survive the production codec exactly")
        }
        var legacyWordRecord = try JSONSerialization.jsonObject(with: JSONEncoder().encode(session.transcriptSegments[0])) as! [String: Any]
        legacyWordRecord.removeValue(forKey: "isUserSpeakerAssigned")
        let decodedLegacyWord = try JSONDecoder().decode(MeetingTranscriptSegment.self,
            from: JSONSerialization.data(withJSONObject: legacyWordRecord))
        check(decodedLegacyWord.isUserSpeakerAssigned == nil, "An older word retains legacy assignment provenance")
        var roleOwner = generated
        roleOwner.isLocalUser = true
        roleOwner.generatedParticipantNumber = 0
        var roleOther = generated
        roleOther.id = UUID()
        var roleAlias = named.speakers[0]
        roleAlias.id = UUID()
        // Explicit alias provenance remains authoritative even with a historical number.
        roleAlias.generatedParticipantNumber = 7
        var roleLegacy = generated
        roleLegacy.id = UUID()
        roleLegacy.displayName = "Preserved legacy name"
        roleLegacy.generatedParticipantNumber = nil
        var roleSession = session
        roleSession.speakers = [roleOwner, roleOther, roleAlias, roleLegacy]
        try roleSession.setLocalUserSpeaker(id: nil, speakerNameFormat: "Captured %lld")
        check(roleSession.speakers.prefix(2).map(\.displayName) == ["Captured 1", "Captured 2"],
              "Clearing the owner renumbers generated names that previously shared one raw label")
        check(roleSession.speakers.prefix(2).map(\.generatedParticipantNumber) == [1, 2],
              "A cleared owner cannot retain the generated zero owner marker")
        check(roleSession.speakers[2].displayName == roleAlias.displayName
              && roleSession.speakers[2].usesCustomDisplayName == true
              && roleSession.speakers[2].generatedParticipantNumber == nil,
              "An explicit custom alias cannot be reformatted as a generated participant")
        check(roleSession.speakers[3] == roleLegacy, "Legacy nil-number names remain verbatim")
        let savedRoles = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(roleSession))
        check(savedRoles.speakers == roleSession.speakers, "Meeting-local role corrections survive the session codec")
        try Self.checkReadableTranscriptContract(check)

        try Self.checkPlainParticipantLabels(template: session, check: check)
        try Self.checkManualCorrectionOfProjectedOwner(template: session, check: check)
        try Self.checkUnmappedCanonicalReadingOwner(template: session, check: check)
        try Self.checkNativeBoundaryReadingOwner(template: session, check: check)
        try await Self.checkReadingProjectionCache(template: session, check: check)
        try await Self.checkProtectedPortableExport(check: check)

        let nativePresentation = MeetingTranscriptExporter.speakerPresentation(
            for: session.transcriptSegments[0], in: session)
        check(MeetingTranscriptExporter.speakerLabel(for: nativePresentation) == "Fixture speaker",
              "Live labels reuse the history attribution resolver")
        var sameNamedSpeaker = speaker
        sameNamedSpeaker.id = UUID()
        var twoSpeakers = session
        twoSpeakers.speakers.append(sameNamedSpeaker)
        var secondVoice = session.transcriptSegments[1]
        secondVoice.speakerID = sameNamedSpeaker.id
        let secondPresentation = MeetingTranscriptExporter.speakerPresentation(for: secondVoice, in: twoSpeakers)
        check(nativePresentation.identity != secondPresentation.identity,
              "Equal aliases cannot collapse two different speaker identities")
        var estimatedWord = session.transcriptSegments[0]
        estimatedWord.speakerAttributionInference = .init(rule: .surroundingSpeaker,
            originalState: .unassigned, originalOverlap: .none,
            precedingSegmentID: UUID(), followingSegmentID: UUID())
        let estimatedPresentation = MeetingTranscriptExporter.speakerPresentation(for: estimatedWord, in: session)
        check(nativePresentation.identity == estimatedPresentation.identity,
              "Per-word native/estimated reasons do not fragment one known readable turn")
        check(estimatedPresentation.isEstimated && nativePresentation.markingEstimated() == estimatedPresentation,
              "A word estimate preserves the shared turn's internal evidence marker")
        var unknownWord = session.transcriptSegments[0]
        unknownWord.speakerID = nil
        unknownWord.attributionState = .unassigned
        let unknownPresentation = MeetingTranscriptExporter.speakerPresentation(for: unknownWord, in: session)
        check(nativePresentation.identity != unknownPresentation.identity,
              "Unknown evidence remains a boundary from a known speaker")
        check(MeetingTranscriptExporter.speakerLabel(for: unknownPresentation) == "Unknown speaker",
              "Unknown evidence retains the standard label")
        let presentationEpoch = MeetingAnalysisEpochID(trackID: track.id, ordinal: 0)
        let presentationToken = MeetingBackendSpeakerToken(analysisEpochID: presentationEpoch, label: "voice-a")
        let backgroundToken = MeetingBackendSpeakerToken(analysisEpochID: presentationEpoch, label: "voice-b")
        func readingDecision(_ rule: MeetingSpeakerAttributionRule, relation: MeetingSpeakerAttributionRelation,
                             background: [MeetingBackendSpeakerToken] = []) -> MeetingSpeakerAttributionDecision {
            .init(unitID: "fixture-word", rawAssignment: .assigned(presentationToken), candidates: [],
                  activeSupportSeconds: 0.1, simultaneousIntervals: [], relation: relation,
                  selectedToken: presentationToken, rule: rule, cueUnitIDs: [], backgroundTokens: background,
                  policyVersion: 2, policyFingerprint: "synthetic-presentation-policy")
        }
        var canonicalWord = session.transcriptSegments[0]
        canonicalWord.speakerAttribution = .init(decision: readingDecision(.rawAssigned, relation: .single),
                                                speakerIDs: [presentationToken: speaker.id])
        let canonicalDirect = MeetingTranscriptExporter.speakerPresentation(for: canonicalWord, in: twoSpeakers)
        canonicalWord.speakerAttribution = .init(decision: readingDecision(.neighborAgreement, relation: .single),
                                                speakerIDs: [presentationToken: speaker.id])
        let canonicalEstimate = MeetingTranscriptExporter.speakerPresentation(for: canonicalWord, in: twoSpeakers)
        check(canonicalDirect.identity == canonicalEstimate.identity && canonicalEstimate.isEstimated,
              "Canonical native/neighbor words share identity without hiding the estimate")
        canonicalWord.speakerAttribution = .init(decision: readingDecision(.briefInterruption, relation: .simultaneous,
                                                                          background: [backgroundToken]),
            speakerIDs: [presentationToken: speaker.id, backgroundToken: sameNamedSpeaker.id])
        let interruption = MeetingTranscriptExporter.speakerPresentation(for: canonicalWord, in: twoSpeakers)
        check(interruption.identity == canonicalDirect.identity,
              "Raw overlap/background changes do not split the same reading participant")
        check(MeetingTranscriptExporter.speakerLabel(for: interruption)
              == "Fixture speaker",
              "Live interruptions reuse the existing explicit foreground/background label")

        var ownerSession = session
        ownerSession.speakers[0].isLocalUser = true
        let ownerPresentation = MeetingTranscriptExporter.speakerPresentation(for: session.transcriptSegments[0], in: ownerSession)
        check(MeetingTranscriptExporter.speakerLabel(for: ownerPresentation) == "You",
              "Local owner presentation uses the existing localized owner marker")
        check(session.transcriptSegments[0].speakerAttributionInference == nil,
              "Creating a reading label does not mutate transcript evidence")

        // Archives written by the retired product-level continuity rule remain readable,
        // with plain participant names and never become new acoustic evidence.
        let oldInference = MeetingSpeakerAttributionInference(rule: .incomingSpeaker,
            originalState: .unassigned, originalOverlap: .none,
            precedingSegmentID: UUID(), followingSegmentID: UUID())
        var archived = session
        archived.transcriptSegments = [session.transcriptSegments[0]]
        archived.transcriptSegments[0].speakerAttributionInference = oldInference
        let archiveEncoder = JSONEncoder(); archiveEncoder.dateEncodingStrategy = .iso8601
        let archiveDecoder = JSONDecoder(); archiveDecoder.dateDecodingStrategy = .iso8601
        let archiveData = try archiveEncoder.encode(archived)
        let restoredArchive = try archiveDecoder.decode(MeetingSession.self, from: archiveData)
        check(restoredArchive.transcriptSegments[0].speakerAttributionInference == oldInference,
              "Old continuity metadata survives the real archive codec")
        check(restoredArchive.transcriptSegments[0].speakerAttribution == nil,
              "Decoding an old estimate never fabricates new canonical decisions")
        let archiveText = MeetingTranscriptExporter.text(for: restoredArchive)
        check(archiveText == "[00:00] Fixture speaker: \(restoredArchive.transcriptSegments[0].text)",
              "Old continuity metadata does not add a visible label qualifier")
        let exportedArchive = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.json(for: restoredArchive)) as! [String: Any]
        let exportedWords = exportedArchive["segments"] as! [[String: Any]]
        let exportedInference = exportedWords[0]["speakerAttributionInference"] as! [String: Any]
        check(exportedInference["rule"] as? String == "incomingSpeaker",
              "Legacy JSON export preserves original rule and anchor IDs")
        check(exportedInference["followingSegmentID"] as? String == oldInference.followingSegmentID.uuidString,
              "Legacy JSON export preserves exact original anchors")
        var confirmedArchive = restoredArchive
        try confirmedArchive.reassignSegment(id: confirmedArchive.transcriptSegments[0].id, to: speaker.id)
        check(confirmedArchive.transcriptSegments[0].speakerAttributionInference == nil,
              "Explicit confirmation of the same legacy speaker clears the old estimate")
        check(MeetingTranscriptExporter.text(for: confirmedArchive) == archiveText,
              "Manual confirmation keeps the same plain participant name")
        var mergedArchive = restoredArchive
        let mergeTarget = MeetingSessionSpeaker(id: UUID(), displayName: "Legacy merge target", diarizationClusterID: nil,
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        mergedArchive.speakers.append(mergeTarget)
        try mergedArchive.mergeSpeakers(speaker.id, into: mergeTarget.id)
        check(mergedArchive.transcriptSegments[0].speakerAttributionInference == nil,
              "Manual merges clear the superseded legacy reading estimate")
        let start = ProcessInfo.processInfo.systemUptime
        try await store.create(session)
        let createSeconds = ProcessInfo.processInfo.systemUptime - start
        // Working-state recovery is opt-in through the captured storage mode, never today's
        // settings. Use the actual encryption/private-write implementation in this harness.
        let strictWorking = MeetingRetainedProcessingCheckpoint(sessionDirectory: root.appendingPathComponent("must-not-exist"))
        check(try strictWorking.read(session: session) == nil, "Strict mode does not read working-state files")
        check(!manager.fileExists(atPath: root.appendingPathComponent("must-not-exist").path), "Strict mode creates no directory")
        var retained = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic retained recovery",
            microphone: .init(captureDeviceID: "fixture", displayName: "Fixture microphone")),
            startedAt: session.startedAt, timebase: timebase)
        retained.audioStorageMode = .retainedFiles
        retained.piiRedactionEnabled = false
        retained.transcriptSegments = []
        try await store.create(retained)
        let retainedDirectory = try await store.sessionDirectory(for: retained.id)
        let working = MeetingRetainedProcessingCheckpoint(sessionDirectory: retainedDirectory)
        let configuration = MeetingFinalProcessingConfiguration(languageCode: retained.languageCode)
        let pin = MeetingRetainedProcessingCheckpoint.Pin(schema: 1, sessionID: retained.id,
            backendID: .init(rawValue: "synthetic-retained"), backendVersion: "1", configuration: configuration,
            piiRedactionEnabled: false, privacyFingerprint: nil)
        let privateText = Data("synthetic working text never exported".utf8)
        let value = MeetingRetainedProcessingCheckpoint.Value(pin: pin, inputFingerprint: "synthetic-source-sha",
            ownerVoiceIdentity: nil, runtimeFingerprint: nil, payload: privateText)
        try working.write(value, session: retained)
        let modeCheckpoint = try Data(contentsOf: retainedDirectory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.fileName))
        var streamingSession = retained
        streamingSession.speakerProcessingMode = .streaming
        do { _ = try working.read(session: streamingSession); preconditionFailure("A post-recording checkpoint must not resume a streaming attempt") }
        catch MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration { checks += 1 }
        do { try working.write(value, session: streamingSession); preconditionFailure("A mismatched mode must be rejected before replacing the last checkpoint") }
        catch MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration { checks += 1 }
        check(try Data(contentsOf: retainedDirectory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.fileName)) == modeCheckpoint,
            "Mismatched speaker scheduling preserves the last durable checkpoint")
        let streamConfiguration = MeetingFinalProcessingConfiguration(languageCode: retained.languageCode,
            speakerProcessingMode: .streaming)
        let streamPin = MeetingRetainedProcessingCheckpoint.Pin(schema: 1, sessionID: retained.id,
            backendID: pin.backendID, backendVersion: pin.backendVersion, configuration: streamConfiguration,
            piiRedactionEnabled: false, privacyFingerprint: nil)
        try working.write(.init(pin: streamPin, inputFingerprint: value.inputFingerprint,
            ownerVoiceIdentity: nil, runtimeFingerprint: nil, payload: privateText), session: streamingSession)
        check(try working.read(session: streamingSession)?.payload == privateText,
            "The captured streaming mode round-trips the authenticated checkpoint")
        do { _ = try working.read(session: retained); preconditionFailure("A streaming checkpoint must not resume a post-recording attempt") }
        catch MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration { checks += 1 }
        try working.write(value, session: retained)
        let obsoleteConfig = MeetingFinalProcessingConfiguration(languageCode: retained.languageCode,
            pipelineVersion: 14, speakerAttributionPolicy: .standard)
        let obsoletePin = MeetingRetainedProcessingCheckpoint.Pin(schema: 1, sessionID: retained.id,
            backendID: pin.backendID, backendVersion: pin.backendVersion, configuration: obsoleteConfig,
            piiRedactionEnabled: false, privacyFingerprint: nil)
        do {
            try working.write(.init(pin: obsoletePin, inputFingerprint: value.inputFingerprint,
                ownerVoiceIdentity: nil, runtimeFingerprint: nil, payload: privateText), session: retained)
            preconditionFailure("The writer's read-back must reject obsolete processing semantics")
        } catch MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration { checks += 1 }
        do { _ = try working.read(session: retained); preconditionFailure("Old attribution semantics must not resume under a new pipeline") }
        catch MeetingRetainedProcessingCheckpoint.Failure.changedConfiguration { checks += 1 }
        try working.write(value, session: retained)
        let checkpointURL = retainedDirectory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.fileName)
        let keyURL = retainedDirectory.appendingPathComponent(MeetingRetainedProcessingCheckpoint.keyFileName)
        let ciphertext = try Data(contentsOf: checkpointURL)
        check(ciphertext.range(of: privateText) == nil, "Working ASR text is not plaintext in the checkpoint")
        check(try MeetingRetainedProcessingCheckpoint(sessionDirectory: retainedDirectory).read(session: retained)?.payload == privateText,
              "A fresh store authenticates and restores exact working-state bytes")
        check(try manager.attributesOfItem(atPath: checkpointURL.path)[.posixPermissions] as? NSNumber == 0o600,
              "Checkpoint permissions are private")
        check(try manager.attributesOfItem(atPath: keyURL.path)[.posixPermissions] as? NSNumber == 0o600,
              "Checkpoint key permissions are private")
        var damaged = ciphertext; damaged[damaged.count / 2] ^= 1
        try damaged.write(to: checkpointURL)
        do { _ = try working.read(session: retained); preconditionFailure("Corruption must not resume") }
        catch { checks += 1 }
        try ciphertext.write(to: checkpointURL)
        var drifted = retained; drifted.piiRedactionEnabled = true
        do { _ = try working.read(session: drifted); preconditionFailure("Privacy policy drift must not resume") }
        catch { checks += 1 }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try working.write(value, session: retained)
        }
        do { try await cancelled.value; preconditionFailure("Cancelled work must not publish") }
        catch is CancellationError { checks += 1 }
        check(try Data(contentsOf: checkpointURL) == ciphertext, "Cancelled checkpoint preserves the last complete generation")
        let abandoned = retainedDirectory.appendingPathComponent(".processing-resume-\(UUID().uuidString).tmp")
        let unrelated = retainedDirectory.appendingPathComponent(".processing-resume-user-note.tmp")
        try Data(repeating: 7, count: 32).write(to: abandoned)
        try Data("unrelated file".utf8).write(to: unrelated)
        try await store.deleteAudioFiles(for: retained.id)
        check(!manager.fileExists(atPath: checkpointURL.path) && !manager.fileExists(atPath: keyURL.path),
              "Deleting retained audio removes ciphertext and key")
        check(!manager.fileExists(atPath: abandoned.path), "Deleting audio removes interrupted atomic checkpoint writes")
        check(manager.fileExists(atPath: unrelated.path), "Cleanup only removes owned temporary names")
        check(try !MeetingRetainedProcessingCheckpoint.hasWorkingState(in: retainedDirectory), "No retained working-state residue survives deletion")
        check(try await store.load(id: retained.id) != nil, "Audio cleanup preserves the meeting manifest")
        try await store.delete(id: retained.id)
        let compact = try Data(contentsOf: manifestURL)
        check(!compact.contains(10), "Canonical JSON has no formatting newlines, while escaped user newlines remain data")
        let legacyEncoder = JSONEncoder()
        legacyEncoder.dateEncodingStrategy = .iso8601
        legacyEncoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let legacyStart = ProcessInfo.processInfo.systemUptime
        let legacy = try legacyEncoder.encode(session)
        let legacyEncodeSeconds = ProcessInfo.processInfo.systemUptime - legacyStart
        check(compact.count < legacy.count, "Checkpoints omit formatting without truncating records")
        let loaded = try await store.load(id: session.id)
        check(loaded == session, "All 20,000 segments, Unicode, edits, speaker and gap metadata round trip exactly")
        let recoverable = try await store.loadRecoverable()
        check(recoverable == [session], "Long strict recording remains recoverable without audio files")

        // A saved pre-change human-readable manifest is still accepted, then compacted on save.
        try legacy.write(to: manifestURL, options: .atomic)
        let legacyLoaded = try await store.load(id: session.id)
        check(legacyLoaded == session, "Historical pretty/sorted manifests decode unchanged")
        try await store.save(session)
        let recompacted = try Data(contentsOf: manifestURL)
        check(!recompacted.contains(10), "Saving an old manifest uses the compact canonical encoding")

        // Touching the index once per audio window was redundant and caused another atomic write.
        let initialIndex = try Data(contentsOf: indexURL)
        let sentinel = Date(timeIntervalSince1970: 1_600_000_000)
        try manager.setAttributes([.modificationDate: sentinel], ofItemAtPath: indexURL.path)
        session.title = "Newest durable title"
        session.transcriptSegments[0].text = "Corrected synthetic text"
        session.transcriptSegments[0].revision += 1
        session.updatedAt = session.startedAt.addingTimeInterval(60)
        let saveStart = ProcessInfo.processInfo.systemUptime
        try await store.save(session)
        let saveSeconds = ProcessInfo.processInfo.systemUptime - saveStart
        let indexAfterSave = try Data(contentsOf: indexURL)
        check(indexAfterSave == initialIndex, "An existing session checkpoint preserves the index bytes")
        let indexDate = try manager.attributesOfItem(atPath: indexURL.path)[.modificationDate] as? Date
        check(indexDate == sentinel, "An existing session checkpoint does not replace or touch the index")
        let latest = try await MeetingSessionStore(rootDirectory: root).load(id: session.id)
        check(latest == session, "A fresh store recovers the complete latest checkpoint and revisions")

        // No process-only membership cache may suppress repair after disk loss/corruption.
        try manager.removeItem(at: indexURL)
        try await store.save(session)
        check(try self.indexIDs(at: indexURL) == [session.id.uuidString], "Missing index is reconstructed")
        try Data("invalid JSON".utf8).write(to: indexURL)
        try await store.save(session)
        check(try self.indexIDs(at: indexURL) == [session.id.uuidString], "Corrupt index is reconstructed")
        var sibling = session
        sibling.id = UUID()
        sibling.title = "Sibling synthetic checkpoint"
        try await store.save(sibling)
        check(try Set(self.indexIDs(at: indexURL)) == Set([session.id.uuidString, sibling.id.uuidString]),
            "A newly saved session still extends index membership")

        for url in [manifestURL, indexURL] {
            let permissions = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o600, "Canonical files retain private permissions")
        }
        for url in [root, directory, directory.appendingPathComponent("tracks")] {
            let permissions = try manager.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
            check(permissions?.intValue == 0o700, "Canonical directories retain private permissions")
        }

        let beforeInvalidSave = try Data(contentsOf: manifestURL)
        var invalid = session
        invalid.transcriptSegments.append(invalid.transcriptSegments[0])
        do {
            try await store.save(invalid)
            preconditionFailure("Duplicate transcript IDs must fail validation")
        } catch MeetingModelValidationError.duplicateSegmentID {
            checks += 1
        }
        check(try Data(contentsOf: manifestURL) == beforeInvalidSave, "Invalid checkpoint never replaces the last valid manifest")
        try await store.delete(id: session.id)
        do {
            try await store.save(session)
            preconditionFailure("A stale checkpoint must not resurrect a deleted meeting")
        } catch MeetingSessionStoreError.sessionDeleted {
            checks += 1
        }
        check(!manager.fileExists(atPath: directory.path), "Deletion removes the entire session directory")
        let deleted = try await store.load(id: session.id)
        check(deleted == nil, "Tombstoned meeting stays absent")
        check(try self.indexIDs(at: indexURL) == [sibling.id.uuidString], "Deletion preserves sibling membership")
        let all = try await MeetingSessionStore(rootDirectory: root).loadAll()
        check(all == [sibling], "Fresh discovery and index loading retain every surviving complete record")
        // Measure serialized transcript storage using actual production models and core.
        // This is a Mac serializer measurement, not a physical iPad memory benchmark.
        let footprintCount = 10_000
        let epoch = MeetingAnalysisEpochID(trackID: track.id, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "synthetic-voice")
        let units = (0..<footprintCount).map { index in
            MeetingFinalTextUnit(id: "synthetic-native-\(index)", trackID: track.id, analysisEpochID: epoch,
                precision: .word, text: "Synthetic", analysisStart: Double(index * 2),
                analysisEnd: Double(index * 2 + 1), speaker: .assigned(token), analysisSpanIDs: [])
        }
        let decisions = try MeetingSpeakerAttribution.resolve(units: units,
            activity: [.init(token: token, start: 0, end: Double(footprintCount * 2))])
        let baseline = Array(session.transcriptSegments.prefix(footprintCount))
        let compactNative = baseline.enumerated().map { index, original in
            var copy = original
            copy.nativePrecision = .word
            copy.nativeUnitID = units[index].id
            copy.nativeSpeakerAssignment = units[index].speaker
            copy.nativeTiming = .init(start: units[index].analysisStart, end: units[index].analysisEnd)
            copy.speakerAttribution = MeetingTranscriptSpeakerAttribution.readingSummary(
                decision: decisions[index], speakerIDs: [token: speaker.id])
            return copy
        }
        let verboseNative = compactNative.enumerated().map { index, original in
            var copy = original
            copy.speakerAttribution = .init(decision: decisions[index], speakerIDs: [token: speaker.id])
            return copy
        }
        var manual = session
        manual.transcriptSegments[0] = verboseNative[0]
        let originalRevision = manual.transcriptSegments[0].revision
        try manual.reassignSegment(id: manual.transcriptSegments[0].id, to: speaker.id)
        check(manual.transcriptSegments[0].speakerAttribution == nil,
            "Explicit confirmation of the displayed person clears inferred attribution metadata")
        check(manual.transcriptSegments[0].revision == originalRevision + 1,
            "Manual confirmation records a revision even when the displayed person stays the same")
        check(manual.transcriptSegments[0].nativeSpeakerAssignment == units[0].speaker,
            "Manual confirmation preserves the raw native speaker annotation")
        let targetSpeaker = MeetingSessionSpeaker(id: UUID(), displayName: "Manual target", diarizationClusterID: nil,
            trackKind: .microphone, isLocalUser: false, identityCandidates: [])
        manual.speakers.append(targetSpeaker)
        try manual.mergeSpeakers(speaker.id, into: targetSpeaker.id)
        check(manual.transcriptSegments[0].nativeSpeakerAssignment == units[0].speaker,
            "Manual identity merge never rewrites native token evidence")
        let legacyWord = try JSONDecoder().decode(MeetingTranscriptSegment.self, from: JSONEncoder().encode(baseline[0]))
        check(legacyWord.nativeSpeakerAssignment == nil, "Legacy source annotations remain optional")
        let persistedNative = try JSONDecoder().decode(MeetingTranscriptSegment.self,
            from: JSONEncoder().encode(compactNative[0]))
        check(persistedNative.nativeSpeakerAssignment == units[0].speaker,
            "Compact direct-word source assignments survive the production segment codec")
        var invalidNative = manual
        invalidNative.transcriptSegments[0].nativeSpeakerAssignment = .assigned(.init(
            analysisEpochID: .init(trackID: UUID(), ordinal: 0), label: "foreign-voice"))
        do { try invalidNative.validateTranscriptStructure(); preconditionFailure("Foreign native source scope must fail") }
        catch MeetingModelValidationError.invalidSpeakerAttribution { checks += 1 }
        let footprintEncoder = JSONEncoder()
        let baselineBytes = try footprintEncoder.encode(baseline).count
        let compactNativeBytes = try footprintEncoder.encode(compactNative).count
        let verboseNativeBytes = try footprintEncoder.encode(verboseNative).count
        check(compactNative.allSatisfy { $0.speakerAttribution == nil }, "Routine direct words use compact metadata")
        check(compactNativeBytes < verboseNativeBytes, "Routine summaries avoid repeated evidence and policy fingerprints")
        print("Attribution serializer footprint: words=\(footprintCount) baselineBytes=\(baselineBytes) "
            + "nativeCompactBytes=\(compactNativeBytes) repeatedSummaryBytes=\(verboseNativeBytes)")
        print("Meeting session checkpoint tests passed: \(checks) checks; \(segmentCount) segments; "
            + "compactBytes=\(compact.count) legacyBytes=\(legacy.count) "
            + "createSeconds=\(createSeconds) saveSeconds=\(saveSeconds) legacyEncodeSeconds=\(legacyEncodeSeconds)")
    }

    /// Exercise the real shared live/history/export renderer and correction operations using
    /// both numbered participant names and a user alias. Interface locale never translates aliases.
    private static func checkPlainParticipantLabels(template: MeetingSession,
                                                    check: (Bool, String) -> Void) throws {
        for (firstAlias, secondAlias) in [("Participant 1", "Participant 2"), ("Участник 1", "Участник 2"), ("Ёлкин", "Мария")] {
            var source = template
            source.state = .completed
            source.endedAt = source.startedAt.addingTimeInterval(2)
            var first = template.speakers[0]; first.displayName = firstAlias
            var second = first; second.id = UUID(); second.displayName = secondAlias
            var merged = first; merged.id = UUID(); merged.displayName = "Retired alias"
            merged.mergedIntoSpeakerID = first.id
            source.speakers = [first, second, merged]
            var direct = template.transcriptSegments[0]; direct.speakerID = merged.id
            var legacy = direct
            legacy.speakerAttributionInference = .init(rule: .incomingSpeaker, originalState: .unassigned,
                originalOverlap: .none, precedingSegmentID: UUID(), followingSegmentID: UUID())
            let token = MeetingBackendSpeakerToken(analysisEpochID: .init(trackID: direct.sourceTrackID, ordinal: 0),
                                                   label: "synthetic-selected")
            let decision = MeetingSpeakerAttributionDecision(unitID: "synthetic-selected-word", rawAssignment: .unassigned,
                candidates: [], activeSupportSeconds: 0, simultaneousIntervals: [], relation: .none,
                selectedToken: token, rule: .neighborAgreement, cueUnitIDs: [], backgroundTokens: [],
                policyVersion: 2, policyFingerprint: MeetingSpeakerAttributionPolicy.standard.fingerprint)
            var heuristic = direct
            heuristic.speakerAttribution = .init(decision: decision, speakerIDs: [token: merged.id])
            for (word, isEstimated) in [(direct, false), (legacy, true), (heuristic, true)] {
                source.transcriptSegments = [word]
                let original = source
                let originalJSON = try MeetingTranscriptExporter.json(for: source)
                let presentation = MeetingTranscriptExporter.speakerPresentation(for: word, in: source)
                check(presentation.isEstimated == isEstimated, "Presentation retains the original heuristic marker")
                let names = Dictionary(uniqueKeysWithValues: source.activeSpeakers.map { ($0.id, $0.displayName) })
                let paragraph = MeetingTranscriptExporter.displayParagraphs(for: [word], in: source)[0]
                for language in [PichiInterfaceLanguage.english, .russian] {
                    check(MeetingTranscriptExporter.speakerLabel(for: presentation, language: language) == firstAlias,
                          "Live labels show the plain resolved participant alias in both interface languages")
                    check(MeetingTranscriptExporter.speakerLabel(for: word, in: source, speakerNames: names,
                        language: language) == firstAlias, "History rows share the plain resolved participant alias")
                    check(MeetingTranscriptExporter.speakerLabel(for: paragraph, in: source, speakerNames: names,
                        language: language) == firstAlias, "History paragraphs share the plain participant alias")
                }
                check(MeetingTranscriptExporter.text(for: source) == "[00:00] \(firstAlias): \(word.text)",
                      "Text export does not prefix selected participants with an estimate qualifier")
                let renderedJSON = try MeetingTranscriptExporter.json(for: source)
                check(source == original && renderedJSON == originalJSON,
                      "Rendering plain labels preserves the session and JSON uncertainty evidence")
            }
            try source.reassignSegment(id: heuristic.id, to: second.id)
            let corrected = source.transcriptSegments[0]
            check(corrected.speakerAttribution == nil && corrected.speakerAttributionInference == nil,
                  "Manual corrections supersede automatic reading evidence through the existing operation")
            for language in [PichiInterfaceLanguage.english, .russian] {
                check(MeetingTranscriptExporter.speakerLabel(for: MeetingTranscriptExporter.speakerPresentation(
                    for: corrected, in: source), language: language) == secondAlias,
                      "A manual participant correction displays its new plain name in both languages")
            }
            check(MeetingTranscriptExporter.text(for: source) == "[00:00] \(secondAlias): \(corrected.text)",
                  "Text export reflects the corrected participant name")
        }
    }

    private static func checkReadingProjectionCache(
        template: MeetingSession, check: (Bool, String) -> Void
    ) async throws {
        let baseline = MeetingTranscriptExporter.ReadingInput(template)
        var unrelated = template
        unrelated.title = "A renamed meeting"
        unrelated.updatedAt = template.updatedAt.addingTimeInterval(1)
        unrelated.audioTracks[0].health.level = 0.7
        check(MeetingTranscriptExporter.ReadingInput(unrelated) == baseline,
              "Meters, title and checkpoint timestamps must not invalidate reading ownership")
        var renamed = template
        renamed.speakers[0].displayName = "Another manually named speaker"
        check(MeetingTranscriptExporter.ReadingInput(renamed) != baseline,
              "A user alias change must invalidate reading labels")
        var edited = template
        edited.transcriptSegments[0].text = "A corrected word"
        check(MeetingTranscriptExporter.ReadingInput(edited) != baseline,
              "A text edit must invalidate the reading document")
        var evidence = template
        evidence.transcriptSegments[0].attributionState = .timingUncertain
        check(MeetingTranscriptExporter.ReadingInput(evidence) != baseline,
              "A revised attribution state must invalidate reading ownership")
        evidence = template; evidence.transcriptCoverageGaps = []
        check(MeetingTranscriptExporter.ReadingInput(evidence) != baseline,
              "Coverage barriers participate in the reading cache identity")
        for count in [1_000, 10_000] {
            var source = template
            source.transcriptSegments = Array(template.transcriptSegments.prefix(count))
            let before = source
            let start = ProcessInfo.processInfo.systemUptime
            let result = try await MeetingTranscriptExporter.readingParagraphs(for: source)
            let elapsed = ProcessInfo.processInfo.systemUptime - start
            check(result.flatMap(\.segments) == source.transcriptSegments,
                  "Background reading projection must retain complete long-meeting history")
            check(result.first?.id == source.transcriptSegments.first?.id,
                  "Background projection keeps the first word's stable UI identity")
            check(source == before, "Background reading projection must not change source evidence")
            let repeated = try await MeetingTranscriptExporter.readingParagraphs(for: source)
            check(result == repeated, "A cached reading result must match repeat projection")
            print("Reading projection synthetic benchmark: words=\(count) seconds=\(elapsed) paragraphs=\(result.count)")
        }
        let cancelled = Task { try await MeetingTranscriptExporter.readingParagraphs(for: template) }
        cancelled.cancel()
        do { _ = try await cancelled.value; preconditionFailure("Cancelled reading projection published") }
        catch is CancellationError { check(true, "Cancelled reading projection is joined") }
    }

    private static func checkManualCorrectionOfProjectedOwner(
        template: MeetingSession, check: (Bool, String) -> Void
    ) throws {
        var source = template
        source.state = .completed
        source.endedAt = source.startedAt.addingTimeInterval(3)
        source.transcriptCoverageGaps = nil
        source.transcriptIsComplete = true
        let speakerA = source.speakers[0]
        var speakerB = speakerA
        speakerB.id = UUID()
        speakerB.displayName = "Intervening participant"
        source.speakers = [speakerA, speakerB]
        source.transcriptSegments = (0..<5).map { index in
            var word = template.transcriptSegments[0]
            word.id = UUID()
            word.start = .init(value: Int64(index * 4), timescale: 10)
            word.end = .init(value: Int64(index * 4 + 3), timescale: 10)
            word.text = "Synthetic \(index)"
            word.originalText = nil
            word.revision = 0
            word.speakerID = index == 2 ? speakerB.id : speakerA.id
            if index == 1 || index == 2 || index == 3 {
                if index != 2 { word.speakerID = nil }
                word.overlap = .ambiguous
                word.attributionState = .overlappingSpeakers
            }
            return word
        }
        let original = source
        let targetID = source.transcriptSegments[2].id
        let readingID = MeetingTranscriptExporter.speakerPresentations(in: source)[targetID]?.participantID
        check(readingID == speakerA.id && source.transcriptSegments[2].speakerID == speakerB.id,
              "A genuinely mixed intervening word can use the continuing reading owner before manual correction")

        try source.reassignSegment(id: targetID, to: speakerB.id, replacingReadingSpeakerID: readingID)
        let corrected = source.transcriptSegments[2]
        check(corrected.speakerID == speakerB.id && corrected.revision == 1,
              "Selecting the raw participant from another reading owner records a manual correction")
        check(corrected.speakerAttribution == nil && corrected.speakerAttributionInference == nil,
              "A legacy correction remains authoritative without fabricating modern provenance")
        check(MeetingTranscriptExporter.speakerPresentations(in: source)[targetID]?.participantID == speakerB.id,
              "The manual boundary prevents the reading projection from absorbing the corrected participant")
        for index in source.transcriptSegments.indices {
            let before = original.transcriptSegments[index], after = source.transcriptSegments[index]
            check(before.id == after.id && before.text == after.text && before.start == after.start
                  && before.end == after.end && before.nativeSpeakerAssignment == after.nativeSpeakerAssignment,
                  "Manual speaker correction preserves source text, member identity, native evidence and timing")
            if index != 2 {
                check(before == after, "A manual correction changes only its selected member")
            }
        }
        let once = source
        try source.reassignSegment(id: targetID, to: speakerB.id, replacingReadingSpeakerID: speakerB.id)
        check(source == once, "Repeating the same displayed participant selection is a no-op")
        var clean = original
        let cleanID = clean.transcriptSegments[0].id
        try clean.reassignSegment(id: cleanID, to: speakerA.id, replacingReadingSpeakerID: speakerA.id)
        check(clean == original, "A clean same-participant selection creates no pointless manual revision")
        let uncertainCases: [(MeetingTranscriptAttributionState?, MeetingTranscriptOverlap)] = [
            (.timingUncertain, .none), (.overlappingSpeakers, .none), (.unassigned, .none),
            (.assigned, .ambiguous), (.assigned, .overlapsOtherTrack), (nil, .ambiguous)
        ]
        for (state, overlap) in uncertainCases {
            var uncertain = original
            uncertain.transcriptSegments = [original.transcriptSegments[2]]
            uncertain.transcriptSegments[0].attributionState = state
            uncertain.transcriptSegments[0].overlap = overlap
            let raw = uncertain.transcriptSegments[0]
            let displayed = MeetingTranscriptExporter.speakerPresentations(in: uncertain)[raw.id]?.participantID
            try uncertain.reassignSegment(id: raw.id, to: speakerB.id, replacingReadingSpeakerID: displayed)
            let confirmed = uncertain.transcriptSegments[0]
            check(confirmed.speakerID == speakerB.id && confirmed.revision == 1
                  && confirmed.attributionState == .assigned && confirmed.overlap == .none,
                  "Same-ID manual confirmation clears legacy timing, attribution and overlap uncertainty")
            check(confirmed.id == raw.id && confirmed.text == raw.text && confirmed.start == raw.start
                  && confirmed.end == raw.end && confirmed.nativeSpeakerAssignment == raw.nativeSpeakerAssignment,
                  "Confirming an uncertain raw participant preserves source identity, text, timing and native evidence")
            let confirmedOnce = uncertain
            try uncertain.reassignSegment(id: raw.id, to: speakerB.id, replacingReadingSpeakerID: speakerB.id)
            check(uncertain == confirmedOnce, "Repeating an already confirmed uncertain participant is a no-op")
        }
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(source))
        check(restored == source
              && MeetingTranscriptExporter.speakerPresentations(in: restored)[targetID]?.participantID == speakerB.id,
              "The explicit correction and its reading boundary survive the production archive codec")
    }

    private static func checkUnmappedCanonicalReadingOwner(
        template: MeetingSession, check: (Bool, String) -> Void
    ) throws {
        var source = template
        source.state = .completed; source.endedAt = source.startedAt.addingTimeInterval(5)
        source.transcriptIsComplete = true; source.transcriptCoverageGaps = []
        let speakerA = source.speakers[0]
        var speakerB = speakerA; speakerB.id = UUID(); speakerB.displayName = "Other participant"
        source.speakers = [speakerA, speakerB]
        let epoch = MeetingAnalysisEpochID(trackID: source.audioTracks[0].id, ordinal: 0)
        let token = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "synthetic-a")
        func word(_ index: Int, start: Double, end: Double, owner: UUID?,
                  rule: MeetingSpeakerAttributionRule, revision: Int = 1) -> MeetingTranscriptSegment {
            let native: MeetingBackendSpeakerAssignment = owner == nil ? .unassigned : .assigned(token)
            let unitID = "synthetic-unmapped-\(index)"
            let decision = MeetingSpeakerAttributionDecision(unitID: unitID, rawAssignment: native,
                candidates: [], activeSupportSeconds: owner == nil ? 0 : end - start,
                simultaneousIntervals: [], relation: owner == nil ? .none : .single,
                selectedToken: token, rule: rule, cueUnitIDs: [], backgroundTokens: [],
                policyVersion: 2, policyFingerprint: "synthetic-unmapped-policy")
            return .init(id: UUID(), start: .init(value: Int64((start * 1000).rounded()), timescale: 1000),
                end: .init(value: Int64((end * 1000).rounded()), timescale: 1000),
                sourceTrackID: epoch.trackID, speakerID: owner, text: ["Before", "island", "after"][index % 3],
                revision: revision, status: .final, overlap: .none, completeness: .complete,
                attributionState: owner == nil ? .unassigned : .assigned, nativePrecision: .word,
                nativeUnitID: unitID, nativeSpeakerAssignment: native, nativeTiming: .init(start: start, end: end),
                speakerAttribution: .init(decision: decision, speakerIDs: owner.map { [token: $0] } ?? [:]))
        }
        for rule in [MeetingSpeakerAttributionRule.neighborAgreement, .incomingSpeaker,
                     .boundaryContinuation, .mainSpeakerContinuation] {
            for revision in [0, 1, 7] {
                source.transcriptSegments = [word(0, start: 2.4, end: 3.4, owner: speakerA.id, rule: .singleAcousticSupport),
                    word(1, start: 3.6, end: 3.68, owner: nil, rule: rule, revision: revision),
                    word(2, start: 3.72, end: 3.76, owner: speakerA.id, rule: .singleAcousticSupport)]
                let before = source, json = try MeetingTranscriptExporter.json(for: source)
                let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: source.transcriptSegments, in: source)
                check(paragraphs.count == 1 && paragraphs[0].segments == source.transcriptSegments,
                      "An already selected canonical voice maps to its independently admitted participant at any automatic revision")
                check(MeetingTranscriptExporter.speakerPresentations(in: source).values.allSatisfy { $0.participantID == speakerA.id },
                      "Live and saved reading share the completed canonical identity mapping")
                check(MeetingTranscriptExporter.text(for: source) == "[00:02] \(speakerA.displayName): Before island after",
                      "Text export has the same complete reading turn")
                let repeatedJSON = try MeetingTranscriptExporter.json(for: source)
                check(source == before && json == repeatedJSON,
                      "Reading preserves native IDs, wording, timing, revisions and JSON evidence")
            }
        }
        let baseline = source
        let islandID = source.transcriptSegments[1].id
        let oldArchive = try JSONEncoder().encode(baseline)
        let decodedOldArchive = try JSONDecoder().decode(MeetingSession.self, from: oldArchive)
        check(!String(decoding: oldArchive, as: UTF8.self).contains("isUserTextEdited")
              && decodedOldArchive.transcriptSegments.allSatisfy { $0.isUserTextEdited == nil },
              "Historical absent manual provenance decodes without manufacturing user edits")
        var manuallyEdited = baseline
        manuallyEdited.transcriptSegments[1].isUserTextEdited = true
        manuallyEdited.transcriptSegments[1].originalText = nil // PII has removed original wording.
        let manualArchive = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(manuallyEdited))
        check(manualArchive.transcriptSegments[1].isUserTextEdited == true
              && MeetingTranscriptExporter.speakerPresentations(in: manualArchive)[islandID]?.participantID == nil,
              "A durable text correction remains a reading boundary after PII and archive round-trip")
        let manualExport = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.json(for: manualArchive)) as! [String: Any]
        let manualExportSegments = manualExport["segments"] as! [[String: Any]]
        check(manualExportSegments[1]["isUserTextEdited"] as? Bool == true,
              "Canonical JSON export retains durable manual provenance")
        var compact = baseline
        for index in [0, 2] {
            compact.transcriptSegments[index].revision = 0
            let previous = compact.transcriptSegments[index]
            let decision = MeetingSpeakerAttributionDecision(unitID: previous.nativeUnitID!, rawAssignment: .assigned(token),
                candidates: [], activeSupportSeconds: 0.1, simultaneousIntervals: [], relation: .single,
                selectedToken: token, rule: .singleAcousticSupport, cueUnitIDs: [], backgroundTokens: [],
                policyVersion: 2, policyFingerprint: "synthetic-unmapped-policy")
            compact.transcriptSegments[index].speakerAttribution = .readingSummary(decision: decision,
                speakerIDs: [token: speakerA.id])
        }
        check(compact.transcriptSegments[0].speakerAttribution == nil
              && MeetingTranscriptExporter.speakerPresentations(in: compact)[islandID]?.participantID == speakerA.id,
              "Production compact native anchors establish identity without a redundant reading summary")
        for index in [0, 2] { compact.transcriptSegments[index].revision = 1 }
        check(MeetingTranscriptExporter.speakerPresentations(in: compact)[islandID]?.participantID == nil,
              "Revised nil-summary native assignments cannot masquerade as untouched acoustic anchors")
        func remainsUnmapped(_ value: MeetingSession, _ reason: String) {
            check(MeetingTranscriptExporter.speakerPresentations(in: value)[islandID]?.participantID == nil, reason)
        }
        for barrier in 0..<11 {
            var blocked = baseline
            switch barrier {
            case 0: blocked.transcriptSegments[1].originalText = "User's corrected wording"
            case 1: blocked.transcriptSegments[1].speakerAttribution = nil
            case 2: blocked.transcriptSegments[1].status = .provisional
            case 3: blocked.transcriptSegments[1].completeness = .incompleteTrack
            case 4: blocked.transcriptSegments[1].attributionState = .timingUncertain
            case 5: blocked.transcriptSegments[1].nativeUnitID = "different-unit"
            case 6: blocked.transcriptSegments[1].nativePrecision = .utterance
            case 7: blocked.transcriptSegments[1].sourceTrackID = UUID()
            case 8:
                blocked.transcriptSegments[0].speakerAttribution = nil
                blocked.transcriptSegments[2].speakerAttribution = nil
            case 9:
                blocked.transcriptSegments[0].originalText = "Manually corrected anchor"
                blocked.transcriptSegments[2].originalText = "Manually corrected anchor"
            default:
                // The same token mapped to two active identities is not a unique proof.
                blocked.transcriptSegments[2] = word(2, start: 3.72, end: 3.76, owner: speakerB.id,
                    rule: .singleAcousticSupport)
            }
            remainsUnmapped(blocked, "Manual, incomplete, ambiguous or incompatible evidence cannot repair a mapping (\(barrier))")
        }
        var corrected = baseline
        try corrected.reassignSegment(id: islandID, to: speakerB.id)
        check(MeetingTranscriptExporter.speakerPresentations(in: corrected)[islandID]?.participantID == speakerB.id,
              "Explicit reassignment supersedes the old canonical token and survives reading")
        var aliases = baseline
        aliases.speakers[0].mergedIntoSpeakerID = speakerB.id
        check(MeetingTranscriptExporter.speakerPresentations(in: aliases)[islandID]?.participantID == speakerB.id,
              "Unique canonical mapping resolves merged participant aliases to the active identity")
        var notChosen = baseline
        notChosen.transcriptSegments[1] = word(1, start: 3.6, end: 3.68, owner: nil, rule: .ambiguous)
        let ambiguousID = notChosen.transcriptSegments[1].id
        check(MeetingTranscriptExporter.speakerPresentations(in: notChosen)[ambiguousID]?.participantID == nil,
              "An ambiguous decision never becomes a known voice through identity mapping")
        var scoped = baseline
        let nextEpoch = MeetingAnalysisEpochID(trackID: epoch.trackID, ordinal: 1)
        let otherToken = MeetingBackendSpeakerToken(analysisEpochID: nextEpoch, label: token.label)
        for index in [0, 2] {
            let prior = scoped.transcriptSegments[index]
            let decision = MeetingSpeakerAttributionDecision(unitID: prior.nativeUnitID!, rawAssignment: .assigned(otherToken),
                candidates: [], activeSupportSeconds: 0.1, simultaneousIntervals: [], relation: .single,
                selectedToken: otherToken, rule: .singleAcousticSupport, cueUnitIDs: [], backgroundTokens: [],
                policyVersion: 2, policyFingerprint: "synthetic-unmapped-policy")
            scoped.transcriptSegments[index].nativeSpeakerAssignment = .assigned(otherToken)
            scoped.transcriptSegments[index].speakerAttribution = .init(decision: decision, speakerIDs: [otherToken: speakerA.id])
        }
        remainsUnmapped(scoped, "Equal slot labels in different analysis epochs are separate voices")
        for acousticRule in [MeetingSpeakerAttributionRule.residualSuppression, .acousticDominance] {
            for sameSpeaker in [false, true] {
                for mixed in [false, true] {
                    var contextual = baseline
                    let incoming = sameSpeaker ? speakerA : speakerB
                    let incomingToken = sameSpeaker ? token : MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "synthetic-b")
                    func acoustic(_ input: MeetingTranscriptSegment, owner: UUID,
                                  voice: MeetingBackendSpeakerToken) -> MeetingTranscriptSegment {
                        var value = input
                        value.speakerID = owner; value.nativeSpeakerAssignment = .assigned(voice)
                        value.overlap = .ambiguous; value.attributionState = .assigned
                        let duration = value.nativeTiming!.end - value.nativeTiming!.start
                        let support = MeetingSpeakerAttributionCandidateSupport(token: voice,
                            intervals: [.init(start: value.nativeTiming!.start, end: value.nativeTiming!.end)],
                            supportSeconds: duration, isSuppressed: false)
                        let decision = MeetingSpeakerAttributionDecision(unitID: value.nativeUnitID!, rawAssignment: .assigned(voice),
                            candidates: [support], activeSupportSeconds: duration, simultaneousIntervals: [], relation: .simultaneous,
                            selectedToken: voice, rule: acousticRule, cueUnitIDs: [], backgroundTokens: [],
                            policyVersion: 2, policyFingerprint: "synthetic-acoustic-rule-provenance")
                        value.speakerAttribution = .init(decision: decision, speakerIDs: [voice: owner])
                        return value
                    }
                    contextual.transcriptSegments[0] = acoustic(baseline.transcriptSegments[0], owner: speakerA.id, voice: token)
                    contextual.transcriptSegments[2] = acoustic(baseline.transcriptSegments[2], owner: incoming.id, voice: incomingToken)
                    contextual.transcriptSegments[1].revision = mixed ? 1 : 0
                    contextual.transcriptSegments[1].speakerAttribution = nil
                    if mixed {
                        let candidates = Array(Set([token, incomingToken]))
                        // Add a second original voice when matching neighbors keep the main turn.
                        let second = sameSpeaker ? MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "interrupter") : incomingToken
                        let raw = MeetingBackendSpeakerAssignment.ambiguous(Array(Set(candidates + [second])))
                        let decision = MeetingSpeakerAttributionDecision(unitID: contextual.transcriptSegments[1].nativeUnitID!, rawAssignment: raw,
                            candidates: [], activeSupportSeconds: 0.08, simultaneousIntervals: [], relation: .simultaneous,
                            selectedToken: nil, rule: .ambiguous, cueUnitIDs: [], backgroundTokens: [],
                            policyVersion: 2, policyFingerprint: "synthetic-acoustic-rule-provenance")
                        contextual.transcriptSegments[1].nativeSpeakerAssignment = raw
                        contextual.transcriptSegments[1].speakerAttribution = .init(decision: decision, speakerIDs: [:])
                        contextual.transcriptSegments[1].attributionState = .overlappingSpeakers
                        contextual.transcriptSegments[1].overlap = .ambiguous
                    }
                    let original = contextual
                    let expectedOwner: UUID? = incoming.id
                    check(MeetingTranscriptExporter.speakerPresentations(in: contextual)[islandID]?.participantID == expectedOwner,
                          "Independent acoustic selections can anchor bounded unresolved reading without swallowing a third voice")
                    let handoff = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: contextual)) as! [String: Any]
                    let handoffRows = handoff["segments"] as! [[String: Any]]
                    check(handoffRows.first(where: { ($0["text"] as? String)?.contains("island") == true })?["speakerID"] as? String
                          == expectedOwner?.uuidString,
                          "Portable handoff resolves an unmapped canonical member to its final contextual reading owner")
                    check(contextual == original, "Contextual reading cannot change original native evidence")
                    if sameSpeaker && mixed {
                        var reply = contextual
                        reply.transcriptSegments[1] = acoustic(reply.transcriptSegments[1], owner: speakerB.id,
                            voice: .init(analysisEpochID: epoch, label: "mixed-independent-b"))
                        check(MeetingTranscriptExporter.speakerPresentations(in: reply)[islandID]?.participantID == speakerA.id,
                              "An independently selected mixed B cannot erase the preceding A owner in A/B/A reading")
                        let handoff = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: reply)) as! [String: Any]
                        check((handoff["segments"] as! [[String: Any]]).allSatisfy { $0["speakerID"] as? String == speakerA.id.uuidString },
                              "Portable grouped interruptions follow the continuing UI owner rather than the raw word assignment")
                    }
                    if mixed && !sameSpeaker {
                        var thirdVoice = contextual
                        let originalSummary = thirdVoice.transcriptSegments[1].speakerAttribution!
                        let third = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "third-original-candidate")
                        let extra = MeetingSpeakerAttributionCandidateSupport(token: third, intervals: [.init(start: 3.6, end: 3.68)],
                            supportSeconds: 0.08, isSuppressed: false)
                        let decision = MeetingSpeakerAttributionDecision(unitID: originalSummary.unitID,
                            rawAssignment: originalSummary.rawAssignment, candidates: [extra], activeSupportSeconds: 0.08,
                            simultaneousIntervals: [], relation: .simultaneous, selectedToken: nil, rule: .ambiguous,
                            cueUnitIDs: [], backgroundTokens: [], policyVersion: 2, policyFingerprint: "synthetic-third-voice")
                        thirdVoice.transcriptSegments[1].speakerAttribution = .init(decision: decision, speakerIDs: [:])
                        check(MeetingTranscriptExporter.speakerPresentations(in: thirdVoice)[islandID]?.participantID == nil,
                              "Summary-only third voice evidence cannot disappear from neighbor admission")
                    }
                    if expectedOwner != nil {
                        for index in contextual.transcriptSegments.indices {
                            var edited = contextual; edited.transcriptSegments[index].isUserTextEdited = true
                            check(MeetingTranscriptExporter.speakerPresentations(in: edited)[islandID]?.participantID == nil,
                                  "Manual text edits block targets and acoustic anchor paths")
                        }
                        var conflict = contextual
                        conflict.transcriptSegments[1].attributionState = .timingUncertain
                        check(MeetingTranscriptExporter.speakerPresentations(in: conflict)[islandID]?.participantID == nil,
                              "Timing uncertainty remains a contextual boundary")
                        conflict = contextual
                        conflict.transcriptCoverageGaps = [.init(trackID: epoch.trackID, start: 3.4, end: 3.6, reason: .processingFailed)]
                        check(MeetingTranscriptExporter.speakerPresentations(in: conflict)[islandID]?.participantID == nil,
                              "Coverage gaps remain contextual boundaries")
                    }
                }
            }
        }
        // Independent native selection may precede participant admission just as a
        // contextual selection can. A distant exact-token anchor completes identity only;
        // no neighboring words, pauses or acoustic decisions are reinterpreted here.
        for rule in [MeetingSpeakerAttributionRule.singleAcousticSupport, .residualSuppression, .acousticDominance] {
            for revision in [0, 1, 7] {
                var selected = baseline
                selected.endedAt = selected.startedAt.addingTimeInterval(40)
                var target = word(1, start: 30, end: 31, owner: nil, rule: rule, revision: revision)
                func selection(_ raw: MeetingBackendSpeakerAssignment = .assigned(token),
                               chosen: MeetingBackendSpeakerToken = token,
                               rule: MeetingSpeakerAttributionRule = rule,
                               relation: MeetingSpeakerAttributionRelation = .single) -> MeetingTranscriptSpeakerAttribution {
                    let decision = MeetingSpeakerAttributionDecision(unitID: target.nativeUnitID!, rawAssignment: raw,
                        candidates: [], activeSupportSeconds: 1, simultaneousIntervals: [], relation: relation,
                        selectedToken: chosen, rule: rule, cueUnitIDs: [], backgroundTokens: [],
                        policyVersion: 2, policyFingerprint: "synthetic-independent-unmapped")
                    return .init(decision: decision, speakerIDs: [:])
                }
                target.nativeSpeakerAssignment = .assigned(token)
                target.speakerAttribution = selection()
                selected.transcriptSegments = [word(0, start: 0, end: 0.2, owner: speakerA.id, rule: .singleAcousticSupport), target]
                let original = selected, originalJSON = try MeetingTranscriptExporter.json(for: selected)
                check(MeetingTranscriptExporter.speakerPresentations(in: selected)[target.id]?.participantID == speakerA.id,
                      "An independently selected unmapped native token resolves from its unique exact-epoch identity without nearby cues")
                let handoff = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: selected)) as! [String: Any]
                check((handoff["segments"] as! [[String: Any]]).allSatisfy { $0["speakerID"] as? String == speakerA.id.uuidString },
                      "Protected export and reading use the same admitted native identity")
                let repeatedJSON = try MeetingTranscriptExporter.json(for: selected)
                check(selected == original && repeatedJSON == originalJSON,
                      "Completing participant identity preserves raw unit IDs, times, native assignment, decisions and canonical JSON")
                for negative in 0..<12 {
                    var blocked = selected
                    switch negative {
                    case 0: blocked.transcriptSegments[1].isUserTextEdited = true
                    case 1: blocked.transcriptSegments[1].speakerAttribution = nil
                    case 2: blocked.transcriptSegments[1].speakerAttribution = selection(rule: .conflict)
                    case 3: blocked.transcriptSegments[1].speakerAttribution = selection(rule: .barrier)
                    case 4: blocked.transcriptSegments[1].speakerAttribution = selection(relation: .conflict)
                    case 5: blocked.transcriptSegments[1].nativeSpeakerAssignment = .unassigned
                    case 6:
                        let mixed = MeetingBackendSpeakerAssignment.ambiguous([token, .init(analysisEpochID: epoch, label: "other")])
                        blocked.transcriptSegments[1].nativeSpeakerAssignment = mixed
                        blocked.transcriptSegments[1].speakerAttribution = selection(mixed)
                    case 7:
                        let otherEpoch = MeetingBackendSpeakerToken(analysisEpochID: .init(trackID: epoch.trackID, ordinal: 1), label: token.label)
                        blocked.transcriptSegments[1].nativeSpeakerAssignment = .assigned(otherEpoch)
                        blocked.transcriptSegments[1].speakerAttribution = selection(.assigned(otherEpoch), chosen: otherEpoch)
                    case 8:
                        blocked.transcriptSegments.append(word(2, start: 35, end: 36, owner: speakerB.id, rule: .singleAcousticSupport))
                    case 9:
                        blocked.transcriptSegments[0].revision = 1
                        blocked.transcriptSegments[0].speakerAttribution = nil
                    case 10: blocked.transcriptSegments[1].sourceTrackID = UUID()
                    default:
                        let otherToken = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "other-selected")
                        var otherAnchor = word(2, start: 35, end: 36, owner: speakerB.id, rule: .singleAcousticSupport)
                        otherAnchor.nativeSpeakerAssignment = .assigned(otherToken)
                        let decision = MeetingSpeakerAttributionDecision(unitID: otherAnchor.nativeUnitID!, rawAssignment: .assigned(otherToken),
                            candidates: [], activeSupportSeconds: 1, simultaneousIntervals: [], relation: .single,
                            selectedToken: otherToken, rule: .singleAcousticSupport, cueUnitIDs: [], backgroundTokens: [],
                            policyVersion: 2, policyFingerprint: "synthetic-other-independent-anchor")
                        otherAnchor.speakerAttribution = .init(decision: decision, speakerIDs: [otherToken: speakerB.id])
                        blocked.transcriptSegments.append(otherAnchor)
                        blocked.transcriptSegments[1].speakerAttribution = selection(chosen: otherToken)
                    }
                    check(MeetingTranscriptExporter.speakerPresentations(in: blocked)[target.id]?.participantID == nil,
                          "Manual, mismatched, ambiguous, conflicting or wrong-epoch native identity cannot be adopted (\(negative))")
                }
            }
        }
        let restored = try JSONDecoder().decode(MeetingSession.self, from: JSONEncoder().encode(baseline))
        check(MeetingTranscriptExporter.speakerPresentations(in: restored)[islandID]?.participantID == speakerA.id,
              "The canonical identity completion works after production archive decoding")
    }

    private static func checkNativeBoundaryReadingOwner(
        template: MeetingSession, check: (Bool, String) -> Void
    ) throws {
        var source = template
        source.state = .completed; source.endedAt = source.startedAt.addingTimeInterval(4)
        source.transcriptIsComplete = true; source.transcriptCoverageGaps = []
        let firstSpeaker = source.speakers[0]
        var nextSpeaker = firstSpeaker; nextSpeaker.id = UUID(); nextSpeaker.displayName = "Incoming voice"
        source.speakers = [firstSpeaker, nextSpeaker]
        let epoch = MeetingAnalysisEpochID(trackID: source.audioTracks[0].id, ordinal: 0)
        let previousToken = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "outgoing")
        let nextToken = MeetingBackendSpeakerToken(analysisEpochID: epoch, label: "incoming")
        func word(_ start: Double, _ end: Double, text: String, owner: UUID?,
                  token: MeetingBackendSpeakerToken?, revision: Int = 0) -> MeetingTranscriptSegment {
            .init(id: UUID(), start: .init(value: Int64((start * 1000).rounded()), timescale: 1000),
                end: .init(value: Int64((end * 1000).rounded()), timescale: 1000), sourceTrackID: epoch.trackID,
                speakerID: owner, text: text, revision: revision, status: .final, overlap: .none, completeness: .complete,
                attributionState: owner == nil ? .unassigned : .assigned, nativePrecision: .word,
                nativeUnitID: UUID().uuidString, nativeSpeakerAssignment: token.map { .assigned($0) } ?? .unassigned,
                nativeTiming: .init(start: start, end: end))
        }
        source.transcriptSegments = [word(0, 0.4, text: "Outgoing", owner: firstSpeaker.id, token: previousToken),
            word(0.48, 0.52, text: "М", owner: nil, token: nil),
            word(1.44, 1.7, text: "Incoming", owner: nextSpeaker.id, token: nextToken, revision: 3)]
        let baseline = source, islandID = source.transcriptSegments[1].id
        func owner(_ value: MeetingSession) -> UUID? {
            MeetingTranscriptExporter.speakerPresentations(in: value)[islandID]?.participantID
        }
        for state in [MeetingSessionState.recording, .completed] {
            var value = baseline; value.state = state
            let originalJSON = try MeetingTranscriptExporter.json(for: value)
            check(owner(value) == firstSpeaker.id,
                  "A tiny adjacent unsupported native tail stays in the outgoing live and final reading turn")
            let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: value.transcriptSegments, in: value)
            check(paragraphs.count == 2 && paragraphs[0].segments == Array(value.transcriptSegments.prefix(2)),
                  "The reading projection removes the isolated tiny-tail header without moving the next voice")
            if state == .completed {
                let handoff = try JSONSerialization.jsonObject(with: MeetingTranscriptExporter.protectedTranscriptJSON(for: value)) as! [String: Any]
                let rows = handoff["segments"] as! [[String: Any]]
                check(rows.count == 2 && rows[0]["speakerID"] as? String == firstSpeaker.id.uuidString,
                      "Protected handoff uses the same reading owner as the live and saved views")
            }
            check(try MeetingTranscriptExporter.json(for: value) == originalJSON && value.transcriptSegments == baseline.transcriptSegments,
                  "Boundary reading preserves original text, unit IDs, revisions, raw ownership and native word times")
        }
        for negative in 0..<23 {
            var value = baseline
            switch negative {
            case 0: value.transcriptSegments[0].revision = 1 // Could be a manual speaker correction.
            case 1: value.transcriptSegments[0].isUserTextEdited = true
            case 2: value.transcriptSegments[1].isUserTextEdited = true
            case 3: value.transcriptSegments[1].attributionState = .timingUncertain
            case 4: value.transcriptSegments[1].completeness = .incompleteTrack
            case 5: value.transcriptSegments[1].status = .provisional
            case 6: value.transcriptSegments[1].isLikelyEcho = true
            case 7: value.transcriptSegments[1].sourceTrackID = UUID()
            case 8:
                value.transcriptSegments[1].nativeTiming = .init(start: 0.48, end: 0.9)
                value.transcriptSegments[1].end = .init(value: 900, timescale: 1000)
            case 9:
                value.transcriptSegments[1].start = .init(value: 500, timescale: 1000)
                value.transcriptSegments[1].nativeTiming = .init(start: 0.5, end: 0.52)
            case 10:
                value.transcriptSegments[2].start = .init(value: 1200, timescale: 1000)
                value.transcriptSegments[2].nativeTiming = .init(start: 1.2, end: 1.7)
            case 11:
                value.transcriptSegments[2].nativeSpeakerAssignment = .assigned(.init(
                    analysisEpochID: .init(trackID: epoch.trackID, ordinal: 1), label: "new-epoch"))
            case 12:
                value.transcriptCoverageGaps = [.init(trackID: epoch.trackID, start: 0.4, end: 0.48, reason: .processingFailed)]
            case 13: value.transcriptSegments[1].overlap = .ambiguous
            case 14: value.transcriptSegments[2].status = .provisional
            case 15: value.transcriptSegments[2].completeness = .incompleteTrack
            case 16: value.transcriptSegments[2].attributionState = .timingUncertain
            case 17: value.transcriptSegments[2].isUserTextEdited = true
            case 18: value.transcriptSegments[2].nativeTiming = .init(start: 1.5, end: 1.7)
            case 19:
                let next = value.transcriptSegments[2]
                let decision = MeetingSpeakerAttributionDecision(unitID: next.nativeUnitID!, rawAssignment: .assigned(nextToken),
                    candidates: [], activeSupportSeconds: 0, simultaneousIntervals: [], relation: .none,
                    selectedToken: nil, rule: .barrier, cueUnitIDs: [], backgroundTokens: [],
                    policyVersion: 2, policyFingerprint: "synthetic-following-quarantine")
                value.transcriptSegments[2].speakerAttribution = .init(decision: decision, speakerIDs: [:])
            case 20:
                value.transcriptCoverageGaps = [.init(trackID: epoch.trackID, start: 0.6, end: 0.8, reason: .processingFailed)]
            case 21: value.transcriptSegments[2].overlap = .ambiguous
            default: value.transcriptSegments[2].speakerID = nil
            }
            check(owner(value) == nil, "Unsafe or manually revised native boundaries keep their uncertainty (\(negative))")
        }
        var independentInterjection = baseline
        independentInterjection.transcriptSegments[1].speakerID = nextSpeaker.id
        independentInterjection.transcriptSegments[1].attributionState = .assigned
        independentInterjection.transcriptSegments[1].nativeSpeakerAssignment = .assigned(nextToken)
        check(owner(independentInterjection) == nextSpeaker.id,
              "A real independently assigned brief other voice is never swallowed as a residual")
        var nearbyIncoming = baseline
        nearbyIncoming.transcriptSegments[2].revision = 0
        nearbyIncoming.transcriptSegments[2].start = .init(value: 1200, timescale: 1000)
        nearbyIncoming.transcriptSegments[2].nativeTiming = .init(start: 1.2, end: 1.7)
        check(owner(nearbyIncoming) == nextSpeaker.id, "Existing bounded incoming-voice admission remains authoritative")
        var punctuation = baseline
        punctuation.transcriptSegments.removeLast()
        punctuation.transcriptSegments[0].end = .init(value: 400, timescale: 1000)
        punctuation.transcriptSegments[1].text = "."
        punctuation.transcriptSegments[1].start = .init(value: 3280, timescale: 1000)
        punctuation.transcriptSegments[1].end = .init(value: 3300, timescale: 1000)
        punctuation.transcriptSegments[1].nativeTiming = .init(start: 3.28, end: 3.3)
        let before = punctuation
        check(owner(punctuation) == firstSpeaker.id && MeetingTranscriptExporter.displayParagraphs(
            for: punctuation.transcriptSegments, in: punctuation).count == 1,
              "Unsupported terminal punctuation attaches typographically without a separate unknown-voice paragraph")
        check(punctuation == before && punctuation.transcriptSegments[1].speakerID == nil,
              "Attaching punctuation never claims a native speaker or changes silence timing")
        for symbol in ["(", "[", "«", "-", "\"", "🙂"] {
            var opener = baseline; opener.transcriptSegments[1].text = symbol
            check(owner(opener) == nil, "Short nonlexical openers or symbols cannot enter the lexical residual path")
        }
        var shortDigit = baseline; shortDigit.transcriptSegments[1].text = "7"
        check(owner(shortDigit) == firstSpeaker.id, "A bounded numeric lexical residual can remain with its adjacent outgoing voice")
        for symbol in ["(", "[", "«", "-", "\"", "7", "🙂"] {
            var opener = punctuation; opener.transcriptSegments[1].text = symbol
            check(owner(opener) == nil, "An opening quote/bracket, separator, symbol or number cannot masquerade as trailing punctuation")
        }
        punctuation.transcriptSegments[1].start = .init(value: 5000, timescale: 1000)
        punctuation.transcriptSegments[1].end = .init(value: 5020, timescale: 1000)
        punctuation.transcriptSegments[1].nativeTiming = .init(start: 5, end: 5.02)
        check(owner(punctuation) == nil, "Punctuation cannot bridge an unbounded silence")
        var barrier = baseline
        let unresolved = barrier.transcriptSegments[1]
        let decision = MeetingSpeakerAttributionDecision(unitID: unresolved.nativeUnitID!, rawAssignment: .unassigned,
            candidates: [], activeSupportSeconds: 0, simultaneousIntervals: [], relation: .none,
            selectedToken: nil, rule: .barrier, cueUnitIDs: [], backgroundTokens: [],
            policyVersion: 2, policyFingerprint: "synthetic-quarantine-barrier")
        barrier.transcriptSegments[1].speakerAttribution = .init(decision: decision, speakerIDs: [:])
        check(owner(barrier) == nil, "Explicit quarantine barriers remain visible rather than being hidden by reading attachment")
    }

    private static func indexIDs(at url: URL) throws -> [String] {
        let object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        guard let ids = object?["sessionIDs"] as? [String] else { preconditionFailure("Missing index IDs") }
        return ids
    }
}
