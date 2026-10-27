import CryptoKit
import Foundation

extension PichiPublicationConsentTests {
    static func checkAssessmentOptions(fixtures: URL) async throws -> Int {
        var checks = 0
        func check(_ value: Bool, _ message: String) { precondition(value, message); checks += 1 }
        func bytes(_ name: String) throws -> Data { try Data(contentsOf: fixtures.appendingPathComponent(name)) }
        func object(_ name: String) throws -> [String: Any] {
            try JSONSerialization.jsonObject(with: bytes(name)) as! [String: Any]
        }
        func json(_ value: Any) throws -> Data { try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) }
        func digest(_ value: Data) -> String { SHA256.hash(data: value).map { String(format: "%02x", $0) }.joined() }
        func replacing(_ object: [String: Any], _ path: [String], _ value: Any?) -> [String: Any] {
            var changed = object
            let key = path[0]
            if path.count == 1 { changed[key] = value }
            else { changed[key] = replacing(changed[key] as! [String: Any], Array(path.dropFirst()), value) }
            return changed
        }
        func rejects(_ expected: PichiPublicationWireFailure, _ message: String, _ operation: () throws -> Void) throws {
            do { try operation(); check(false, message) }
            catch let failure as PichiPublicationWireFailure { check(failure == expected, message) }
        }

        let provenance = try object("provenance.json")
        check(provenance["repository"] as? String == "Pichi-AI/web"
              && provenance["commit"] as? String == "ac2b6c352de1c74080c44e0fe206f039b84726eb",
              "Assessment options derive from the approved immutable W2 implementation")
        let files = provenance["files"] as! [[String: Any]]
        check(Set(files.map { $0["path"] as! String }) == [".gitattributes", "options-bound.json", "options-first-page.json", "options-next-page.json"],
              "The fixture manifest covers every synthetic response and byte-preserving attributes")
        for file in files {
            let content = try bytes(file["path"] as! String)
            check(digest(content) == file["sha256"] as? String && content.count == file["byteLength"] as? Int,
                  "Every derived assessment-options fixture retains its pinned bytes")
        }
        let source = try Data(contentsOf: fixtures.deletingLastPathComponent()
            .appendingPathComponent("PichiAccountSyncV1/protected-transcript.json"))
        let nativeSource = provenance["nativeSource"] as! [String: Any]
        check(digest(source) == nativeSource["sha256"] as? String && source.count == nativeSource["byteLength"] as? Int,
              "Represented participants are checked against the approved protected source bytes")
        let configuration = AccountConfiguration(issuer: URL(string: "https://identity.example/realms/pichi")!,
            apiBaseURL: URL(string: "https://api.example")!, clientID: "synthetic-native",
            apiAudience: "synthetic-api", bundleIdentifier: "ai.synthetic.voice")
        let context = AccountContext(identity: .init(issuer: configuration.issuer.absoluteString,
            subject: "synthetic-owner", internalUserID: "123"), organizationID: "17", workspaceID: "9", generation: UUID())
        let receipt = PichiPublicationReceipt(schemaVersion: 1, importID: "synthetic-import-201",
            recordingID: "synthetic-recording-201", uploadState: .accepted, analysisState: .needsParticipant)
        func request(cursor: String? = nil, limit: Int = 2) throws -> PichiPublicationRequest {
            try .assessmentOptions(configuration: configuration, context: context, receipt: receipt,
                transcriptBytes: source, cursor: cursor, limit: limit)
        }
        let firstRequest = try request()
        let firstBytes = try bytes("options-first-page.json")
        let firstObject = try object("options-first-page.json")
        func decode(_ value: [String: Any], using request: PichiPublicationRequest = firstRequest) throws -> PichiPublicationAssessmentOptions {
            try request.assessmentOptions(from: .init(status: 200, body: json(value), retryAfter: nil))
        }
        let first = try firstRequest.assessmentOptions(from: .init(status: 200, body: firstBytes, retryAfter: nil))
        check(first.context == .init(accountID: "123", organizationID: "17", workspaceID: "9")
              && first.receipt == receipt && first.participants.map(\.displayName) == ["Борис Ёлкин", "Алёна Ёжик"],
              "An authorized first page preserves context, receipt and represented display data")
        check(first.criteria.data.map(\.id) == ["31", "32"] && first.criteria.pagination.limit == 2
              && first.criteria.pagination.cursor == nil && first.criteria.pagination.hasMore
              && first.currentAssessment == .init(participantID: nil, criteriaIDs: []) && first.canResolvePending,
              "Null selection and explicit first-page pagination do not choose an assessment")
        let cursor = first.criteria.pagination.nextCursor!
        let nextRequest = try request(cursor: cursor)
        let next = try nextRequest.assessmentOptions(from: .init(status: 200, body: bytes("options-next-page.json"), retryAfter: nil))
        check(next.criteria.data.map(\.id) == ["33"] && next.criteria.pagination.cursor == cursor
              && next.criteria.pagination.nextCursor == nil && !next.criteria.pagination.hasMore
              && next.currentAssessment == first.currentAssessment && next.participants == first.participants,
              "A continuation echoes its cursor and terminates without losing represented participants")
        let bound = try firstRequest.assessmentOptions(from: .init(status: 200, body: bytes("options-bound.json"), retryAfter: nil))
        check(bound.receipt.analysisState == .queued && !bound.canResolvePending
              && bound.currentAssessment.participantID == UUID(uuidString: "00000000-0000-4000-8000-000000000003")
              && bound.currentAssessment.criteriaIDs == ["33"] && !bound.criteria.data.contains(where: { $0.id == "33" }),
              "Current selected criteria may be outside this authorized page and never imply a PATCH")
        check(firstRequest.unsignedRequest.httpMethod == "GET" && firstRequest.unsignedRequest.httpBody == nil
              && firstRequest.unsignedRequest.value(forHTTPHeaderField: "Authorization") == nil
              && firstRequest.unsignedRequest.url?.absoluteString == "https://api.example/api/v1/recordings/imports/synthetic-import-201/assessment-options?organizationID=17&workspaceID=9&limit=2",
              "The immutable options request is an unsigned bodyless GET for one existing receipt")
        let defaults = try PichiPublicationRequest.assessmentOptions(configuration: configuration, context: context,
            receipt: receipt, transcriptBytes: source)
        check(URLComponents(url: defaults.unsignedRequest.url!, resolvingAgainstBaseURL: false)?.queryItems?.last?.value == "50",
              "The native default page size matches W2")

        // Exact object keys and scalar types are checked at each nested boundary.
        let paths: [[String]] = [["schemaVersion"], ["context", "accountID"], ["receipt", "analysisState"],
            ["criteria", "data"], ["criteria", "pagination", "limit"], ["currentAssessment", "participantID"],
            ["currentAssessment", "criteriaIDs"], ["criteria", "pagination", "cursor"],
            ["criteria", "pagination", "next_cursor"], ["canResolvePending"]]
        for path in paths {
            try rejects(.invalidResponse, "Missing required options field fails closed: " + path.joined(separator: ".")) {
                _ = try decode(replacing(firstObject, path, nil))
            }
        }
        for path in [["extra"], ["context", "extra"], ["receipt", "extra"], ["criteria", "extra"],
                     ["criteria", "pagination", "extra"], ["currentAssessment", "extra"]] {
            try rejects(.invalidResponse, "Unknown options field fails closed") { _ = try decode(replacing(firstObject, path, "PRIVATE")) }
        }
        for (path, value) in [(["schemaVersion"], true as Any), (["receipt", "schemaVersion"], true),
                              (["criteria", "pagination", "limit"], true), (["criteria", "pagination", "limit"], 2.5),
                              (["criteria", "pagination", "has_more"], 1), (["canResolvePending"], 1),
                              (["currentAssessment", "participantID"], 3), (["currentAssessment", "criteriaIDs"], NSNull())] {
            try rejects(.invalidResponse, "Options scalar types cannot use numeric or boolean coercion") {
                _ = try decode(replacing(firstObject, path, value))
            }
        }
        for key in ["accountID", "organizationID", "workspaceID"] {
            try rejects(.invalidResponse, "Options context is pinned to the actual owner and destination") {
                _ = try decode(replacing(firstObject, ["context", key], "foreign"))
            }
        }
        for (key, value) in [("importID", "foreign"), ("recordingID", "foreign"), ("uploadState", "pending"), ("analysisState", "unknown")] {
            try rejects(.invalidResponse, "An options response cannot retarget the known accepted receipt") {
                _ = try decode(replacing(firstObject, ["receipt", key], value))
            }
        }
        try rejects(.invalidResponse, "A settled analysis cannot claim pending-resolution eligibility") {
            _ = try decode(replacing(firstObject, ["receipt", "analysisState"], "succeeded"))
        }

        let participants = firstObject["participants"] as! [[String: Any]]
        for mutation in ["duplicate", "foreign", "missing", "overCount", "oversizedName", "invalidID", "unknown", "missingName"] {
            var changed = participants
            switch mutation {
            case "duplicate": changed[1] = changed[0]
            case "foreign": changed[1]["id"] = "00000000-0000-4000-8000-000000000999"
            case "missing": changed.removeLast()
            case "overCount": changed = Array(repeating: changed[0], count: 101)
            case "oversizedName": changed[0]["displayName"] = String(repeating: "😀", count: 101)
            case "invalidID": changed[0]["id"] = "synthetic-not-a-uuid"
            case "unknown": changed[0]["employeeID"] = "PRIVATE"
            default: changed[0].removeValue(forKey: "displayName")
            }
            try rejects(.invalidResponse, "Only the bounded represented participant set is exposed: " + mutation) {
                _ = try decode(replacing(firstObject, ["participants"], changed))
            }
        }
        var boundaryParticipants = participants
        boundaryParticipants[0]["displayName"] = String(repeating: "😀", count: 100)
        check(try decode(replacing(firstObject, ["participants"], boundaryParticipants)).participants[0].displayName.utf16.count == 200,
              "The participant display-name boundary counts UTF-16 like W2")
        try rejects(.invalidResponse, "The current participant must be represented by this source") {
            _ = try decode(replacing(firstObject, ["currentAssessment", "participantID"], "00000000-0000-4000-8000-000000000999"))
        }

        let data = (firstObject["criteria"] as! [String: Any])["data"] as! [[String: Any]]
        for mutation in ["duplicate", "extraRow", "invalidID", "numericID", "unknown", "missingName"] {
            var changed = data
            switch mutation {
            case "duplicate": changed[1]["id"] = changed[0]["id"]
            case "extraRow": changed.append(["id": "33", "name": "Synthetic criterion 33"])
            case "invalidID": changed[0]["id"] = "\nPRIVATE"
            case "numericID": changed[0]["id"] = 31
            case "unknown": changed[0]["description"] = "PRIVATE"
            default: changed[0].removeValue(forKey: "name")
            }
            try rejects(.invalidResponse, "Criteria pages are bounded, typed and duplicate-free: " + mutation) {
                _ = try decode(replacing(firstObject, ["criteria", "data"], changed))
            }
        }
        var longName = data
        longName[0]["name"] = String(repeating: "Ё", count: 1_000)
        check(try decode(replacing(firstObject, ["criteria", "data"], longName)).criteria.data[0].name.utf16.count == 1_000,
              "Criterion names use the response byte bound without inventing a server length limit")
        for selection in [Array(repeating: "31", count: 101), ["\nPRIVATE"]] {
            try rejects(.invalidResponse, "Current selected criteria remain bounded opaque IDs") {
                _ = try decode(replacing(firstObject, ["currentAssessment", "criteriaIDs"], selection))
            }
        }
        for (path, value) in [(["limit"], 1 as Any), (["cursor"], cursor), (["next_cursor"], NSNull()),
                              (["has_more"], false), (["next_cursor"], "invalid+cursor"),
                              (["next_cursor"], String(repeating: "a", count: 2_049))] {
            try rejects(.invalidResponse, "Pagination must match the requested bounded page and make progress") {
                _ = try decode(replacing(firstObject, ["criteria", "pagination"] + path, value))
            }
        }
        try rejects(.invalidResponse, "A page that claims more results must contain the requested number of rows") {
            _ = try decode(replacing(firstObject, ["criteria", "data"], [data[0]]))
        }
        let nextObject = try object("options-next-page.json")
        let repeated = replacing(replacing(nextObject, ["criteria", "pagination", "has_more"], true),
            ["criteria", "pagination", "next_cursor"], cursor)
        try rejects(.invalidResponse, "A continuation cannot repeat its own cursor") { _ = try decode(repeated, using: nextRequest) }
        try rejects(.responseTooLarge, "Options bytes are bounded before JSON decoding") {
            _ = try firstRequest.assessmentOptions(from: .init(status: 200, body: Data(repeating: 32, count: 65_537), retryAfter: nil))
        }
        try rejects(.invalidResponse, "Malformed options bodies are rejected") {
            _ = try firstRequest.assessmentOptions(from: .init(status: 200, body: Data("PRIVATE malformed JSON".utf8), retryAfter: nil))
        }
        let status = try PichiPublicationRequest.status(configuration: configuration, context: context, receipt: receipt)
        try rejects(.invalidRequest, "Another request kind cannot decode an options page") {
            _ = try status.assessmentOptions(from: .init(status: 200, body: firstBytes, retryAfter: nil))
        }

        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let errors: [(Int, String, PichiPublicationRemoteAction)] = [
            (400, "INVALID_REQUEST", .stopAndShowValidation), (401, "AUTHENTICATION_FAILED", .pauseForReauthentication),
            (403, "PERMISSION_DENIED", .pauseForPermissionReview), (404, "RESOURCE_NOT_FOUND", .pauseForReceiptReview),
            (409, "CONFLICT", .pauseForConflictReview), (429, "RATE_LIMITED", .boundedRetry),
            (500, "INTERNAL_ERROR", .boundedRetry), (503, "INTERNAL_ERROR", .boundedRetry),
            (402, "PRECONDITION_FAILED", .pauseForReceiptReview), (202, "UNKNOWN", .pauseForReceiptReview)]
        for (status, code, action) in errors {
            let body = try json(["error": ["status": status, "code": code, "message": "PRIVATE token/source",
                "details": ["text": "PRIVATE"], "requestID": "PRIVATE"]] as [String: Any])
            do {
                _ = try firstRequest.assessmentOptions(from: .init(status: status, body: body, retryAfter: "30"), now: now)
                check(false, "Only HTTP 200 is an options success")
            } catch let failure as PichiPublicationRemoteFailure {
                check(failure.action == action && failure.httpStatus == status
                      && failure.retryAfter == (action == .boundedRetry ? .seconds(30) : nil)
                      && !String(describing: failure).contains("PRIVATE"),
                      "Options errors use safe method-specific actions and discard server prose")
            }
        }
        for (status, body) in [(403, try json(["error": ["status": 401, "code": "AUTHENTICATION_FAILED"]])),
                               (503, Data("<html>PRIVATE</html>".utf8)),
                               (418, try json(["error": ["status": 418, "code": "PRIVATE_UNKNOWN", "message": "PRIVATE"]]))] {
            do {
                _ = try firstRequest.assessmentOptions(from: .init(status: status, body: body, retryAfter: "30"))
                check(false, "An unknown or malformed options error cannot become success")
            } catch let failure as PichiPublicationRemoteFailure {
                check(failure.action == .pauseForReceiptReview && failure.code == nil && failure.retryAfter == nil
                      && !String(describing: failure).contains("PRIVATE"), "Untrusted errors pause without exposing their raw body")
            }
        }

        let opaqueContext = AccountContext(identity: context.identity, organizationID: "org +/?#%Ё",
            workspaceID: "ws &=+/%ё", generation: context.generation)
        for id in ["a/b", "a?x=1", "a#fragment", "%2F", "Ё ё", ".", ".."] {
            let opaque = PichiPublicationReceipt(schemaVersion: 1, importID: id, recordingID: receipt.recordingID,
                uploadState: .accepted, analysisState: .needsParticipant)
            let value = try PichiPublicationRequest.assessmentOptions(configuration: configuration, context: opaqueContext,
                receipt: opaque, transcriptBytes: source, cursor: "opaque_cursor-1", limit: 100)
            let parts = URLComponents(url: value.unsignedRequest.url!, resolvingAgainstBaseURL: false)!
            let segments = parts.percentEncodedPath.split(separator: "/")
            let query = parts.queryItems!
            check(segments.count == 6 && String(segments[4]).removingPercentEncoding == id
                  && segments[5] == "assessment-options" && parts.fragment == nil && parts.host == "api.example"
                  && query.first(where: { $0.name == "organizationID" })?.value == opaqueContext.organizationID
                  && query.first(where: { $0.name == "workspaceID" })?.value == opaqueContext.workspaceID
                  && parts.percentEncodedQuery?.contains("+") == false,
                  "Opaque destination values and import IDs stay in their own encoded query or single path segment")
        }
        for limit in [-1, 0, 101, Int.max] {
            try rejects(.invalidRequest, "Request page limits must be within W2 bounds") { _ = try request(limit: limit) }
        }
        for cursor in ["", "a+b", "a=b", "a/b", "\nPRIVATE", String(repeating: "a", count: 2_049)] {
            try rejects(.invalidRequest, "Request cursors use the bounded opaque base64url form") { _ = try request(cursor: cursor) }
        }
        check(try request(limit: 1).unsignedRequest.url != nil
              && request(cursor: String(repeating: "a", count: 2_048), limit: 100).unsignedRequest.url != nil,
              "Both page-size boundaries and the maximum cursor are admitted without interpreting opaque IDs")

        // All client calls below are invalid during local preflight or already cancelled.
        // Never execute a valid request against the example authority.
        let http = try PichiPublicationHTTPClient(configuration: configuration)
        let authorized = try firstRequest.authorized(using: .init(context: context, accessToken: "synthetic-options-access"))
        let base = "https://api.example/api/v1/recordings/imports"
        let validQuery = "organizationID=17&workspaceID=9&limit=2"
        for url in [base + "/synthetic-import-201?" + validQuery,
                    base + "/synthetic-import-201/assessment?" + validQuery,
                    base + "/synthetic-import-201/assessment-options/extra?" + validQuery,
                    base + "/synthetic-import-201/assessment-options",
                    base + "/synthetic-import-201/assessment-options?" + validQuery + "&limit=2",
                    base + "/synthetic-import-201/assessment-options?" + validQuery + "&extra=PRIVATE",
                    base + "/synthetic-import-201/assessment-options?organizationID=17&limit=2",
                    base + "/synthetic-import-201/assessment-options?organizationID=17&workspaceID=9&limit=0",
                    base + "/synthetic-import-201/assessment-options?organizationID=17&workspaceID=9&limit=101",
                    base + "/synthetic-import-201/assessment-options?organizationID=17&workspaceID=9&limit=true",
                    base + "/synthetic-import-201/assessment-options?" + validQuery + "&cursor=bad%2Bcursor"] {
            var invalid = authorized; invalid.url = URL(string: url)!
            do { _ = try await http.perform(invalid); check(false, "Unsafe options query must fail locally") }
            catch let failure as PichiPublicationNetworkFailure {
                check(failure == .invalidRequest, "Only the assessment-options GET accepts its exact scoped query keys")
            }
        }
        for method in ["POST", "PATCH", "DELETE"] {
            var invalid = authorized; invalid.httpMethod = method
            do { _ = try await http.perform(invalid); check(false, "Options parameters cannot authorize a different HTTP method") }
            catch let failure as PichiPublicationNetworkFailure { check(failure == .invalidRequest, "Options query admission is GET-only") }
        }
        var withBody = authorized; withBody.httpBody = Data("PRIVATE".utf8)
        do { _ = try await http.perform(withBody); check(false, "Options GET cannot carry a body") }
        catch let failure as PichiPublicationNetworkFailure { check(failure == .invalidRequest, "Options GET body fails before I/O") }
        for operation in 0..<3 {
            let cancelled = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                if operation == 0 { _ = try request() }
                else if operation == 1 { _ = try firstRequest.assessmentOptions(from: .init(status: 200, body: firstBytes, retryAfter: nil)) }
                else { _ = try await http.perform(authorized) }
            }
            do { _ = try await cancelled.value; check(false, "Cancelled options work cannot proceed") }
            catch is CancellationError { check(true, "Options construction, decoding and executor preserve cancellation") }
        }
        await http.shutdown()
        check(firstRequest.unsignedRequest.httpBody == nil && firstRequest.unsignedRequest.value(forHTTPHeaderField: "Authorization") == nil,
              "Options decoding and failures do not mutate the immutable unsigned request")
        return checks
    }
}
