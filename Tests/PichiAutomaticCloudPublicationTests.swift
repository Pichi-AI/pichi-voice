import Foundation

extension PichiPublicationOutboxTests {
    /// Real facade, admissions, encrypted stores and retry/cleanup state. The server,
    /// deletion owner and account are synthetic; no model, Keychain, socket or UI runs.
    static func checkAutomaticCloudPublication(root: URL) async throws -> Int {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previous = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(previous) }
        PrivateProfileStorage.select(try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root))
        var checks = 0
        var lastCheckpoint = "setup"
        defer { FileHandle.standardError.write(Data("Automatic fixture last checkpoint: \(lastCheckpoint)\n".utf8)) }
        func check(_ condition: Bool, _ message: String) {
            precondition(condition, message); checks += 1; lastCheckpoint = message
        }
        func wait(_ condition: @MainActor () async throws -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(12))
            while !(try await condition()) {
                guard ContinuousClock.now < deadline else { throw AutomaticFixtureFailure.timeout }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let configuration = LegacyAccountConfiguration(apiBaseURL: URL(string: "https://automatic.example")!, bundleIdentifier: "ai.synthetic.voice")
        let transport = AutomaticFixtureTransport(configuration: configuration)
        let profiles = PrivateProfileService()
        try profiles.configure(isBusy: { false }, prepare: {}, activate: { _ in })
        let account = AccountSessionService(configuration: nil, browser: AutomaticFixtureBrowser(),
            transport: AutomaticFixtureOIDC(), credentials: AutomaticFixtureCredentials(),
            lifecycle: profiles, legacyConfiguration: configuration, legacyTransport: transport)
        var meetings = PrivateProfileMeetingStore()
        let cleanup = AutomaticCleanupOwner(store: meetings)
        let keyOwner = AutomaticCipherOwner()
        func makeService(_ store: PrivateProfileMeetingStore) -> PichiCloudPublicationService {
            .init(account: account, meetings: store, profiles: profiles,
                recordingCipher: { try await keyOwner.load($0) },
                localEncryptionRequested: { _ in keyOwner.localEncryptionEnabled },
                deleteAcceptedRecording: { try await cleanup.delete($0, owner: $1, expectedSourceSHA256: $2) })
        }
        var service = makeService(meetings)
        try await service.install()
        try await service.restoreEncryptedLocalStorage()
        check(keyOwner.loads == 0, "Cold startup with no ciphertext does not manufacture a local key")
        let guest = PrivateProfileStorage.current
        let ordinary = try await service.prepareCapturePersistencePolicy()
        check(ordinary == .init() && keyOwner.loads == 0, "Default guest recording does not create a local key or grant delivery")
        keyOwner.localEncryptionEnabled = true
        keyOwner.holdNextLoad = true
        let startingGuest = Task { try await service.prepareCapturePersistencePolicy() }
        try await wait { keyOwner.isHolding }
        keyOwner.localEncryptionEnabled = false
        keyOwner.releaseLoad()
        let guestPolicy = try await startingGuest.value
        check(guestPolicy.requiresEncryptedPersistence,
              "Changing the checkbox during key preflight cannot downgrade the admitted security snapshot")
        keyOwner.localEncryptionEnabled = true
        check(guestPolicy.requiresEncryptedPersistence && !guestPolicy.requiresPIIRedaction,
              "Guest-local encryption is independent of account consent and PII cleanup")
        var guestConfiguration = MeetingCaptureConfiguration(mode: .inRoom, title: "Guest confidential Ёё",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"))
        guestConfiguration.audioStorageMode = .memoryOnly; guestConfiguration.requiresEncryptedPersistence = true
        var guestSource = MeetingSession(configuration: guestConfiguration,
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil))
        guestSource.profileOwnership = try await meetings.captureOwnership(for: guestSource.id, configuration: guestConfiguration)
        try await meetings.create(guestSource)
        let guestFile = guest.rootDirectory.appendingPathComponent("Meetings/" + guestSource.id.uuidString + "/session.json")
        let guestBytes = try Data(contentsOf: guestFile)
        check(MeetingRecordingCipher.isEncryptedEnvelope(guestBytes)
            && guestBytes.range(of: Data("Guest confidential".utf8)) == nil, "Guest transcript/title reaches disk only as authenticated ciphertext")
        check(try await meetings.loadTranscript(id: guestSource.id)?.isLocalContentConcealed == true,
              "Trusted local reads retain a per-record concealed-content marker")
        check(!manager.fileExists(atPath: guest.rootDirectory.appendingPathComponent("CloudPublication").path),
              "Guest encryption creates no account queue, receipt or upload consent")
        await service.shutdown(); meetings = PrivateProfileMeetingStore(); cleanup.store = meetings
        service = makeService(meetings); try await service.install()
        do { _ = try await meetings.loadTranscript(id: guestSource.id); check(false, "A missing guest key cannot decode stored ciphertext") }
        catch MeetingRecordingCipher.Failure.unavailableKey { check(true, "Relaunch never treats existing ciphertext as plaintext without its key") }
        keyOwner.holdNextLoad = true
        let racingGuest = Task { try await service.prepareCapturePersistencePolicy() }
        try await wait { keyOwner.isHolding }
        let otherGuest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(),
            legacyRootDirectory: root.appendingPathComponent("other-generation"))
        PrivateProfileStorage.select(otherGuest)
        keyOwner.releaseLoad()
        do { _ = try await racingGuest.value; check(false, "A changed profile cannot commit the earlier key admission") }
        catch AccountError.staleOperation { check(true, "Profile/generation replacement cancels encryption preflight without plaintext fallback") }
        check(!manager.fileExists(atPath: otherGuest.rootDirectory.appendingPathComponent("Meetings").path),
              "The stale preflight writes no manifest into the replacement profile")
        PrivateProfileStorage.select(guest)
        keyOwner.locked = true
        do { try await service.restoreEncryptedLocalStorage(); check(false, "Locked guest keys cannot restore ciphertext after relaunch") }
        catch is ProtectedDataAccessError { check(true, "Locked guest key failure never falls back to plaintext") }
        keyOwner.locked = false; keyOwner.missing = true
        do { try await service.restoreEncryptedLocalStorage(); check(false, "A missing retained guest key cannot be replaced") }
        catch MeetingRecordingCipher.Failure.unavailableKey {
            check((try Data(contentsOf: guestFile)) == guestBytes, "Key loss preserves ciphertext without a replacement key or plaintext write")
        }
        keyOwner.missing = false; try await service.restoreEncryptedLocalStorage()
        check(try await meetings.loadTranscript(id: guestSource.id)?.title == guestSource.title,
              "An unlocked cold guest restores its original key before any new capture is prepared")
        keyOwner.localEncryptionEnabled = false
        let disabledGuest = try await service.prepareCapturePersistencePolicy()
        let retainedGuestBytes = try Data(contentsOf: guestFile)
        check(disabledGuest == .init() && retainedGuestBytes == guestBytes,
              "Changing future encryption policy does not rewrite or decrypt existing history")
        await service.shutdown(); meetings = PrivateProfileMeetingStore(); cleanup.store = meetings
        service = makeService(meetings); try await service.install()
        keyOwner.localEncryptionEnabled = true; keyOwner.holdNextLoad = true
        let guestBeforeLogin = Task { try await service.prepareCapturePersistencePolicy() }
        try await wait { keyOwner.isHolding }
        let signingIn = Task { await account.signIn(email: "a@synthetic.example", password: "synthetic-only") }
        try await wait { profiles.isTransitioning }
        keyOwner.releaseLoad()
        do { _ = try await guestBeforeLogin.value; check(false, "Login cannot complete an older guest key admission") }
        catch is CancellationError { check(true, "The real profile transition cancels and joins its pending guest encryption preflight") }
        catch AccountError.staleOperation { check(true, "The committed owner fence rejects the older guest preflight") }
        await signingIn.value
        keyOwner.localEncryptionEnabled = false; keyOwner.loads = 0
        check(try await service.prepareAutomaticCapture() == false && keyOwner.loads == 0,
              "Signed-in accounts without a selected workspace keep ordinary local recording available")
        check(try await meetings.loadTranscript(id: guestSource.id) == nil,
              "A new login cannot adopt or expose an earlier guest's encrypted source")
        do { try await service.refresh(); check(false, "An unselected publication workspace remains an explicit configuration error") }
        catch AccountError.workspaceUnavailable { check(true, "Workspace configuration failure is typed without constructing storage") }
        let unselectedRoot = PrivateProfileStorage.current.rootDirectory
        check(service.snapshot.availability == .unconfigured
            && !manager.fileExists(atPath: unselectedRoot.appendingPathComponent("CloudPublication").path),
              "An unselected workspace cannot construct an invalid outbox or consent directory")
        await account.retireLegacySession()
        check(profiles.isPrivateDataVisible && PrivateProfileStorage.current.isGuest && account.presentationError == nil,
              "A no-workspace account retires through the existing profile lifecycle without a hidden cleanup failure")
        check(try await service.prepareCapturePersistencePolicy() == .init(),
              "A committed logout reopens ordinary guest capture instead of retaining the old closing latch")
        await account.signIn(email: "a@synthetic.example", password: "synthetic-only")
        try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        check(try await service.prepareAutomaticCapture() == false, "Automatic capture is off before explicit future consent")
        try await service.setDeleteLocalAfterAcceptance(true)
        check(keyOwner.loads == 0, "Reading disabled policy or changing retention does not create an encryption key")
        keyOwner.locked = true
        do { try await service.setCloudSyncEnabled(true); check(false, "A locked keystore cannot admit automatic capture") }
        catch is ProtectedDataAccessError {
            check(service.snapshot.availability == .protectedDataUnavailable && keyOwner.loads == 0,
                  "Device lock preserves explicit consent as an automatic unlock wait, without a replacement key")
        }
        keyOwner.locked = false
        await service.notifyServerAvailabilityChanged()
        check(try await service.prepareAutomaticCapture(), "Automatic admission resumes after unlock and preflights its cipher and queue")
        let profile = PrivateProfileStorage.current
        let cipher = try MeetingRecordingCipher(profileID: profile.id, key: Data(repeating: 0xA7, count: 32))
        func box() -> PichiPublicationOutboxStore { .init(profile: profile, destination: .legacy(configuration), cipher: cipher) }
        // Inspect atomic snapshots without opening a second live outbox actor: a new
        // actor intentionally performs crash recovery and must not race the active owner.
        func record(_ id: UUID) throws -> PichiPublicationOutboxRecord? {
            for leaf in ["settled", "pending"] {
                let file = profile.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/" + leaf + "/" + id.uuidString.lowercased() + ".json")
                guard manager.fileExists(atPath: file.path) else { continue }
                let bytes: Data
                do { bytes = try Data(contentsOf: file) }
                catch CocoaError.fileReadNoSuchFile { continue }
                let json = MeetingRecordingCipher.isEncryptedEnvelope(bytes)
                    ? try cipher.open(bytes, sessionID: id, artifactKind: .publicationOutbox, maximumPlaintextBytes: 1_048_576) : bytes
                return try JSONDecoder().decode(PichiPublicationOutboxRecord.self, from: json)
            }
            return nil
        }

        func createSource() async throws -> MeetingSession {
            var configuration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic automatic Ёё", languageCode: "ru",
                microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"), timestampDefaultTitle: true)
            configuration.audioStorageMode = .memoryOnly; configuration.piiRedactionEnabled = true
            configuration.requiresEncryptedPersistence = true
            let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil)
            var session = MeetingSession(configuration: configuration,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
            session.state = .recording; session.audioStorageMode = .memoryOnly; session.piiRedactionEnabled = true
            session.profileOwnership = try await meetings.captureOwnership(for: session.id, configuration: configuration)
            let track = UUID(), speaker = UUID()
            session.audioTracks = [.init(id: track, kind: .microphone, sourceIdentifier: "synthetic", sourceDisplayName: "Synthetic",
                format: nil, timebase: timebase, health: .waiting, chunks: [])]
            try await meetings.create(session)
            session.state = .completed; session.endedAt = session.startedAt.addingTimeInterval(5); session.transcriptIsComplete = true
            session.speakers = [.init(id: speaker, displayName: "Unidentified participant", diarizationClusterID: nil,
                trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
            session.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1), end: .init(value: 5, timescale: 1),
                sourceTrackID: track, speakerID: speaker, text: "Synthetic protected [PERSON].", revision: 0,
                status: .final, overlap: .none, completeness: .complete, attributionState: .assigned)]
            try await meetings.save(session)
            return session
        }
        await transport.setOffline(true)
        let source = try await createSource()
        try await wait { try record(source.id)?.state == .retryScheduled }
        let manifest = profile.directory("Meetings").appendingPathComponent(source.id.uuidString + "/session.json")
        let queueFile = profile.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/pending/" + source.id.uuidString.lowercased() + ".json")
        check(MeetingRecordingCipher.isEncryptedEnvelope(try Data(contentsOf: manifest)), "Offline recording manifest is authenticated ciphertext")
        check(MeetingRecordingCipher.isEncryptedEnvelope(try Data(contentsOf: queueFile)), "Offline outbox is ciphertext from its first admission")
        check(await transport.postCount() == 0 && cleanup.calls == 0, "Offline server validation sends no source and deletes nothing")
        check(service.snapshot.automaticRecordingIDs.contains(source.id) && service.snapshot.deleteLocalAfterAcceptance,
              "Current account projection identifies automatic records and its future retention setting")
        var maintained = try await meetings.loadTranscript(id: source.id)!
        let acceptedLocalRevision = try PichiProtectedPublicationSource.localFingerprint(for: maintained)
        maintained.updatedAt = maintained.updatedAt.addingTimeInterval(90)
        maintained.retention.audioDeletedAt = maintained.endedAt
        maintained.retention.retainAudioUntil = nil
        try await meetings.save(maintained)
        check(try record(source.id)?.localSourceSHA256 == acceptedLocalRevision
            && PichiProtectedPublicationSource.localFingerprint(for: maintained) == acceptedLocalRevision,
              "Post-freeze audio retention and update-clock maintenance cannot strand accepted local cleanup")
        check(maintained.displayTitle(language: .english) != maintained.displayTitle(language: .russian),
              "The deletion fixture actually has presentation-dependent generated titles")
        var renamed = maintained; renamed.title += " user edit"; renamed.defaultTitleBase = nil
        check(try PichiProtectedPublicationSource.localFingerprint(for: renamed) != acceptedLocalRevision,
              "A real title edit remains newer user work despite normalized maintenance metadata")
        await transport.setOffline(false); await transport.loseNextResponse()
        await service.notifyServerAvailabilityChanged()
        try await wait {
            let count = await transport.postCount(), record = try record(source.id)
            return count == 1 && record?.state == .retryScheduled
        }
        await service.notifySceneActive(true)
        try await wait { try record(source.id)?.state == .acceptedCleanupPending }
        let replay = await transport.replaySummary(for: source.id)
        check(replay.posts == 2 && replay.rows == 1 && replay.identical, "Lost response repeats immutable bytes into one accepted source")
        let posted = try JSONSerialization.jsonObject(with: replay.body) as! [String: Any]
        check(posted["assessmentMode"] as? String == "account_context" && posted["userId"] == nil
            && posted["criteriaIds"] == nil && posted["analysisId"] == nil && posted["managerSpeakerId"] == nil,
              "Unknown speaker still uploads under server-owned context without inferred employee or forced criteria")
        check(try await meetings.loadTranscript(id: source.id) != nil, "A busy deletion owner retains the encrypted accepted source")
        let acceptedPendingBytes = try Data(contentsOf: queueFile)
        let postsBeforeRestart = await transport.postCount()
        await service.shutdown()
        meetings = PrivateProfileMeetingStore(); cleanup.store = meetings
        service = makeService(meetings); try await service.install(); try await service.activateCurrentProfile()
        check(await transport.postCount() == postsBeforeRestart, "Restarting delivery with a durable receipt never re-enters POST")
        cleanup.busy = false; cleanup.locked = true
        await service.notifySceneActive(true)
        try await wait { service.snapshot.availability == .protectedDataUnavailable }
        check(try record(source.id)?.state == .acceptedCleanupPending, "Lock during local removal retains accepted cleanup state without another upload")
        cleanup.locked = false; cleanup.failAfterDeleteOnce = true
        await service.notifySceneActive(true)
        try await wait {
            let local = try await meetings.loadTranscript(id: source.id), record = try record(source.id)
            return local == nil && record?.state == .acceptedCleanupPending
        }
        check(try record(source.id)?.receipt != nil, "Failure after source deletion retains the durable accepted cleanup intent")
        await service.notifySceneActive(true)
        try await wait { try record(source.id)?.sourcePurged == true }
        check(try await meetings.loadTranscript(id: source.id) == nil, "Existing owner deletion removes the local recording after accepted receipt")
        let compact = try record(source.id)!
        let compactFile = profile.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/settled/" + source.id.uuidString.lowercased() + ".json")
        let compactJSON = try cipher.open(Data(contentsOf: compactFile), sessionID: source.id,
            artifactKind: .publicationOutbox, maximumPlaintextBytes: 1_048_576)
        let compactObject = try JSONSerialization.jsonObject(with: compactJSON) as! [String: Any]
        check(compact.transcriptBytes == nil && compactObject["transcriptBytes"] == nil
            && !String(decoding: compactJSON, as: UTF8.self).contains("Synthetic protected"),
              "Settled receipt retains no transcript, title or participant names")
        await transport.finishAnalysis(for: source.id)
        try await service.reconcile(source.id)
        if case .accepted(let receipt) = try await service.status(for: source.id) {
            check(receipt.analysisState == .succeeded && receipt.accountContextPolicyCriteriaIDs == [],
                  "Purged source reconciles genuine no-criteria summary through its semantic fingerprint")
        } else { check(false, "Purged accepted source remains visible as receipt only") }
        check(await transport.postCount() == postsBeforeRestart, "Cleanup and later analysis status never repeat upload or billing")
        await service.pause(); await service.shutdown()
        // The paused service still owns local receipt cleanup. Join it before corrupting
        // durable snapshots for isolated cold-recovery and key-authentication probes.
        try acceptedPendingBytes.write(to: queueFile)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: queueFile.path)
        let orphan = profile.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/.write-" + UUID().uuidString + ".tmp")
        try acceptedPendingBytes.write(to: orphan)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: orphan.path)
        let cold = box()
        let recoveredPending = try await cold.pendingRecords()
        check(!manager.fileExists(atPath: orphan.path), "Recovery removes a validated orphan transaction copy containing accepted source ciphertext")
        check(recoveredPending.allSatisfy { $0.sessionID != source.id }
            && !manager.fileExists(atPath: queueFile.path), "Compacted settled receipt wins over an interrupted encrypted full pending copy")
        check(try PichiPublicationOutboxStore.hasEncryptedPersistenceData(in: profile), "Header-only preflight detects retained ciphertext before key loading")
        let withoutKey = PichiPublicationOutboxStore(profile: profile, destination: .legacy(configuration))
        do { _ = try await withoutKey.record(id: source.id); check(false, "Missing key must fail closed") }
        catch let failure as PichiPublicationOutboxFailure { check(failure == .unavailable, "Missing key cannot decode or silently replace queued data") }
        let ciphertext = try Data(contentsOf: compactFile)
        let wrong = try MeetingRecordingCipher(profileID: profile.id, key: Data(repeating: 0xA8, count: 32))
        do {
            _ = try await PichiPublicationOutboxStore(profile: profile, destination: .legacy(configuration), cipher: wrong).record(id: source.id)
            check(false, "Wrong key cannot decode a receipt")
        } catch let failure as PichiPublicationOutboxFailure { check(failure == .corruptRecord, "Authenticated envelope rejects a wrong key") }
        check(try Data(contentsOf: compactFile) == ciphertext, "Failed authentication preserves original ciphertext")
        try compactJSON.write(to: compactFile)
        do { _ = try await box().record(id: source.id); check(false, "Encrypted record cannot downgrade to plaintext") }
        catch let failure as PichiPublicationOutboxFailure { check(failure == .invalidStorage, "A known encrypted-mode record rejects plaintext fallback") }
        try ciphertext.write(to: compactFile)
        meetings = PrivateProfileMeetingStore(); cleanup.store = meetings
        service = makeService(meetings); try await service.install()
        try await service.resume()

        await transport.setAccountThrottled(true, retryAfter: "0")
        let repeatedlyThrottled = try await createSource()
        for attempt in 1...6 {
            try await wait { try record(repeatedlyThrottled.id)?.state == .retryScheduled
                && record(repeatedlyThrottled.id)?.attemptCount == attempt }
            check(try record(repeatedlyThrottled.id)?.pauseReason == nil,
                  "Account validation throttling remains retryable instead of requiring authentication")
            if attempt < 6 { await service.notifySceneActive(true) }
        }
        let retainedThrottledSource = try await meetings.loadTranscript(id: repeatedlyThrottled.id)
        check(try record(repeatedlyThrottled.id)?.receipt == nil && retainedThrottledSource != nil,
              "Repeated temporary validation cannot erase the encrypted pending source")
        await transport.setAccountThrottled(false)
        await service.notifySceneActive(true)
        try await wait { try record(repeatedlyThrottled.id)?.sourcePurged == true }
        check(try record(repeatedlyThrottled.id)?.receipt != nil,
              "A successful foreground validation resumes the same source and receipt cleanup")
        await transport.setAccountThrottled(true, retryAfter: "2")
        let serverPaced = try await createSource()
        try await wait { try record(serverPaced.id)?.state == .retryScheduled }
        let serverFloor = try record(serverPaced.id)?.serverRetryNotBefore
        check(serverFloor != nil && (serverFloor?.timeIntervalSinceNow ?? 0) > 0,
              "Validation Retry-After is retained as a durable lower bound")
        await transport.setAccountThrottled(false)
        let postsBeforePacedWake = await transport.postCount()
        await service.notifySceneActive(true)
        check(await transport.postCount() == postsBeforePacedWake,
              "A foreground wake cannot bypass the server's Retry-After lower bound")
        try await Task.sleep(for: .seconds(2.1))
        await service.notifySceneActive(true)
        try await wait { try record(serverPaced.id)?.sourcePurged == true }
        check(try record(serverPaced.id)?.receipt != nil, "Server-paced validation recovers after its lower bound")

        await transport.holdNextResponse()
        let editedSource = try await createSource()
        try await wait { await transport.isHolding() }
        var edit = editedSource; edit.transcriptSegments[0].text = "New protected manual edit [PERSON]."
        try await meetings.save(edit)
        await transport.releaseResponse()
        try await wait { try record(editedSource.id)?.receiptPauseReason == .sourceConflict }
        check(try await meetings.loadTranscript(id: editedSource.id)?.transcriptSegments[0].text == edit.transcriptSegments[0].text,
              "Editing during upload preserves newer encrypted local work instead of deleting it")
        cleanup.editBeforeValidationOnce = true
        let lateEdited = try await createSource()
        try await wait { try record(lateEdited.id)?.receiptPauseReason == .sourceConflict }
        check(try await meetings.loadTranscript(id: lateEdited.id)?.transcriptSegments[0].text == "Late protected edit at deletion boundary [PERSON].",
              "The deletion owner receives the frozen digest and rejects work changed after publication preflight")
        cleanup.busy = true
        let acceptedBeforeOff = try await createSource()
        try await wait { try record(acceptedBeforeOff.id)?.state == .acceptedCleanupPending }
        let postedBeforeOff = await transport.postCount()
        try await service.setCloudSyncEnabled(false)
        cleanup.busy = false
        await service.notifySceneActive(true)
        try await wait { try record(acceptedBeforeOff.id)?.sourcePurged == true }
        let postedAfterOff = await transport.postCount()
        check(!service.snapshot.cloudSyncEnabled && postedAfterOff == postedBeforeOff,
              "Disabled publication still completes previously authorized local cleanup without another network upload")
        try await service.setDeleteLocalAfterAcceptance(false)
        try await service.setCloudSyncEnabled(true)
        let acceptedWithRetentionOff = try await createSource()
        try await wait { try record(acceptedWithRetentionOff.id)?.state == .accepted }
        check(try await meetings.loadTranscript(id: acceptedWithRetentionOff.id) != nil,
              "A server receipt preserves local data while the current deletion checkbox is OFF")
        let postsBeforeRetentionOn = await transport.postCount()
        try await service.setCloudSyncEnabled(false)
        try await service.setDeleteLocalAfterAcceptance(true)
        try await wait { try record(acceptedWithRetentionOff.id)?.sourcePurged == true }
        check(await transport.postCount() == postsBeforeRetentionOn && !service.snapshot.cloudSyncEnabled,
              "Enabling current cleanup reconciles an older managed receipt even with new uploads disabled")
        try await service.setCloudSyncEnabled(true)
        await transport.holdNextResponse()
        let admittedBeforeRetentionOff = try await createSource()
        try await wait { await transport.isHolding() }
        let turnOff = Task { try await service.setDeleteLocalAfterAcceptance(false) }
        try await wait { !service.snapshot.deleteLocalAfterAcceptance }
        await transport.releaseResponse()
        try await turnOff.value
        await service.notifySceneActive(true)
        try await wait { try record(admittedBeforeRetentionOff.id)?.state == .accepted }
        check(try await meetings.loadTranscript(id: admittedBeforeRetentionOff.id) != nil,
              "OFF joins in-flight work and prevents a frozen ON admission from deleting on its later receipt")
        let postsBeforeReenable = await transport.postCount()
        try await service.setDeleteLocalAfterAcceptance(true)
        try await wait { try record(admittedBeforeRetentionOff.id)?.sourcePurged == true }
        check(await transport.postCount() == postsBeforeReenable,
              "Re-enabling cleanup compacts the existing durable receipt without another POST")
        let knownAutomaticIDs: Set<UUID> = [source.id, editedSource.id, lateEdited.id, acceptedBeforeOff.id,
            acceptedWithRetentionOff.id, admittedBeforeRetentionOff.id, repeatedlyThrottled.id, serverPaced.id]
        var coherentProjection = true
        for _ in 0..<130 {
            _ = try await service.status(for: UUID())
            let visible = Set(service.snapshot.items.keys)
            coherentProjection = coherentProjection && service.snapshot.automaticRecordingIDs == knownAutomaticIDs.intersection(visible)
        }
        check(coherentProjection && service.snapshot.items.count <= 128,
              "Bounded status and automatic-mode projections stay coherent when old history rows are evicted")
        await account.logout(); await account.signIn(email: "b@synthetic.example", password: "synthetic-only")
        try await account.selectWorkspace(organizationID: "17", workspaceID: "9"); try await service.refresh()
        check(!service.snapshot.cloudSyncEnabled && !service.snapshot.deleteLocalAfterAcceptance
            && service.snapshot.automaticRecordingIDs.isEmpty, "Account B inherits no A delivery/retention policy or receipt projection")
        await service.shutdown(); await account.shutdown()
        return checks
    }
}

private enum AutomaticFixtureFailure: Error { case timeout, busy }
@MainActor private final class AutomaticCipherOwner {
    var locked = false; var missing = false; var loads = 0; var holdNextLoad = false
    var localEncryptionEnabled = false
    private(set) var isHolding = false
    private var loadGate: CheckedContinuation<Void, Never>?
    func releaseLoad() { loadGate?.resume(); loadGate = nil }
    func load(_ profile: PrivateProfileSnapshot) async throws -> MeetingRecordingCipher {
        if holdNextLoad {
            holdNextLoad = false; isHolding = true
            await withCheckedContinuation { loadGate = $0 }
            isHolding = false
        }
        try Task.checkCancellation()
        if locked { throw ProtectedDataAccessError.temporarilyUnavailable }
        if missing { throw MeetingRecordingCipher.Failure.unavailableKey }
        loads += 1
        return try MeetingRecordingCipher(profileID: profile.id, key: Data(repeating: 0xA7, count: 32))
    }
}
@MainActor private final class AutomaticCleanupOwner {
    var store: PrivateProfileMeetingStore; var busy = true; var calls = 0; var failAfterDeleteOnce = false; var locked = false; var editBeforeValidationOnce = false
    init(store: PrivateProfileMeetingStore) { self.store = store }
    func delete(_ id: UUID, owner: MeetingProfileOwnership, expectedSourceSHA256: String) async throws {
        try Task.checkCancellation()
        calls += 1
        if busy { throw AutomaticFixtureFailure.busy }
        if locked { throw ProtectedDataAccessError.temporarilyUnavailable }
        if editBeforeValidationOnce, var current = try await store.loadTranscript(id: id) {
            editBeforeValidationOnce = false
            current.transcriptSegments[0].text = "Late protected edit at deletion boundary [PERSON]."
            try await store.save(current)
        }
        if let current = try await store.loadTranscript(id: id) {
            guard try PichiProtectedPublicationSource.localFingerprint(for: current) == expectedSourceSHA256 else {
                throw PichiPublicationOutboxFailure.receiptConflict
            }
        }
        try await store.delete(id: id, expectedOwnership: owner)
        if failAfterDeleteOnce { failAfterDeleteOnce = false; throw AutomaticFixtureFailure.busy }
    }
}
@MainActor private final class AutomaticFixtureBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw AccountError.unconfigured }
    func cancel() {}
}
private actor AutomaticFixtureCredentials: AccountCredentialStoring {
    func load() async throws -> AccountGrant? { nil }
    func save(_ grant: AccountGrant) async throws { preconditionFailure("Legacy does not use OIDC grants") }
    func clear() async throws {}
}
private actor AutomaticFixtureOIDC: AccountTransporting {
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL { throw AccountError.unconfigured }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func account(accessToken: String) async throws -> AccountSnapshot { throw AccountError.unconfigured }
    func revoke(refreshToken: String) async throws {}
}
private actor AutomaticFixtureTransport: LegacyAccountTransporting {
    let configuration: LegacyAccountConfiguration
    private var userID = "123", offline = false, loseNext = false, holdNext = false, holding = false
    private var accountThrottled = false
    private var accountRetryAfter: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var rows: [String: [String: Any]] = [:]
    private var bodies: [String: [Data]] = [:]
    init(configuration: LegacyAccountConfiguration) { self.configuration = configuration }
    func login(email: String, password: String, captchaToken: String?) async throws -> AccountSnapshot {
        userID = email.hasPrefix("b@") ? "124" : "123"; return try await account()
    }
    func account() async throws -> AccountSnapshot {
        if offline { throw LegacyAccountConnectivityFailure.unavailable }
        if accountThrottled { throw LegacyAccountConnectivityFailure.rateLimited(retryAfter: accountRetryAfter) }
        return .init(schemaVersion: 1, account: .init(id: userID, displayName: "Synthetic", email: nil),
            identity: .init(issuer: "", subject: "", legacyOrigin: configuration.apiBaseURL.absoluteString),
            organizations: [.init(id: "17", name: "Synthetic", workspaces: [.init(id: "9", name: "Synthetic", capabilities: ["recordings:import"])])],
            activeOrganizationID: "17")
    }
    func switchOrganization(_ organizationID: String) async throws -> AccountSnapshot { try await account() }
    func logout() async throws {}
    func clearSession() async {}
    func shutdown() async {}
    func setOffline(_ value: Bool) { offline = value }
    func setAccountThrottled(_ value: Bool, retryAfter: String? = nil) {
        accountThrottled = value; accountRetryAfter = retryAfter
    }
    func loseNextResponse() { loseNext = true }
    func holdNextResponse() { holdNext = true }
    func isHolding() -> Bool { holding }
    func releaseResponse() { holding = false; gate?.resume(); gate = nil }
    func postCount() -> Int { bodies.values.reduce(0) { $0 + $1.count } }
    func replaySummary(for id: UUID) -> (posts: Int, rows: Int, identical: Bool, body: Data) {
        let key = id.uuidString.lowercased(), list = bodies[id.uuidString.lowercased()] ?? []
        return (list.count, rows[key] == nil ? 0 : 1, Set(list).count == 1, list.first ?? Data())
    }
    func finishAnalysis(for id: UUID) {
        let key = id.uuidString.lowercased()
        rows[key]?["importBillingStatus"] = "not_required"; rows[key]?["summary"] = "Synthetic account-context summary"
        rows[key]?["evaluationResults"] = ["noCriteria": true, "evaluations": []]
    }
    func perform(_ request: URLRequest) async throws -> LegacyAccountHTTPResponse {
        if offline { throw LegacyAccountConnectivityFailure.unavailable }
        let row: [String: Any]
        if request.url!.path == "/api/recordings/transcript" {
            let body = request.httpBody!, posted = try JSONSerialization.jsonObject(with: body) as! [String: Any]
            let source = posted["transcriptImport"] as! [String: Any], key = (source["sessionID"] as! String).lowercased()
            bodies[key, default: []].append(body)
            if rows[key] == nil {
                var accepted = posted
                accepted["id"] = 100 + rows.count; accepted["uploadedById"] = Int(userID)!; accepted["userId"] = Int(userID)!
                accepted["managerSpeakerId"] = posted["managerSpeakerId"] ?? NSNull(); accepted["analysisId"] = NSNull()
                accepted["criteriaIds"] = []; accepted["assessmentPolicyCriteriaIds"] = []
                accepted["importSourceId"] = key; accepted["transcriptionStatus"] = "completed"
                accepted["evaluationResults"] = NSNull(); accepted["importBillingStatus"] = "uncertain"
                rows[key] = accepted
            }
            if holdNext { holdNext = false; holding = true; await withCheckedContinuation { gate = $0 } }
            if loseNext { loseNext = false; throw LegacyAccountConnectivityFailure.unavailable }
            row = rows[key]!
        } else if request.url!.path.hasPrefix("/api/recordings/"),
                  let id = Int(request.url!.lastPathComponent), let existing = rows.values.first(where: { $0["id"] as? Int == id }) {
            row = existing
        } else { throw AccountError.invalidConfiguration }
        return .init(status: 200, body: try JSONSerialization.data(withJSONObject: row), retryAfter: nil)
    }
}
