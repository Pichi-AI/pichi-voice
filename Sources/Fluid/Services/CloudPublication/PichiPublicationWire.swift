import CryptoKit
import CoreFoundation
import Foundation

nonisolated enum PichiPublicationWireFailure: String, Error, Sendable {
    case invalidConfiguration, invalidRequest, invalidResponse, responseTooLarge
}

nonisolated enum PichiPublicationAnalysisState: String, Codable, CaseIterable, Sendable {
    case queued, running, succeeded, failed, needsParticipant, needsCriteria
}

nonisolated struct PichiPublicationReceipt: Codable, Equatable, Sendable {
    enum UploadState: String, Codable, Sendable { case accepted }
    let schemaVersion: Int
    let importID: String
    let recordingID: String
    let uploadState: UploadState
    let analysisState: PichiPublicationAnalysisState
    var billingState: PichiPublicationBillingState? = nil
    /// Frozen server policy outcome for account-context imports, never a client default.
    var accountContextPolicyCriteriaIDs: [String]? = nil

    fileprivate func validate() throws {
        guard self.schemaVersion == 1, PichiPublicationRequest.validID(self.importID),
              PichiPublicationRequest.validID(self.recordingID) else { throw PichiPublicationWireFailure.invalidResponse }
    }
}

/// Original POST binding and later PATCH selection are separate immutable values. No
/// speaker label, name or isLocalUser flag supplies a default represented participant.
nonisolated struct PichiPublicationAssessment: Equatable, Sendable {
    let participantID: UUID?
    let criteriaIDs: [String]

    fileprivate func encoded(representedParticipants: Set<UUID>, requiresComplete: Bool) throws -> Data {
        guard self.criteriaIDs.count <= 100, Set(self.criteriaIDs).count == self.criteriaIDs.count,
              self.criteriaIDs.allSatisfy(PichiPublicationRequest.validID),
              self.participantID.map({ representedParticipants.contains($0) }) != false,
              !requiresComplete || (self.participantID != nil && !self.criteriaIDs.isEmpty) else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        // Fixed key order matches the approved multipart fixture. Encode values with the
        // JSON encoder, and preserve an explicit null rather than omitting the optional key.
        let encoder = JSONEncoder(); encoder.outputFormatting = [.withoutEscapingSlashes]
        let participant = try self.participantID.map { try encoder.encode($0.uuidString) } ?? Data("null".utf8)
        var result = Data("{\"participantID\":".utf8)
        result.append(participant); result.append(Data(",\"criteriaIDs\":".utf8))
        result.append(try encoder.encode(self.criteriaIDs)); result.append(Data("}".utf8))
        return result
    }
}

/// One authorized page for an existing accepted source. Names are display data, not
/// employee identities or defaults. The caller chooses whether to request another page.
nonisolated struct PichiPublicationAssessmentOptions: Equatable, Sendable {
    struct Context: Equatable, Sendable {
        let accountID: String
        let organizationID: String
        let workspaceID: String
    }
    struct Participant: Equatable, Sendable { let id: UUID; let displayName: String }
    struct Criterion: Equatable, Sendable { let id: String; let name: String }
    struct Pagination: Equatable, Sendable {
        let limit: Int
        let cursor: String?
        let nextCursor: String?
        let hasMore: Bool
    }
    struct Criteria: Equatable, Sendable { let data: [Criterion]; let pagination: Pagination }
    let schemaVersion: Int
    let context: Context
    let receipt: PichiPublicationReceipt
    let participants: [Participant]
    let criteria: Criteria
    let currentAssessment: PichiPublicationAssessment
    let canResolvePending: Bool
}

nonisolated enum PichiPublicationRemoteAction: String, Codable, Sendable {
    case stopAndShowValidation, pauseForReauthentication, pauseForAccountReview
    case pauseForPermissionReview, pauseForReceiptReview, pauseForConflictReview, boundedRetry
}

nonisolated enum PichiPublicationRemoteCode: String, Codable, Sendable {
    case invalidRequest = "INVALID_REQUEST"
    case authenticationFailed = "AUTHENTICATION_FAILED"
    case preconditionFailed = "PRECONDITION_FAILED"
    case permissionDenied = "PERMISSION_DENIED"
    case resourceNotFound = "RESOURCE_NOT_FOUND"
    case conflict = "CONFLICT"
    case rateLimited = "RATE_LIMITED"
    case internalError = "INTERNAL_ERROR"
}

/// Server prose, arbitrary details and request IDs are intentionally absent. A billing
/// reason example is not a complete safe allowlist, so 402 exposes only account review.
nonisolated struct PichiPublicationRemoteFailure: Error, Equatable, Sendable {
    let action: PichiPublicationRemoteAction
    let httpStatus: Int
    let code: PichiPublicationRemoteCode?
    let retryAfter: PichiPublicationRetryAfter?
}

/// The HTTP executor must retain bounded status/body and Retry-After instead of using
/// AccountHTTPRequesting, which deliberately collapses errors for the login boundary.
nonisolated struct PichiPublicationHTTPResponse: Sendable {
    let status: Int
    let body: Data
    let retryAfter: String?
}

/// Pure immutable wire operation. Runtime callers must obtain N1 authorizedAccess(for:)
/// for this exact context, and recheck isCurrent after every request before applying it
/// through N2's owner-bound store. This codec does not authenticate a profile or do I/O.
nonisolated struct PichiPublicationRequest: Sendable {
    enum Kind: Sendable { case importSource, status, assessment, assessmentOptions }
    static let maximumResponseBytes = 65_536
    static let maximumMultipartBytes = 1_048_576

    let configuration: AccountConfiguration
    let context: AccountContext
    let kind: Kind
    let unsignedRequest: URLRequest
    private let expectedReceipt: PichiPublicationReceipt?
    private struct OptionsPage: Sendable {
        let represented: Set<UUID>
        let limit: Int
        let cursor: String?
    }
    private let optionsPage: OptionsPage?

    private init(configuration: AccountConfiguration, context: AccountContext, kind: Kind,
                 request: URLRequest, expectedReceipt: PichiPublicationReceipt?, optionsPage: OptionsPage? = nil) {
        self.configuration = configuration; self.context = context; self.kind = kind
        self.unsignedRequest = request; self.expectedReceipt = expectedReceipt
        self.optionsPage = optionsPage
    }

    static func importSource(configuration: AccountConfiguration, context: AccountContext,
        operationID: UUID, transcriptBytes: Data, sourceSHA256: String, assessment: PichiPublicationAssessment,
        boundary: String = "pichi-import-" + UUID().uuidString) throws -> Self {
        try Task.checkCancellation()
        try self.validate(configuration: configuration, context: context)
        let represented = try self.validateProtectedBytes(transcriptBytes)
        guard sourceSHA256.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil,
              SHA256.hash(data: transcriptBytes).map({ String(format: "%02x", $0) }).joined() == sourceSHA256,
              boundary.range(of: "^[A-Za-z0-9-]{1,70}$", options: .regularExpression) != nil else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        let binding = try assessment.encoded(representedParticipants: represented, requiresComplete: false)
        let fields: [(String, Data)] = [
            ("schemaVersion", Data("1".utf8)), ("organizationID", Data(context.organizationID!.utf8)),
            ("workspaceID", Data(context.workspaceID!.utf8)), ("sourceRevision", Data("1".utf8)),
            ("sourceSHA256", Data(sourceSHA256.utf8)), ("assessment", binding)]
        let delimiter = Data(("--" + boundary).utf8)
        guard transcriptBytes.range(of: delimiter) == nil, fields.allSatisfy({ $0.1.range(of: delimiter) == nil }) else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        var body = Data()
        for (name, bytes) in fields {
            body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"\(name)\"\r\n\r\n".utf8))
            body.append(bytes); body.append(Data("\r\n".utf8))
        }
        body.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"transcript\"; filename=\"protected-transcript.json\"\r\nContent-Type: application/json\r\n\r\n".utf8))
        body.append(transcriptBytes); body.append(Data("\r\n--\(boundary)--\r\n".utf8))
        guard body.count <= self.maximumMultipartBytes else { throw PichiPublicationWireFailure.invalidRequest }
        var request = URLRequest(url: try self.url(configuration: configuration))
        request.httpMethod = "POST"; request.httpBody = body
        request.setValue(operationID.uuidString, forHTTPHeaderField: "Idempotency-Key")
        request.setValue("multipart/form-data; boundary=" + boundary, forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        return Self(configuration: configuration, context: context, kind: .importSource,
            request: request, expectedReceipt: nil)
    }

    static func status(configuration: AccountConfiguration, context: AccountContext,
                       receipt: PichiPublicationReceipt) throws -> Self {
        try Task.checkCancellation()
        try self.validate(configuration: configuration, context: context); try receipt.validate()
        var request = URLRequest(url: try self.url(configuration: configuration, importID: receipt.importID))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return Self(configuration: configuration, context: context, kind: .status, request: request, expectedReceipt: receipt)
    }

    static func resolveAssessment(configuration: AccountConfiguration, context: AccountContext,
        receipt: PichiPublicationReceipt, transcriptBytes: Data, assessment: PichiPublicationAssessment) throws -> Self {
        try Task.checkCancellation()
        try self.validate(configuration: configuration, context: context); try receipt.validate()
        let represented = try self.validateProtectedBytes(transcriptBytes)
        var request = URLRequest(url: try self.url(configuration: configuration, importID: receipt.importID, resource: "assessment"))
        request.httpMethod = "PATCH"
        request.httpBody = try assessment.encoded(representedParticipants: represented, requiresComplete: true)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        try Task.checkCancellation()
        return Self(configuration: configuration, context: context, kind: .assessment, request: request, expectedReceipt: receipt)
    }

    /// Runtime access must come from the existing owner, including its trusted API/client
    /// configuration. AccountContext alone does not bind a bearer to an API origin.
    @MainActor func authorized(using account: AccountSessionService) async throws -> URLRequest {
        guard account.configuration == self.configuration else { throw AccountError.invalidConfiguration }
        let access = try await account.authorizedAccess(for: self.context)
        try Task.checkCancellation()
        guard account.isCurrent(self.context) else { throw AccountError.staleOperation }
        return try self.authorized(using: access)
    }

    static func assessmentOptions(configuration: AccountConfiguration, context: AccountContext,
        receipt: PichiPublicationReceipt, transcriptBytes: Data, cursor: String? = nil, limit: Int = 50) throws -> Self {
        try Task.checkCancellation()
        try self.validate(configuration: configuration, context: context); try receipt.validate()
        let represented = try self.validateProtectedBytes(transcriptBytes)
        let items = [URLQueryItem(name: "organizationID", value: context.organizationID!),
            URLQueryItem(name: "workspaceID", value: context.workspaceID!),
            URLQueryItem(name: "limit", value: String(limit))]
            + (cursor.map { [URLQueryItem(name: "cursor", value: $0)] } ?? [])
        guard self.validAssessmentOptionsQuery(items),
              var parts = URLComponents(url: try self.url(configuration: configuration,
                importID: receipt.importID, resource: "assessment-options"), resolvingAgainstBaseURL: false) else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        // Query values are opaque. Encode '+' too, since the server's query parser
        // otherwise treats that literal character as a space.
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        parts.percentEncodedQuery = try items.map { item in
            guard let value = item.value?.addingPercentEncoding(withAllowedCharacters: safe) else { throw PichiPublicationWireFailure.invalidRequest }
            return item.name + "=" + value
        }.joined(separator: "&")
        guard let url = parts.url, URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems == items else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        var request = URLRequest(url: url); request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return .init(configuration: configuration, context: context, kind: .assessmentOptions,
            request: request, expectedReceipt: receipt, optionsPage: .init(represented: represented, limit: limit, cursor: cursor))
    }

    /// The HTTP executor shares this narrow query allowlist with the immutable builder.
    /// No other publication route may carry a query or accept these extra parameters.
    static func validAssessmentOptionsQuery(_ items: [URLQueryItem]?) -> Bool {
        guard let items, (3...4).contains(items.count), Set(items.map(\.name)).count == items.count,
              Set(items.map(\.name)).isSubset(of: ["organizationID", "workspaceID", "limit", "cursor"]),
              let organization = items.first(where: { $0.name == "organizationID" })?.value,
              let workspace = items.first(where: { $0.name == "workspaceID" })?.value,
              let limit = items.first(where: { $0.name == "limit" })?.value,
              self.validID(organization), self.validID(workspace), (1...3).contains(limit.utf8.count),
              limit.utf8.allSatisfy({ (48...57).contains($0) }), let count = Int(limit), (1...100).contains(count) else { return false }
        if let cursor = items.first(where: { $0.name == "cursor" }) { return cursor.value.map(self.validCursor) == true }
        return items.count == 3
    }

    private static func validCursor(_ value: String) -> Bool {
        !value.isEmpty && value.utf8.count <= 2048
            && value.utf8.allSatisfy { (65...90).contains($0) || (97...122).contains($0) || (48...57).contains($0) || $0 == 45 || $0 == 95 }
    }

    /// Called after the HTTP await and before any N2-owned durable or visible mutation.
    /// N2 still must validate the capture/profile handle around its own awaited work.
    @MainActor func receipt(from response: PichiPublicationHTTPResponse, account: AccountSessionService,
                            now: Date = Date()) throws -> PichiPublicationReceipt {
        guard account.configuration == self.configuration, account.isCurrent(self.context) else { throw AccountError.staleOperation }
        return try self.receipt(from: response, now: now)
    }

    @MainActor func assessmentOptions(from response: PichiPublicationHTTPResponse, account: AccountSessionService,
                                      now: Date = Date()) throws -> PichiPublicationAssessmentOptions {
        guard account.configuration == self.configuration, account.isCurrent(self.context) else { throw AccountError.staleOperation }
        return try self.assessmentOptions(from: response, now: now)
    }

    func assessmentOptions(from response: PichiPublicationHTTPResponse, now: Date = Date()) throws -> PichiPublicationAssessmentOptions {
        try Task.checkCancellation()
        guard self.kind == .assessmentOptions, let page = self.optionsPage, let expectedReceipt else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        guard response.body.count <= Self.maximumResponseBytes else { throw PichiPublicationWireFailure.responseTooLarge }
        guard response.status == 200 else { throw try self.remoteFailure(response, now: now) }
        let root = try Self.responseObject(try? JSONSerialization.jsonObject(with: response.body),
            keys: ["schemaVersion", "context", "receipt", "participants", "criteria", "currentAssessment", "canResolvePending"])
        guard Self.responseInteger(root["schemaVersion"], range: 1...1) != nil else { throw PichiPublicationWireFailure.invalidResponse }
        let destination = try Self.responseObject(root["context"], keys: ["accountID", "organizationID", "workspaceID"])
        guard let account = destination["accountID"] as? String, account == self.context.identity.internalUserID,
              let organization = destination["organizationID"] as? String, organization == self.context.organizationID,
              let workspace = destination["workspaceID"] as? String, workspace == self.context.workspaceID,
              [account, organization, workspace].allSatisfy(Self.validID) else { throw PichiPublicationWireFailure.invalidResponse }
        let receiptObject = try Self.responseObject(root["receipt"], keys: ["schemaVersion", "importID", "recordingID", "uploadState", "analysisState"])
        guard Self.responseInteger(receiptObject["schemaVersion"], range: 1...1) != nil,
              receiptObject["importID"] as? String == expectedReceipt.importID,
              receiptObject["recordingID"] as? String == expectedReceipt.recordingID,
              receiptObject["uploadState"] as? String == "accepted",
              let analysis = receiptObject["analysisState"] as? String, let state = PichiPublicationAnalysisState(rawValue: analysis) else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        let receipt = PichiPublicationReceipt(schemaVersion: 1, importID: expectedReceipt.importID,
            recordingID: expectedReceipt.recordingID, uploadState: .accepted, analysisState: state)
        guard let participants = root["participants"] as? [Any], participants.count <= 100 else { throw PichiPublicationWireFailure.invalidResponse }
        var participantIDs = Set<UUID>()
        let choices: [PichiPublicationAssessmentOptions.Participant] = try participants.map { raw in
            try Task.checkCancellation()
            let item = try Self.responseObject(raw, keys: ["id", "displayName"])
            guard let rawID = item["id"] as? String, let id = UUID(uuidString: rawID),
                  participantIDs.insert(id).inserted, page.represented.contains(id),
                  let name = item["displayName"] as? String, name.utf16.count <= 200 else { throw PichiPublicationWireFailure.invalidResponse }
            return .init(id: id, displayName: name)
        }
        guard participantIDs == page.represented else { throw PichiPublicationWireFailure.invalidResponse }
        let criteria = try Self.responseObject(root["criteria"], keys: ["data", "pagination"])
        let pagination = try Self.responseObject(criteria["pagination"], keys: ["limit", "cursor", "next_cursor", "has_more"])
        guard Self.responseInteger(pagination["limit"], range: 1...100) == page.limit,
              let hasMore = Self.responseBoolean(pagination["has_more"]),
              let data = criteria["data"] as? [Any], data.count <= page.limit else { throw PichiPublicationWireFailure.invalidResponse }
        let cursor = try Self.responseCursor(pagination["cursor"]), next = try Self.responseCursor(pagination["next_cursor"])
        guard cursor == page.cursor, hasMore == (next != nil), next == nil || next != cursor,
              !hasMore || data.count == page.limit else { throw PichiPublicationWireFailure.invalidResponse }
        var criterionIDs = Set<String>()
        let entries: [PichiPublicationAssessmentOptions.Criterion] = try data.map { raw in
            try Task.checkCancellation()
            let item = try Self.responseObject(raw, keys: ["id", "name"])
            guard let id = item["id"] as? String, Self.validID(id), criterionIDs.insert(id).inserted,
                  let name = item["name"] as? String else { throw PichiPublicationWireFailure.invalidResponse }
            // W2 has no separate criterion-name length cap. The full response byte
            // limit bounds every string without inventing a different server schema.
            return .init(id: id, name: name)
        }
        let assessment = try Self.responseObject(root["currentAssessment"], keys: ["participantID", "criteriaIDs"])
        let participantID: UUID?
        if assessment["participantID"] is NSNull { participantID = nil }
        else {
            guard let raw = assessment["participantID"] as? String, let id = UUID(uuidString: raw), page.represented.contains(id) else {
                throw PichiPublicationWireFailure.invalidResponse
            }
            participantID = id
        }
        guard let selectedCriteria = assessment["criteriaIDs"] as? [String], selectedCriteria.count <= 100,
              selectedCriteria.allSatisfy(Self.validID), let canResolve = Self.responseBoolean(root["canResolvePending"]),
              !canResolve || state == .needsParticipant || state == .needsCriteria else { throw PichiPublicationWireFailure.invalidResponse }
        try Task.checkCancellation()
        return .init(schemaVersion: 1, context: .init(accountID: account, organizationID: organization, workspaceID: workspace),
            receipt: receipt, participants: choices, criteria: .init(data: entries,
                pagination: .init(limit: page.limit, cursor: cursor, nextCursor: next, hasMore: hasMore)),
            currentAssessment: .init(participantID: participantID, criteriaIDs: selectedCriteria), canResolvePending: canResolve)
    }

    private static func responseObject(_ value: Any?, keys: Set<String>) throws -> [String: Any] {
        guard let object = value as? [String: Any], Set(object.keys) == keys else { throw PichiPublicationWireFailure.invalidResponse }
        return object
    }

    private static func responseInteger(_ value: Any?, range: ClosedRange<Int>) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number.doubleValue.isFinite, number.doubleValue.rounded() == number.doubleValue,
              number.doubleValue >= Double(range.lowerBound), number.doubleValue <= Double(range.upperBound) else { return nil }
        return number.intValue
    }

    private static func responseBoolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }

    private static func responseCursor(_ value: Any?) throws -> String? {
        if value is NSNull { return nil }
        guard let cursor = value as? String, self.validCursor(cursor) else { throw PichiPublicationWireFailure.invalidResponse }
        return cursor
    }

    func authorized(using access: AccountAuthorizedAccess) throws -> URLRequest {
        try Task.checkCancellation()
        guard access.context == self.context else { throw AccountError.staleOperation }
        guard !access.accessToken.isEmpty, access.accessToken.utf8.count <= 32_768,
              access.accessToken.rangeOfCharacter(from: .controlCharacters) == nil else { throw AccountError.invalidToken }
        var request = self.unsignedRequest
        request.setValue("Bearer " + access.accessToken, forHTTPHeaderField: "Authorization")
        return request
    }

    func receipt(from response: PichiPublicationHTTPResponse, now: Date = Date()) throws -> PichiPublicationReceipt {
        try Task.checkCancellation()
        guard self.kind != .assessmentOptions else { throw PichiPublicationWireFailure.invalidRequest }
        guard response.body.count <= Self.maximumResponseBytes else { throw PichiPublicationWireFailure.responseTooLarge }
        let success = response.status == 200 || ((self.kind == .importSource || self.kind == .assessment) && response.status == 202)
        guard success else { throw try self.remoteFailure(response, now: now) }
        guard let receipt = try? JSONDecoder().decode(PichiPublicationReceipt.self, from: response.body) else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        try receipt.validate()
        if let expectedReceipt {
            guard receipt.importID == expectedReceipt.importID, receipt.recordingID == expectedReceipt.recordingID else {
                throw PichiPublicationWireFailure.invalidResponse
            }
        }
        // The original POST may be replayed after PATCH resolution. Its returned analysis
        // state is current, so it must not be compared to the initial pending binding.
        try Task.checkCancellation()
        return receipt
    }

    private func remoteFailure(_ response: PichiPublicationHTTPResponse, now: Date) throws -> PichiPublicationRemoteFailure {
        struct Envelope: Decodable { struct Detail: Decodable { let code: String; let status: Int }; let error: Detail }
        let parsed = try? JSONDecoder().decode(Envelope.self, from: response.body)
        let code = parsed.flatMap { $0.error.status == response.status ? PichiPublicationRemoteCode(rawValue: $0.error.code) : nil }
        let action: PichiPublicationRemoteAction
        switch (response.status, code) {
        case (400, .invalidRequest) where self.kind != .status: action = .stopAndShowValidation
        case (413, .invalidRequest) where self.kind == .importSource: action = .stopAndShowValidation
        case (401, .authenticationFailed): action = .pauseForReauthentication
        case (402, .preconditionFailed) where self.kind == .importSource: action = .pauseForAccountReview
        case (403, .permissionDenied): action = .pauseForPermissionReview
        case (404, .resourceNotFound) where self.kind != .importSource: action = .pauseForReceiptReview
        case (409, .conflict) where self.kind != .status: action = .pauseForConflictReview
        case (429, .rateLimited), (500, .internalError), (503, .internalError): action = .boundedRetry
        default: action = .pauseForReceiptReview
        }
        return PichiPublicationRemoteFailure(action: action, httpStatus: response.status, code: code,
            retryAfter: action == .boundedRetry ? PichiPublicationRetryPolicy.parseRetryAfter(response.retryAfter, now: now) : nil)
    }

    fileprivate static func validID(_ value: String) -> Bool {
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf16.count <= 256 && value.utf8.count <= 512
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func validate(configuration: AccountConfiguration, context: AccountContext) throws {
        do { try configuration.validate() } catch { throw PichiPublicationWireFailure.invalidConfiguration }
        guard context.identity.issuer == configuration.issuer.absoluteString else { throw PichiPublicationWireFailure.invalidConfiguration }
        guard let organization = context.organizationID, let workspace = context.workspaceID,
              self.validID(organization), self.validID(workspace) else { throw PichiPublicationWireFailure.invalidRequest }
    }

    private static func url(configuration: AccountConfiguration, importID: String? = nil, resource: String? = nil) throws -> URL {
        guard var parts = URLComponents(url: configuration.apiBaseURL, resolvingAgainstBaseURL: false) else {
            throw PichiPublicationWireFailure.invalidConfiguration
        }
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_~")
        var path = parts.percentEncodedPath + "/api/v1/recordings/imports"
        if let importID {
            guard self.validID(importID), let encoded = importID.addingPercentEncoding(withAllowedCharacters: safe) else {
                throw PichiPublicationWireFailure.invalidRequest
            }
            path += "/" + encoded
        }
        if let resource { path += "/" + resource }
        parts.percentEncodedPath = path
        guard let result = parts.url, URLComponents(url: result, resolvingAgainstBaseURL: false)?.percentEncodedPath == path else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        return result
    }

    private static func validateProtectedBytes(_ data: Data) throws -> Set<UUID> {
        do { return try PichiProtectedPublicationPayload.validate(data) }
        catch is CancellationError { throw CancellationError() }
        catch { throw PichiPublicationWireFailure.invalidRequest }
    }
}

/// Legacy imports select an employee and assessment before the first POST. These IDs
/// are server data, never inferred from a display name or a local speaker flag.
nonisolated struct LegacyPublicationSelection: Codable, Equatable, Sendable {
    let userID: String
    let participantID: UUID
    let criteriaIDs: [String]

    func validate(represented: Set<UUID>) throws {
        guard PichiLegacyPublicationRequest.databaseID(userID) != nil,
              represented.contains(participantID), !criteriaIDs.isEmpty, criteriaIDs.count <= 100,
              Set(criteriaIDs).count == criteriaIDs.count,
              criteriaIDs.allSatisfy({ PichiLegacyPublicationRequest.databaseID($0) != nil }) else {
            throw PichiPublicationWireFailure.invalidRequest
        }
    }
}

nonisolated struct LegacyPublicationOptions: Equatable, Sendable {
    struct Employee: Equatable, Sendable { let id: String; let name: String }
    struct Criterion: Equatable, Sendable { let id: String; let name: String }
    struct Participant: Equatable, Sendable { let id: UUID; let displayName: String }
    let employees: [Employee]
    let criteria: [Criterion]
    let participants: [Participant]
    let title: String
}

nonisolated enum PichiPublicationBillingState: String, Codable, Sendable {
    case pending, charged, notRequired = "not_required", uncertain
    var needsReview: Bool { self == .pending || self == .uncertain }
}

/// Pure codec for the existing cookie-authenticated route. The account service owns
/// its isolated cookie session. Protected source bytes are embedded verbatim and the
/// full body is frozen by the existing outbox before any HTTP attempt can start.
nonisolated enum PichiLegacyPublicationRequest {
    static let maximumResponseBytes = 2_097_152

    static func databaseID(_ value: String) -> Int? {
        guard !value.isEmpty, value.utf8.allSatisfy({ (48...57).contains($0) }),
              let id = Int(value), id > 0, id <= 2_147_483_647, String(id) == value else { return nil }
        return id
    }

    static func endpoint(origin: URL, path: String) throws -> URLRequest {
        guard let parts = URLComponents(url: origin, resolvingAgainstBaseURL: false),
              parts.scheme == "https", parts.host != nil, parts.user == nil, parts.password == nil,
              parts.query == nil, parts.fragment == nil, parts.path.isEmpty || parts.path == "/",
              path.hasPrefix("/api/"), !path.contains("?"), !path.contains("#"),
              let url = URL(string: path, relativeTo: origin)?.absoluteURL else {
            throw PichiPublicationWireFailure.invalidConfiguration
        }
        var request = URLRequest(url: url)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return request
    }

    static func importBody(context: AccountContext, transcriptBytes: Data,
                           selection: LegacyPublicationSelection) throws -> Data {
        let represented = try PichiProtectedPublicationPayload.validate(transcriptBytes)
        try selection.validate(represented: represented)
        guard let workspace = context.workspaceID.flatMap(databaseID),
              let object = try JSONSerialization.jsonObject(with: transcriptBytes) as? [String: Any],
              let title = object["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        struct Binding: Encodable { let title: String; let workspaceId: Int; let userId: Int; let managerSpeakerId: String; let criteriaIds: [Int] }
        let binding = Binding(title: title, workspaceId: workspace, userId: databaseID(selection.userID)!,
            managerSpeakerId: selection.participantID.uuidString,
            criteriaIds: selection.criteriaIDs.map { databaseID($0)! })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var body = try encoder.encode(binding)
        guard body.last == 125 else { throw PichiPublicationWireFailure.invalidRequest }
        body.removeLast(); body.append(Data(",\"transcriptImport\":".utf8))
        body.append(transcriptBytes); body.append(125)
        guard body.count <= PichiPublicationRequest.maximumMultipartBytes else { throw PichiPublicationWireFailure.invalidRequest }
        return body
    }

    /// Account ownership comes from the authenticated session. The source is embedded
    /// verbatim; an optional represented voice hint never becomes an employee identity.
    static func accountContextBody(context: AccountContext, transcriptBytes: Data,
                                   managerSpeakerID: UUID?) throws -> Data {
        let represented = try PichiProtectedPublicationPayload.validate(transcriptBytes)
        guard managerSpeakerID.map({ represented.contains($0) }) != false,
              let workspace = context.workspaceID.flatMap(databaseID),
              let object = try JSONSerialization.jsonObject(with: transcriptBytes) as? [String: Any],
              let title = object["title"] as? String, !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        struct Binding: Encodable {
            let title: String; let workspaceId: Int
            let assessmentMode = "account_context"; let assessmentPolicyVersion = 1
            let managerSpeakerId: String?
        }
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        var body = try encoder.encode(Binding(title: title, workspaceId: workspace,
            managerSpeakerId: managerSpeakerID?.uuidString))
        guard body.last == 125 else { throw PichiPublicationWireFailure.invalidRequest }
        body.removeLast(); body.append(Data(",\"transcriptImport\":".utf8))
        body.append(transcriptBytes); body.append(125)
        guard body.count <= PichiPublicationRequest.maximumMultipartBytes else { throw PichiPublicationWireFailure.invalidRequest }
        return body
    }

    /// JSONB can reorder object keys. A validated semantic fingerprint lets a minimal
    /// accepted receipt verify later GETs after all local transcript content is removed.
    static func canonicalSourceSHA256(_ bytes: Data) throws -> String {
        _ = try PichiProtectedPublicationPayload.validate(bytes)
        let object = try JSONSerialization.jsonObject(with: bytes)
        let canonical = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        return SHA256.hash(data: canonical).map { String(format: "%02x", $0) }.joined()
    }

    static func confirmedLocalUserHint(in bytes: Data) throws -> UUID? {
        let represented = try PichiProtectedPublicationPayload.validate(bytes)
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let speakers = object["speakers"] as? [[String: Any]] else { throw PichiPublicationWireFailure.invalidRequest }
        let candidates = speakers.compactMap { speaker -> UUID? in
            guard let local = speaker["isLocalUser"] as? NSNumber, CFGetTypeID(local) == CFBooleanGetTypeID(), local.boolValue,
                  let provisional = speaker["identityIsProvisional"] as? NSNumber,
                  CFGetTypeID(provisional) == CFBooleanGetTypeID(), !provisional.boolValue,
                  let raw = speaker["id"] as? String, let id = UUID(uuidString: raw), represented.contains(id) else { return nil }
            return id
        }
        return candidates.count == 1 ? candidates[0] : nil
    }

    static func accountContextReceipt(from response: PichiPublicationHTTPResponse, context: AccountContext,
        sessionID: UUID, canonicalSourceSHA256: String, managerSpeakerID: UUID?,
        expected: PichiPublicationReceipt? = nil) throws -> PichiPublicationReceipt {
        guard let object = try checkedJSON(response) as? [String: Any],
              let id = jsonID(object["id"]), jsonID(object["workspaceId"]) == context.workspaceID,
              jsonID(object["uploadedById"]) == context.identity.internalUserID,
              jsonID(object["userId"]) == context.identity.internalUserID,
              object["assessmentMode"] as? String == "account_context",
              let version = object["assessmentPolicyVersion"] as? NSNumber,
              CFGetTypeID(version) != CFBooleanGetTypeID(), version.doubleValue == 1,
              object["analysisId"] == nil || object["analysisId"] is NSNull,
              object["deletedAt"] == nil || object["deletedAt"] is NSNull,
              object["importSourceId"] as? String == sessionID.uuidString.lowercased(),
              let source = object["transcriptImport"] as? [String: Any],
              let rawSourceID = source["sessionID"] as? String, UUID(uuidString: rawSourceID) == sessionID,
              expected != nil || object["title"] as? String == source["title"] as? String,
              try Self.canonicalSourceSHA256(JSONSerialization.data(withJSONObject: source, options: [.sortedKeys, .withoutEscapingSlashes])) == canonicalSourceSHA256,
              expected.map({ $0.importID == sessionID.uuidString.lowercased() && $0.recordingID == id }) != false else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        let acceptedHint: UUID?
        if let raw = object["managerSpeakerId"] as? String, let hint = UUID(uuidString: raw) { acceptedHint = hint }
        else if object["managerSpeakerId"] == nil || object["managerSpeakerId"] is NSNull { acceptedHint = nil }
        else { throw PichiPublicationWireFailure.invalidResponse }
        guard acceptedHint == managerSpeakerID else { throw PichiPublicationWireFailure.invalidResponse }
        let criteria: [String]
        if object["criteriaIds"] == nil || object["criteriaIds"] is NSNull { criteria = [] }
        else if let values = object["criteriaIds"] as? [Any], values.count <= 10_000,
                values.compactMap(jsonID).count == values.count {
            criteria = values.compactMap(jsonID).sorted()
        } else { throw PichiPublicationWireFailure.invalidResponse }
        guard let policyValues = object["assessmentPolicyCriteriaIds"] as? [Any], policyValues.count <= 10_000,
              policyValues.compactMap(jsonID).count == policyValues.count else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        let policyCriteria = policyValues.compactMap(jsonID).sorted()
        guard Set(criteria).count == criteria.count, Set(policyCriteria).count == policyCriteria.count,
              expected?.accountContextPolicyCriteriaIDs.map({ $0.sorted() == policyCriteria }) != false else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        let billing = (object["importBillingStatus"] as? String).flatMap(PichiPublicationBillingState.init(rawValue:)) ?? .uncertain
        let state: PichiPublicationAnalysisState
        if object["transcriptionStatus"] as? String == "failed" { state = .failed }
        else if billing.needsReview { state = .queued }
        else if object["processingStage"] as? String == "analyzing" { state = .running }
        else if object["transcriptionStatus"] as? String == "completed",
                let result = object["evaluationResults"] as? [String: Any] {
            let evaluated = Set((result["evaluations"] as? [[String: Any]] ?? []).compactMap { jsonID($0["criterion_id"]) })
            let noCriteria = (result["noCriteria"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } == true
            let hasSummary = (object["summary"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
            state = criteria.isEmpty ? (noCriteria && hasSummary ? .succeeded : .queued)
                : (Set(criteria).isSubset(of: evaluated) ? .succeeded : .queued)
        } else { state = .queued }
        var receipt = PichiPublicationReceipt(schemaVersion: 1, importID: sessionID.uuidString.lowercased(), recordingID: id,
            uploadState: .accepted, analysisState: state)
        receipt.billingState = billing; receipt.accountContextPolicyCriteriaIDs = policyCriteria
        return receipt
    }

    static func importSource(origin: URL, frozenBody: Data) throws -> URLRequest {
        guard !frozenBody.isEmpty, frozenBody.count <= PichiPublicationRequest.maximumMultipartBytes else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        var request = try endpoint(origin: origin, path: "/api/recordings/transcript")
        request.httpMethod = "POST"; request.httpBody = frozenBody
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return request
    }

    static func status(origin: URL, receipt: PichiPublicationReceipt) throws -> URLRequest {
        guard databaseID(receipt.recordingID) != nil else { throw PichiPublicationWireFailure.invalidRequest }
        return try endpoint(origin: origin, path: "/api/recordings/" + receipt.recordingID)
    }

    static func checkedJSON(_ response: PichiPublicationHTTPResponse) throws -> Any {
        guard response.body.count <= maximumResponseBytes else { throw PichiPublicationWireFailure.responseTooLarge }
        guard response.status == 200 || response.status == 202 else { throw remoteFailure(response) }
        guard let object = try? JSONSerialization.jsonObject(with: response.body) else { throw PichiPublicationWireFailure.invalidResponse }
        return object
    }

    static func receipt(from response: PichiPublicationHTTPResponse, context: AccountContext,
                        transcriptBytes: Data, selection: LegacyPublicationSelection,
                        expected: PichiPublicationReceipt? = nil) throws -> PichiPublicationReceipt {
        guard let object = try checkedJSON(response) as? [String: Any],
              let id = jsonID(object["id"]), let workspace = jsonID(object["workspaceId"]), workspace == context.workspaceID,
              jsonID(object["uploadedById"]) == context.identity.internalUserID,
              jsonID(object["userId"]) == selection.userID,
              let manager = object["managerSpeakerId"] as? String, UUID(uuidString: manager) == selection.participantID,
              let criteria = object["criteriaIds"] as? [Any], criteria.compactMap(jsonID).count == criteria.count,
              Set(criteria.compactMap(jsonID)) == Set(selection.criteriaIDs),
              let source = try JSONSerialization.jsonObject(with: transcriptBytes) as? NSDictionary,
              let acceptedSource = object["transcriptImport"] as? NSDictionary, acceptedSource == source,
              object["title"] as? String == source["title"] as? String,
              object["deletedAt"] == nil || object["deletedAt"] is NSNull,
              let sessionID = source["sessionID"] as? String,
              object["importSourceId"] as? String == sessionID.lowercased(),
              expected.map({ $0.importID == sessionID.lowercased() && $0.recordingID == id }) != false else {
            throw PichiPublicationWireFailure.invalidResponse
        }
        let billing = (object["importBillingStatus"] as? String).flatMap(PichiPublicationBillingState.init(rawValue:))
        // A missing billing status means the deployed route predates safe reconciliation.
        // Acceptance is retained, but analysis is never reported successful from that reply.
        let safeBilling = billing ?? .uncertain
        let state: PichiPublicationAnalysisState
        if object["transcriptionStatus"] as? String == "failed" { state = .failed }
        else if safeBilling.needsReview { state = .queued }
        else if object["processingStage"] as? String == "analyzing" { state = .running }
        else if object["transcriptionStatus"] as? String == "completed",
                let results = object["evaluationResults"] as? [String: Any],
                let evaluations = results["evaluations"] as? [[String: Any]],
                Set(selection.criteriaIDs).isSubset(of: Set(evaluations.compactMap { jsonID($0["criterion_id"]) })) {
            state = .succeeded
        } else { state = .queued }
        var receipt = PichiPublicationReceipt(schemaVersion: 1, importID: sessionID.lowercased(), recordingID: id,
            uploadState: .accepted, analysisState: state)
        receipt.billingState = safeBilling
        return receipt
    }

    static func remoteFailure(_ response: PichiPublicationHTTPResponse) -> PichiPublicationRemoteFailure {
        let action: PichiPublicationRemoteAction
        switch response.status {
        case 400, 413: action = .stopAndShowValidation
        case 401: action = .pauseForReauthentication
        case 402: action = .pauseForAccountReview
        case 403: action = .pauseForPermissionReview
        case 409: action = .pauseForConflictReview
        case 429, 500, 502, 503, 504: action = .boundedRetry
        default: action = .pauseForReceiptReview
        }
        return .init(action: action, httpStatus: response.status, code: nil,
            retryAfter: action == .boundedRetry ? PichiPublicationRetryPolicy.parseRetryAfter(response.retryAfter, now: Date()) : nil)
    }

    static func jsonID(_ value: Any?) -> String? {
        guard let value = value as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
              value.doubleValue.isFinite, value.doubleValue.rounded() == value.doubleValue,
              value.doubleValue > 0, value.doubleValue <= 2_147_483_647 else { return nil }
        return String(value.intValue)
    }
}
