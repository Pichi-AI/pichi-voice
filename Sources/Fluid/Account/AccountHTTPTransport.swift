import Foundation

nonisolated protocol AccountHTTPRequesting: Sendable {
    func request(_ request: URLRequest) async throws -> Data
    func shutdown() async
}

/// Ephemeral session, no cookies/cache, no redirects, bounded bodies and total resource timeout.
nonisolated final class AccountHTTPClient: NSObject, URLSessionTaskDelegate, AccountHTTPRequesting, @unchecked Sendable {
    private var session: URLSession!
    override init() {
        super.init()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false; configuration.httpCookieStorage = nil
        configuration.urlCredentialStorage = nil; configuration.urlCache = nil
        configuration.timeoutIntervalForRequest = 20; configuration.timeoutIntervalForResource = 30
        session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func request(_ request: URLRequest) async throws -> Data {
        do {
            let (bytes, response) = try await session.bytes(for: request)
            defer { bytes.task.cancel() }
            guard let response = response as? HTTPURLResponse else { throw AccountError.invalidResponse }
            guard (200...299).contains(response.statusCode) else {
                switch response.statusCode {
                case 400, 401: throw AccountError.reauthenticationRequired
                case 403: throw AccountError.permissionDenied
                default: throw AccountError.networkUnavailable
                }
            }
            guard response.expectedContentLength <= 262_144 else { throw AccountError.invalidResponse }
            var result = Data()
            for try await byte in bytes {
                guard result.count < 262_144 else { throw AccountError.invalidResponse }
                result.append(byte)
            }
            return result
        } catch let error as AccountError { throw error }
        catch is CancellationError { throw CancellationError() }
        catch { throw AccountError.networkUnavailable }
    }
    func shutdown() async { session.invalidateAndCancel() }
}

/// Signed distribution selects issuer/API/client; discovery may only supply same-origin endpoints.
actor AccountHTTPTransport: AccountTransporting {
    private struct Discovery: Decodable, Sendable {
        let issuer: String
        let authorization_endpoint: URL
        let token_endpoint: URL
        let jwks_uri: URL
        let revocation_endpoint: URL?
        let code_challenge_methods_supported: [String]?
    }
    private struct Tokens: Decodable {
        let access_token: String
        let refresh_token: String?
        let id_token: String?
        let token_type: String
        let expires_in: Double
    }
    private let configuration: AccountConfiguration
    private let http: any AccountHTTPRequesting
    private var metadata: Discovery?

    init(configuration: AccountConfiguration, http: any AccountHTTPRequesting = AccountHTTPClient()) {
        self.configuration = configuration; self.http = http
    }
    func authorizationURL(state: String, nonce: String, challenge: String) async throws -> URL {
        let discovery = try await discover()
        var url = URLComponents(url: discovery.authorization_endpoint, resolvingAgainstBaseURL: false)!
        url.queryItems = ["response_type": "code", "client_id": configuration.clientID,
            "redirect_uri": configuration.redirectURI.absoluteString, "scope": "openid profile email",
            "state": state, "nonce": nonce, "code_challenge": challenge, "code_challenge_method": "S256"]
            .sorted(by: { $0.key < $1.key }).map { URLQueryItem(name: $0.key, value: $0.value) }
        guard let result = url.url else { throw AccountError.invalidConfiguration }
        return result
    }
    func exchange(code: String, verifier: String, nonce: String) async throws -> AccountTokenResponse {
        try await tokens(fields: ["grant_type": "authorization_code", "code": code,
            "redirect_uri": configuration.redirectURI.absoluteString, "code_verifier": verifier], nonce: nonce, previous: nil)
    }
    func refresh(_ grant: AccountGrant) async throws -> AccountTokenResponse {
        let result = try await tokens(fields: ["grant_type": "refresh_token", "refresh_token": grant.refreshToken], nonce: nil, previous: grant)
        guard result.subject == grant.identity.subject else { throw AccountError.invalidToken }
        return result
    }
    func account(accessToken: String) async throws -> AccountSnapshot {
        var request = URLRequest(url: configuration.apiBaseURL.appendingPathComponent("api/v1/account"))
        request.setValue("Bearer " + accessToken, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        return try JSONDecoder().decode(AccountSnapshot.self, from: await http.request(request))
    }
    func revoke(refreshToken: String) async throws {
        guard let endpoint = try await discover().revocation_endpoint else { throw AccountError.revocationUnavailable }
        _ = try await http.request(form(endpoint, fields: ["client_id": configuration.clientID,
            "token": refreshToken, "token_type_hint": "refresh_token"]))
    }
    func shutdown() async { await http.shutdown() }
    private func tokens(fields: [String: String], nonce: String?, previous: AccountGrant?) async throws -> AccountTokenResponse {
        let discovery = try await discover()
        var fields = fields; fields["client_id"] = configuration.clientID
        // Obtain verification material before consuming a rotating refresh token.
        let keysData = try await http.request(URLRequest(url: discovery.jwks_uri))
        let keys = try JSONDecoder().decode(AccountJWTValidator.JWKSet.self, from: keysData)
        let data: Data
        do { data = try await http.request(form(discovery.token_endpoint, fields: fields)) }
        catch {
            // A lost refresh response is ambiguous. Never replay a potentially consumed token.
            if previous != nil { throw AccountError.reauthenticationRequired }
            throw error
        }
        guard let tokens = try? JSONDecoder().decode(Tokens.self, from: data) else { throw AccountError.invalidToken }
        guard tokens.token_type.lowercased() == "bearer", tokens.expires_in.isFinite, tokens.expires_in > 0,
              tokens.expires_in <= 86400, tokens.access_token.utf8.count <= 32768,
              let refresh = tokens.refresh_token ?? previous?.refreshToken, !refresh.isEmpty,
              refresh.utf8.count <= 32768 else { throw AccountError.invalidToken }
        let access = try AccountJWTValidator.validate(tokens.access_token, keys: keys, issuer: configuration.issuer.absoluteString,
            audience: configuration.apiAudience)
        if let idToken = tokens.id_token {
            let id = try AccountJWTValidator.validate(idToken, keys: keys, issuer: configuration.issuer.absoluteString,
                audience: configuration.clientID, nonce: nonce ?? previous?.nonce, authorizedParty: configuration.clientID, requireNonce: nonce != nil)
            guard id.subject == access.subject else { throw AccountError.invalidToken }
        } else if nonce != nil { throw AccountError.invalidToken }
        return AccountTokenResponse(accessToken: tokens.access_token, refreshToken: refresh,
            expiresAt: min(access.expiresAt, Date().addingTimeInterval(tokens.expires_in)), subject: access.subject)
    }
    private func discover() async throws -> Discovery {
        if let metadata { return metadata }
        try configuration.validate()
        let data = try await http.request(URLRequest(url: configuration.issuer.appendingPathComponent(".well-known/openid-configuration")))
        let value = try JSONDecoder().decode(Discovery.self, from: data)
        guard value.issuer == configuration.issuer.absoluteString,
              value.code_challenge_methods_supported?.contains("S256") == true else { throw AccountError.invalidConfiguration }
        for url in [value.authorization_endpoint, value.token_endpoint, value.jwks_uri, value.revocation_endpoint].compactMap({ $0 }) {
            guard url.scheme == "https", url.host == configuration.issuer.host, url.port == configuration.issuer.port,
                  url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else { throw AccountError.invalidConfiguration }
        }
        metadata = value
        return value
    }
    private func form(_ url: URL, fields: [String: String]) -> URLRequest {
        let safe = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields.sorted(by: { $0.key < $1.key }).map {
            $0.key.addingPercentEncoding(withAllowedCharacters: safe)! + "=" + $0.value.addingPercentEncoding(withAllowedCharacters: safe)!
        }.joined(separator: "&")
        var request = URLRequest(url: url); request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = Data(body.utf8)
        return request
    }
}
