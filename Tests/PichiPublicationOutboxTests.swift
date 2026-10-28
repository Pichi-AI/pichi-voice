import CryptoKit
import Darwin
import Foundation

@main
struct PichiPublicationOutboxTests {
    static func main() async throws {
        let manager = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? manager.removeItem(at: root) }
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func rejects(_ expected: PichiPublicationOutboxFailure, _ message: String,
                     _ operation: () async throws -> Void) async throws {
            do { try await operation(); check(false, message) }
            catch let failure as PichiPublicationOutboxFailure { check(failure == expected, message) }
        }
        let configuration = AccountConfiguration(issuer: URL(string: "https://identity.example/realms/pichi")!,
            apiBaseURL: URL(string: "https://api.example")!, clientID: "synthetic-native", apiAudience: "synthetic-api",
            bundleIdentifier: "ai.synthetic.voice")
        let identity = AccountIdentity(issuer: configuration.issuer.absoluteString, subject: "synthetic-A", internalUserID: "user-A")
        func profile(_ directory: String, identity: AccountIdentity? = nil) throws -> PrivateProfileSnapshot {
            let url = root.appendingPathComponent(directory, isDirectory: true)
            try manager.createDirectory(at: url, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            return .init(id: "synthetic-profile", context: .init(identity: identity ?? identityA,
                organizationID: "organization-A", workspaceID: "workspace-A", generation: UUID()),
                generation: UUID(), rootDirectory: url, legacyRootDirectory: root, isReadable: true)
        }
        let identityA = identity
        let a = try profile("A")
        let store = PichiPublicationOutboxStore(profile: a, configuration: configuration)
        func source(id: UUID = UUID(), text: String = "Synthetic protected contact [PERSON].", participantID: UUID? = nil) throws -> PichiProtectedPublicationSource {
            let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil)
            var session = MeetingSession(id: id, configuration: .init(mode: .inRoom, title: "Synthetic outbox Ёё",
                languageCode: "ru", microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
            session.state = .completed; session.endedAt = session.startedAt.addingTimeInterval(5)
            session.piiRedactionEnabled = true; session.transcriptIsComplete = true
            if let participantID {
                session.speakers = [.init(id: participantID, displayName: "Synthetic Ёё", diarizationClusterID: nil,
                    trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
            }
            session.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1),
                end: .init(value: 5, timescale: 1), sourceTrackID: UUID(), speakerID: participantID, text: text,
                revision: 0, status: .final, overlap: .none, completeness: .complete, attributionState: participantID == nil ? .unassigned : .assigned)]
            return try .prepare(for: session)
        }
        func receipt(_ state: PichiPublicationAnalysisState = .needsParticipant, importID: String = "import-A") -> PichiPublicationReceipt {
            .init(schemaVersion: 1, importID: importID, recordingID: "recording-A", uploadState: .accepted, analysisState: state)
        }
        func location(_ profile: PrivateProfileSnapshot, _ id: UUID, settled: Bool = false) -> URL {
            profile.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/" + (settled ? "settled/" : "pending/")
                + id.uuidString.lowercased() + ".json")
        }
        func write(_ bytes: Data, _ url: URL) throws {
            try bytes.write(to: url)
            try manager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        }
        func mutate(_ url: URL, _ transform: (inout [String: Any]) -> Void) throws {
            var object = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
            transform(&object)
            try write(JSONSerialization.data(withJSONObject: object), url)
        }

        let prepared = try source(), id = prepared.sessionID
        let capture = try await store.capture(id: id, automaticConsent: true)
        check(capture.state == .waitingForSource && capture.attemptCount == 0 && capture.transcriptBytes == nil,
              "Capture consent and operation key persist before source admission")
        check(capture.originalAssessment == .init(participantID: nil, criteriaIDs: []), "Initial POST assessment never guesses a participant")
        let first = try await store.installSource(id: id, source: prepared)
        check(first.transcriptBytes == prepared.transcriptBytes && first.sourceSHA256 == prepared.sourceSHA256 && first.state == .queued,
              "Exact protected exporter bytes and digest are installed")
        let laterEdit = try source(id: id, text: "A later protected correction")
        async let duplicate1 = store.installSource(id: id, source: laterEdit)
        async let duplicate2 = store.installSource(id: id, source: prepared)
        let duplicates = try await (duplicate1, duplicate2)
        check(duplicates.0 == first && duplicates.1 == first, "Concurrent duplicate saves retain first exact source and operation")
        try await store.cancelCapture(id: id)
        check(try await store.record(id: id) == first, "Capture cancellation never removes source payload")
        let savedBytes = try Data(contentsOf: location(a, id))
        check(!String(decoding: savedBytes, as: UTF8.self).contains(a.context!.generation.uuidString)
            && !String(decoding: savedBytes, as: UTF8.self).contains(a.rootDirectory.path),
              "Durable owner excludes local roots and process generations")
        let newGeneration = PrivateProfileSnapshot(id: a.id, context: .init(identity: identity,
            organizationID: "organization-A", workspaceID: "workspace-A", generation: UUID()), generation: UUID(),
            rootDirectory: a.rootDirectory, legacyRootDirectory: root, isReadable: true)
        let reopened = PichiPublicationOutboxStore(profile: newGeneration, configuration: configuration)
        check(try await reopened.record(id: id) == first, "Offline reopening same stable owner accepts a fresh generation")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sending = try await reopened.beginAttempt(id: id, now: now)
        check(sending.state == .sending && sending.attemptCount == 1, "Attempt count is durable before network I/O")
        let crashed = PichiPublicationOutboxStore(profile: newGeneration, configuration: configuration)
        let uncertain = try await crashed.record(id: id)!
        check(uncertain.state == .paused && uncertain.pauseReason == .uncertainDelivery
            && uncertain.operationID == first.operationID && uncertain.transcriptBytes == first.transcriptBytes,
              "Restart preserves uncertain same-key source and exposes a reconciliation pause")
        let resumed = try await crashed.explicitRetry(id: id)
        check(resumed.operationID == first.operationID && resumed.multipartBoundary == first.multipartBoundary,
              "Explicit replay preserves operation and multipart boundary")
        _ = try await crashed.beginAttempt(id: id, now: now)
        let retry = try await crashed.scheduleRetry(id: id, decision: .retry(afterSeconds: 1), now: now)
        check(retry.attemptCount == 2 && retry.nextAttemptAt == now.addingTimeInterval(10), "Retry policy enforces a finite lower backoff")
        try await rejects(.invalidTransition, "Retry cannot start before the durable deadline") { _ = try await crashed.beginAttempt(id: id, now: now) }
        _ = try await crashed.beginAttempt(id: id, now: now.addingTimeInterval(10))
        let paused = try await crashed.scheduleRetry(id: id, decision: .retry(afterSeconds: .infinity), now: now)
        check(paused.pauseReason == .retryAfterBeyondBudget, "Nonfinite retry delay safely pauses")
        _ = try await crashed.explicitRetry(id: id)
        let accepted = try await crashed.accept(id: id, receipt: receipt())
        check(accepted.state == .accepted && accepted.receipt?.analysisState == .needsParticipant,
              "Upload acceptance remains separate from analysis pending action")
        check(try await crashed.pendingRecords().isEmpty && !manager.fileExists(atPath: location(a, id).path),
              "Settled records release bounded pending capacity")
        check(try await crashed.installSource(id: id, source: laterEdit) == accepted, "Accepted source cannot be replaced or reimported")
        let resolved = try await crashed.updateReceipt(id: id, receipt: receipt(.running))
        check(resolved.receipt?.analysisState == .running && resolved.originalAssessment == first.originalAssessment
            && resolved.transcriptBytes == first.transcriptBytes && resolved.operationID == first.operationID,
              "Effective PATCH receipt does not mutate initial POST fingerprint")
        let receiptDelay = try await crashed.pauseReceipt(id: id, reason: .transportUnavailable, retryAfter: .seconds(7200), now: now)
        let shorterDelay = try await crashed.pauseReceipt(id: id, reason: .transportUnavailable, retryAfter: .seconds(30), now: now)
        check(shorterDelay.retryNotBefore == receiptDelay.retryNotBefore, "A shorter later receipt delay cannot erase the outstanding server deadline")
        let receiptRestart = PichiPublicationOutboxStore(profile: newGeneration, configuration: configuration)
        check(try await receiptRestart.record(id: id)?.retryNotBefore == receiptDelay.retryNotBefore,
              "Accepted receipt review deadline survives store restart without returning to POST delivery")
        _ = try await crashed.updateReceipt(id: id, receipt: receipt(.running))
        try await rejects(.receiptConflict, "Receipt IDs cannot change during reconciliation") {
            _ = try await crashed.updateReceipt(id: id, receipt: receipt(importID: "another-import"))
        }
        // Simulate a crash after settled commit and before pending unlink.
        try write(savedBytes, location(a, id))
        let acceptanceRecovery = PichiPublicationOutboxStore(profile: newGeneration, configuration: configuration)
        let recoveredReceipt = try await acceptanceRecovery.record(id: id)?.receipt
        check(try await acceptanceRecovery.pendingRecords().isEmpty
            && recoveredReceipt?.analysisState == .running,
              "Verified settled record wins an interrupted acceptance move without reimport")

        let noConsent = UUID()
        let localOnly = try await store.capture(id: noConsent, automaticConsent: false)
        check(localOnly.state == .withheld && !localOnly.automaticConsent, "Absent capture consent is durable local-only state")
        check(try await store.capture(id: noConsent, automaticConsent: true) == localOnly,
              "Later opt-in cannot upgrade earlier capture consent")
        try await rejects(.notAdmitted, "Local-only capture cannot admit a protected source") {
            _ = try await store.installSource(id: noConsent, source: source(id: noConsent))
        }
        let cancelled = UUID()
        _ = try await store.capture(id: cancelled, automaticConsent: true)
        try await store.cancelCapture(id: cancelled)
        check(try await store.record(id: cancelled) == nil, "Cancellation removes only an unprepared capture")
        let pausedCancellation = UUID()
        _ = try await store.capture(id: pausedCancellation, automaticConsent: true)
        try await store.pauseAll()
        try await store.cancelCapture(id: pausedCancellation)
        check(try await store.record(id: pausedCancellation) == nil,
              "Cancelled capture after joined profile pause releases its source-less pending slot")
        try await rejects(.notAdmitted, "Missing capture state never reconstructs retroactive consent") {
            _ = try await store.installSource(id: cancelled, source: source(id: cancelled))
        }
        let incomplete = UUID()
        _ = try await store.capture(id: incomplete, automaticConsent: true)
        let withheld = try await store.withhold(id: incomplete, reason: .incompleteTranscript)
        check(withheld.withholdingReason == .incompleteTranscript && withheld.state == .withheld,
              "Incomplete recognition remains local with a typed reason")
        try await rejects(.invalidTransition, "Withheld capture cannot later auto-admit a corrected historical source") {
            _ = try await store.installSource(id: incomplete, source: source(id: incomplete))
        }
        let transition = try source()
        _ = try await store.capture(id: transition.sessionID, automaticConsent: true)
        try await store.pauseAll()
        let installedWhilePaused = try await store.installSource(id: transition.sessionID, source: transition)
        check(installedWhilePaused.state == .paused && installedWhilePaused.pauseReason == .profileTransition,
              "A paused admitted writer does not auto-resume delivery after source persistence")

        // Copied same-ID records must fail against both stable owner and full trust config.
        let b = try profile("B", identity: .init(issuer: identity.issuer, subject: "synthetic-B", internalUserID: "user-B"))
        let bStore = PichiPublicationOutboxStore(profile: b, configuration: configuration)
        _ = try await bStore.pendingRecords()
        try write(savedBytes, location(b, id))
        try await rejects(.corruptRecord, "Copied records cannot cross accounts") { _ = try await bStore.record(id: id) }
        let changedConfiguration = AccountConfiguration(issuer: configuration.issuer, apiBaseURL: URL(string: "https://other-api.example")!,
            clientID: configuration.clientID, apiAudience: configuration.apiAudience, bundleIdentifier: configuration.bundleIdentifier)
        let foreignDistribution = PichiPublicationOutboxStore(profile: a, configuration: changedConfiguration)
        try await rejects(.corruptRecord, "Copied records cannot cross trusted API distributions") { _ = try await foreignDistribution.record(id: id) }

        // Filesystem adversarial cases run in isolated roots so damaged evidence stays intact.
        for kind in ["digest", "owner", "schema", "state", "oversize", "symlink", "fifo", "permissions", "consent", "payload", "sourceID", "hardlink", "attempt"] {
            let p = try profile("bad-" + kind), s = PichiPublicationOutboxStore(profile: p, configuration: configuration)
            _ = try await s.pendingRecords()
            let path = location(p, id)
            try write(savedBytes, path)
            switch kind {
            case "digest": try mutate(path) { $0["sourceSHA256"] = String(repeating: "0", count: 64) }
            case "owner": try mutate(path) { $0["owner"] = ["profileID": "different-profile"] }
            case "schema": try mutate(path) { $0["schemaVersion"] = 99 }
            case "state": try mutate(path) { $0["state"] = "future-unsupported-state" }
            case "oversize": try write(Data(repeating: 65, count: 1_048_577), path)
            case "symlink": try manager.removeItem(at: path); try manager.createSymbolicLink(at: path, withDestinationURL: location(a, id, settled: true))
            case "fifo": try manager.removeItem(at: path); check(mkfifo(path.path, 0o600) == 0, "Synthetic FIFO created")
            case "permissions": try manager.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path)
            case "consent": try mutate(path) { $0.removeValue(forKey: "automaticConsent") }
            case "sourceID": try mutate(path) {
                var object = try! JSONSerialization.jsonObject(with: prepared.transcriptBytes) as! [String: Any]
                object["sessionID"] = UUID().uuidString
                let bytes = try! JSONSerialization.data(withJSONObject: object)
                $0["transcriptBytes"] = bytes.base64EncodedString()
                $0["sourceSHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            case "hardlink": check(link(path.path, path.appendingPathExtension("linked").path) == 0, "Synthetic hard link created")
            case "attempt": try mutate(path) {
                $0["state"] = "paused"; $0["pauseReason"] = "uncertainDelivery"; $0["attemptCount"] = 1
                $0.removeValue(forKey: "transcriptBytes"); $0.removeValue(forKey: "sourceSHA256")
            }
            case "payload": try mutate(path) {
                let bytes = Data(repeating: 65, count: 750_001)
                $0["transcriptBytes"] = bytes.base64EncodedString()
                $0["sourceSHA256"] = SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined()
            }
            default: break
            }
            let before = try manager.attributesOfItem(atPath: path.path)
            let expected: PichiPublicationOutboxFailure = kind == "symlink" ? .invalidStorage : .corruptRecord
            try await rejects(expected, "Invalid durable " + kind + " is preserved and never reaches transport") { _ = try await s.record(id: id) }
            let after = try manager.attributesOfItem(atPath: path.path)
            check(manager.fileExists(atPath: path.path)
                && (after[.size] as? NSNumber) == (before[.size] as? NSNumber),
                  "Damaged " + kind + " evidence is not overwritten")
        }
        let linkedRoot = root.appendingPathComponent("linked-root", isDirectory: true)
        try manager.createSymbolicLink(at: linkedRoot, withDestinationURL: a.rootDirectory)
        let linked = PrivateProfileSnapshot(id: a.id, context: a.context, generation: UUID(), rootDirectory: linkedRoot,
            legacyRootDirectory: root, isReadable: true)
        try await rejects(.invalidStorage, "A linked profile root is never followed") {
            _ = try await PichiPublicationOutboxStore(profile: linked, configuration: configuration).pendingRecords()
        }

        let capacityProfile = try profile("capacity"), capacity = PichiPublicationOutboxStore(profile: capacityProfile, configuration: configuration)
        var ids: [UUID] = []
        for _ in 0..<32 { let id = UUID(); ids.append(id); _ = try await capacity.capture(id: id, automaticConsent: true) }
        check(try await capacity.pendingRecords().count == 32, "Bounded pending capacity admits exactly 32 records")
        let overflow = UUID()
        try await rejects(.capacityExceeded, "The next admission reports capacity without affecting recording") {
            _ = try await capacity.capture(id: overflow, automaticConsent: true)
        }
        check(try await capacity.record(id: overflow) == nil, "Failed capacity admission leaves no retroactive capture marker")
        _ = try await capacity.withhold(id: ids[0], reason: .redactionNotEnabled)
        _ = try await capacity.capture(id: overflow, automaticConsent: true)
        check(try await capacity.pendingRecords().count == 32, "Settled withheld records do not exhaust pending capacity")
        let capSource = try source(id: ids[1])
        _ = try await capacity.installSource(id: ids[1], source: capSource)
        for attempt in 1...5 {
            _ = try await capacity.beginAttempt(id: ids[1], now: now.addingTimeInterval(Double(attempt * 1_000)))
            let value = try await capacity.scheduleRetry(id: ids[1], decision: .retry(afterSeconds: 0),
                now: now.addingTimeInterval(Double(attempt * 1_000)))
            check(value.attemptCount == attempt, "Attempt counter is monotonic and durable")
            if attempt == 5 { check(value.state == .paused && value.pauseReason == .retryBudgetExhausted, "Automatic retry count is finite") }
        }
        let review = PichiPublicationOutboxStore(profile: try profile("review-gates"), configuration: configuration)
        let reviewSource = try source()
        _ = try await review.capture(id: reviewSource.sessionID, automaticConsent: true)
        _ = try await review.installSource(id: reviewSource.sessionID, source: reviewSource)
        _ = try await review.beginAttempt(id: reviewSource.sessionID)
        _ = try await review.pause(id: reviewSource.sessionID, reason: .accountReview)
        try await review.pauseAll(reason: .profileTransition)
        check(try await review.record(id: reviewSource.sessionID)?.pauseReason == .accountReview,
              "Logout cannot convert a402 review pause into automatic delivery")
        _ = try await review.explicitRetry(id: reviewSource.sessionID)
        _ = try await review.beginAttempt(id: reviewSource.sessionID)
        let scheduled = try await review.scheduleRetry(id: reviewSource.sessionID, decision: .retry(afterSeconds: 60), now: Date())
        try await review.pauseAll(reason: .profileTransition)
        let resumedReview = try await review.explicitRetry(id: reviewSource.sessionID)
        check(resumedReview.state == .retryScheduled && resumedReview.nextAttemptAt == scheduled.nextAttemptAt,
              "Resume preserves a valid Retry-After deadline instead of retrying early")
        let unfinished = UUID()
        _ = try await review.capture(id: unfinished, automaticConsent: true)
        try await review.pauseAll(reason: .profileTransition)
        let resumedCapture = try await review.explicitRetry(id: unfinished)
        check(resumedCapture.state == .waitingForSource && resumedCapture.attemptCount == 0,
              "Same-owner resume can retain unfinished source preparation without manufacturing payload")
        try await capacity.pauseAll(reason: .profileTransition)
        check(try await capacity.record(id: ids[1])?.pauseReason == .retryBudgetExhausted,
              "Logout cannot erase an exhausted automatic retry budget")
        let retryProfile = try profile("retry-deadlines")
        let retryStore = PichiPublicationOutboxStore(profile: retryProfile, configuration: configuration)
        let retrySource = try source()
        _ = try await retryStore.capture(id: retrySource.sessionID, automaticConsent: true)
        _ = try await retryStore.installSource(id: retrySource.sessionID, source: retrySource)
        for attempt in 1...5 {
            let time = now.addingTimeInterval(Double(attempt * 100))
            _ = try await retryStore.beginAttempt(id: retrySource.sessionID, now: time)
            _ = try await retryStore.scheduleRetry(id: retrySource.sessionID,
                decision: PichiPublicationRetryPolicy.decision(afterAttempt: attempt, retryAfter: .seconds(30)),
                retryAfter: .seconds(30), now: time)
        }
        let fifthDeadline = now.addingTimeInterval(530)
        let exhausted = try await retryStore.record(id: retrySource.sessionID)!
        check(exhausted.pauseReason == .retryBudgetExhausted && exhausted.retryNotBefore == fifthDeadline,
              "Fifth-attempt Retry-After survives automatic budget exhaustion")
        try await retryStore.pauseAll(reason: .profileTransition)
        let retryReopened = PichiPublicationOutboxStore(profile: retryProfile, configuration: configuration)
        try await rejects(.invalidTransition, "Explicit retry after restart cannot bypass the fifth-attempt deadline") {
            _ = try await retryReopened.explicitRetry(id: retrySource.sessionID, now: fifthDeadline.addingTimeInterval(-1))
        }
        let due = try await retryReopened.explicitRetry(id: retrySource.sessionID, now: fifthDeadline)
        check(due.state == .queued && due.operationID == exhausted.operationID && due.transcriptBytes == exhausted.transcriptBytes,
              "A due explicit retry retains the exhausted operation's original bytes and key")
        _ = try await retryReopened.beginAttempt(id: retrySource.sessionID, now: fifthDeadline)
        let longDelay = try await retryReopened.scheduleRetry(id: retrySource.sessionID, decision: .pause(.retryBudgetExhausted),
            retryAfter: .seconds(7200), now: fifthDeadline)
        check(longDelay.retryNotBefore == fifthDeadline.addingTimeInterval(7200), "Long server delay remains durable even after budget exhaustion")
        try await rejects(.invalidTransition, "Manual retry cannot shorten a long server delay") {
            _ = try await retryReopened.explicitRetry(id: retrySource.sessionID, now: fifthDeadline.addingTimeInterval(60))
        }
        _ = try await retryReopened.explicitRetry(id: retrySource.sessionID, now: fifthDeadline.addingTimeInterval(7200))
        _ = try await retryReopened.beginAttempt(id: retrySource.sessionID, now: fifthDeadline.addingTimeInterval(7200))
        _ = try await retryReopened.scheduleRetry(id: retrySource.sessionID, decision: .pause(.retryAfterBeyondBudget),
            retryAfter: .beyondAutomaticWindow, now: fifthDeadline)
        let unrepresentable = PichiPublicationOutboxStore(profile: retryProfile, configuration: configuration)
        try await rejects(.invalidTransition, "An unrepresentable server deadline remains a review pause after restart") {
            _ = try await unrepresentable.explicitRetry(id: retrySource.sessionID, now: .distantFuture)
        }
        let legacyOrigin = URL(string: "https://legacy.example")!
        let legacyConfiguration = LegacyAccountConfiguration(apiBaseURL: legacyOrigin, bundleIdentifier: "ai.synthetic.voice")
        let legacyDirectory = root.appendingPathComponent("legacy", isDirectory: true)
        try manager.createDirectory(at: legacyDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let legacyContext = AccountContext(identity: .legacy(origin: legacyOrigin, internalUserID: "123"),
            organizationID: "17", workspaceID: "9", generation: UUID())
        let legacyProfile = PrivateProfileSnapshot(id: "synthetic-legacy", context: legacyContext, generation: UUID(),
            rootDirectory: legacyDirectory, legacyRootDirectory: root, isReadable: true)
        let legacyStore = PichiPublicationOutboxStore(profile: legacyProfile, destination: .legacy(legacyConfiguration))
        let representedID = UUID(), legacySource = try source(participantID: representedID)
        let legacySelection = LegacyPublicationSelection(userID: "123", participantID: representedID, criteriaIDs: ["31"])
        _ = try await legacyStore.capture(id: legacySource.sessionID, automaticConsent: true)
        _ = try await legacyStore.installSource(id: legacySource.sessionID, source: legacySource)
        let frozen = try await legacyStore.freezeLegacySelection(id: legacySource.sessionID, selection: legacySelection)
        check(frozen.legacySelection == legacySelection && frozen.legacyBodySHA256?.count == 64,
              "Explicit legacy selection and deterministic request digest are durable before an attempt")
        check(try await legacyStore.freezeLegacySelection(id: legacySource.sessionID, selection: legacySelection) == frozen,
              "The same legacy choice reuses its immutable request")
        try await rejects(.receiptConflict, "A changed employee cannot overwrite the original request") {
            _ = try await legacyStore.freezeLegacySelection(id: legacySource.sessionID,
                selection: .init(userID: "124", participantID: representedID, criteriaIDs: ["31"]))
        }
        _ = try await legacyStore.beginAttempt(id: legacySource.sessionID)
        let legacyReopened = PichiPublicationOutboxStore(profile: legacyProfile, destination: .legacy(legacyConfiguration))
        let legacyUncertain = try await legacyReopened.record(id: legacySource.sessionID)!
        check(legacyUncertain.pauseReason == .uncertainDelivery && legacyUncertain.legacySelection == legacySelection
            && legacyUncertain.legacyBodySHA256 == frozen.legacyBodySHA256 && legacyUncertain.transcriptBytes == frozen.transcriptBytes,
              "Lost-response recovery retains the exact source and selected assessment")
        let legacyConsentDirectory = legacyDirectory.appendingPathComponent("Consent", isDirectory: true)
        try manager.createDirectory(at: legacyConsentDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let legacyConsent = PichiPublicationConsentStore(directory: legacyConsentDirectory, destination: .legacy(legacyConfiguration))
        check(try await !legacyConsent.automaticPublicationEnabled(for: legacyContext), "Legacy consent defaults off")
        try await legacyConsent.setCloudSyncEnabled(true, for: legacyContext)
        check(try await legacyConsent.automaticPublicationEnabled(for: legacyContext), "Explicit legacy consent uses the same private setting store")
        let otherLegacyContext = AccountContext(identity: .legacy(origin: legacyOrigin, internalUserID: "124"),
            organizationID: "17", workspaceID: "9", generation: UUID())
        check(try await !legacyConsent.automaticPublicationEnabled(for: otherLegacyContext), "Another legacy account cannot inherit consent")
        try mutate(location(legacyProfile, legacySource.sessionID)) { $0["legacyBodySHA256"] = String(repeating: "0", count: 64) }
        try await rejects(.corruptRecord, "A changed frozen request digest fails closed") {
            _ = try await legacyReopened.record(id: legacySource.sessionID)
        }
        print("Pichi publication outbox: \(checks) synthetic checks passed")
        let facadeChecks = try await Self.checkCloudPublicationService(root: root.appendingPathComponent("facade", isDirectory: true))
        print("Pichi publication facade: \(facadeChecks) synthetic integration checks passed; no live transport")
        let legacyChecks = try await Self.checkLegacyCloudPublicationService(root: root.appendingPathComponent("legacy-facade", isDirectory: true))
        print("Pichi legacy facade: \(legacyChecks) synthetic integration checks passed; no live transport")
        let automaticChecks = try await Self.checkAutomaticCloudPublication(root: root.appendingPathComponent("automatic-facade", isDirectory: true))
        print("Pichi automatic encrypted delivery: \(automaticChecks) synthetic integration checks passed; no live transport")
    }
}
