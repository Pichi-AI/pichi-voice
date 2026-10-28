import CryptoKit
import Foundation

extension PichiPublicationConsentTests {
    static func checkPublicationWire(fixtures: URL) async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
        func object(_ name: String) throws -> [String: Any] { try JSONSerialization.jsonObject(with: bytes(name)) as! [String: Any] }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        let provenance = try object("provenance.json")
        check(provenance["commit"] as? String == "128e1dc17b51f0f0877e00eafb1f73c13cadddf5", "Wire fixture pin is explicit")
        for file in provenance["files"] as! [[String: Any]] {
            let content = try bytes(file["path"] as! String)
            check(digest(content) == file["sha256"] as? String && content.count == file["byteLength"] as? Int,
                  "Every copied approved fixture retains its frozen bytes")
        }
        let manifest = try object("manifest.json")
        let source = try bytes("protected-transcript.json")
        let sourceHash = (manifest["source"] as! [String: Any])["sha256"] as! String
        check(source.count == 1392 && digest(source) == sourceHash, "The source byte length and digest match W2")
        let provisional = try bytes("protected-transcript-provisional.json")
        check(provisional.count == 1469 && digest(provisional) == "23ffa082ef9ab6ac1b57963757fac8293917db051854756c3bd318786d9f574a",
              "The separately approved W2 provisional fixture retains its pinned bytes")
        let configuration = AccountConfiguration(issuer: URL(string: "https://identity.example/realms/pichi")!,
            apiBaseURL: URL(string: "https://api.example")!, clientID: "synthetic-native",
            apiAudience: "synthetic-api", bundleIdentifier: "ai.synthetic.voice")
        let context = AccountContext(identity: .init(issuer: configuration.issuer.absoluteString,
            subject: "synthetic-owner", internalUserID: "123"), organizationID: "17", workspaceID: "9", generation: UUID())
        let operationID = UUID(uuidString: "00000000-0000-4000-8000-000000000201")!
        let participantID = UUID(uuidString: "00000000-0000-4000-8000-000000000003")!
        let boundary = "pichi-synthetic-protected-import-v1"
        func upload(_ data: Data = source, hash: String? = nil, assessment: PichiPublicationAssessment? = nil,
                    boundary: String = boundary) throws -> PichiPublicationRequest {
            try .importSource(configuration: configuration, context: context, operationID: operationID,
                transcriptBytes: data, sourceSHA256: hash ?? digest(data),
                assessment: assessment ?? .init(participantID: participantID, criteriaIDs: []), boundary: boundary)
        }
        let post = try upload()
        let provisionalPost = try upload(provisional)
        check(provisionalPost.unsignedRequest.httpBody?.range(of: provisional) != nil,
              "Display-only provisional flags are preserved without stripping or re-encoding")
        let originalBody = post.unsignedRequest.httpBody
        check(originalBody == (try bytes("pending-criteria.multipart")), "POST multipart bytes exactly match W2's approved pending-criteria body")
        check(post.unsignedRequest.httpMethod == "POST" && post.unsignedRequest.url?.absoluteString == "https://api.example/api/v1/recordings/imports",
              "The import uses the signed API route")
        check(post.unsignedRequest.value(forHTTPHeaderField: "Idempotency-Key") == operationID.uuidString,
              "The original operation UUID is the idempotency key")
        check(post.unsignedRequest.value(forHTTPHeaderField: "Content-Type") == "multipart/form-data; boundary=" + boundary,
              "Multipart boundary/header matches the frozen body")
        check(post.unsignedRequest.value(forHTTPHeaderField: "Authorization") == nil, "Durable wire operations contain no bearer")
        let pending = try post.receipt(from: .init(status: 202, body: bytes("receipt-pending-criteria.json"), retryAfter: nil))
        check(pending.analysisState == .needsCriteria && pending.uploadState == .accepted, "Pending criteria is still an accepted upload")
        check(try post.receipt(from: .init(status: 200, body: bytes("receipt-pending-criteria.json"), retryAfter: nil)) == pending,
              "An identical delivery retry accepts the same receipt")
        let get = try PichiPublicationRequest.status(configuration: configuration, context: context, receipt: pending)
        let binding = PichiPublicationAssessment(participantID: participantID, criteriaIDs: ["31"])
        let patch = try PichiPublicationRequest.resolveAssessment(configuration: configuration, context: context,
            receipt: pending, transcriptBytes: source, assessment: binding)
        check(patch.unsignedRequest.httpMethod == "PATCH" && patch.unsignedRequest.url?.absoluteString == "https://api.example/api/v1/recordings/imports/synthetic-import-201/assessment",
              "Pending resolution uses the existing import identity")
        let resolution = try object("resolution-cases.json")
        check((try JSONSerialization.jsonObject(with: patch.unsignedRequest.httpBody!) as! NSDictionary)
              == ((resolution["resolve"] as! [String: Any])["body"] as! NSDictionary), "PATCH body matches the explicit approved binding")
        for key in ["resolve", "identicalEffectivePatchRetry"] {
            let value = resolution[key] as! [String: Any]
            let receipt = try patch.receipt(from: .init(status: value["httpStatus"] as! Int, body: json(value["receipt"]!), retryAfter: nil))
            check(receipt.importID == pending.importID && receipt.recordingID == pending.recordingID && receipt.analysisState == .queued,
                  "First and identical PATCH responses preserve source identity")
        }
        let nullPost = try upload(assessment: .init(participantID: nil, criteriaIDs: []))
        let nullBody = nullPost.unsignedRequest.httpBody
        check(nullBody == (try bytes("pending-participant.multipart")), "Explicit null/empty assessment exactly matches W2 multipart")
        check(String(data: nullBody!, encoding: .utf8)?.contains("{\"participantID\":null,\"criteriaIDs\":[]}") == true,
              "Null participant is encoded rather than omitted")
        let nullReceipt = try nullPost.receipt(from: .init(status: 202, body: bytes("receipt-pending-participant.json"), retryAfter: nil))
        check(nullReceipt.analysisState == .needsParticipant, "Null participant has precedence over empty criteria")
        let replay = resolution["originalPostAfterResolution"] as! [String: Any]
        let current = try nullPost.receipt(from: .init(status: replay["httpStatus"] as! Int, body: json(replay["receipt"]!), retryAfter: nil))
        check(current.importID == nullReceipt.importID && current.analysisState == .queued && nullPost.unsignedRequest.httpBody == nullBody,
              "Original null-binding POST can return current queued analysis without mutating its fingerprint")
        for snapshot in (try object("status-receipts.json"))["receipts"] as! [[String: Any]] {
            let receipt = try get.receipt(from: .init(status: 200, body: json(snapshot["body"]!), retryAfter: nil))
            check(receipt.uploadState == .accepted && receipt.analysisState.rawValue == (snapshot["body"] as! [String: Any])["analysisState"] as? String,
                  "All six analysis states are independent from accepted upload")
        }
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let protocolFixture = try object("protocol-candidate.json")
        for value in protocolFixture["errors"] as! [[String: Any]] {
            for method in value["methods"] as! [String] {
                let request = method == "POST" ? post : method == "GET" ? get : patch
                let response = PichiPublicationHTTPResponse(status: value["httpStatus"] as! Int, body: try json(value["body"]!),
                    retryAfter: (value["exampleHeaders"] as? [String: String])?["Retry-After"])
                do { _ = try request.receipt(from: response, now: now); check(false, "An error cannot become accepted") }
                catch let error as PichiPublicationRemoteFailure {
                    check(error.action.rawValue == value["nativeAction"] as? String && error.httpStatus == response.status,
                          "Every approved method/status/code maps to its frozen native action")
                    if value["case"] as? String == "insufficient-balance" {
                        check(error.action == .pauseForAccountReview && error.retryAfter == nil,
                              "402 preserves the source for account review without retry or logout")
                    }
                }
            }
        }
        func rejects(_ expected: PichiPublicationWireFailure, _ message: String, _ operation: () throws -> Void) throws {
            do { try operation(); check(false, message) }
            catch let error as PichiPublicationWireFailure { check(error == expected, message) }
        }
        for status in [201, 204, 302, 422, 501] {
            let body = try json(["error": ["code": "UNKNOWN", "status": status, "message": "PRIVATE SOURCE/TOKEN", "details": ["text": "PRIVATE"]]])
            do { _ = try post.receipt(from: .init(status: status, body: body, retryAfter: "30")); check(false, "Unexpected status cannot become success") }
            catch let error as PichiPublicationRemoteFailure {
                check(error.action == .pauseForReceiptReview && error.retryAfter == nil
                      && !String(describing: error).contains("PRIVATE"), "Unknown errors pause and discard server prose/details")
            }
        }
        let mismatch = try json(["error": ["code": "AUTHENTICATION_FAILED", "status": 401]])
        do { _ = try post.receipt(from: .init(status: 403, body: mismatch, retryAfter: nil)); check(false, "Mismatched envelope cannot classify auth") }
        catch let error as PichiPublicationRemoteFailure { check(error.action == .pauseForReceiptReview && error.code == nil, "Status/code pairs must agree") }
        do { _ = try post.receipt(from: .init(status: 503, body: Data("<html>PRIVATE</html>".utf8), retryAfter: nil)); check(false, "Malformed errors cannot infer retry") }
        catch let error as PichiPublicationRemoteFailure { check(error.action == .pauseForReceiptReview, "Malformed errors pause for review") }
        for (status, code) in [(429, "RATE_LIMITED"), (500, "INTERNAL_ERROR"), (503, "INTERNAL_ERROR")] {
            let response = PichiPublicationHTTPResponse(status: status,
                body: try json(["error": ["code": code, "status": status]]), retryAfter: "30")
            check(post.retryableFailure(from: response, now: now)?.retryAfter == .seconds(30),
                  "Early failure extraction preserves the existing strict wire retry classification")
        }
        for response in [PichiPublicationHTTPResponse(status: 202, body: Data(), retryAfter: "30"),
                         .init(status: 401, body: try json(["error": ["code": "AUTHENTICATION_FAILED", "status": 401]]), retryAfter: "30"),
                         .init(status: 403, body: mismatch, retryAfter: "30"),
                         .init(status: 503, body: Data("<html>PRIVATE</html>".utf8), retryAfter: "30"),
                         .init(status: 503, body: Data(repeating: 0, count: PichiPublicationRequest.maximumResponseBytes + 1), retryAfter: "30")] {
            check(post.retryableFailure(from: response, now: now) == nil,
                  "Early failure extraction admits no success, authentication, malformed or oversized response")
        }
        var receiptObject = try object("receipt-pending-criteria.json")
        for (key, value) in [("schemaVersion", 2 as Any), ("uploadState", "pending"), ("analysisState", "unknown"), ("importID", ""), ("recordingID", "\nforeign")] {
            var changed = receiptObject; changed[key] = value
            try rejects(.invalidResponse, "Malformed receipt never becomes accepted") { _ = try post.receipt(from: .init(status: 202, body: json(changed), retryAfter: nil)) }
        }
        for key in ["importID", "recordingID"] {
            var changed = receiptObject; changed[key] = "foreign-identity"
            try rejects(.invalidResponse, "Status/PATCH cannot replace a known receipt identity") { _ = try get.receipt(from: .init(status: 200, body: json(changed), retryAfter: nil)) }
        }
        receiptObject.removeValue(forKey: "analysisState")
        try rejects(.invalidResponse, "Missing receipt fields fail closed") { _ = try post.receipt(from: .init(status: 200, body: json(receiptObject), retryAfter: nil)) }
        try rejects(.responseTooLarge, "Responses are bounded before parsing") { _ = try post.receipt(from: .init(status: 200, body: Data(repeating: 32, count: 65_537), retryAfter: nil)) }
        try rejects(.invalidRequest, "A changed source digest cannot be sent") { _ = try upload(hash: String(repeating: "0", count: 64)) }
        try rejects(.invalidRequest, "Hash spelling is lowercase and exact") { _ = try upload(hash: sourceHash.uppercased()) }
        try rejects(.invalidRequest, "Boundary header injection is rejected") { _ = try upload(boundary: "bad\r\nboundary") }
        try rejects(.invalidRequest, "A source cannot assess an unrepresented participant") { _ = try upload(assessment: .init(participantID: UUID(), criteriaIDs: [])) }
        try rejects(.invalidRequest, "Duplicate criteria cannot change effective binding semantics") { _ = try upload(assessment: .init(participantID: participantID, criteriaIDs: ["31", "31"])) }
        for selection in [PichiPublicationAssessment(participantID: nil, criteriaIDs: ["31"]), .init(participantID: participantID, criteriaIDs: [])] {
            try rejects(.invalidRequest, "PATCH requires a complete explicit binding") {
                _ = try PichiPublicationRequest.resolveAssessment(configuration: configuration, context: context, receipt: pending, transcriptBytes: source, assessment: selection)
            }
        }
        let sourceObject = try JSONSerialization.jsonObject(with: source) as! [String: Any]
        for mutation in ["audio", "original", "redaction", "boolean", "oversized", "boundary", "empty", "blank", "zeroDuration", "tooLong", "tooManySpeakers"] {
            var changed = sourceObject
            switch mutation {
            case "audio": changed["audio"] = "/private/audio.caf"
            case "redaction": var privacy = changed["privacy"] as! [String: Any]; privacy["transcriptPIIRedacted"] = false; changed["privacy"] = privacy
            case "boolean": changed["schemaVersion"] = true
            case "empty": changed["segments"] = []
            case "tooLong": changed["durationSeconds"] = 86_401
            case "tooManySpeakers": changed["speakers"] = (0..<101).map { _ in ["id": UUID().uuidString, "displayName": "Synthetic", "isLocalUser": false] as [String: Any] }
            default:
                var segments = changed["segments"] as! [[String: Any]]
                if mutation == "original" { segments[0]["originalText"] = "PRIVATE ORIGINAL" }
                if mutation == "oversized" { segments[0]["text"] = String(repeating: "x", count: 100_001) }
                if mutation == "boundary" { segments[0]["text"] = "--" + boundary }
                if mutation == "blank" { segments[0]["text"] = " \n\t" }
                if mutation == "zeroDuration" { segments[0]["endSeconds"] = segments[0]["startSeconds"] }
                changed["segments"] = segments
            }
            try rejects(.invalidRequest, "Unsafe recovered source fails before transport: " + mutation) { _ = try upload(json(changed)) }
        }
        // W2 PR1649 ac2b6c35 source-validation parity. These checks retain exact
        // payload bytes and do not change the independent retry-policy cases below.
        for blank in ["", " \n\t", "\u{00A0}", "\u{FEFF}"] {
            var changed = sourceObject
            var speakers = changed["speakers"] as! [[String: Any]]
            speakers[0]["displayName"] = blank
            changed["speakers"] = speakers
            try rejects(.invalidRequest, "Blank speaker names fail before transport") { _ = try upload(json(changed)) }
        }
        var changed = sourceObject
        var speakers = changed["speakers"] as! [[String: Any]]
        speakers[1]["isLocalUser"] = true
        changed["speakers"] = speakers
        try rejects(.invalidRequest, "At most one speaker may be marked as the local user") { _ = try upload(json(changed)) }
        speakers[0]["isLocalUser"] = false
        speakers[1]["isLocalUser"] = false
        // U+0085 is content under ECMAScript trim, while U+FEFF above is whitespace.
        speakers[0]["displayName"] = "\u{0085}"
        changed["speakers"] = speakers
        let noLocalUserBytes = try json(changed)
        check(try upload(noLocalUserBytes).unsignedRequest.httpBody?.range(of: noLocalUserBytes) != nil,
              "Zero local-user markers and nonblank names preserve their exact bytes")
        changed = sourceObject
        var segments = changed["segments"] as! [[String: Any]]
        segments.swapAt(0, 1)
        changed["segments"] = segments
        try rejects(.invalidRequest, "Segment starts must be nondecreasing") { _ = try upload(json(changed)) }
        segments = sourceObject["segments"] as! [[String: Any]]
        segments[1]["startSeconds"] = 0
        segments[2]["endSeconds"] = sourceObject["durationSeconds"]
        changed["segments"] = segments
        let equalStartBytes = try json(changed)
        check(try upload(equalStartBytes).unsignedRequest.httpBody?.range(of: equalStartBytes) != nil,
              "Equal starts, overlapping turns and an end at the exact duration remain valid")
        segments[2]["endSeconds"] = (sourceObject["durationSeconds"] as! Double) + 0.001
        changed["segments"] = segments
        try rejects(.invalidRequest, "Every segment ends within the transcript duration") { _ = try upload(json(changed)) }

        let firstSpeakerID = (sourceObject["speakers"] as! [[String: Any]])[0]["id"] as! String
        for attributed in [true, false] {
            changed = sourceObject
            speakers = changed["speakers"] as! [[String: Any]]
            speakers[0]["displayName"] = String(repeating: "\u{1F600}", count: 100)
            changed["speakers"] = speakers
            let segmentCount = attributed ? 1_000 : 2_500
            let text = String(repeating: "\u{1F600}", count: attributed ? 9 : 18)
            segments = (0..<segmentCount).map { index in
                var segment: [String: Any] = [
                    "id": String(format: "00000000-0000-4000-8000-%012d", index + 1_000),
                    "startSeconds": 0, "endSeconds": 1, "text": text]
                if attributed { segment["speakerID"] = firstSpeakerID }
                return segment
            }
            changed["segments"] = segments
            let atLimitBytes = try json(changed)
            let request = try upload(atLimitBytes, assessment: .init(participantID: nil, criteriaIDs: []))
            check(request.unsignedRequest.httpBody?.range(of: atLimitBytes) != nil,
                  "The exact 250000 rendered UTF-16 limit includes speaker labels or the 32-unit unknown label")
            segments[segmentCount - 1]["text"] = text + "x"
            changed["segments"] = segments
            try rejects(.invalidRequest, "Repeated labels cannot amplify rendering beyond 250000 units") {
                _ = try upload(json(changed), assessment: .init(participantID: nil, criteriaIDs: []))
            }
        }
        let bearer = "synthetic-access-token-not-a-real-credential"
        let authorized = try post.authorized(using: .init(context: context, accessToken: bearer))
        check(authorized.value(forHTTPHeaderField: "Authorization") == "Bearer " + bearer
              && post.unsignedRequest.value(forHTTPHeaderField: "Authorization") == nil && authorized.httpBody == originalBody,
              "Authorization adds a transient bearer without changing durable bytes")
        for stale in [AccountContext(identity: context.identity, organizationID: "17", workspaceID: "9", generation: UUID()),
                      .init(identity: context.identity, organizationID: "17", workspaceID: "other", generation: context.generation)] {
            do { _ = try post.authorized(using: .init(context: stale, accessToken: bearer)); check(false, "A different context cannot authorize this operation") }
            catch let error as AccountError { check(error == .staleOperation, "Owner/destination/generation is immutable across access") }
        }
        do { _ = try post.authorized(using: .init(context: context, accessToken: "bad\r\nheader")); check(false, "Bearer header injection cannot be sent") }
        catch let error as AccountError { check(error == .invalidToken, "Invalid bearer material is not projected or sent") }
        for id in ["a/b", "a?x=1", "a#fragment", "%2F", "Ё ё", ".", "..", " a "] {
            let receipt = PichiPublicationReceipt(schemaVersion: 1, importID: id, recordingID: "recording", uploadState: .accepted, analysisState: .queued)
            let request = try PichiPublicationRequest.status(configuration: configuration, context: context, receipt: receipt)
            let parts = URLComponents(url: request.unsignedRequest.url!, resolvingAgainstBaseURL: false)!
            let path = parts.percentEncodedPath
            check(parts.host == "api.example" && parts.query == nil && parts.fragment == nil
                  && path.hasPrefix("/api/v1/recordings/imports/")
                  && path.split(separator: "/").count == 5 && String(path.split(separator: "/").last!).removingPercentEncoding == id,
                  "Opaque receipt IDs remain exactly one encoded path segment")
        }
        check(PichiPublicationRetryPolicy.parseRetryAfter("30", now: now) == .seconds(30), "Delta-seconds retry header parses")
        check(PichiPublicationRetryPolicy.parseRetryAfter("Tue, 14 Nov 2023 22:13:50 GMT", now: now) == .seconds(30), "HTTP-date retry header uses fixed locale/timezone")
        check(PichiPublicationRetryPolicy.parseRetryAfter("Tue, 14 Nov 2023 22:13:19 GMT", now: now) == .seconds(0), "Past retry dates cannot create negative delay")
        for header in ["-1", "1.5", "NaN", "garbage", "Mon, 14 Nov 2023 22:13:50 GMT"] {
            check(PichiPublicationRetryPolicy.parseRetryAfter(header, now: now) == nil, "Invalid retry headers do not become numeric schedules")
        }
        check(PichiPublicationRetryPolicy.parseRetryAfter("3601", now: now) == .seconds(3601), "A long representable Retry-After retains its real deadline")
        check(PichiPublicationRetryPolicy.parseRetryAfter("Wed, 15 Nov 2023 22:13:50 GMT", now: now) == .seconds(86430), "A long HTTP-date retains its real deadline")
        check(PichiPublicationRetryPolicy.parseRetryAfter(String(repeating: "9", count: 128), now: now) == .beyondAutomaticWindow, "An unrepresentable server deadline requires review")
        check(PichiPublicationRetryPolicy.decision(afterAttempt: 1, retryAfter: nil) == .retry(afterSeconds: 5), "Retry backoff starts bounded")
        check(PichiPublicationRetryPolicy.decision(afterAttempt: 4, retryAfter: nil) == .retry(afterSeconds: 40), "Retry backoff increases without a hot loop")
        check(PichiPublicationRetryPolicy.decision(afterAttempt: 1, retryAfter: .seconds(30)) == .retry(afterSeconds: 30), "Valid server retry timing is honored")
        check(PichiPublicationRetryPolicy.decision(afterAttempt: 1, retryAfter: .beyondAutomaticWindow) == .pause(.retryAfterBeyondBudget), "Over-window retry becomes visible pause")
        check(PichiPublicationRetryPolicy.decision(afterAttempt: 1, retryAfter: .seconds(7200)) == .pause(.retryAfterBeyondBudget), "Long server delays do not extend automatic delivery")
        for attempt in [-1, 0, 5, Int.max] {
            check(PichiPublicationRetryPolicy.decision(afterAttempt: attempt, retryAfter: nil) == .pause(.retryBudgetExhausted), "Automatic attempts have a finite persisted budget")
        }
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try post.authorized(using: .init(context: context, accessToken: bearer))
        }
        do { _ = try await cancelled.value; check(false, "Cancellation cannot become authorization") }
        catch is CancellationError { check(true, "Cancellation remains distinct from retryable transport failure") }
        check(post.unsignedRequest.httpBody == originalBody && nullPost.unsignedRequest.httpBody == nullBody,
              "Parsing, PATCH and failures never mutate either original POST")
        // These injected services exercise only N1's operation fences. The synthetic
        // lifecycle is not evidence of N2 profile isolation or production readiness.
        let account = AccountSessionService(configuration: configuration, browser: WireSyntheticBrowser(),
            transport: WireSyntheticAccountTransport(configuration: configuration), credentials: WireSyntheticCredentials(),
            lifecycle: WireSyntheticLifecycle())
        await account.signIn()
        try await account.selectWorkspace(organizationID: "17", workspaceID: "9")
        let admitted = account.context!
        let bound = try PichiPublicationRequest.importSource(configuration: configuration, context: admitted,
            operationID: operationID, transcriptBytes: source, sourceSHA256: sourceHash,
            assessment: .init(participantID: nil, criteriaIDs: []), boundary: boundary)
        let accessRequest = try await bound.authorized(using: account)
        check(accessRequest.value(forHTTPHeaderField: "Authorization") == "Bearer synthetic-wire-access",
              "Runtime request obtains a bearer through the actual N1 authorizedAccess operation")
        check(try bound.receipt(from: .init(status: 202, body: bytes("receipt-pending-participant.json"), retryAfter: nil), account: account).importID == pending.importID,
              "A current N1 context may parse its response before N2 application")
        let foreignConfiguration = AccountConfiguration(issuer: configuration.issuer,
            apiBaseURL: URL(string: "https://foreign.example")!, clientID: configuration.clientID,
            apiAudience: configuration.apiAudience, bundleIdentifier: configuration.bundleIdentifier)
        let foreign = try PichiPublicationRequest.importSource(configuration: foreignConfiguration, context: admitted,
            operationID: operationID, transcriptBytes: source, sourceSHA256: sourceHash,
            assessment: .init(participantID: nil, criteriaIDs: []), boundary: boundary)
        do { _ = try await foreign.authorized(using: account); check(false, "Another valid API URL must not receive this grant") }
        catch let error as AccountError { check(error == .invalidConfiguration, "N1's exact trusted configuration fences bearer destination") }
        await account.logout()
        do { _ = try bound.receipt(from: .init(status: 202, body: bytes("receipt-pending-participant.json"), retryAfter: nil), account: account); check(false, "A late response after logout cannot be applied") }
        catch let error as AccountError { check(error == .staleOperation, "Post-await N1 generation fence rejects a late response") }
        do { _ = try await bound.authorized(using: account); check(false, "Logged-out context cannot send") }
        catch let error as AccountError { check(error == .staleOperation, "Authorization is not restored from a durable descriptor") }
        await account.shutdown()
        let http = try PichiPublicationHTTPClient(configuration: configuration)
        for url in ["https://foreign.example/api/v1/recordings/imports", "http://api.example/api/v1/recordings/imports",
                    "https://api.example/api/v1/account", "https://api.example/api/v1/recordings/imports?extra=1"] {
            var request = authorized; request.url = URL(string: url)!
            do { _ = try await http.perform(request); check(false, "Unsafe request must fail before network I/O") }
            catch let error as PichiPublicationNetworkFailure { check(error == .invalidRequest, "HTTP executor rejects authority/route/scheme changes locally") }
        }
        do { _ = try await http.perform(post.unsignedRequest); check(false, "A stored unsigned request must not be sent") }
        catch let error as PichiPublicationNetworkFailure { check(error == .invalidRequest, "HTTP executor requires transient authorization") }
        async let shutdownA: Void = http.shutdown()
        async let shutdownB: Void = http.shutdown()
        _ = await (shutdownA, shutdownB)
        do { _ = try await http.perform(authorized); check(false, "Closed executor cannot reopen") }
        catch let error as PichiPublicationNetworkFailure { check(error == .shutdown, "Joined shutdown closes executor admission") }
        checks += try await checkAssessmentOptions(fixtures: fixtures.deletingLastPathComponent().appendingPathComponent("PichiAssessmentOptionsV1"))
        // The separate legacy codec shares protected source validation while retaining
        // its actual cookie-session JSON protocol and pre-upload employee selection.
        let legacyOrigin = URL(string: "https://legacy.example")!
        let legacySelection = LegacyPublicationSelection(userID: "123", participantID: participantID, criteriaIDs: ["31"])
        let legacyBody = try PichiLegacyPublicationRequest.importBody(context: context, transcriptBytes: source, selection: legacySelection)
        let legacyPost = try PichiLegacyPublicationRequest.importSource(origin: legacyOrigin, frozenBody: legacyBody)
        check(legacyPost.httpMethod == "POST" && legacyPost.url?.absoluteString == "https://legacy.example/api/recordings/transcript"
              && legacyPost.value(forHTTPHeaderField: "Authorization") == nil && legacyPost.value(forHTTPHeaderField: "Cookie") == nil,
              "Legacy wire uses the existing JSON route without serializing session credentials")
        let legacyReplayBody = try PichiLegacyPublicationRequest.importBody(context: context, transcriptBytes: source, selection: legacySelection)
        check(legacyBody.range(of: source) != nil && legacyBody == legacyReplayBody,
              "Every legacy replay retains exact protected bytes and deterministic binding")
        let sourceID = (sourceObject["sessionID"] as! String).lowercased()
        var legacyRow: [String: Any] = ["id": 101, "title": sourceObject["title"]!, "workspaceId": 9, "userId": 123, "uploadedById": 123,
            "criteriaIds": [31], "managerSpeakerId": participantID.uuidString, "transcriptImport": sourceObject,
            "importSourceId": sourceID, "transcriptionStatus": "completed", "processingStage": NSNull(),
            "evaluationResults": NSNull(), "importBillingStatus": "charged"]
        func legacyReceipt(_ row: [String: Any], status: Int = 202) throws -> PichiPublicationReceipt {
            try PichiLegacyPublicationRequest.receipt(from: .init(status: status, body: json(row), retryAfter: nil),
                context: context, transcriptBytes: source, selection: legacySelection)
        }
        let legacyAccepted = try legacyReceipt(legacyRow)
        check(legacyAccepted.recordingID == "101" && legacyAccepted.importID == sourceID && legacyAccepted.analysisState == .queued,
              "A completed source with no assessment result is accepted, not successful analysis")
        check(try legacyReceipt(legacyRow, status: 200) == legacyAccepted, "An idempotent legacy replay retains the same receipt")
        legacyRow["evaluationResults"] = ["evaluations": [["criterion_id": 31, "score": 5, "reasoning": "Synthetic"]]]
        check(try legacyReceipt(legacyRow).analysisState == .succeeded, "Legacy success requires a result for every selected criterion")
        legacyRow["evaluationResults"] = ["evaluations": [["criterion_id": 32, "score": 5]]]
        check(try legacyReceipt(legacyRow).analysisState == .queued, "Unrelated assessment cannot satisfy the selected criteria")
        legacyRow["importBillingStatus"] = "pending"
        let pendingBilling = try legacyReceipt(legacyRow)
        check(pendingBilling.billingState?.needsReview == true && pendingBilling.analysisState != .succeeded,
              "Accepted pending billing requires review without another debit")
        legacyRow.removeValue(forKey: "importBillingStatus")
        check(try legacyReceipt(legacyRow).billingState == .uncertain, "Old deployed routes cannot imply safe billing reconciliation")
        legacyRow["transcriptionStatus"] = "failed"
        check(try legacyReceipt(legacyRow).analysisState == .failed, "Explicit server failure is a separate terminal analysis outcome")
        legacyRow["uploadedById"] = 124
        try rejects(.invalidResponse, "Another account's row cannot become this source's receipt") { _ = try legacyReceipt(legacyRow) }
        legacyRow["uploadedById"] = 123; legacyRow["workspaceId"] = 10
        try rejects(.invalidResponse, "A different destination workspace is rejected") { _ = try legacyReceipt(legacyRow) }
        legacyRow["workspaceId"] = 9; legacyRow["managerSpeakerId"] = UUID().uuidString
        try rejects(.invalidResponse, "The selected source speaker is immutable") { _ = try legacyReceipt(legacyRow) }
        try rejects(.invalidRequest, "Legacy cannot upload with empty criteria") {
            _ = try PichiLegacyPublicationRequest.importBody(context: context, transcriptBytes: source,
                selection: .init(userID: "123", participantID: participantID, criteriaIDs: []))
        }
        try rejects(.invalidRequest, "An unrepresented source speaker cannot be selected") {
            _ = try PichiLegacyPublicationRequest.importBody(context: context, transcriptBytes: source,
                selection: .init(userID: "123", participantID: UUID(), criteriaIDs: ["31"]))
        }
        for (status, action) in [(401, PichiPublicationRemoteAction.pauseForReauthentication), (403, .pauseForPermissionReview),
            (409, .pauseForConflictReview), (402, .pauseForAccountReview), (429, .boundedRetry), (503, .boundedRetry)] {
            let failure = PichiLegacyPublicationRequest.remoteFailure(.init(status: status,
                body: Data("PRIVATE SERVER PROSE".utf8), retryAfter: "30"))
            check(failure.action == action && !String(describing: failure).contains("PRIVATE"),
                  "Legacy errors retain bounded action/status while discarding server prose")
        }
        check(PichiLegacyPublicationRequest.databaseID("01") == nil && PichiLegacyPublicationRequest.databaseID("2147483648") == nil,
              "Legacy database IDs cannot smuggle path syntax or exceed server bounds")
        let autoBody = try PichiLegacyPublicationRequest.accountContextBody(context: context, transcriptBytes: source, managerSpeakerID: nil)
        let autoObject = try JSONSerialization.jsonObject(with: autoBody) as! [String: Any]
        check(autoBody.range(of: source) != nil && autoObject["userId"] == nil && autoObject["criteriaIds"] == nil
            && autoObject["analysisId"] == nil && autoObject["managerSpeakerId"] == nil,
              "Account-context import keeps original bytes and never requires a manager or inferred employee")
        check(autoObject["assessmentMode"] as? String == "account_context" && autoObject["assessmentPolicyVersion"] as? Int == 1,
              "Account-context mode has an explicit immutable server policy version")
        let canonical = try PichiLegacyPublicationRequest.canonicalSourceSHA256(source)
        check(try PichiLegacyPublicationRequest.canonicalSourceSHA256(json(sourceObject)) == canonical,
              "Semantic source fingerprint tolerates JSONB object-key ordering without changing content")
        var autoRow: [String: Any] = ["id": 201, "title": sourceObject["title"]!, "workspaceId": 9,
            "userId": 123, "uploadedById": 123, "assessmentMode": "account_context", "assessmentPolicyVersion": 1,
            "managerSpeakerId": NSNull(), "analysisId": NSNull(), "criteriaIds": [], "assessmentPolicyCriteriaIds": [],
            "transcriptImport": sourceObject, "importSourceId": sourceID, "transcriptionStatus": "completed",
            "evaluationResults": NSNull(), "importBillingStatus": "not_required"]
        func automaticReceipt(_ row: [String: Any], expected: PichiPublicationReceipt? = nil) throws -> PichiPublicationReceipt {
            try PichiLegacyPublicationRequest.accountContextReceipt(from: .init(status: 202, body: json(row), retryAfter: nil),
                context: context, sessionID: UUID(uuidString: sourceID)!, canonicalSourceSHA256: canonical,
                managerSpeakerID: nil, expected: expected)
        }
        let autoAccepted = try automaticReceipt(autoRow)
        check(autoAccepted.analysisState == .queued && autoAccepted.accountContextPolicyCriteriaIDs == [],
              "Accepted unknown-speaker source freezes server policy without claiming analysis success")
        autoRow["evaluationResults"] = ["noCriteria": true, "evaluations": []]
        check(try automaticReceipt(autoRow).analysisState == .queued, "No-criteria boolean alone cannot fabricate a summary outcome")
        autoRow["summary"] = "Existing synthetic contextual summary"
        check(try automaticReceipt(autoRow).analysisState == .succeeded, "Completed actual summary is a terminal no-criteria outcome")
        autoRow["criteriaIds"] = [31]
        autoRow["evaluationResults"] = ["evaluations": [["criterion_id": 31, "score": 5]]]
        autoRow["title"] = "Authorized display rename"
        check(try automaticReceipt(autoRow, expected: autoAccepted).analysisState == .succeeded,
              "Authorized current criteria/display edits preserve original policy/source binding")
        autoRow["assessmentPolicyCriteriaIds"] = [99]
        try rejects(.invalidResponse, "Original server policy criterion snapshot cannot change during later status reads") {
            _ = try automaticReceipt(autoRow, expected: autoAccepted)
        }
        autoRow["assessmentPolicyCriteriaIds"] = []; autoRow["assessmentPolicyVersion"] = true
        try rejects(.invalidResponse, "A boolean cannot masquerade as policy version one") { _ = try automaticReceipt(autoRow, expected: autoAccepted) }
        autoRow["assessmentPolicyVersion"] = 1.5
        try rejects(.invalidResponse, "Fractional policy versions are invalid") { _ = try automaticReceipt(autoRow, expected: autoAccepted) }
        autoRow["assessmentPolicyVersion"] = 1; autoRow["uploadedById"] = 124
        try rejects(.invalidResponse, "Another uploader cannot become the account's accepted receipt") { _ = try automaticReceipt(autoRow, expected: autoAccepted) }
        check(PichiPublicationRetryPolicy.automaticContextDecision(afterAttempt: 100, retryAfter: nil) == .retry(afterSeconds: 60),
              "Long offline account-context delivery remains queued with a bounded backoff")
        return checks
    }
}

@MainActor private final class WireSyntheticBrowser: AccountBrowserAuthenticating {
    func authenticate(url: URL, callbackScheme: String) async throws -> URL {
        let state = URLComponents(url: url, resolvingAgainstBaseURL: false)!.queryItems!.first { $0.name == "state" }!.value!
        var callback = URLComponents(string: callbackScheme + ":/oauth/callback")!
        callback.queryItems = [.init(name: "code", value: "synthetic-code"), .init(name: "state", value: state)]
        return callback.url!
    }
    func cancel() {}
}
private actor WireSyntheticCredentials: AccountCredentialStoring {
    private var grant: AccountGrant?
    func load() async throws -> AccountGrant? { self.grant }
    func save(_ grant: AccountGrant) async throws { self.grant = grant }
    func clear() async throws { self.grant = nil }
}
private actor WireSyntheticAccountTransport: AccountTransporting {
    let configuration: AccountConfiguration
    init(configuration: AccountConfiguration) { self.configuration = configuration }
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL {
        var url = URLComponents(string: "https://identity.example/authorize")!
        url.queryItems = [.init(name: "state", value: state)]
        return url.url!
    }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse {
        .init(accessToken: "synthetic-wire-access", refreshToken: "synthetic-wire-refresh", expiresAt: Date().addingTimeInterval(3_600), subject: "synthetic-owner")
    }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse { try await exchange(code: "", verifier: "", nonce: "") }
    func account(accessToken: String) async throws -> AccountSnapshot {
        .init(schemaVersion: 1, account: .init(id: "123", displayName: "Synthetic", email: nil),
            identity: .init(issuer: self.configuration.issuer.absoluteString, subject: "synthetic-owner"),
            organizations: [.init(id: "17", name: "Synthetic", workspaces: [.init(id: "9", name: "Synthetic", capabilities: [])])])
    }
    func revoke(refreshToken: String) async throws {}
}
@MainActor private final class WireSyntheticLifecycle: AccountSessionLifecycle {
    var isAccountIsolationReady: Bool { true }
    func transition(from: AccountContext?, to: AccountContext?, generation: UUID) async throws {}
}
