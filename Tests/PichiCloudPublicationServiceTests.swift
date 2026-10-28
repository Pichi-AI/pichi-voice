import Foundation

extension PichiPublicationOutboxTests {
    /// Test-only composition owns N1/N2 setup over an isolated synthetic root. This is
    /// observer/queue evidence, not readiness of the application's private source inventory.
    static func checkCloudPublicationService(root: URL) async throws -> Int {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previous = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(previous) }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func wait(_ condition: @MainActor () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(8)
            while !(try await condition()) {
                guard Date() < deadline else { throw FacadeProbeFailure.timeout }
                try await Task.sleep(for: .milliseconds(20))
            }
        }
        let configuration = AccountConfiguration(issuer: URL(string: "https://identity.example/realms/pichi")!,
            apiBaseURL: URL(string: "https://api.example")!, clientID: "synthetic-native",
            apiAudience: "synthetic-api", bundleIdentifier: "ai.synthetic.voice")
        let profiles = PrivateProfileService()
        try profiles.configure(isBusy: { false }, prepare: {}, activate: { _ in })
        let identity = FacadeSyntheticAccountTransport(configuration: configuration)
        let account = AccountSessionService(configuration: configuration, browser: FacadeSyntheticBrowser(),
            transport: identity, credentials: FacadeSyntheticCredentials(), lifecycle: profiles)
        let http = FacadeFixtureHTTP()
        let meetings = PrivateProfileMeetingStore.shared
        let localEncryption = FacadeLocalEncryptionChoice()
        let service = PichiCloudPublicationService(account: account, meetings: meetings, profiles: profiles, http: http,
            recordingCipher: { try MeetingRecordingCipher(profileID: $0.id, key: Data(repeating: 0x67, count: 32)) },
            localEncryptionRequested: { _ in localEncryption.enabled },
            deleteAcceptedRecording: { id, owner, digest in
                try await meetings.delete(id: id, expectedOwnership: owner, validating: { source in
                    try Task.checkCancellation()
                    guard try PichiProtectedPublicationSource.localFingerprint(for: source) == digest else {
                        throw PichiPublicationOutboxFailure.receiptConflict
                    }
                })
            })
        try await service.install()
        do { try await service.install(); check(false, "A second observer cannot be installed") }
        catch let error as AccountError { check(error == .busy, "Observer/participant composition is singular") }
        let participantID = UUID()
        func capture(text: String = "Synthetic protected contact [PERSON].", empty: Bool = false, encrypted: Bool = false,
                     beforeSave: (() async throws -> Void)? = nil) async throws -> MeetingSession {
            let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil)
            let captureConfiguration = MeetingCaptureConfiguration(mode: .inRoom, title: "Synthetic queued source Ёё",
                languageCode: "ru", microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic"),
                audioStorageMode: .memoryOnly, piiRedactionEnabled: true, requiresEncryptedPersistence: encrypted)
            var session = MeetingSession(configuration: captureConfiguration,
                startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
            session.state = .recording
            session.profileOwnership = try await meetings.captureOwnership(for: session.id, configuration: captureConfiguration)
            let track = UUID()
            session.audioTracks = [.init(id: track, kind: .microphone, sourceIdentifier: "synthetic",
                sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: [])]
            try await meetings.create(session)
            if let beforeSave { try await beforeSave() }
            session.state = .completed; session.endedAt = session.startedAt.addingTimeInterval(5)
            session.transcriptIsComplete = true
            var speaker = MeetingSessionSpeaker(id: participantID, displayName: "Synthetic represented speaker",
                diarizationClusterID: nil, trackKind: .microphone, isLocalUser: false, identityCandidates: [])
            speaker.identityIsProvisional = true
            session.speakers = [speaker]
            session.transcriptSegments = empty ? [] : [.init(id: UUID(), start: .init(value: 0, timescale: 1),
                end: .init(value: 5, timescale: 1), sourceTrackID: track, speakerID: participantID,
                text: text, revision: 0, status: .final, overlap: .none, completeness: .complete, attributionState: .assigned)]
            try await meetings.save(session)
            return session
        }
        func durable(_ profile: PrivateProfileSnapshot, id: UUID, settled: Bool) throws -> PichiPublicationOutboxRecord {
            let file = profile.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/" + (settled ? "settled/" : "pending/") + id.uuidString.lowercased() + ".json")
            let bytes = try Data(contentsOf: file)
            let cipher = try MeetingRecordingCipher(profileID: profile.id, key: Data(repeating: 0x67, count: 32))
            let plaintext = MeetingRecordingCipher.isEncryptedEnvelope(bytes)
                ? try cipher.open(bytes, sessionID: id, artifactKind: .publicationOutbox, maximumPlaintextBytes: 1_048_576) : bytes
            return try JSONDecoder().decode(PichiPublicationOutboxRecord.self, from: plaintext)
        }
        let guestSource = try await capture()
        check(!manager.fileExists(atPath: root.appendingPathComponent("CloudPublication").path), "Guest callbacks do not create account publication storage")
        let guestFile = root.appendingPathComponent("Meetings/" + guestSource.id.uuidString + "/session.json")
        let guestBytes = try Data(contentsOf: guestFile)
        await account.signIn(); try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        try await service.refresh()
        let profileA = PrivateProfileStorage.current
        check(!service.snapshot.cloudSyncEnabled, "Fresh signed-in workspace consent defaults off")
        let guestHidden = try await meetings.load(id: guestSource.id) == nil
        let guestPreserved = try Data(contentsOf: guestFile) == guestBytes
        check(guestHidden && guestPreserved,
              "Signing in neither exposes nor migrates guest history")
        let localOnly = try await capture()
        check(try await service.status(for: localOnly.id) == .localOnly, "A capture without consent is durably local-only")
        try await service.setCloudSyncEnabled(true)
        await service.pause()
        check(try await service.status(for: localOnly.id) == .localOnly, "Opt-in after completion cannot grant historical consent")
        do { try await service.send(localOnly.id); check(false, "Historical local-only source cannot be admitted") }
        catch let error as PichiPublicationOutboxFailure { check(error == .notAdmitted, "Manual send cannot bypass recording-time policy") }

        let first = try await capture()
        let firstStatus = try await service.status(for: first.id)
        let beforeResumeCount = await http.count()
        check(firstStatus == .queued && beforeResumeCount == 0,
              "Completion observer queues locally and starts no network")
        let firstRecord = try durable(profileA, id: first.id, settled: false)
        try await meetings.save(first)
        check(try durable(profileA, id: first.id, settled: false).operationID == firstRecord.operationID,
              "Repeated persisted-source notifications deduplicate durably")
        let empty = try await capture(empty: true)
        check(try await service.status(for: empty.id) == .withheld(.emptyTranscript), "Measured-complete empty source is visibly withheld before transport")
        await http.loseNextResponse()
        try await service.resume()
        try await wait {
            if case .retryScheduled = try await service.status(for: first.id) { return true }; return false
        }
        let lost = try durable(profileA, id: first.id, settled: false)
        check(lost.operationID == firstRecord.operationID && lost.attemptCount == 1 && lost.transcriptBytes == firstRecord.transcriptBytes,
              "Lost acceptance response preserves exact durable operation and source")
        try await service.retry(first.id)
        try await wait { if case .accepted = try await service.status(for: first.id) { return true }; return false }
        let accepted = try durable(profileA, id: first.id, settled: true)
        check(accepted.operationID == firstRecord.operationID && accepted.attemptCount == 2, "Lost-response replay never mints another operation")
        check(await http.identicalPosts(), "HTTP replay reuses exact multipart bytes/key after server acceptance")
        let patchCount = await http.count(method: "PATCH")
        let options = try await service.assessmentOptions(for: first.id, limit: 2)
        check(options.context.accountID == "user-A" && options.context.organizationID == "17" && options.context.workspaceID == "9",
              "Assessment options are bound to the current authorized account and workspace")
        check(options.participants.map(\.id) == [participantID] && options.canResolvePending
              && options.currentAssessment.participantID == nil && options.currentAssessment.criteriaIDs.isEmpty,
              "Options offer represented participants without inventing an initial assessment")
        let nextOptions = try await service.assessmentOptions(for: first.id, cursor: options.criteria.pagination.nextCursor, limit: 2)
        check(options.criteria.data.map(\.id) == ["31", "32"] && nextOptions.criteria.data.map(\.id) == ["33"]
              && !nextOptions.criteria.pagination.hasMore && nextOptions.criteria.pagination.nextCursor == nil,
              "Criteria pages are fetched explicitly and retain their opaque cursor")
        let afterOptions = try durable(profileA, id: first.id, settled: true)
        let optionsPatchCount = await http.count(method: "PATCH")
        check(afterOptions.operationID == firstRecord.operationID && afterOptions.transcriptBytes == firstRecord.transcriptBytes
              && afterOptions.originalAssessment.participantID == nil && optionsPatchCount == patchCount,
              "Fetching options preserves source identity and never automatically patches")
        for control in ["OFF", "logout"] {
            await http.holdNextRequest("OPTIONS")
            var escaped = false, controlReturned = false
            let fetching = Task { let page = try await service.assessmentOptions(for: first.id); escaped = true; return page }
            try await wait { await http.isHeld() }
            let closing = Task {
                if control == "OFF" { try await service.setCloudSyncEnabled(false) }
                else { await account.logout() }
                controlReturned = true
            }
            try await wait { service.snapshot.availability == (control == "OFF" ? .pausing : .profileUnavailable) }
            check(!controlReturned && !escaped, control + " waits for the held options request and hides stale options")
            await http.release(); try await closing.value
            switch await fetching.result {
            case .success: check(false, "Cancelled options cannot escape after " + control)
            case .failure: check(!escaped, "Joined " + control + " cancels the complete typed options command")
            }
            if control == "OFF" {
                do { _ = try await service.assessmentOptions(for: first.id); check(false, "OFF must block options transport") }
                catch let error as PichiCloudPublicationControlFailure { check(error == .cloudSyncDisabled, "OFF blocks paged options through the shared admission gate") }
                try await service.setCloudSyncEnabled(true)
            } else {
                await account.signIn(); try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
                try await service.activateCurrentProfile()
            }
        }
        try await service.resolveAssessment(first.id, participantID: participantID, criteriaIDs: ["31"])
        try await service.reconcile(first.id)
        if case let .accepted(receipt) = try await service.status(for: first.id) {
            check(receipt.analysisState == .queued, "Explicit PATCH and GET update analysis separately from accepted upload")
        } else { check(false, "Accepted source must retain its receipt") }
        let boundOptions = try await service.assessmentOptions(for: first.id, limit: 2)
        check(!boundOptions.canResolvePending && boundOptions.currentAssessment.participantID == participantID
              && boundOptions.currentAssessment.criteriaIDs == ["31"], "Options preserve the effective explicit binding separately from the original POST")
        let afterPatch = try durable(profileA, id: first.id, settled: true)
        check(afterPatch.transcriptBytes == firstRecord.transcriptBytes && afterPatch.sourceSHA256 == firstRecord.sourceSHA256
              && afterPatch.originalAssessment.participantID == nil, "Assessment resolution never rewrites original POST fingerprint")
        await http.failNextRequest("GET", status: 404, code: "RESOURCE_NOT_FOUND")
        do { try await service.reconcile(first.id); check(false, "Purged import status must require review") }
        catch let error as PichiPublicationRemoteFailure { check(error.action == .pauseForReceiptReview, "Purge GET404 is a receipt review response") }
        let reviewedReceipt = try durable(profileA, id: first.id, settled: true)
        let reopenedReceipt = PichiPublicationOutboxStore(profile: profileA, configuration: configuration)
        check(try await reopenedReceipt.record(id: first.id)?.receiptPauseReason == .receiptReview
              && reviewedReceipt.operationID == firstRecord.operationID && reviewedReceipt.transcriptBytes == firstRecord.transcriptBytes,
              "Receipt review persists across a new store without erasing acceptance or creating another operation")
        if case let .acceptedNeedsReview(receipt, reason) = try await service.status(for: first.id) {
            check(receipt == reviewedReceipt.receipt && reason == .receiptReview, "Shared status separates retained acceptance from receipt review")
        } else { check(false, "Receipt review must be visible") }
        try await service.reconcile(first.id)
        check(try durable(profileA, id: first.id, settled: true).receiptPauseReason == nil, "A successful explicit GET clears the receipt review overlay")
        await http.failNextRequest("PATCH", status: 429, code: "RATE_LIMITED")
        do { try await service.resolveAssessment(first.id, participantID: participantID, criteriaIDs: ["31"]); check(false, "PATCH429 must remain visible") }
        catch let error as PichiPublicationRemoteFailure { check(error.action == .boundedRetry, "Assessment throttling retains bounded retry classification") }
        check(try durable(profileA, id: first.id, settled: true).receiptPauseReason == .transportUnavailable,
              "PATCH transport review is durable while original upload remains accepted")
        try await service.reconcile(first.id)
        await http.finishNextStatus()
        try await wait {
            if case let .accepted(receipt) = try await service.status(for: first.id) { return receipt.analysisState == .succeeded }; return false
        }
        check(true, "The bounded worker reconciles observed queued analysis to completion without reimport")
        await http.holdNextRequest("GET")
        let heldStatus = Task { try await service.reconcile(first.id) }
        try await wait { await http.isHeld() }
        let beforeConcurrent = await http.count()
        do { try await service.reconcile(first.id); check(false, "Duplicate GET must not race receipt completion") }
        catch let error as AccountError { check(error == .busy, "A current receipt request excludes another GET for that record") }
        do { try await service.resolveAssessment(first.id, participantID: participantID, criteriaIDs: ["31"]); check(false, "PATCH must not race a receipt GET") }
        catch let error as AccountError { check(error == .busy, "A current receipt request excludes PATCH for that record") }
        do { _ = try await service.assessmentOptions(for: first.id); check(false, "Options must not race a receipt GET") }
        catch let error as AccountError { check(error == .busy, "Options share the same per-record request lease") }
        check(await http.count() == beforeConcurrent, "Rejected concurrent receipt requests never reach transport")
        await http.release(); try await heldStatus.value

        await service.pause()
        let cancelledSource = try await capture()
        let beforeCancel = try durable(profileA, id: cancelledSource.id, settled: false)
        await http.holdNextPost()
        var cancelledReturned = false
        let cancelledSend = Task { try await service.send(cancelledSource.id); cancelledReturned = true }
        try await wait { await http.isHeld() }
        cancelledSend.cancel()
        try await Task.sleep(for: .milliseconds(50))
        check(!cancelledReturned, "A cancelled manual send still joins its uncooperative concrete request")
        await http.release(); _ = await cancelledSend.result
        let afterCancel = try durable(profileA, id: cancelledSource.id, settled: false)
        check(afterCancel.state == .paused && afterCancel.pauseReason == .uncertainDelivery
              && afterCancel.operationID == beforeCancel.operationID && afterCancel.transcriptBytes == beforeCancel.transcriptBytes,
              "Individual cancellation durably releases sending state without replacing owner, key or bytes")
        try await service.retry(cancelledSource.id)
        let afterCancelledRetry = try durable(profileA, id: cancelledSource.id, settled: true)
        check(afterCancelledRetry.operationID == beforeCancel.operationID && afterCancelledRetry.attemptCount == 2,
              "Cancelled delivery can replay in the same retained service without restart")
        for (status, code) in [(429, "RATE_LIMITED"), (503, "INTERNAL_ERROR")] {
            let pacedSource = try await capture()
            let before = try durable(profileA, id: pacedSource.id, settled: false)
            await http.holdNextPost()
            await http.failHeldPost(status: status, code: code)
            let pacedSend = Task { try await service.send(pacedSource.id) }
            try await wait { await http.isHeld() }
            pacedSend.cancel()
            await http.release(); _ = await pacedSend.result
            let paced = try durable(profileA, id: pacedSource.id, settled: false)
            check(paced.state == .retryScheduled && paced.retryNotBefore != nil && paced.receipt == nil,
                  "A returned OIDC retry response keeps its durable floor despite racing cancellation")
            check(paced.operationID == before.operationID && paced.transcriptBytes == before.transcriptBytes,
                  "Safe OIDC failure extraction cannot replace frozen payload or authorize a receipt")
            let beforeEarlyRetry = await http.count(method: "POST")
            try await service.retry(pacedSource.id)
            check(await http.count(method: "POST") == beforeEarlyRetry,
                  "An explicit OIDC retry cannot send before the persisted server/backoff deadline")
        }
        let diskFailureSource = try await capture()
        let beforeDiskFailure = try durable(profileA, id: diskFailureSource.id, settled: false)
        await http.holdNextPost()
        let failingSave = Task { try await service.send(diskFailureSource.id) }
        try await wait { await http.isHeld() }
        let outboxRoot = profileA.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1")
        let unwritable = [outboxRoot.appendingPathComponent("pending"), outboxRoot.appendingPathComponent("settled")]
        for directory in unwritable { try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path) }
        await http.release(); try await failingSave.value
        check(service.snapshot.availability == .storageUnavailable && service.snapshot.cloudSyncEnabled,
              "A failed acceptance/recovery write visibly closes delivery without claiming consent changed")
        let failedRequestCount = await http.count()
        do { try await service.reconcile(first.id); check(false, "Disk failure must close current network admission") }
        catch let error as PichiCloudPublicationControlFailure { check(error == .cloudSyncDisabled, "Storage failure blocks further transport") }
        check(await http.count() == failedRequestCount, "No request escapes the storage-failure admission latch")
        for directory in unwritable { try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }
        try await service.setCloudSyncEnabled(true)
        try await wait { if case .accepted = try await service.status(for: diskFailureSource.id) { return true }; return false }
        let repaired = try durable(profileA, id: diskFailureSource.id, settled: true)
        check(repaired.operationID == beforeDiskFailure.operationID && repaired.transcriptBytes == beforeDiskFailure.transcriptBytes,
              "Explicit recovery after repairing disk joins work and replays the same uncertain operation")
        let pauseConsentRoot = profileA.rootDirectory.appendingPathComponent("CloudPublication/Consent")
        try manager.setAttributes([.posixPermissions: 0o500], ofItemAtPath: pauseConsentRoot.path)
        await service.pause()
        check(service.snapshot.availability == .storageUnavailable, "A failed scoped pause write stays visibly unavailable")
        do { try await service.reconcile(first.id); check(false, "Failed pause persistence must close transport admission") }
        catch let error as PichiCloudPublicationControlFailure { check(error == .cloudSyncDisabled, "Failed pause persistence cannot leave manual network admission open") }
        try manager.setAttributes([.posixPermissions: 0o700], ofItemAtPath: pauseConsentRoot.path)
        try await service.setCloudSyncEnabled(true)

        await service.pause()
        let paused = try await capture()
        let requestCount = await http.count()
        try await service.activateCurrentProfile()
        try await Task.sleep(for: .milliseconds(100))
        check(await http.count() == requestCount && service.snapshot.availability == .paused,
              "Persisted user pause survives profile activation without implicit resume")
        let otherPaused = try await capture()
        try await service.send(paused.id)
        let selectedStatus = try await service.status(for: paused.id), otherStatus = try await service.status(for: otherPaused.id)
        check(selectedStatus != .queued && otherStatus == .queued && service.snapshot.availability == .paused,
              "Manual per-record send does not resume unrelated paused work or clear persistent pause")
        try await service.resume()
        try await wait { if case .accepted = try await service.status(for: otherPaused.id) { return true }; return false }

        await http.holdNextPost()
        let disabledDuringTransfer = try await capture()
        try await wait { await http.isHeld() }
        var offReturned = false
        let disabling = Task { try await service.setCloudSyncEnabled(false); offReturned = true }
        try await wait { service.snapshot.availability == .pausing }
        check(!offReturned && service.snapshot.cloudSyncEnabled,
              "OFF is visibly pending until an uncooperative concrete transfer joins")
        let capturedDuringOff = try await capture()
        check(try await service.status(for: capturedDuringOff.id) == .localOnly,
              "OFF intent closes future-capture policy before the durable setting write")
        await http.release(); try await disabling.value
        check(offReturned && !service.snapshot.cloudSyncEnabled, "OFF returns only after scoped disable/pause is durable and transport joined")
        let offCount = await http.count()
        do { try await service.reconcile(first.id); check(false, "OFF must close GET status too") }
        catch let error as PichiCloudPublicationControlFailure { check(error == .cloudSyncDisabled, "OFF blocks GET without deleting accepted receipt") }
        do { try await service.resolveAssessment(first.id, participantID: participantID, criteriaIDs: ["31"]); check(false, "OFF must close PATCH too") }
        catch let error as PichiCloudPublicationControlFailure { check(error == .cloudSyncDisabled, "OFF blocks explicit assessment transport") }
        check(await http.count() == offCount, "No POST/GET/PATCH escapes after OFF completion")
        try await service.setCloudSyncEnabled(true)
        try await wait { if case .accepted = try await service.status(for: disabledDuringTransfer.id) { return true }; return false }
        check(try await service.status(for: capturedDuringOff.id) == .localOnly, "ON resumes prior admissions without claiming captures made during OFF")

        for method in ["GET", "PATCH"] {
            await http.holdNextRequest(method)
            let inFlight = Task {
                if method == "GET" { try await service.reconcile(first.id) }
                else { try await service.resolveAssessment(first.id, participantID: participantID, criteriaIDs: ["31"]) }
            }
            try await wait { await http.isHeld() }
            var stopped = false
            let offCommand = Task { try await service.setCloudSyncEnabled(false); stopped = true }
            try await wait { service.snapshot.availability == .pausing }
            check(!stopped && service.snapshot.cloudSyncEnabled, "OFF joins an already active " + method + " before publishing disabled")
            await http.release(); try await offCommand.value; _ = await inFlight.result
            let receiptRetained = try durable(profileA, id: first.id, settled: true).receipt != nil
            check(stopped && !service.snapshot.cloudSyncEnabled && receiptRetained,
                  "Joined " + method + " cancellation preserves accepted cloud history")
            try await service.setCloudSyncEnabled(true)
        }

        await service.pause()
        let frozenConsent = try await capture(beforeSave: { try await service.setCloudSyncEnabled(false) })
        let off = try await capture()
        let frozenStatus = try await service.status(for: frozenConsent.id)
        let offStatus = try await service.status(for: off.id)
        check(frozenStatus == .paused(.userRequested) && offStatus == .localOnly,
              "A later consent toggle affects only future captures")
        await http.holdNextPost()
        try await service.setCloudSyncEnabled(true)
        check(try await service.status(for: off.id) == .localOnly, "Re-enabling consent cannot discover old off-policy captures")
        try await wait { await http.isHeld() }
        let beforeLogout = try durable(profileA, id: frozenConsent.id, settled: false)
        var logoutReturned = false
        let logout = Task { await account.logout(); logoutReturned = true }
        try await wait { service.snapshot.availability == .profileUnavailable }
        check(!logoutReturned && service.snapshot.items.isEmpty, "Transition hides projections and waits for uncooperative transfer completion")
        await http.release()
        await logout.value
        check(logoutReturned, "Logout joins the concrete request before completion")
        let retained = try durable(profileA, id: frozenConsent.id, settled: false)
        check(retained.operationID == beforeLogout.operationID && retained.receipt == nil && retained.pauseReason == .profileTransition,
              "Late remote acceptance remains original-owner uncertain work after cancellation")
        await identity.selectPerson("B")
        await account.signIn(); try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        try await service.activateCurrentProfile()
        let firstAsB = try await service.status(for: first.id), pendingAsB = try await service.status(for: frozenConsent.id)
        check(!service.snapshot.cloudSyncEnabled && firstAsB == .localOnly
              && pendingAsB == .localOnly, "B cannot view or resume A's queue and has separate consent")
        do { try await service.send(frozenConsent.id); check(false, "B cannot claim A's known session UUID") }
        catch let error as PichiPublicationOutboxFailure { check(error == .notAdmitted, "Foreign source ID cannot become a B admission") }
        do { _ = try await service.assessmentOptions(for: first.id); check(false, "B cannot fetch A's assessment options") }
        catch let error as PichiPublicationOutboxFailure { check(error == .notAdmitted, "Options cannot claim another owner's known meeting ID") }
        check(try Data(contentsOf: guestFile) == guestBytes, "Guest bytes survive A/logout/B unchanged")
        await account.logout(); await identity.selectPerson("A")
        await account.signIn(); try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        try await service.activateCurrentProfile()
        try await wait { if case .accepted = try await service.status(for: frozenConsent.id) { return true }; return false }
        let returned = try durable(PrivateProfileStorage.current, id: frozenConsent.id, settled: true)
        check(returned.operationID == retained.operationID && returned.transcriptBytes == retained.transcriptBytes,
              "Same-owner fresh admission resumes frozen bytes across new account/local generations")

        await service.pause()
        let consentRoot = PrivateProfileStorage.current.rootDirectory.appendingPathComponent("CloudPublication/Consent")
        let consentFile = try manager.contentsOfDirectory(at: consentRoot, includingPropertiesForKeys: nil).first { $0.pathExtension == "json" }!
        let preservedConsent = try Data(contentsOf: consentFile)
        let heldDuringCapture = try await capture()
        await http.holdNextPost()
        let heldSend = Task { try await service.send(heldDuringCapture.id) }
        try await wait { await http.isHeld() }
        try Data("corrupt synthetic consent".utf8).write(to: consentFile)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: consentFile.path)
        var localSaveReturned = false
        let localSave = Task { let session = try await capture(); localSaveReturned = true; return session }
        try await wait { localSaveReturned }
        let failedAdmission = try await localSave.value
        check(await http.isHeld(), "Consent failure during another upload does not join network from recording callbacks")
        check(try await meetings.load(id: failedAdmission.id) != nil, "Consent persistence/read failure never prevents local recording save")
        check(try await service.status(for: failedAdmission.id) == .paused(.storageUnavailable), "Failed publication admission has a visible safe reason")
        try preservedConsent.write(to: consentFile)
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: consentFile.path)
        await http.release(); _ = await heldSend.result
        check(try await service.status(for: failedAdmission.id) != .queued, "Repairing settings cannot retroactively admit the failed capture")
        try await service.setCloudSyncEnabled(true)
        let legacyReceiptWithoutFingerprint = try await capture(text: "Synthetic older managed source.")
        let newerManualSource = try await capture(text: "Synthetic mutable source.")
        try await wait {
            if case .accepted = try await service.status(for: legacyReceiptWithoutFingerprint.id),
               case .accepted = try await service.status(for: newerManualSource.id) { return true }
            return false
        }
        try await service.setCloudSyncEnabled(false)
        let currentProfile = PrivateProfileStorage.current
        let olderReceiptFile = currentProfile.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/settled/"
            + legacyReceiptWithoutFingerprint.id.uuidString.lowercased() + ".json")
        var olderReceipt = try JSONSerialization.jsonObject(with: Data(contentsOf: olderReceiptFile)) as! [String: Any]
        olderReceipt.removeValue(forKey: "localSourceSHA256")
        try JSONSerialization.data(withJSONObject: olderReceipt, options: [.sortedKeys]).write(to: olderReceiptFile, options: [.atomic])
        try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: olderReceiptFile.path)
        var editedManual = newerManualSource
        editedManual.transcriptSegments[0].text = "Newer synthetic local edit after receipt."
        try await meetings.save(editedManual)
        let retainedOIDCReceipt = try durable(PrivateProfileStorage.current, id: first.id, settled: true).receipt
        let requestsBeforeOIDCCleanup = await http.count()
        check(try await meetings.loadTranscript(id: first.id) != nil,
              "Current cleanup OFF retains an accepted manual OIDC recording")
        try await service.setDeleteLocalAfterAcceptance(true)
        try await wait { try durable(PrivateProfileStorage.current, id: first.id, settled: true).sourcePurged == true }
        let compactedOIDC = try durable(PrivateProfileStorage.current, id: first.id, settled: true)
        check(compactedOIDC.sourcePurged == true && compactedOIDC.transcriptBytes == nil
            && compactedOIDC.receipt == retainedOIDCReceipt && compactedOIDC.automaticAccountContext != true,
              "Current cleanup ON reconciles a fingerprint-backed manual OIDC receipt")
        try await wait {
            if case .acceptedNeedsReview(_, .sourceConflict) = try await service.status(for: newerManualSource.id) { return true }
            return false
        }
        check(try await meetings.loadTranscript(id: legacyReceiptWithoutFingerprint.id) != nil,
              "A historical managed receipt without a local fingerprint cannot authorize deletion")
        check(try await meetings.loadTranscript(id: newerManualSource.id)?.transcriptSegments[0].text == editedManual.transcriptSegments[0].text,
              "A newer manual local edit survives current-policy reconciliation")
        check(await http.count() == requestsBeforeOIDCCleanup,
              "Manual OIDC receipt cleanup issues no new POST, GET or PATCH")
        try await service.setDeleteLocalAfterAcceptance(false)
        localEncryption.enabled = true
        let localPolicy = try await service.prepareCapturePersistencePolicy()
        check(localPolicy.requiresEncryptedPersistence && !localPolicy.requiresPIIRedaction,
              "OIDC local encryption is independent of publication consent")
        let requestsBeforeEncryptedOff = await http.count()
        let encryptedWithoutConsent = try await capture(encrypted: true)
        let disabledEncrypted = try durable(PrivateProfileStorage.current, id: encryptedWithoutConsent.id, settled: true)
        check(!disabledEncrypted.automaticConsent && disabledEncrypted.requiresEncryptedPersistence == true,
              "An encrypted OIDC capture freezes explicit OFF consent in the existing outbox")
        let encryptedOffStatus = try await service.status(for: encryptedWithoutConsent.id)
        let encryptedOffRequests = await http.count()
        check(encryptedOffStatus == .localOnly && encryptedOffRequests == requestsBeforeEncryptedOff,
              "Local encryption alone cannot upload an OIDC source")
        try await service.setCloudSyncEnabled(true)
        await service.pause()
        let encryptedWithConsent = try await capture(encrypted: true)
        let enabledEncrypted = try durable(PrivateProfileStorage.current, id: encryptedWithConsent.id, settled: false)
        check(enabledEncrypted.automaticConsent && enabledEncrypted.automaticAccountContext != true
            && enabledEncrypted.requiresEncryptedPersistence == true,
              "Encrypted OIDC admission retains OIDC consent without adding legacy account-context fields")
        let encryptedQueueFile = PrivateProfileStorage.current.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/pending/"
            + encryptedWithConsent.id.uuidString.lowercased() + ".json")
        check(MeetingRecordingCipher.isEncryptedEnvelope(try Data(contentsOf: encryptedQueueFile)),
              "The cipher is installed before the encrypted OIDC outbox is reserved")
        try await service.resume()
        try await wait { if case .accepted = try await service.status(for: encryptedWithConsent.id) { return true }; return false }
        check(try await meetings.loadTranscript(id: encryptedWithConsent.id)?.isLocalContentConcealed == true,
              "A real OIDC receipt does not expose or remove the encrypted local source while retention is OFF")
        check(try await service.status(for: encryptedWithoutConsent.id) == .localOnly,
              "Later OIDC consent cannot adopt a previously declined encrypted capture")
        await account.logout(); await service.shutdown(); await account.shutdown()
        check(await http.wasShutdown(), "Service shutdown joins and releases its HTTP owner")
        return checks
    }
}

@MainActor private final class FacadeLocalEncryptionChoice { var enabled = false }
private enum FacadeProbeFailure: Error { case timeout }
@MainActor private final class FacadeSyntheticBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(string: callbackScheme + ":/oauth/callback")!
        callback.queryItems = [.init(name: "state", value: state), .init(name: "code", value: "synthetic")]
        return callback.url!
    }
    func cancel() {}
}
private actor FacadeSyntheticCredentials: AccountCredentialStoring {
    var grant: AccountGrant?
    func load() async throws -> AccountGrant? { grant }
    func save(_ value: AccountGrant) async throws { grant = value }
    func clear() async throws { grant = nil }
}
private actor FacadeSyntheticAccountTransport: AccountTransporting {
    let configuration: AccountConfiguration
    var person = "A"
    init(configuration: AccountConfiguration) { self.configuration = configuration }
    func selectPerson(_ value: String) { person = value }
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL {
        var url = URLComponents(string: "https://identity.example/authorize")!
        url.queryItems = [.init(name: "state", value: state)]; return url.url!
    }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse {
        .init(accessToken: "synthetic-" + person, refreshToken: "synthetic-refresh-" + person,
            expiresAt: Date().addingTimeInterval(3_600), subject: "subject-" + person)
    }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse { try await exchange(code: "", verifier: "", nonce: "") }
    func account(accessToken: String) async throws -> AccountSnapshot {
        let value = accessToken == "synthetic-A" ? "A" : "B"
        return .init(schemaVersion: 1, account: .init(id: "user-" + value, displayName: "Synthetic", email: nil),
            identity: .init(issuer: configuration.issuer.absoluteString, subject: "subject-" + value),
            organizations: [.init(id: "17", name: "Synthetic", workspaces: [.init(id: "9", name: "Synthetic", capabilities: [])])])
    }
    func revoke(refreshToken: String) async throws {}
}

/// Simulates only HTTP acceptance/replay, not W2 persistence, billing or authorization.
private actor FacadeFixtureHTTP: PichiPublicationHTTPPerforming {
    private var posts: [String: Data] = [:]
    private var receipts: [String: PichiPublicationReceipt] = [:]
    private var bodiesMatch = true
    private var requests = 0
    private var requestMethods: [String: Int] = [:]
    private var participants: [String: [[String: String]]] = [:]
    private var assessments: [String: PichiPublicationAssessment] = [:]
    private var loseNext = false
    private var heldMethod: String?
    private var gate: CheckedContinuation<Void, Never>?
    private var held = false
    private var closed = false
    private var failure: (method: String, status: Int, code: String)?
    private var finishStatus = false
    private var heldPostFailure: (status: Int, code: String)?
    func count() -> Int { requests }
    func count(method: String) -> Int { requestMethods[method] ?? 0 }
    func identicalPosts() -> Bool { bodiesMatch }
    func loseNextResponse() { loseNext = true }
    func holdNextPost() { heldMethod = "POST" }
    func holdNextRequest(_ method: String) { heldMethod = method }
    func isHeld() -> Bool { held }
    func release() { let saved = gate; gate = nil; held = false; saved?.resume() }
    func wasShutdown() -> Bool { closed }
    func failNextRequest(_ method: String, status: Int, code: String) { failure = (method, status, code) }
    func finishNextStatus() { finishStatus = true }
    func failHeldPost(status: Int, code: String) { heldPostFailure = (status, code) }
    func perform(_ request: URLRequest) async throws -> PichiPublicationHTTPResponse {
        requests += 1
        let method = request.httpMethod ?? "GET"
        let isOptions = request.url!.lastPathComponent == "assessment-options"
        let operation = isOptions ? "OPTIONS" : method
        requestMethods[operation, default: 0] += 1
        if let failure, failure.method == operation {
            self.failure = nil
            return .init(status: failure.status, body: try JSONSerialization.data(withJSONObject: ["error": ["code": failure.code, "status": failure.status]]), retryAfter: "0")
        }
        let key: String
        var status = 200
        if method == "POST" {
            key = request.value(forHTTPHeaderField: "Idempotency-Key")!
            if let prior = posts[key] { bodiesMatch = bodiesMatch && prior == request.httpBody }
            else {
                posts[key] = request.httpBody; status = 202
                let body = String(decoding: request.httpBody!, as: UTF8.self)
                let start = body.range(of: "Content-Type: application/json\r\n\r\n")!.upperBound
                let end = body.range(of: "\r\n--pichi-import-", range: start..<body.endIndex)!.lowerBound
                let source = try JSONSerialization.jsonObject(with: Data(body[start..<end].utf8)) as! [String: Any]
                let represented = Set((source["segments"] as! [[String: Any]]).compactMap { $0["speakerID"] as? String })
                participants[key] = (source["speakers"] as! [[String: Any]]).filter { represented.contains($0["id"] as! String) }
                    .map { ["id": $0["id"] as! String, "displayName": $0["displayName"] as! String] }
                receipts[key] = .init(schemaVersion: 1, importID: "import-" + key, recordingID: "recording-" + key,
                    uploadState: .accepted, analysisState: .needsParticipant)
            }
        } else {
            let components = request.url!.pathComponents
            let importID = method == "PATCH" || isOptions ? components[components.count - 2] : components.last!
            key = String(importID.dropFirst("import-".count))
            if method == "PATCH" {
                let old = receipts[key]!
                status = old.analysisState == .needsParticipant ? 202 : 200
                receipts[key] = .init(schemaVersion: 1, importID: old.importID, recordingID: old.recordingID,
                    uploadState: .accepted, analysisState: .queued)
                let binding = try JSONSerialization.jsonObject(with: request.httpBody!) as! [String: Any]
                assessments[key] = .init(participantID: UUID(uuidString: binding["participantID"] as! String), criteriaIDs: binding["criteriaIDs"] as! [String])
            } else if !isOptions, finishStatus {
                finishStatus = false
                let old = receipts[key]!
                receipts[key] = .init(schemaVersion: 1, importID: old.importID, recordingID: old.recordingID,
                    uploadState: .accepted, analysisState: .succeeded)
            }
        }
        if heldMethod == operation { heldMethod = nil; held = true; await withCheckedContinuation { gate = $0 } }
        if method == "POST", let failure = heldPostFailure {
            heldPostFailure = nil
            return .init(status: failure.status,
                body: try JSONSerialization.data(withJSONObject: ["error": ["code": failure.code, "status": failure.status]]), retryAfter: "3")
        }
        if method == "POST", loseNext { loseNext = false; throw PichiPublicationNetworkFailure.unavailable }
        if isOptions {
            let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!.queryItems!
            let cursor = query.first { $0.name == "cursor" }?.value
            let limit = Int(query.first { $0.name == "limit" }!.value!)!
            let ids = cursor == nil ? ["31", "32"] : ["33"]
            let receipt = receipts[key]!, binding = assessments[key]
            let receiptObject = try JSONSerialization.jsonObject(with: JSONEncoder().encode(receipt))
            let response: [String: Any] = ["schemaVersion": 1,
                "context": ["accountID": "user-A", "organizationID": "17", "workspaceID": "9"],
                "receipt": receiptObject, "participants": participants[key]!,
                "criteria": ["data": ids.map { ["id": $0, "name": "Synthetic criterion " + $0] },
                    "pagination": ["limit": limit, "cursor": cursor as Any? ?? NSNull(),
                        "next_cursor": cursor == nil && limit == 2 ? "c3ludGhldGljLW5leHQ" : NSNull(), "has_more": cursor == nil && limit == 2]],
                "currentAssessment": ["participantID": binding?.participantID?.uuidString as Any? ?? NSNull(), "criteriaIDs": binding?.criteriaIDs ?? []],
                "canResolvePending": [.needsParticipant, .needsCriteria].contains(receipt.analysisState) && binding == nil]
            return .init(status: 200, body: try JSONSerialization.data(withJSONObject: response), retryAfter: nil)
        }
        return .init(status: status, body: try JSONEncoder().encode(receipts[key]!), retryAfter: nil)
    }
    func shutdown() async { closed = true; release(); posts.removeAll(); receipts.removeAll(); participants.removeAll(); assessments.removeAll() }
}
