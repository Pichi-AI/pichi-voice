import Foundation

extension PichiPublicationOutboxTests {
    /// Actual shared facade and private stores, with an in-memory legacy server double.
    /// These checks do not establish deployed billing, analysis quality or device login.
    static func checkLegacyCloudPublicationService(root: URL) async throws -> Int {
        let manager = FileManager.default
        try manager.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let previous = PrivateProfileStorage.current
        defer { PrivateProfileStorage.select(previous) }
        let guest = try PrivateProfileStorage.proposed(context: nil, generation: UUID(), legacyRootDirectory: root)
        PrivateProfileStorage.select(guest)
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func wait(_ condition: @MainActor () async throws -> Bool) async throws {
            let deadline = Date().addingTimeInterval(12)
            while !(try await condition()) {
                guard Date() < deadline else { throw LegacyFacadeFailure.timeout }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        let configuration = LegacyAccountConfiguration(apiBaseURL: URL(string: "https://legacy.example")!, bundleIdentifier: "ai.synthetic.voice")
        let transport = LegacyFacadeTransport(configuration: configuration)
        let profiles = PrivateProfileService()
        try profiles.configure(isBusy: { false }, prepare: {}, activate: { _ in })
        let account = AccountSessionService(configuration: nil, browser: LegacyFacadeBrowser(), transport: LegacyFacadeUnusedOIDC(),
            credentials: LegacyFacadeCredentials(), lifecycle: profiles, legacyConfiguration: configuration, legacyTransport: transport)
        let meetings = PrivateProfileMeetingStore()
        let service = PichiCloudPublicationService(account: account, meetings: meetings, profiles: profiles,
            recordingCipher: { try MeetingRecordingCipher(profileID: $0.id, key: Data(repeating: 0x73, count: 32)) },
            deleteAcceptedRecording: { id, owner, digest in
                try await meetings.delete(id: id, expectedOwnership: owner, validating: { source in
                    try Task.checkCancellation()
                    guard try PichiProtectedPublicationSource.localFingerprint(for: source) == digest else {
                        throw PichiPublicationOutboxFailure.receiptConflict
                    }
                })
            })
        try await service.install()
        await account.signIn(email: "a@synthetic.example", password: "synthetic-password")
        try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        try await service.refresh()
        check(service.isLegacySession && service.legacyDestinationURL == configuration.apiBaseURL && !service.snapshot.cloudSyncEnabled,
              "Legacy composition uses the trusted destination and defaults consent off without an OIDC HTTP client")
        let participantID = UUID()
        func capture(priorLegacyAdmission: Bool = false) async throws -> MeetingSession {
            let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1, firstPresentationTime: nil)
            var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic legacy Ёё", languageCode: "ru",
                microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
                startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
            session.state = .recording; session.audioStorageMode = .memoryOnly; session.piiRedactionEnabled = true
            if priorLegacyAdmission {
                // Explicitly restore an already admitted pre-automatic source. The ordinary
                // capture callback cannot grant new historical/automatic consent.
                let prior = PichiPublicationOutboxStore(profile: PrivateProfileStorage.current, destination: .legacy(configuration))
                _ = try await prior.capture(id: session.id, automaticConsent: true)
            }
            session.profileOwnership = try await meetings.captureOwnership(for: session.id)
            let track = UUID()
            session.audioTracks = [.init(id: track, kind: .microphone, sourceIdentifier: "synthetic", sourceDisplayName: "Synthetic",
                format: nil, timebase: timebase, health: .waiting, chunks: [])]
            try await meetings.create(session)
            session.state = .completed; session.endedAt = session.startedAt.addingTimeInterval(5); session.transcriptIsComplete = true
            session.speakers = [.init(id: participantID, displayName: "Source speaker Ёё", diarizationClusterID: nil,
                trackKind: .microphone, isLocalUser: false, identityCandidates: [])]
            session.transcriptSegments = [.init(id: UUID(), start: .init(value: 0, timescale: 1), end: .init(value: 5, timescale: 1),
                sourceTrackID: track, speakerID: participantID, text: "Synthetic protected [PERSON].", revision: 0,
                status: .final, overlap: .none, completeness: .complete, attributionState: .assigned)]
            try await meetings.save(session)
            return session
        }
        let oldLocal = try await capture()
        try await service.setCloudSyncEnabled(true)
        check(try await service.status(for: oldLocal.id) == .localOnly, "Later consent cannot grant historical send admission")
        let source = try await capture(priorLegacyAdmission: true)
        try await Task.sleep(for: .seconds(5.2))
        let unsentPosts = await transport.postCount(), unsentStatus = try await service.status(for: source.id)
        check(unsentPosts == 0 && unsentStatus == .queued,
              "A resumed legacy worker never uploads a new source without explicit assessment and Send")
        let options = try await service.legacyAssessmentOptions(for: source.id)
        check(options.employees.map(\.id) == ["123", "124"] && options.criteria.map(\.id) == ["31"]
              && options.participants == [.init(id: participantID, displayName: "Source speaker Ёё")],
              "Before-send options preserve source labels and server employee identities independently")
        await transport.loseNextPostResponse()
        try await service.sendLegacy(source.id, userID: "124", participantID: participantID, criteriaIDs: ["31"])
        if case .retryScheduled = try await service.status(for: source.id) { check(true, "Offline ambiguous delivery schedules the same request") }
        else { check(false, "Offline ambiguous delivery schedules the same request") }
        try await wait {
            if case .acceptedNeedsReview(_, .accountReview) = try await service.status(for: source.id) { return true }
            return false
        }
        let replay = await transport.replaySummary()
        check(replay.posts == 2 && replay.rows == 1 && replay.identical,
              "Lost-response replay reuses exact source/selection bytes and observes one synthetic accepted row")
        try await service.reconcile(source.id)
        check(await transport.postCount() == 2, "Pending billing reconciliation uses GET, never another upload or debit request")
        await transport.finishAnalysis()
        try await service.reconcile(source.id)
        if case .accepted(let receipt) = try await service.status(for: source.id) {
            check(receipt.analysisState == .succeeded && receipt.billingState == .charged, "Analysis success is shown only after a matching terminal assessment")
        } else { check(false, "Terminal assessment receipt remains accepted") }
        try await service.retry(source.id)
        check(await transport.postCount() == 2, "Retry of an accepted source remains status reconciliation")
        try await service.setCloudSyncEnabled(false)
        let receiptBeforeManualCleanup = try await service.status(for: source.id)
        check(try await meetings.loadTranscript(id: source.id) != nil,
              "Accepted manual legacy data is retained while current cleanup is OFF")
        try await service.setDeleteLocalAfterAcceptance(true)
        let compactedManualFile = PrivateProfileStorage.current.rootDirectory.appendingPathComponent("CloudPublication/OutboxV1/settled/"
            + source.id.uuidString.lowercased() + ".json")
        try await wait {
            try JSONDecoder().decode(PichiPublicationOutboxRecord.self, from: Data(contentsOf: compactedManualFile)).sourcePurged == true
        }
        check(try await service.status(for: source.id) == receiptBeforeManualCleanup,
              "Manual legacy cleanup keeps the original accepted receipt")
        check(await transport.postCount() == 2,
              "Enabling cleanup for a manual legacy receipt never repeats its POST")
        await account.logout()
        await account.signIn(email: "b@synthetic.example", password: "synthetic-password")
        try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        try await service.refresh()
        check(!service.snapshot.cloudSyncEnabled && service.snapshot.items.isEmpty,
              "Account B does not inherit account A's consent or publication projection")
        let hiddenSource = try await meetings.load(id: source.id), hiddenStatus = try await service.status(for: source.id)
        check(hiddenSource == nil && hiddenStatus == .localOnly,
              "Account B cannot observe A's local source or accepted receipt")
        await account.logout(); await service.shutdown(); await account.shutdown()
        check(await transport.isClosed(), "Shared service and account shutdown release their own legacy transport")
        return checks
    }
}

private enum LegacyFacadeFailure: Error { case timeout }
@MainActor private final class LegacyFacadeBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL { throw AccountError.unconfigured }
    func cancel() {}
}
private actor LegacyFacadeCredentials: AccountCredentialStoring {
    func load() async throws -> AccountGrant? { nil }
    func save(_ grant: AccountGrant) async throws { preconditionFailure("Legacy credentials cannot enter the OIDC vault") }
    func clear() async throws {}
}
private actor LegacyFacadeUnusedOIDC: AccountTransporting {
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL { throw AccountError.unconfigured }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse { throw AccountError.unconfigured }
    func account(accessToken: String) async throws -> AccountSnapshot { throw AccountError.unconfigured }
    func revoke(refreshToken: String) async throws {}
}
private actor LegacyFacadeTransport: LegacyAccountTransporting {
    let configuration: LegacyAccountConfiguration
    private var userID = "123"
    private var row: [String: Any]?
    private var bodies: [Data] = []
    private var loseNext = false
    private var closed = false
    init(configuration: LegacyAccountConfiguration) { self.configuration = configuration }
    func login(email: String, password: String, captchaToken: String?) async throws -> AccountSnapshot {
        userID = email.hasPrefix("b@") ? "124" : "123"
        return try await account()
    }
    func account() async throws -> AccountSnapshot {
        .init(schemaVersion: 1, account: .init(id: userID, displayName: "Synthetic", email: nil),
            identity: .init(issuer: "", subject: "", legacyOrigin: configuration.apiBaseURL.absoluteString),
            organizations: [.init(id: "17", name: "Synthetic", workspaces: [.init(id: "9", name: "Synthetic", capabilities: ["recordings:import"])])],
            activeOrganizationID: "17")
    }
    func switchOrganization(_ organizationID: String) async throws -> AccountSnapshot { try await account() }
    func logout() async throws {}
    func clearSession() async {}
    func shutdown() async { closed = true }
    func isClosed() -> Bool { closed }
    func postCount() -> Int { bodies.count }
    func loseNextPostResponse() { loseNext = true }
    func replaySummary() -> (posts: Int, rows: Int, identical: Bool) { (bodies.count, row == nil ? 0 : 1, Set(bodies).count == 1) }
    func finishAnalysis() {
        row?["importBillingStatus"] = "charged"
        row?["evaluationResults"] = ["evaluations": [["criterion_id": 31, "score": 5, "reasoning": "Synthetic"]]]
    }
    func perform(_ request: URLRequest) async throws -> LegacyAccountHTTPResponse {
        let value: Any
        switch request.url!.path {
        case "/api/workspaces/9/users":
            value = [["id": 123, "fullName": "Employee A", "isActive": true], ["id": 124, "fullName": "Employee B", "isActive": true]]
        case "/api/evaluation-criteria/names": value = [["id": 31, "name": "Synthetic criterion"]]
        case "/api/recordings/transcript":
            guard let body = request.httpBody else { throw AccountError.invalidResponse }
            bodies.append(body)
            if row == nil {
                var accepted = try JSONSerialization.jsonObject(with: body) as! [String: Any]
                let source = accepted["transcriptImport"] as! [String: Any]
                accepted["id"] = 101; accepted["uploadedById"] = Int(userID)!
                accepted["importSourceId"] = (source["sessionID"] as! String).lowercased()
                accepted["transcriptionStatus"] = "completed"; accepted["processingStage"] = NSNull()
                accepted["evaluationResults"] = NSNull(); accepted["importBillingStatus"] = "uncertain"
                row = accepted
            }
            if loseNext { loseNext = false; throw AccountError.networkUnavailable }
            value = row!
        case "/api/recordings/101": value = row!
        default: throw AccountError.invalidConfiguration
        }
        return .init(status: 200, body: try JSONSerialization.data(withJSONObject: value), retryAfter: nil)
    }
}
