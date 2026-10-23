import CoreFoundation
import CryptoKit
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
    enum Kind: Sendable { case importSource, status, assessment }
    static let maximumResponseBytes = 65_536
    static let maximumMultipartBytes = 1_048_576

    let configuration: AccountConfiguration
    let context: AccountContext
    let kind: Kind
    let unsignedRequest: URLRequest
    private let expectedReceipt: PichiPublicationReceipt?

    private init(configuration: AccountConfiguration, context: AccountContext, kind: Kind,
                 request: URLRequest, expectedReceipt: PichiPublicationReceipt?) {
        self.configuration = configuration; self.context = context; self.kind = kind
        self.unsignedRequest = request; self.expectedReceipt = expectedReceipt
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
        var request = URLRequest(url: try self.url(configuration: configuration, importID: receipt.importID, assessment: true))
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

    /// Called after the HTTP await and before any N2-owned durable or visible mutation.
    /// N2 still must validate the capture/profile handle around its own awaited work.
    @MainActor func receipt(from response: PichiPublicationHTTPResponse, account: AccountSessionService,
                            now: Date = Date()) throws -> PichiPublicationReceipt {
        guard account.configuration == self.configuration, account.isCurrent(self.context) else { throw AccountError.staleOperation }
        return try self.receipt(from: response, now: now)
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
        guard response.body.count <= Self.maximumResponseBytes else { throw PichiPublicationWireFailure.responseTooLarge }
        let success = response.status == 200 || (self.kind != .status && response.status == 202)
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
        !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && value.utf8.count <= 512
            && value.rangeOfCharacter(from: .controlCharacters) == nil
    }

    private static func validate(configuration: AccountConfiguration, context: AccountContext) throws {
        do { try configuration.validate() } catch { throw PichiPublicationWireFailure.invalidConfiguration }
        guard context.identity.issuer == configuration.issuer.absoluteString else { throw PichiPublicationWireFailure.invalidConfiguration }
        guard let organization = context.organizationID, let workspace = context.workspaceID,
              self.validID(organization), self.validID(workspace) else { throw PichiPublicationWireFailure.invalidRequest }
    }

    private static func url(configuration: AccountConfiguration, importID: String? = nil, assessment: Bool = false) throws -> URL {
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
        if assessment { path += "/assessment" }
        parts.percentEncodedPath = path
        guard let result = parts.url, URLComponents(url: result, resolvingAgainstBaseURL: false)?.percentEncodedPath == path else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        return result
    }

    /// Durable recovery supplies exact bytes, not a re-encoded transcript. This bounded
    /// structural allowlist prevents another internal/audio export from reaching transport.
    /// It does not prove native completeness, redaction quality or N2 capture ownership.
    private static func validateProtectedBytes(_ data: Data) throws -> Set<UUID> {
        guard data.count > 0, data.count <= 750_000, String(data: data, encoding: .utf8) != nil,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys) == Set(["format", "schemaVersion", "sessionID", "title", "languageCode", "startedAt", "endedAt", "durationSeconds", "speakers", "segments", "privacy"]),
              object["format"] as? String == "pichi-voice-transcript", self.number(object["schemaVersion"]) == 1,
              let session = object["sessionID"] as? String, UUID(uuidString: session) != nil,
              let title = object["title"] as? String, title.utf16.count <= 200,
              let language = object["languageCode"] as? String, language.utf16.count <= 35,
              let started = object["startedAt"] as? String, let ended = object["endedAt"] as? String,
              let startDate = ISO8601DateFormatter().date(from: started), let endDate = ISO8601DateFormatter().date(from: ended), endDate >= startDate,
              let duration = self.number(object["durationSeconds"]), duration >= 0,
              let privacy = object["privacy"] as? [String: Any], Set(privacy.keys) == Set(["transcriptPIIRedacted", "includesAudio", "metadataMayContainPersonalData"]),
              self.boolean(privacy["transcriptPIIRedacted"]) == true, self.boolean(privacy["includesAudio"]) == false,
              self.boolean(privacy["metadataMayContainPersonalData"]) == true,
              let speakers = object["speakers"] as? [[String: Any]], let segments = object["segments"] as? [[String: Any]], segments.count <= 10_000 else {
            throw PichiPublicationWireFailure.invalidRequest
        }
        var speakerIDs = Set<UUID>()
        for speaker in speakers {
            try Task.checkCancellation()
            guard Set(speaker.keys).isSubset(of: ["id", "displayName", "isLocalUser", "identityIsProvisional"]),
                  let id = speaker["id"] as? String, let uuid = UUID(uuidString: id), speakerIDs.insert(uuid).inserted,
                  let name = speaker["displayName"] as? String, name.utf16.count <= 200,
                  self.boolean(speaker["isLocalUser"]) != nil,
                  speaker["identityIsProvisional"] == nil || self.boolean(speaker["identityIsProvisional"]) != nil else {
                throw PichiPublicationWireFailure.invalidRequest
            }
        }
        var represented = Set<UUID>(), segmentIDs = Set<UUID>(), textUnits = 0
        for segment in segments {
            try Task.checkCancellation()
            guard Set(segment.keys).isSubset(of: ["id", "startSeconds", "endSeconds", "speakerID", "text"]),
                  let id = segment["id"] as? String, let uuid = UUID(uuidString: id), segmentIDs.insert(uuid).inserted,
                  let start = self.number(segment["startSeconds"]), let end = self.number(segment["endSeconds"]), start >= 0, end >= start,
                  let text = segment["text"] as? String else { throw PichiPublicationWireFailure.invalidRequest }
            textUnits += text.utf16.count
            guard textUnits <= 100_000 else { throw PichiPublicationWireFailure.invalidRequest }
            if let raw = segment["speakerID"] {
                guard let id = raw as? String, let uuid = UUID(uuidString: id), speakerIDs.contains(uuid) else {
                    throw PichiPublicationWireFailure.invalidRequest
                }
                represented.insert(uuid)
            }
        }
        return represented
    }

    private static func number(_ value: Any?) -> Double? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite else { return nil }
        return number.doubleValue
    }
    private static func boolean(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number.boolValue
    }
}
