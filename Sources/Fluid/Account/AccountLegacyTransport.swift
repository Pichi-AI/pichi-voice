import Foundation

nonisolated struct LegacyAccountHTTPResponse: Sendable {
    let status: Int
    let body: Data
    let retryAfter: String?
}

/// Owns the legacy credential in private memory, never the OIDC grant envelope.
nonisolated protocol LegacyAccountTransporting: Sendable {
    func login(email: String, password: String, captchaToken: String?) async throws -> AccountSnapshot
    func account() async throws -> AccountSnapshot
    func switchOrganization(_ organizationID: String) async throws -> AccountSnapshot
    func perform(_ request: URLRequest) async throws -> LegacyAccountHTTPResponse
    func logout() async throws
    func clearSession() async
    func shutdown() async
    func sessionCookie() async throws -> LegacyAccountCookie?
    func restoreSession(_ cookie: LegacyAccountCookie) async throws
    func refreshSession() async throws
}

/// Existing injected memory-only adapters do not opt in to durable credentials.
extension LegacyAccountTransporting {
    nonisolated func sessionCookie() async throws -> LegacyAccountCookie? { nil }
    nonisolated func restoreSession(_ cookie: LegacyAccountCookie) async throws { throw AccountError.invalidState }
    nonisolated func refreshSession() async throws { throw AccountError.invalidState }
}

nonisolated enum LegacyAccountConnectivityFailure: Error, Sendable { case unavailable }

private nonisolated final class LegacyAccountRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

/// One ephemeral session and an origin-bound in-memory cookie jar. Shared cookie,
/// cache and credential stores are disabled. Every redirect is refused.
actor LegacyAccountHTTPTransport: LegacyAccountTransporting {
    static let maximumResponseBytes = 2_097_152
    private let configuration: LegacyAccountConfiguration
    private let session: URLSession
    private var cookie: HTTPCookie?
    private var cookieReceivedAt: Date?
    private var active: [UUID: Task<LegacyAccountHTTPResponse, Error>] = [:]
    private var closed = false
    private var sessionGeneration = UUID()
    private var clearing: Task<Void, Never>?

    init(configuration: LegacyAccountConfiguration, sessionConfiguration: URLSessionConfiguration? = nil) throws {
        try configuration.validate()
        self.configuration = configuration
        let policy = sessionConfiguration ?? .ephemeral
        policy.httpShouldSetCookies = false; policy.httpCookieStorage = nil
        policy.urlCredentialStorage = nil; policy.urlCache = nil
        policy.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        policy.timeoutIntervalForRequest = 20; policy.timeoutIntervalForResource = 30
        session = URLSession(configuration: policy, delegate: LegacyAccountRedirectPolicy(), delegateQueue: nil)
    }

    func login(email: String, password: String, captchaToken: String?) async throws -> AccountSnapshot {
        guard !email.isEmpty, email.utf8.count <= 320, !password.isEmpty, password.utf8.count <= 4096,
              captchaToken == nil || captchaToken!.utf8.count <= 16_384 else { throw AccountError.invalidAccount }
        await clearSession()
        var fields = ["email": email, "password": password]
        if let captchaToken { fields["captchaToken"] = captchaToken }
        _ = try await checked(path: "/api/auth/login", method: "POST", body: fields)
        // Fresh /me, not the login response, establishes admission identity.
        guard cookie != nil else { throw AccountError.invalidResponse }
        return try await account()
    }

    func account() async throws -> AccountSnapshot {
        struct Me: Decodable { struct User: Decodable {
            let id: Int; let fullName: String?; let email: String?; let organizationId: Int
        }; let user: User }
        let me = try Self.decode(Me.self, await checked(path: "/api/auth/me"))
        guard me.user.id > 0, me.user.organizationId > 0 else { throw AccountError.invalidAccount }
        struct Organizations: Decodable { struct Organization: Decodable { let id: Int; let name: String }
            let organizations: [Organization]; let currentOrganizationId: Int }
        let organizations = try Self.decode(Organizations.self, await checked(path: "/api/auth/organizations"))
        guard organizations.currentOrganizationId == me.user.organizationId, organizations.organizations.count <= 100,
              Set(organizations.organizations.map(\.id)).count == organizations.organizations.count,
              organizations.organizations.contains(where: { $0.id == me.user.organizationId }) else { throw AccountError.invalidAccount }
        struct Workspaces: Decodable { struct Workspace: Decodable { let id: Int; let name: String; let organizationId: Int }
            struct Organization: Decodable { let id: Int }
            let workspaces: [Workspace]; let organization: Organization? }
        let workspaces = try Self.decode(Workspaces.self, await checked(path: "/api/workspaces"))
        guard workspaces.organization?.id == me.user.organizationId, workspaces.workspaces.count <= 1000,
              Set(workspaces.workspaces.map(\.id)).count == workspaces.workspaces.count else { throw AccountError.invalidAccount }
        var editable: [AccountSnapshot.Workspace] = []
        for workspace in workspaces.workspaces {
            try Task.checkCancellation()
            guard workspace.id > 0, workspace.organizationId == me.user.organizationId,
                  workspace.name.utf8.count <= 4096 else { throw AccountError.invalidAccount }
            struct Permission: Decodable { let permission: String? }
            let permission = try Self.decode(Permission.self, await checked(path: "/api/workspaces/\(workspace.id)/user-permission"))
            if permission.permission == "edit" {
                editable.append(.init(id: String(workspace.id), name: workspace.name, capabilities: ["recordings:import"]))
            }
        }
        let snapshot = AccountSnapshot(schemaVersion: 1,
            account: .init(id: String(me.user.id), displayName: me.user.fullName ?? "", email: me.user.email),
            identity: .init(issuer: "", subject: "", legacyOrigin: configuration.apiBaseURL.absoluteString),
            organizations: organizations.organizations.map {
                .init(id: String($0.id), name: $0.name, workspaces: $0.id == me.user.organizationId ? editable : [])
            }, activeOrganizationID: String(me.user.organizationId))
        try snapshot.validateLegacy(origin: configuration.apiBaseURL)
        return snapshot
    }

    func switchOrganization(_ organizationID: String) async throws -> AccountSnapshot {
        guard let id = Int(organizationID), id > 0, String(id) == organizationID else { throw AccountError.workspaceUnavailable }
        _ = try await checked(path: "/api/auth/switch-organization", method: "POST", body: ["organizationId": id])
        return try await account()
    }

    func sessionCookie() throws -> LegacyAccountCookie? {
        guard let cookie, let cookieReceivedAt, let expiresAt = cookie.expiresDate else { return nil }
        let value = LegacyAccountCookie(value: cookie.value, receivedAt: cookieReceivedAt, expiresAt: expiresAt)
        try value.validate()
        return value
    }
    func restoreSession(_ saved: LegacyAccountCookie) async throws {
        try saved.validate()
        await clearSession()
        guard !closed else { throw AccountError.staleOperation }
        try Task.checkCancellation()
        guard let host = configuration.apiBaseURL.host,
              let restored = HTTPCookie(properties: [.name: "auth_token", .value: saved.value, .domain: host,
                .path: "/", .secure: "TRUE", HTTPCookiePropertyKey("HttpOnly"): "TRUE", .expires: saved.expiresAt]) else {
            throw AccountError.invalidAccount
        }
        cookie = restored; cookieReceivedAt = saved.receivedAt
    }
    func refreshSession() async throws {
        guard let cookie, cookie.expiresDate.map({ $0 > Date() }) != false else { throw AccountError.reauthenticationRequired }
        _ = try await checked(path: "/api/auth/refresh", method: "POST")
    }

    func logout() async throws {
        // The server revokes every session for this user. UI exposes that effect.
        defer { cookie = nil; cookieReceivedAt = nil }
        if cookie != nil { _ = try await checked(path: "/api/auth/logout", method: "POST") }
    }
    func clearSession() async {
        if let clearing { await clearing.value; return }
        sessionGeneration = UUID(); cookie = nil; cookieReceivedAt = nil
        let tasks = Array(active.values)
        tasks.forEach { $0.cancel() }
        let task = Task { for request in tasks { _ = try? await request.value } }
        clearing = task
        await task.value
        clearing = nil
    }
    func shutdown() async { closed = true; await clearSession(); session.invalidateAndCancel() }

    private func checked(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> Data {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let response = try await perform(request)
        guard (200...299).contains(response.status) else {
            // A maintenance/gateway response is not evidence that the saved local
            // owner or cookie was revoked. Cached admission remains local-only.
            if response.status == 408 || (500...599).contains(response.status) {
                throw LegacyAccountConnectivityFailure.unavailable
            }
            struct Failure: Decodable { let message: String?; let requireCaptcha: Bool? }
            let error = try? JSONDecoder().decode(Failure.self, from: response.body)
            if error?.requireCaptcha == true { throw AccountError.captchaRequired }
            if error?.message == "error.auth.ciam_required" { throw AccountError.browserLoginRequired }
            switch response.status {
            case 400, 401: throw AccountError.reauthenticationRequired
            case 403: throw AccountError.permissionDenied
            case 429: throw AccountError.rateLimited
            default: throw AccountError.networkUnavailable
            }
        }
        return response.body
    }

    func perform(_ original: URLRequest) async throws -> LegacyAccountHTTPResponse {
        try Task.checkCancellation()
        guard !closed, clearing == nil, active.count < 4 else { throw AccountError.busy }
        try validate(original)
        var request = original
        if let cookie {
            guard cookie.expiresDate.map({ $0 > Date() }) != false else {
                self.cookie = nil; self.cookieReceivedAt = nil; throw AccountError.reauthenticationRequired
            }
            request.setValue("auth_token=" + cookie.value, forHTTPHeaderField: "Cookie")
        }
        let id = UUID(), session = self.session, captured = sessionGeneration
        let task = Task<LegacyAccountHTTPResponse, Error> {
            do {
                let (stream, response) = try await session.bytes(for: request)
                defer { stream.task.cancel() }
                guard let response = response as? HTTPURLResponse, response.url == request.url,
                      response.expectedContentLength <= Self.maximumResponseBytes else { throw AccountError.invalidResponse }
                var result = Data()
                for try await byte in stream {
                    guard result.count < Self.maximumResponseBytes else { throw AccountError.invalidResponse }
                    result.append(byte)
                }
                try Task.checkCancellation()
                try self.receiveCookie(response, requestedURL: request.url!, generation: captured)
                return .init(status: response.statusCode, body: result, retryAfter: response.value(forHTTPHeaderField: "Retry-After"))
            } catch let error as AccountError { throw error }
            catch is CancellationError { throw CancellationError() }
            catch let error as URLError {
                if [.notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed].contains(error.code) {
                    throw LegacyAccountConnectivityFailure.unavailable
                }
                throw AccountError.networkUnavailable
            }
            catch { throw AccountError.networkUnavailable }
        }
        active[id] = task
        defer { active.removeValue(forKey: id) }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    private func receiveCookie(_ response: HTTPURLResponse, requestedURL: URL, generation: UUID) throws {
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw AccountError.staleOperation }
        guard let raw = response.value(forHTTPHeaderField: "Set-Cookie") else { return }
        guard ["/api/auth/login", "/api/auth/refresh", "/api/auth/switch-organization", "/api/auth/logout"].contains(requestedURL.path) else {
            throw AccountError.invalidResponse
        }
        let values = HTTPCookie.cookies(withResponseHeaderFields: ["Set-Cookie": raw], for: requestedURL).filter { $0.name == "auth_token" }
        guard values.count == 1, let next = values.first,
              next.domain.lowercased() == configuration.apiBaseURL.host?.lowercased(), next.path == "/",
              next.isHTTPOnly, next.value.utf8.count <= 32_768,
              next.value.rangeOfCharacter(from: .controlCharacters) == nil else { throw AccountError.invalidResponse }
        cookie = next.value.isEmpty || next.expiresDate.map({ $0 <= Date() }) == true ? nil : next
        cookieReceivedAt = cookie == nil ? nil : Date()
    }

    private func validate(_ request: URLRequest) throws {
        guard let url = request.url, url.scheme == "https", url.host == configuration.apiBaseURL.host,
              url.port == configuration.apiBaseURL.port, url.user == nil, url.password == nil, url.fragment == nil,
              url.path.hasPrefix("/api/"), !url.path.contains(".."), !url.absoluteString.lowercased().contains("%2f"),
              ["GET", "POST"].contains(request.httpMethod ?? "GET"),
              request.value(forHTTPHeaderField: "Authorization") == nil,
              request.value(forHTTPHeaderField: "Cookie") == nil,
              request.value(forHTTPHeaderField: "Origin") == nil,
              request.value(forHTTPHeaderField: "Referer") == nil,
              (request.httpBody?.count ?? 0) <= 1_048_576 else { throw AccountError.invalidConfiguration }
    }
    private static func decode<T: Decodable>(_ type: T.Type, _ data: Data) throws -> T {
        guard let value = try? JSONDecoder().decode(type, from: data) else { throw AccountError.invalidResponse }
        return value
    }
}

extension AccountSnapshot {
    nonisolated func validateLegacy(origin: URL) throws {
        func valid(_ id: String) -> Bool {
            guard let number = Int(id), number > 0 else { return false }
            return String(number) == id
        }
        guard schemaVersion == 1, identity.issuer.isEmpty, identity.subject.isEmpty,
              identity.legacyOrigin == origin.absoluteString, valid(account.id),
              let activeOrganizationID, valid(activeOrganizationID), organizations.count <= 100,
              Set(organizations.map(\.id)).count == organizations.count,
              organizations.contains(where: { $0.id == activeOrganizationID }) else { throw AccountError.invalidAccount }
        for organization in organizations {
            guard valid(organization.id), organization.name.utf8.count <= 4096, organization.workspaces.count <= 1000,
                  Set(organization.workspaces.map(\.id)).count == organization.workspaces.count,
                  organization.workspaces.allSatisfy({ valid($0.id) && $0.name.utf8.count <= 4096 && $0.capabilities == ["recordings:import"] }) else {
                throw AccountError.invalidAccount
            }
        }
    }
}
