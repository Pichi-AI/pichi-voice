@preconcurrency import AVFoundation
import CoreMedia
import CryptoKit
import Foundation
import XCTest
@testable import PichiVoiceMobile

/// Separately gated tests for the isolated Docker stand and direct QA. Recognition is synthetic; account,
/// capture admission, encrypted persistence, delivery, TLS and receipts are production.
/// No URLProtocol, certificate delegate, microphone, model or shared defaults is used.
@MainActor
final class MobileProtectedDeliveryHTTPTests: XCTestCase {
    func testDirectQASyntheticCaptureReceiptHistoryAndLocalRemoval() async throws {
        let fixture = try HTTPFixture.configuration(mode: .qa)
        let run = try HTTPFixture(configuration: fixture, attach: { self.add($0) })
        addTeardownBlock { await run.cleanup(preserveFailure: (self.testRun?.failureCount ?? 1) > 0) }
        try await run.start()
        try await run.service.setDeleteLocalAfterAcceptance(false)
        let source = try await run.record()
        XCTAssertTrue(source.title.hasPrefix("pichi-native-qa-"))
        try await run.wait { try run.outbox(source.id)?.receipt != nil }
        let durable = try XCTUnwrap(run.outbox(source.id))
        let receipt = try XCTUnwrap(durable.receipt)
        XCTAssertFalse(durable.sourcePurged == true)
        let retained = try await run.store.loadTranscript(id: source.id)
        XCTAssertNotNil(retained)
        try run.assertCiphertext(source.id)
        try await run.assertQAServerRecording(source.id)

        try await run.service.setDeleteLocalAfterAcceptance(true)
        try await run.wait { try run.outbox(source.id)?.sourcePurged == true }
        let removed = try await run.store.loadTranscript(id: source.id)
        XCTAssertNil(removed)
        XCTAssertEqual(try run.outbox(source.id)?.receipt?.recordingID, receipt.recordingID)
        // Local removal must retain the same source in ordinary server History/detail.
        try await run.assertQAServerRecording(source.id)
    }

    func testEncryptedCaptureRealHTTPSReceiptHistoryAndCurrentDeletePolicy() async throws {
        let fixture = try HTTPFixture.configuration()
        let run = try HTTPFixture(configuration: fixture, attach: { self.add($0) })
        addTeardownBlock { await run.cleanup(preserveFailure: (self.testRun?.failureCount ?? 1) > 0) }
        try await run.start()
        try await run.service.setDeleteLocalAfterAcceptance(false)
        let source = try await run.record()
        try await run.wait { try run.outbox(source.id)?.receipt != nil }
        let accepted = try XCTUnwrap(run.outbox(source.id))
        let history = try await run.store.loadHistory()
        XCTAssertTrue(history.contains { $0.id == source.id && $0.isLocalContentConcealed })
        XCTAssertNotNil(accepted.receipt)
        XCTAssertEqual(accepted.owner, source.profileOwnership)
        XCTAssertEqual(accepted.localSourceSHA256, try PichiProtectedPublicationSource.localFingerprint(for: source))
        try run.assertCiphertext(source.id)
        try await run.assertOneServerRecording(source.id, minimumAttempts: 1)
        let owner = try XCTUnwrap(source.profileOwnership)
        let wrongOwner = MeetingProfileOwnership(profileID: "synthetic-other-owner", legacyOrigin: owner.legacyOrigin,
            issuer: owner.issuer, subject: owner.subject, internalUserID: owner.internalUserID,
            organizationID: owner.organizationID, workspaceID: owner.workspaceID)
        do {
            try await run.coordinator.deleteSession(id: source.id, expectedOwnership: wrongOwner, validating: { _ in })
            XCTFail("A durable receipt cannot authorize another owner's deletion")
        } catch AccountError.staleOperation {
            let stillOwned = try await run.store.loadTranscript(id: source.id)
            XCTAssertEqual(stillOwned?.profileOwnership, owner)
        }

        // Current ON must reconcile an already accepted source. A real coordinator
        // capture is the busy owner; no fabricated cleanup success stands in for it.
        try await run.service.setCloudSyncEnabled(false)
        try run.coordinator.resetForNewMeeting()
        _ = try await run.beginRecording()
        try await run.service.setDeleteLocalAfterAcceptance(true)
        await run.service.notifySceneActive(true)
        let busySource = try await run.store.loadTranscript(id: source.id)
        XCTAssertNotNil(busySource, "An active capture prevents accepted source removal")
        try await run.service.setDeleteLocalAfterAcceptance(false)
        _ = try await run.finishRecording()
        await run.service.notifySceneActive(true)
        let retained = try await run.store.loadTranscript(id: source.id)
        XCTAssertNotNil(retained, "Current OFF cancels deferred cleanup after the owner becomes quiescent")
        try await run.service.setDeleteLocalAfterAcceptance(true)
        try await run.wait { try run.outbox(source.id)?.sourcePurged == true }
        let removed = try await run.store.loadTranscript(id: source.id)
        XCTAssertNil(removed)
        XCTAssertEqual(try run.outbox(source.id)?.receipt?.importID, accepted.receipt?.importID)
        try await run.assertOneServerRecording(source.id, minimumAttempts: 1)
    }

    func testLostCommittedResponseRetainsSourceWithDeletionOnUntilDurableReceipt() async throws {
        let fixture = try HTTPFixture.configuration()
        let run = try HTTPFixture(configuration: fixture, attach: { self.add($0) })
        addTeardownBlock { await run.cleanup(preserveFailure: (self.testRun?.failureCount ?? 1) > 0) }
        try await run.start()
        try await run.service.setDeleteLocalAfterAcceptance(true)
        try await run.control(["dropNextSuccessfulImportResponse": true, "offlineAfterDroppedResponse": true])
        let source = try await run.record()
        try await run.wait {
            let ledger = try await run.ledger(source.id)
            let state = try run.outbox(source.id)?.state
            return ledger.attempts.contains { $0.outcome == "dropped_after_commit" }
                && state == .retryScheduled
        }

        let unconfirmed = try XCTUnwrap(run.outbox(source.id))
        XCTAssertNil(unconfirmed.receipt)
        XCTAssertFalse(unconfirmed.sourcePurged == true,
            "Current deletion ON still requires a durable matching receipt")
        let retained = try await run.store.loadTranscript(id: source.id)
        XCTAssertNotNil(retained, "A lost response cannot delete the encrypted local source")
        try run.assertCiphertext(source.id)
        try await run.assertOneServerRecording(source.id, minimumAttempts: 1)

        try await run.control(["offline": false])
        await run.service.notifySceneActive(true)
        try await run.wait {
            guard let accepted = try run.outbox(source.id) else { return false }
            return accepted.receipt != nil && accepted.sourcePurged == true
        }
        let removed = try await run.store.loadTranscript(id: source.id)
        XCTAssertNil(removed)
        try await run.assertOneServerRecording(source.id, minimumAttempts: 2)
    }

    func testLostCommittedResponseRetriesIdenticalBodyWithoutDuplicateImportOrCharge() async throws {
        let fixture = try HTTPFixture.configuration()
        let run = try HTTPFixture(configuration: fixture, attach: { self.add($0) })
        addTeardownBlock { await run.cleanup(preserveFailure: (self.testRun?.failureCount ?? 1) > 0) }
        try await run.start()
        try await run.service.setDeleteLocalAfterAcceptance(false)
        try await run.control(["dropNextSuccessfulImportResponse": true, "offlineAfterDroppedResponse": true])
        let source = try await run.record()
        try await run.wait {
            let ledger = try await run.ledger(source.id)
            let state = try run.outbox(source.id)?.state
            return ledger.attempts.contains { $0.outcome == "dropped_after_commit" }
                && state == .retryScheduled
        }
        let beforeRetry = try XCTUnwrap(run.outbox(source.id))
        XCTAssertNil(beforeRetry.receipt, "A committed server row alone cannot authorize local deletion")
        let retained = try await run.store.loadTranscript(id: source.id)
        XCTAssertNotNil(retained)
        try run.assertCiphertext(source.id)
        try await run.control(["offline": false])
        await run.service.notifySceneActive(true)
        try await run.wait { try run.outbox(source.id)?.receipt != nil }
        let ledger = try await run.ledger(source.id)
        XCTAssertEqual(ledger.attempts.count, 2, "Exactly one application retry follows the lost response")
        XCTAssertEqual(Set(ledger.attempts.map(\.bodySHA256)).count, 1)
        XCTAssertEqual(ledger.attempts.first?.bodySHA256, beforeRetry.legacyBodySHA256)
        try await run.assertOneServerRecording(source.id, minimumAttempts: 2)

        // Newer user work after a durable receipt is never the accepted revision.
        let editable = try await run.store.loadTranscript(id: source.id)
        var edited = try XCTUnwrap(editable)
        edited.transcriptSegments[0].text = "Synthetic newer local edit [PERSON]."
        try await run.store.save(edited)
        try await run.service.setDeleteLocalAfterAcceptance(true)
        await run.service.notifySceneActive(true)
        try await run.wait { try run.outbox(source.id)?.receiptPauseReason == .sourceConflict }
        let preserved = try await run.store.loadTranscript(id: source.id)
        XCTAssertEqual(preserved?.transcriptSegments.first?.text, edited.transcriptSegments.first?.text)
        try await run.assertOneServerRecording(source.id, minimumAttempts: 2)
    }

    func testOfflineQueueSurvivesFreshAccountStoreAndForegroundNetworkWake() async throws {
        let fixture = try HTTPFixture.configuration()
        let run = try HTTPFixture(configuration: fixture, attach: { self.add($0) })
        addTeardownBlock { await run.cleanup(preserveFailure: (self.testRun?.failureCount ?? 1) > 0) }
        try await run.start()
        try await run.service.setDeleteLocalAfterAcceptance(false)
        try await run.control(["offline": true])
        let source = try await run.record()
        try await run.wait { try run.outbox(source.id)?.state == .retryScheduled }
        let originalOwner = source.profileOwnership
        try run.assertCiphertext(source.id)
        await run.stop()
        try await run.start(restoring: true)
        XCTAssertTrue(run.account.isAwaitingLegacyServerValidation,
            "The previously verified account may reopen its own local queue while offline")
        let offlineSource = try await run.store.loadTranscript(id: source.id)
        XCTAssertEqual(offlineSource?.profileOwnership, originalOwner)
        XCTAssertNil(try run.outbox(source.id)?.receipt)
        try await run.control(["offline": false])
        await run.account.restoreAfterConnectivity()
        await run.service.notifyServerAvailabilityChanged()
        await run.service.notifySceneActive(true)
        try await run.wait { try run.outbox(source.id)?.receipt != nil }
        XCTAssertEqual(try run.outbox(source.id)?.owner, originalOwner)
        try await run.assertOneServerRecording(source.id, minimumAttempts: 1)
    }

    /// Run this method twice in separate test-host launches with phase=queue then
    /// phase=resume and the same owned relaunch root. It never passes silently when
    /// explicitly enabled but missing the durable first-phase evidence.
    func testOfflineQueueAcrossTestHostRelaunch() async throws {
        let fixture = try HTTPFixture.configuration()
        let environment = ProcessInfo.processInfo.environment
        guard let phase = environment["PICHI_HTTP_RELAUNCH_PHASE"], ["queue", "resume"].contains(phase),
              let path = environment["PICHI_HTTP_RELAUNCH_ROOT"], path.hasPrefix("/") else {
            throw XCTSkip("Set PICHI_HTTP_RELAUNCH_PHASE and an owned PICHI_HTTP_RELAUNCH_ROOT for the two-launch case")
        }
        let root = URL(fileURLWithPath: path, isDirectory: true)
        let run = try HTTPFixture(configuration: fixture, relaunchRoot: root, restoring: phase == "resume", attach: { self.add($0) })
        addTeardownBlock { await run.cleanup(preserveFailure: (self.testRun?.failureCount ?? 1) > 0) }
        try await run.start(restoring: phase == "resume")
        let marker = root.appendingPathComponent("queued-session.json")
        if phase == "queue" {
            try await run.service.setDeleteLocalAfterAcceptance(false)
            try await run.control(["offline": true])
            let source = try await run.record()
            try await run.wait { try run.outbox(source.id)?.state == .retryScheduled }
            try run.assertCiphertext(source.id)
            try JSONEncoder().encode(source.id).write(to: marker, options: .atomic)
            await run.stop()
            run.preserveForRelaunch = true
            // Keep the backend offline until the separate host has restored its owner.
        } else {
            let id = try JSONDecoder().decode(UUID.self, from: Data(contentsOf: marker))
            let queued = try await run.store.loadTranscript(id: id)
            XCTAssertNotNil(queued)
            XCTAssertNil(try run.outbox(id)?.receipt)
            XCTAssertTrue(run.account.isAwaitingLegacyServerValidation)
            try await run.control(["offline": false])
            await run.account.restoreAfterConnectivity()
            await run.service.notifySceneActive(true)
            try await run.wait { try run.outbox(id)?.receipt != nil }
            try await run.assertOneServerRecording(id, minimumAttempts: 1)
        }
    }
}

@MainActor
private final class HTTPFixture {
    enum Mode: Equatable { case localStand, qa }
    struct Configuration: Decodable {
        let origin: URL
        let email: String
        let password: String
        let organizationID: String
        let workspaceID: String
        let controlToken: String
        let expectedAccountID: String?
        var mode = Mode.localStand
        private enum CodingKeys: String, CodingKey {
            case origin, email, password, organizationID, workspaceID, controlToken, expectedAccountID
        }
    }
    struct Ledger: Decodable {
        struct Attempt: Decodable { let bodySHA256: String; let status: Int?; let outcome: String }
        let sessionID: String
        let attempts: [Attempt]
        let sourceCount: Int
        let recordingCount: Int
        let importCount: Int
        let chargeCount: Int
        let chargedRecordingCount: Int
        let analysisProvider: String
    }
    private struct QARecord: Decodable {
        let id: Int
        let workspaceId: Int
        let userId: Int?
        let uploadedById: Int?
        let title: String
        let source: String?
        let importSourceId: String?
        let assessmentMode: String?
        let assessmentPolicyVersion: Int?
    }
    private struct QAHistory: Decodable { let recordings: [QARecord] }
    private struct Ownership: Codable {
        let purpose: String
        let runID: UUID
        let origin: URL
    }
    static let text = "Synthetic HTTPS protected transcript [PERSON] Ёё 4829."
    let configuration: Configuration
    let root: URL
    let runID: UUID
    let previousProfile = PrivateProfileStorage.current
    let defaults: UserDefaults
    let settings: SettingsStore
    var preserveForRelaunch = false
    private let controlSession = URLSession(configuration: .ephemeral, delegate: HTTPControlRedirects(), delegateQueue: nil)
    private let attach: @MainActor (XCTAttachment) -> Void
    private var running = false
    private var profile: PrivateProfileSnapshot?
    private var capture: HTTPCapture!
    private var recognizer: HTTPRecognizer!
    private var arbiter: HTTPArbiter!
    private var cipher: MeetingRecordingCipher?
    private var legacy: LegacyAccountHTTPTransport!
    private var qaCredentials: HTTPMemorySession?
    private var capturedIDs = Set<UUID>()
    private var waitFailed = false
    private(set) var account: AccountSessionService!
    private(set) var store: PrivateProfileMeetingStore!
    private(set) var coordinator: MeetingSessionCoordinator!
    private(set) var service: PichiCloudPublicationService!
    private var suite: String { "MobileProtectedDeliveryHTTPTests." + runID.uuidString }

    static func configuration(mode: Mode = .localStand) throws -> Configuration {
        #if !targetEnvironment(simulator)
        throw XCTSkip("Synthetic HTTPS acceptance requires a task-owned simulator")
        #else
        let environment = ProcessInfo.processInfo.environment
        let flag = mode == .qa ? "PICHI_NATIVE_QA_ACCEPTANCE" : "PICHI_NATIVE_HTTP_ACCEPTANCE"
        let pathVariable = mode == .qa ? "PICHI_QA_FIXTURE_PATH" : "PICHI_HTTP_FIXTURE_PATH"
        guard environment[flag] == "1" else {
            throw XCTSkip("Opt in with " + flag + "=1")
        }
        guard let path = environment[pathVariable], path.hasPrefix("/") else {
            throw Failure.invalidConfiguration
        }
        let url = URL(fileURLWithPath: path)
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        guard permissions?.intValue == 0o600, url.resolvingSymlinksInPath() == url else {
            throw Failure.invalidConfiguration
        }
        var value: Configuration
        do { value = try JSONDecoder().decode(Configuration.self, from: Data(contentsOf: url)) }
        catch { throw Failure.invalidConfiguration }
        value.mode = mode
        guard value.origin.scheme == "https",
              value.origin.path.isEmpty, value.origin.user == nil, value.origin.password == nil,
              value.origin.query == nil, value.origin.fragment == nil,
              !value.email.isEmpty, !value.password.isEmpty,
              Int(value.organizationID).map({ $0 > 0 }) == true,
              Int(value.workspaceID).map({ $0 > 0 }) == true else { throw Failure.invalidConfiguration }
        switch mode {
        case .localStand:
            guard value.origin.absoluteString == "https://localhost:18443",
                  value.email.hasSuffix(".invalid"), !value.controlToken.isEmpty else { throw Failure.invalidConfiguration }
        case .qa:
            guard value.origin.absoluteString == "https://ai-call-studio.qa.aspirity.com",
                  value.organizationID == "112", value.workspaceID == "155",
                  value.expectedAccountID.flatMap(PichiLegacyPublicationRequest.databaseID) != nil else {
                throw Failure.invalidConfiguration
            }
        }
        return value
        #endif
    }

    init(configuration: Configuration, relaunchRoot: URL? = nil, restoring: Bool = false,
         attach: @escaping @MainActor (XCTAttachment) -> Void) throws {
        self.configuration = configuration
        self.attach = attach
        guard configuration.mode != .qa || (relaunchRoot == nil && !restoring) else { throw Failure.invalidConfiguration }
        let manager = FileManager.default
        let root = relaunchRoot ?? manager.temporaryDirectory.appendingPathComponent("pichi-http-" + UUID().uuidString)
        let marker = root.appendingPathComponent("test-owner.json")
        guard root.path.hasPrefix("/"), root.standardizedFileURL == root,
              root.resolvingSymlinksInPath().path == root.path,
              root.lastPathComponent.hasPrefix("pichi-http-") else { throw Failure.invalidConfiguration }
        let identifier: UUID
        if restoring {
            let ownership = try JSONDecoder().decode(Ownership.self, from: Data(contentsOf: marker))
            guard ownership.purpose == "pichi-native-http-acceptance-v1", ownership.origin == configuration.origin else {
                throw Failure.invalidConfiguration
            }
            identifier = ownership.runID
        } else {
            guard !manager.fileExists(atPath: root.path) else { throw Failure.invalidConfiguration }
            identifier = UUID()
            try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            try JSONEncoder().encode(Ownership(purpose: "pichi-native-http-acceptance-v1", runID: identifier,
                origin: configuration.origin)).write(to: marker, options: .atomic)
        }
        self.runID = identifier
        self.root = root
        defaults = try XCTUnwrap(UserDefaults(suiteName: "MobileProtectedDeliveryHTTPTests." + identifier.uuidString))
        settings = SettingsStore(defaults: defaults, initializeDesktop: false)
        settings.fluidMeetEnabled = true
        settings.selectedSpeechModel = .whisperSmall
        settings.meetingSaveAudio = true
        settings.meetingSpeakerLabelsEnabled = false
        settings.meetingPIIRedactionRequested = true
        settings.meetingPIIRedactionEnabled = true
        settings.meetingEncryptLocalRecordings = true
    }

    func start(restoring: Bool = false) async throws {
        guard !running else { throw Failure.invalidConfiguration }
        running = true
        if !restoring && configuration.mode == .localStand {
            try await control(["offline": false, "releaseHeldResponses": true, "resetLedger": true,
                "dropNextSuccessfulImportResponse": false, "holdNextImportResponse": false,
                "offlineAfterDroppedResponse": false])
        }
        PrivateProfileStorage.select(try PrivateProfileStorage.proposed(context: nil, generation: UUID(),
            legacyRootDirectory: root.appendingPathComponent("private-data", isDirectory: true)))
        store = PrivateProfileMeetingStore()
        capture = HTTPCapture()
        recognizer = HTTPRecognizer()
        arbiter = HTTPArbiter()
        coordinator = MeetingSessionCoordinator(store: store, capture: capture, processing: recognizer,
            audioArbiter: arbiter, settings: settings, redactorProvider: { HTTPRedactor() }, processingLogger: { _ in })
        let profiles = PrivateProfileService()
        let store = self.store!, coordinator = self.coordinator!
        // A known synthetic key is intentional. These tests verify envelope handling,
        // owner binding and relaunch, not Keychain secrecy or Data Protection.
        let key = Data(SHA256.hash(data: Data(("synthetic-http-key-" + runID.uuidString).utf8)))
        let cipherFor: @MainActor @Sendable (PrivateProfileSnapshot) throws -> MeetingRecordingCipher = {
            try MeetingRecordingCipher(profileID: $0.id, key: key)
        }
        try profiles.configure(isBusy: { !coordinator.isQuiescent }, prepare: {}, activate: { profile in
            try await store.installEncryptionCipher(cipherFor(profile), for: profile)
        })
        let destination = LegacyAccountConfiguration(apiBaseURL: configuration.origin,
            bundleIdentifier: "ai.synthetic.http-acceptance")
        let network = URLSessionConfiguration.ephemeral
        if configuration.mode == .qa { network.connectionProxyDictionary = [:] }
        legacy = try LegacyAccountHTTPTransport(configuration: destination, sessionConfiguration: network)
        let sessionStorage: any LegacyAccountSessionStoring
        if configuration.mode == .qa {
            let memory = HTTPMemorySession()
            qaCredentials = memory
            sessionStorage = memory
        } else {
            sessionStorage = HTTPStoredSession(url: root.appendingPathComponent("synthetic-session.private.json"))
        }
        account = AccountSessionService(configuration: nil, browser: HTTPBrowser(), transport: HTTPNoOIDC(),
            credentials: HTTPNoGrant(), lifecycle: profiles,
            restoration: AccountRestorationPolicy(defaults: defaults, scope: runID.uuidString),
            legacyConfiguration: destination, legacyTransport: legacy,
            legacyCredentials: sessionStorage)
        service = PichiCloudPublicationService(account: account, meetings: store, profiles: profiles,
            recordingCipher: { try cipherFor($0) },
            localEncryptionRequested: { [settings] _ in settings.meetingEncryptLocalRecordings },
            deleteAcceptedRecording: { [weak self] id, owner, expectedSHA in
                guard let self else { throw CancellationError() }
                // Read the encrypted envelope from disk, rather than trusting the
                // facade's in-memory accepted status, at the deletion boundary.
                let durable = try self.outbox(id)
                XCTAssertNotNil(durable?.receipt, "Local deletion was requested before receipt persistence")
                guard durable?.receipt != nil else { throw Failure.invalidLedger }
                let current = PrivateProfileStorage.current
                guard owner.matches(current), PrivateProfileStorage.isReadable(current),
                      profiles.isPrivateDataVisible, !profiles.isTransitioning else { throw AccountError.staleOperation }
                try await coordinator.deleteSession(id: id, expectedOwnership: owner, validating: {
                    guard try PichiProtectedPublicationSource.localFingerprint(for: $0) == expectedSHA else {
                        throw PichiPublicationOutboxFailure.receiptConflict
                    }
                })
            })
        try await service.install()
        if restoring { await account.restore() }
        else {
            await account.signIn(email: configuration.email, password: configuration.password)
            guard account.presentationError == nil else { throw Failure.authentication }
            if configuration.mode == .qa {
                guard account.account?.account.id == configuration.expectedAccountID,
                      account.account?.account.email?.lowercased() == configuration.email.lowercased(),
                      account.account?.activeOrganizationID == configuration.organizationID else { throw Failure.authentication }
            }
            try await account.selectWorkspace(organizationID: configuration.organizationID, workspaceID: configuration.workspaceID)
        }
        guard account.context?.workspaceID == configuration.workspaceID,
              account.context?.organizationID == configuration.organizationID else { throw Failure.authentication }
        if configuration.mode == .qa {
            guard account.account?.account.id == configuration.expectedAccountID,
                  account.account?.account.email?.lowercased() == configuration.email.lowercased(),
                  account.context?.identity.internalUserID == configuration.expectedAccountID,
                  account.context?.identity.legacyOrigin == configuration.origin.absoluteString else { throw Failure.authentication }
        }
        profile = PrivateProfileStorage.current
        cipher = try cipherFor(try XCTUnwrap(profile))
        try await service.activateCurrentProfile()
        if !restoring { try await service.setCloudSyncEnabled(true) }
    }

    func beginRecording() async throws -> MeetingSession {
        // Deliberately request retained audio. Production admission must override it
        // once and preserve the encrypted request through later preference changes.
        let title = configuration.mode == .qa ? "pichi-native-qa-" + runID.uuidString.lowercased() : "Synthetic HTTPS Ёё"
        var request = MeetingCaptureConfiguration(mode: .inRoom, title: title,
            languageCode: "en", microphone: .init(captureDeviceID: "synthetic-http-pcm", displayName: "Synthetic PCM"),
            audioStorageMode: .retainedFiles, speakerLabelsEnabled: false, piiRedactionEnabled: true,
            transcriptionBackendID: MeetingBackendID.legacyCompatibility.rawValue)
        request.timestampDefaultTitle = false
        let admitted = try await coordinator.startRecording(configuration: request)
        capturedIDs.insert(admitted.id)
        XCTAssertTrue(admitted.requiresEncryptedPersistence == true)
        XCTAssertEqual(admitted.audioStorageMode, .memoryOnly)
        XCTAssertTrue(admitted.isLocalContentConcealed)
        let summary = try await capture.summary()
        XCTAssertEqual(summary.frames, 24_000)
        XCTAssertGreaterThan(summary.peak, 0.02)
        try await recognizer.recognize(summary, session: try XCTUnwrap(coordinator.activeSession))
        return admitted
    }

    func finishRecording() async throws -> MeetingSession {
        settings.meetingEncryptLocalRecordings = false
        defer { settings.meetingEncryptLocalRecordings = true }
        let result = try await coordinator.stopAndTranscribe()
        XCTAssertTrue(result.requiresEncryptedPersistence == true)
        XCTAssertEqual(result.audioStorageMode, .memoryOnly)
        XCTAssertTrue(result.transcriptIsComplete == true)
        XCTAssertEqual(result.transcriptSegments.map(\.text), [Self.text])
        XCTAssertTrue(coordinator.isQuiescent)
        XCTAssertFalse(arbiter.hasLease)
        return result
    }

    func record() async throws -> MeetingSession {
        if coordinator.activeSession != nil { try coordinator.resetForNewMeeting() }
        _ = try await beginRecording()
        return try await finishRecording()
    }

    func outbox(_ id: UUID) throws -> PichiPublicationOutboxRecord? {
        let profile = try XCTUnwrap(profile), cipher = try XCTUnwrap(cipher)
        for leaf in ["settled", "pending"] {
            let path = profile.directory("CloudPublication/OutboxV1/" + leaf)
                .appendingPathComponent(id.uuidString.lowercased() + ".json")
            guard FileManager.default.fileExists(atPath: path.path) else { continue }
            let bytes: Data
            do { bytes = try Data(contentsOf: path) }
            catch CocoaError.fileReadNoSuchFile { continue }
            XCTAssertTrue(MeetingRecordingCipher.isEncryptedEnvelope(bytes))
            return try JSONDecoder().decode(PichiPublicationOutboxRecord.self,
                from: cipher.open(bytes, sessionID: id, artifactKind: .publicationOutbox, maximumPlaintextBytes: 1_048_576))
        }
        return nil
    }

    func assertCiphertext(_ id: UUID) throws {
        let profile = try XCTUnwrap(profile)
        let manifest = profile.directory("Meetings").appendingPathComponent(id.uuidString + "/session.json")
        let bytes = try Data(contentsOf: manifest)
        XCTAssertTrue(MeetingRecordingCipher.isEncryptedEnvelope(bytes))
        let enumerator = try XCTUnwrap(FileManager.default.enumerator(at: profile.rootDirectory,
            includingPropertiesForKeys: [.isRegularFileKey], options: []))
        for case let file as URL in enumerator {
            guard try file.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true else { continue }
            let content = try Data(contentsOf: file)
            XCTAssertNil(content.range(of: Data(Self.text.utf8)), "Synthetic transcript appeared in plaintext: " + file.lastPathComponent)
            XCTAssertNil(content.range(of: Data("Synthetic HTTPS protected transcript".utf8)),
                "An escaped JSON representation must not leave plaintext speech on disk")
            XCTAssertFalse(["caf", "wav", "m4a", "pcm"].contains(file.pathExtension.lowercased()))
        }
    }

    func assertQAServerRecording(_ id: UUID) async throws {
        guard configuration.mode == .qa, let record = try outbox(id), let receipt = record.receipt,
              let canonical = record.canonicalSourceSHA256,
              let serverID = PichiLegacyPublicationRequest.databaseID(receipt.recordingID) else {
            throw Failure.invalidLedger
        }
        let context = try qaContext()
        let detailRequest = try PichiLegacyPublicationRequest.endpoint(origin: configuration.origin,
            path: "/api/recordings/" + String(serverID))
        let detail = try await account.performAuthorizedLegacyRequest(for: context, request: detailRequest)
        // Reuse the production source, receipt, owner and canonical hash validation.
        _ = try PichiLegacyPublicationRequest.accountContextReceipt(from:
            .init(status: detail.status, body: detail.body, retryAfter: detail.retryAfter), context: context,
            sessionID: id, canonicalSourceSHA256: canonical, managerSpeakerID: record.managerSpeakerHint, expected: receipt)
        let detailRecord = try JSONDecoder().decode(QARecord.self, from: detail.body)
        try validateQARecord(detailRecord, sourceID: id, serverID: serverID)

        // The ordinary frontend History route has a query and is intentionally outside
        // AccountSessionService's publication-only request allowlist. Reuse the same
        // cookie-owning production transport after fresh identity/ACL validation.
        let fresh = try await legacy.account()
        guard fresh.stableIdentity == context.identity, fresh.account.id == configuration.expectedAccountID,
              fresh.account.email?.lowercased() == configuration.email.lowercased(),
              fresh.activeOrganizationID == configuration.organizationID,
              fresh.contains(organizationID: configuration.organizationID, workspaceID: configuration.workspaceID),
              account.isCurrent(context) else { throw Failure.authentication }
        var historyURL = try XCTUnwrap(URLComponents(url: configuration.origin, resolvingAgainstBaseURL: false))
        historyURL.path = "/api/workspaces/" + configuration.workspaceID + "/recordings"
        historyURL.queryItems = [.init(name: "page", value: "1"), .init(name: "limit", value: "30"),
            .init(name: "userId", value: configuration.expectedAccountID)]
        var historyRequest = URLRequest(url: try XCTUnwrap(historyURL.url))
        historyRequest.httpMethod = "GET"
        historyRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        let response = try await legacy.perform(historyRequest)
        guard response.status == 200, account.isCurrent(context) else { throw Failure.invalidLedger }
        let history = try JSONDecoder().decode(QAHistory.self, from: response.body)
        let matches = history.recordings.filter { $0.id == serverID }
        guard matches.count == 1, let match = matches.first else { throw Failure.invalidLedger }
        try validateQARecord(match, sourceID: id, serverID: serverID)
        _ = try qaContext()
        // Only identifiers for this invented source are evidence. Never attach raw
        // responses, account snapshots, login configuration, passwords or cookies.
        let evidence = XCTAttachment(string: "Direct QA synthetic source: " + id.uuidString.lowercased()
            + "\nrecordingID=" + receipt.recordingID + "\nHistory and detail source/owner/hash bindings verified."
            + "\nlocalSourcePurged=" + String(record.sourcePurged == true)
            + "\nAnalysis completion and AI quality are outside this smoke test.")
        evidence.name = "direct-qa-synthetic-source-" + id.uuidString.lowercased()
            + (record.sourcePurged == true ? "-after-local-removal" : "-before-local-removal")
        evidence.lifetime = .keepAlways
        attach(evidence)
    }

    private func qaContext() throws -> AccountContext {
        guard configuration.mode == .qa, let context = account.context,
              account.state == .signedIn, account.isCurrent(context),
              context.identity.internalUserID == configuration.expectedAccountID,
              context.identity.legacyOrigin == configuration.origin.absoluteString,
              context.organizationID == configuration.organizationID,
              context.workspaceID == configuration.workspaceID else { throw Failure.authentication }
        return context
    }

    private func validateQARecord(_ value: QARecord, sourceID: UUID, serverID: Int) throws {
        guard value.id == serverID, String(value.workspaceId) == configuration.workspaceID,
              value.userId.map(String.init) == configuration.expectedAccountID,
              value.uploadedById.map(String.init) == configuration.expectedAccountID,
              value.title == "pichi-native-qa-" + runID.uuidString.lowercased(), value.source == "transcript",
              value.importSourceId == sourceID.uuidString.lowercased(), value.assessmentMode == "account_context",
              value.assessmentPolicyVersion == 1 else { throw Failure.invalidLedger }
    }

    func control(_ values: [String: Bool]) async throws {
        guard configuration.mode == .localStand else { throw Failure.invalidConfiguration }
        _ = try await request(path: "/__e2e/control", body: JSONSerialization.data(withJSONObject: values))
    }

    func ledger(_ id: UUID) async throws -> Ledger {
        guard configuration.mode == .localStand else { throw Failure.invalidConfiguration }
        let bytes = try await request(path: "/__e2e/ledger?sessionID=" + id.uuidString.lowercased())
        let value = try JSONDecoder().decode(Ledger.self, from: bytes)
        guard value.sessionID.lowercased() == id.uuidString.lowercased() else { throw Failure.invalidLedger }
        return value
    }

    func assertOneServerRecording(_ id: UUID, minimumAttempts: Int) async throws {
        let ledger = try await ledger(id)
        XCTAssertGreaterThanOrEqual(ledger.attempts.count, minimumAttempts)
        XCTAssertEqual(ledger.sourceCount, 1)
        XCTAssertEqual(ledger.recordingCount, 1)
        XCTAssertEqual(ledger.importCount, 1)
        XCTAssertEqual(ledger.chargeCount, 1)
        XCTAssertEqual(ledger.chargedRecordingCount, 1)
        XCTAssertFalse(ledger.analysisProvider.isEmpty, "The server must identify real or synthetic analysis explicitly")
        let attachment = XCTAttachment(data: try await request(path: "/__e2e/ledger?sessionID=" + id.uuidString.lowercased()),
            uniformTypeIdentifier: "public.json")
        attachment.name = "synthetic-https-server-ledger-" + id.uuidString
        attachment.lifetime = .keepAlways
        attach(attachment)
    }

    private func request(path: String, body: Data? = nil) async throws -> Data {
        guard let url = URL(string: path, relativeTo: configuration.origin)?.absoluteURL,
              url.host == "localhost", url.port == 18443, url.scheme == "https" else { throw Failure.invalidConfiguration }
        var request = URLRequest(url: url)
        request.httpMethod = body == nil ? "GET" : "POST"
        request.httpBody = body
        request.timeoutInterval = 10
        request.setValue(configuration.controlToken, forHTTPHeaderField: "X-Codex-Control-Token")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (bytes, response) = try await controlSession.data(for: request)
        guard let response = response as? HTTPURLResponse, response.url == url,
              response.statusCode == 200, bytes.count <= 1_048_576 else { throw Failure.invalidLedger }
        return bytes
    }

    func wait(file: StaticString = #filePath, line: UInt = #line,
              _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(90))
        while !(try await condition()) {
            guard ContinuousClock.now < deadline else {
                waitFailed = true
                preserveWaitEvidence(line: line)
                XCTFail("Synthetic HTTPS condition timed out at its calling step", file: file, line: line)
                throw Failure.timeout
            }
            try await Task.sleep(for: .milliseconds(100))
        }
    }

    private func preserveWaitEvidence(line: UInt) {
        let current = PrivateProfileStorage.current
        var records: [[String: Any]] = []
        for id in capturedIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            if let value = try? outbox(id) {
                records.append(["id": id.uuidString, "state": value.state.rawValue,
                    "attemptCount": value.attemptCount, "automaticConsent": value.automaticConsent,
                    "automaticAccountContext": value.automaticAccountContext == true,
                    "pause": value.pauseReason?.rawValue ?? "none", "hasSourceHash": value.sourceSHA256 != nil,
                    "hasTranscriptBytes": value.transcriptBytes != nil, "hasReceipt": value.receipt != nil])
            } else { records.append(["id": id.uuidString, "recordMissing": true]) }
        }
        // Only queue metadata for invented sources, never account envelopes or HTTP bodies.
        let diagnostic: [String: Any] = ["callingLine": line, "availability": service.snapshot.availability.rawValue,
            "cloudSync": service.snapshot.cloudSyncEnabled, "deleteLocal": service.snapshot.deleteLocalAfterAcceptance,
            "accountState": String(describing: account.state), "awaitingValidation": account.isAwaitingLegacyServerValidation,
            "accountCurrent": account.context.map { account.isCurrent($0) } ?? false,
            "currentProfile": current.id, "currentGeneration": current.generation.uuidString,
            "expectedProfile": profile?.id ?? "none", "expectedGeneration": profile?.generation.uuidString ?? "none",
            "profileReadable": profile.map { PrivateProfileStorage.isReadable($0) } ?? false, "records": records]
        do {
            let bytes = try JSONSerialization.data(withJSONObject: diagnostic, options: [.prettyPrinted, .sortedKeys])
            let evidence = XCTAttachment(data: bytes, uniformTypeIdentifier: "public.json")
            evidence.name = "synthetic-https-wait-diagnostic"; evidence.lifetime = .keepAlways; attach(evidence)
            if let path = ProcessInfo.processInfo.environment["PICHI_KIOSK_EVIDENCE_DIR"] {
                let destination = URL(fileURLWithPath: path, isDirectory: true)
                    .appendingPathComponent("http-wait-" + runID.uuidString, isDirectory: true)
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                try bytes.write(to: destination.appendingPathComponent("diagnostic.json"), options: .atomic)
                try FileManager.default.copyItem(at: root, to: destination.appendingPathComponent(root.lastPathComponent, isDirectory: true))
            }
        } catch { XCTFail("Synthetic timeout evidence preservation failed") }
    }

    func stop() async {
        guard running else { return }
        await service?.shutdown()
        await coordinator?.shutdownForTermination()
        await capture?.shutdownForTermination()
        await account?.shutdown()
        running = false
    }

    func cleanup(preserveFailure: Bool) async {
        await stop()
        var mustPreserve = preserveFailure || waitFailed
        if !preserveForRelaunch && configuration.mode == .localStand {
            // Only the task-private stand is controlled. Reset even on failed assertions.
            do {
                try await control(["offline": false, "releaseHeldResponses": true,
                    "dropNextSuccessfulImportResponse": false, "holdNextImportResponse": false,
                    "offlineAfterDroppedResponse": false])
            } catch {
                mustPreserve = true
                XCTFail("Task-private HTTPS control reset failed: \(error)")
            }
        }
        controlSession.invalidateAndCancel()
        await qaCredentials?.clear()
        qaCredentials = nil
        if configuration.mode == .qa {
            // Retained failure evidence must never contain a persisted QA session.
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("synthetic-session.private.json").path))
        }
        PrivateProfileStorage.select(previousProfile)
        if mustPreserve {
            let evidence = XCTAttachment(string: "Synthetic HTTPS failure evidence retained at: " + root.path)
            evidence.name = "synthetic-https-retained-failure-root"
            evidence.lifetime = .keepAlways
            attach(evidence)
        }
        if !preserveForRelaunch && !mustPreserve {
            defaults.removePersistentDomain(forName: suite)
            do {
                let owner = try JSONDecoder().decode(Ownership.self,
                    from: Data(contentsOf: root.appendingPathComponent("test-owner.json")))
                guard owner.purpose == "pichi-native-http-acceptance-v1", owner.runID == runID,
                      owner.origin == configuration.origin, root.resolvingSymlinksInPath().path == root.path else {
                    throw Failure.invalidConfiguration
                }
                try FileManager.default.removeItem(at: root)
            }
            catch { XCTFail("Owned HTTPS fixture cleanup failed: \(error)") }
        }
    }

    nonisolated enum Failure: Error { case invalidConfiguration, authentication, invalidLedger, timeout, invalidPCM }
}

private final class HTTPControlRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

private actor HTTPStoredSession: LegacyAccountSessionStoring {
    let url: URL
    init(url: URL) { self.url = url }
    func load() throws -> LegacyAccountStoredSession? {
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        return try JSONDecoder().decode(LegacyAccountStoredSession.self, from: Data(contentsOf: url))
    }
    func save(_ session: LegacyAccountStoredSession) throws {
        try JSONEncoder().encode(session).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    func clear() throws { if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) } }
}

/// QA credentials remain in memory even if a test fails and keeps synthetic evidence.
private actor HTTPMemorySession: LegacyAccountSessionStoring {
    private var value: LegacyAccountStoredSession?
    func load() -> LegacyAccountStoredSession? { value }
    func save(_ session: LegacyAccountStoredSession) { value = session }
    func clear() { value = nil }
}

@MainActor private final class HTTPBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw AccountError.unconfigured }
    func cancel() {}
}
private actor HTTPNoGrant: AccountCredentialStoring {
    func load() async throws -> AccountGrant? { nil }
    func save(_ grant: AccountGrant) async throws { throw AccountError.unconfigured }
    func clear() async throws {}
}
private actor HTTPNoOIDC: AccountTransporting {
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL { throw AccountError.unconfigured }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func account(accessToken: String) async throws -> AccountSnapshot { throw AccountError.unconfigured }
    func revoke(refreshToken: String) async throws {}
}
private struct HTTPRedactor: TranscriptTextRedacting {
    func redactWithSpans(_ text: String) async throws -> TranscriptTextRedaction {
        .init(text: text, spans: [], provisionalSafeUTF16: text.utf16.count)
    }
}
@MainActor private final class HTTPArbiter: MeetingAudioActivityArbitrating {
    private(set) var hasLease = false
    func acquireMeetingCapture() async throws -> MeetingAudioActivityLease {
        guard !hasLease else { throw MeetingCoordinatorError.recordingAlreadyActive }
        hasLease = true
        return .init(id: UUID())
    }
    func release(_ lease: MeetingAudioActivityLease) async { hasLease = false }
}

private actor HTTPCapture: MeetingCaptureControlling {
    struct Summary: Sendable { let frames: Int; let peak: Float; let pcm: Data; let sha256: Data }
    private var track: MeetingAudioTrack?
    private var startedAt = Date()
    private var captured: Summary?
    func preflightPermissions() async throws {}
    func start(session: MeetingSession, configuration: MeetingCaptureConfiguration, sessionDirectory: URL,
               eventHandler: @escaping @Sendable (MeetingCaptureEvent) -> Void,
               liveAudioHandler: (@Sendable (MeetingAudioTrackKind, CMSampleBuffer) -> Void)?) async throws -> MeetingCaptureStartResult {
        guard configuration.audioStorageMode == .memoryOnly, configuration.requiresEncryptedPersistence == true else {
            throw HTTPFixture.Failure.invalidPCM
        }
        let format = try XCTUnwrap(AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000,
            channels: 1, interleaved: false))
        let pcm = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 24_000))
        pcm.frameLength = 24_000
        let samples = try XCTUnwrap(pcm.floatChannelData?[0])
        for frame in 0..<24_000 { samples[frame] = 0.1 * sin(Float(frame) * 0.1) }
        let bytes = Data(bytes: samples, count: 24_000 * MemoryLayout<Float>.size)
        captured = .init(frames: 24_000, peak: 0.1, pcm: bytes, sha256: Data(SHA256.hash(data: bytes)))
        let sample = try MeetingCapturePCMConverter.sampleBuffer(buffer: pcm, presentationTime: .zero)
        liveAudioHandler?(.microphone, sample)
        let track = MeetingAudioTrack(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic-http-pcm",
            sourceDisplayName: "Synthetic PCM", format: nil, timebase: session.timebase, health: .waiting, chunks: [])
        self.track = track; startedAt = session.startedAt
        return .init(tracks: [track], firstPresentationTime: .init(value: 0, timescale: 16_000))
    }
    func summary() throws -> Summary { try XCTUnwrap(captured) }
    func stop(sessionID: MeetingSessionID) async throws -> MeetingCaptureStopResult {
        .init(tracks: [try XCTUnwrap(track)], stoppedAt: startedAt.addingTimeInterval(1.5))
    }
    func shutdownForTermination() async { track = nil; captured = nil }
}

@MainActor private final class HTTPRecognizer: MeetingProcessingControlling {
    private var checkpoint: (@MainActor (MeetingPCMTranscriptBatch) async throws -> Void)?
    func validateMemoryAudioInput(configuration: MeetingCaptureConfiguration, backendID: MeetingBackendID) throws -> MeetingBackendDescriptor {
        try XCTUnwrap(MeetingTranscriptionBackendRegistry.makeDefault().descriptor(for: backendID))
    }
    func prepareMemoryAudio(session: MeetingSession, sessionDirectory: URL,
        checkpoint: @escaping @MainActor (MeetingPCMTranscriptBatch) async throws -> Void) async throws {
        self.checkpoint = checkpoint
    }
    func recognize(_ pcm: HTTPCapture.Summary, session: MeetingSession) async throws {
        guard pcm.frames == 24_000, pcm.peak > 0, pcm.pcm.count == pcm.frames * MemoryLayout<Float>.size,
              Data(SHA256.hash(data: pcm.pcm)) == pcm.sha256 else { throw HTTPFixture.Failure.invalidPCM }
        let track = try XCTUnwrap(session.audioTracks.first)
        let segment = MeetingTranscriptSegment(id: UUID(), start: .init(value: 0, timescale: 16_000),
            end: .init(value: 24_000, timescale: 16_000), sourceTrackID: track.id, speakerID: nil,
            text: HTTPFixture.text, revision: 0, status: .final, overlap: .none, completeness: .complete)
        try await XCTUnwrap(checkpoint)(.init(segments: [segment]))
    }
    func cancelMemoryAudio(sessionID: MeetingSessionID) async { checkpoint = nil }
    func process(session: MeetingSession, sessionDirectory: URL,
                 progress: @escaping @MainActor (MeetingProcessingStage) -> Void) async throws -> MeetingProcessingResult {
        progress(.transcribing)
        let attempt = MeetingProcessingAttempt(id: UUID(), startedAt: session.startedAt, completedAt: Date(),
            stage: .completed, pipelineVersion: MeetingProcessingPipeline.pipelineVersion,
            asrProvider: "synthetic-pcm-recognizer", asrModel: "synthetic", diarizationModel: nil,
            lastCompletedTrackID: session.audioTracks.first?.id, errorCode: nil)
        return .init(speakers: session.speakers, segments: session.transcriptSegments, attempt: attempt)
    }
}
