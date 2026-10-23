import Foundation

nonisolated enum PichiPublicationNetworkFailure: String, Error, Sendable {
    case unavailable, invalidRequest, invalidResponse, responseTooLarge, shutdown
}

nonisolated protocol PichiPublicationHTTPPerforming: Sendable {
    func perform(_ request: URLRequest) async throws -> PichiPublicationHTTPResponse
    func shutdown() async
}

/// No mutable policy or credentials. Redirects, including same-origin redirects, are refused.
private nonisolated final class PichiPublicationRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// Created only by an explicitly configured composition. It owns one ephemeral session and
/// joins its own requests on shutdown. The durable worker owns all retry scheduling.
actor PichiPublicationHTTPClient: PichiPublicationHTTPPerforming {
    private let configuration: AccountConfiguration
    private let session: URLSession
    private var active: [UUID: Task<PichiPublicationHTTPResponse, Error>] = [:]
    private var closed = false
    private var closing: Task<Void, Never>?

    init(configuration: AccountConfiguration) throws {
        try configuration.validate()
        self.configuration = configuration
        let policy = URLSessionConfiguration.ephemeral
        policy.httpShouldSetCookies = false; policy.httpCookieStorage = nil
        policy.urlCredentialStorage = nil; policy.urlCache = nil
        policy.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        policy.timeoutIntervalForRequest = 20; policy.timeoutIntervalForResource = 30
        self.session = URLSession(configuration: policy, delegate: PichiPublicationRedirectPolicy(), delegateQueue: nil)
    }

    func perform(_ request: URLRequest) async throws -> PichiPublicationHTTPResponse {
        try Task.checkCancellation()
        guard !self.closed else { throw PichiPublicationNetworkFailure.shutdown }
        guard self.active.count < 4 else { throw PichiPublicationNetworkFailure.unavailable }
        try self.validate(request)
        let id = UUID(), session = self.session
        let task = Task<PichiPublicationHTTPResponse, Error> {
            do {
                let (stream, response) = try await session.bytes(for: request)
                defer { stream.task.cancel() }
                guard let response = response as? HTTPURLResponse, response.url == request.url else {
                    throw PichiPublicationNetworkFailure.invalidResponse
                }
                guard response.expectedContentLength <= PichiPublicationRequest.maximumResponseBytes else {
                    throw PichiPublicationNetworkFailure.responseTooLarge
                }
                var body = Data()
                for try await byte in stream {
                    try Task.checkCancellation()
                    guard body.count < PichiPublicationRequest.maximumResponseBytes else {
                        throw PichiPublicationNetworkFailure.responseTooLarge
                    }
                    body.append(byte)
                }
                try Task.checkCancellation()
                return PichiPublicationHTTPResponse(status: response.statusCode, body: body,
                    retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            } catch is CancellationError { throw CancellationError() }
            catch let failure as PichiPublicationNetworkFailure { throw failure }
            catch {
                if Task.isCancelled || (error as? URLError)?.code == .cancelled { throw CancellationError() }
                throw PichiPublicationNetworkFailure.unavailable
            }
        }
        self.active[id] = task
        defer { self.active.removeValue(forKey: id) }
        return try await withTaskCancellationHandler {
            try await task.value
        } onCancel: { task.cancel() }
    }

    func shutdown() async {
        if let closing { await closing.value; return }
        guard !self.closed else { return }
        self.closed = true
        let tasks = Array(self.active.values)
        self.active.removeAll()
        for task in tasks { task.cancel() }
        let session = self.session
        let joined = Task {
            session.invalidateAndCancel()
            for task in tasks { _ = await task.result }
        }
        self.closing = joined
        await joined.value
        self.closing = nil
    }

    private func validate(_ request: URLRequest) throws {
        guard let url = request.url,
              let requested = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let trusted = URLComponents(url: self.configuration.apiBaseURL, resolvingAgainstBaseURL: false),
              requested.scheme == "https", requested.host == trusted.host, requested.port == trusted.port,
              requested.user == nil, requested.password == nil, requested.fragment == nil,
              (request.httpBody?.count ?? 0) <= PichiPublicationRequest.maximumMultipartBytes,
              let authorization = request.value(forHTTPHeaderField: "Authorization"), authorization.hasPrefix("Bearer "),
              authorization.utf8.count <= 32_775, authorization.count > 7,
              authorization.rangeOfCharacter(from: .controlCharacters) == nil else {
            throw PichiPublicationNetworkFailure.invalidRequest
        }
        let prefix = trusted.percentEncodedPath + "/api/v1/recordings/imports"
        let path = requested.percentEncodedPath
        let suffix = path.hasPrefix(prefix + "/") ? String(path.dropFirst(prefix.count + 1)) : nil
        let pieces = suffix?.split(separator: "/", omittingEmptySubsequences: false)
        let allowed: Bool
        switch request.httpMethod ?? "GET" {
        case "POST": allowed = path == prefix && requested.query == nil
        case "GET":
            if pieces?.count == 2, pieces?.first?.isEmpty == false, pieces?.last == "assessment-options" {
                allowed = request.httpBody == nil && PichiPublicationRequest.validAssessmentOptionsQuery(requested.queryItems)
            } else { allowed = pieces?.count == 1 && pieces?.first?.isEmpty == false && requested.query == nil }
        case "PATCH": allowed = pieces?.count == 2 && pieces?.first?.isEmpty == false && pieces?.last == "assessment" && requested.query == nil
        default: allowed = false
        }
        guard allowed else { throw PichiPublicationNetworkFailure.invalidRequest }
    }
}
