import CryptoKit
import Foundation

/// Transport metadata extends the existing provider repository. It is independent
/// of model IDs, prompts, branding and per-mode orchestration.
nonisolated struct CloudTextProvider: Sendable {
    struct Field: Identifiable, Sendable {
        let id: String
        let title: String
        let choices: [String]
        let defaultValue: String
    }
    enum Authorization: Sendable {
        case apiKey(scheme: String)
        case oauth(tokenURL: URL)
    }
    enum StructuredResponse: Sendable {
        case namedSchema, inlineSchema
    }
    let id: String
    let name: String
    let baseURL: String
    let hosts: Set<String>
    let website: String
    let credentialTitle: String
    let fields: [Field]
    let authorization: Authorization
    let projectHeader: String?
    let supportsTools: Bool
    let structuredResponse: StructuredResponse

    static let registered: [Self] = [
        .init(id: "gigachat", name: "GigaChat", baseURL: "https://api.giga.chat/v1",
              hosts: ["api.giga.chat", "gigachat.devices.sberbank.ru"],
              website: "https://developers.sber.ru/docs/ru/gigachat/api/reference/rest/gigachat-api",
              credentialTitle: "Authorization key", fields: [
                  .init(id: "scope", title: "API scope", choices: ["GIGACHAT_API_PERS", "GIGACHAT_API_B2B", "GIGACHAT_API_CORP"], defaultValue: "GIGACHAT_API_PERS"),
              ], authorization: .oauth(tokenURL: URL(string: "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")!),
              projectHeader: nil, supportsTools: false, structuredResponse: .inlineSchema),
        .init(id: "yandex", name: "Yandex AI Studio", baseURL: "https://ai.api.cloud.yandex.net/v1",
              hosts: ["ai.api.cloud.yandex.net"], website: "https://aistudio.yandex.ru/ru/docs/ai-studio/quickstart/",
              credentialTitle: "API key", fields: [.init(id: "project", title: "Folder ID", choices: [], defaultValue: "")],
              authorization: .apiKey(scheme: "Api-Key"), projectHeader: "OpenAI-Project", supportsTools: true,
              structuredResponse: .namedSchema),
    ]

    /// Preserve the caller's schema while encoding the registered API's envelope.
    /// The inference pipeline always supplies the existing named-schema contract.
    func responseFormat(_ format: [String: Any]) -> [String: Any] {
        guard case .inlineSchema = self.structuredResponse,
              format["type"] as? String == "json_schema",
              let named = format["json_schema"] as? [String: Any], let schema = named["schema"]
        else { return format }
        var result: [String: Any] = ["type": "json_schema", "schema": schema]
        if let strict = named["strict"] { result["strict"] = strict }
        return result
    }

    /// The existing verification fingerprint remains byte-compatible when no
    /// connection metadata exists. Additional fields are encoded unambiguously.
    static func connectionFingerprint(baseURL: String, apiKey: String, options: [String: String] = [:]) -> String? {
        let base = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        let key = apiKey.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !base.isEmpty else { return nil }
        var input = "\(base)|\(key)"
        if !options.isEmpty {
            let ordered = options.keys.sorted().flatMap { [$0, options[$0] ?? ""] }
            guard let data = try? JSONEncoder().encode(ordered), let value = String(data: data, encoding: .utf8) else { return nil }
            input += "|" + value
        }
        return SHA256.hash(data: Data(input.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func descriptor(for id: String) -> Self? { self.registered.first { $0.id == id } }

    static func descriptor(forEndpoint endpoint: String) -> Self? {
        guard let url = URL(string: endpoint), let host = url.host?.lowercased(),
              url.scheme?.lowercased() == "https", url.port == nil || url.port == 443,
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil
        else { return nil }
        return self.registered.first { $0.hosts.contains(host) }
    }

    /// Only descriptor-owned nonsecret fields may enter settings or backups.
    static func sanitizedOptions(_ values: [String: [String: String]]) -> [String: [String: String]] {
        var result: [String: [String: String]] = [:]
        for provider in self.registered {
            guard let options = values[provider.id] else { continue }
            let fields = Set(provider.fields.map(\.id))
            result[provider.id] = options.filter { key, value in
                fields.contains(key) && value.utf8.count <= 200
                    && !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            }
        }
        return result
    }

    static func validateCredential(_ credential: String) throws {
        guard !credential.isEmpty, credential.utf8.count <= 16_384,
              !credential.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
        else { throw CloudTextProviderError.invalidConfiguration }
    }

    func normalizedOptions(_ options: [String: String]) throws -> [String: String] {
        var result: [String: String] = [:]
        for field in self.fields {
            let value = (options[field.id] ?? field.defaultValue).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !value.isEmpty, value.utf8.count <= 200, !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
                  field.choices.isEmpty || field.choices.contains(value)
            else { throw CloudTextProviderError.invalidConfiguration }
            result[field.id] = value
        }
        return result
    }

    func validateModel(_ model: String, options: [String: String]) throws {
        guard self.projectHeader != nil else { return }
        let prefix = "gpt://\(options["project"] ?? "")/"
        // Preserve the selected URI exactly; never substitute a folder or model.
        guard model.hasPrefix(prefix), model.count > prefix.count else { throw CloudTextProviderError.invalidModelURI }
    }
}

nonisolated enum CloudTextProviderError: LocalizedError {
    case invalidConfiguration, invalidModelURI, invalidToken, invalidResponse, http(Int)
    var errorDescription: String? {
        switch self {
        case .invalidConfiguration: PichiLocalization.text("Check the provider's connection parameters and credentials.")
        case .invalidModelURI: PichiLocalization.text("Use the full model URI returned by the provider, with the same folder ID.")
        case .invalidResponse: PichiLocalization.text("The cloud provider returned an invalid response.")
        case .invalidToken: PichiLocalization.text("The provider returned an invalid or expired access token.")
        case let .http(status): PichiLocalization.format("Cloud provider request failed (HTTP %lld). Check your credentials and connection settings.", Int64(status))
        }
    }
}

/// No redirects, credential logging, cookies or custom trust bypasses. OAuth and
/// the two registered services use normal platform TLS validation.
final nonisolated class CloudTextProviderRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) { completionHandler(nil) }
}

nonisolated enum CloudTextProviderTransport {
    static let redirectPolicy = CloudTextProviderRedirectPolicy()
    static let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.httpShouldSetCookies = false
        config.httpCookieStorage = nil
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 600
        return URLSession(configuration: config, delegate: redirectPolicy, delegateQueue: nil)
    }()
}

/// Tokens live only in memory. Each suspended exchange is owned by the caller's
/// task, so cancellation joins the URLSession request without detached work.
actor CloudTextProviderAuthorization {
    static let shared = CloudTextProviderAuthorization()
    private struct Token { let value: String; let expiry: Date }
    private var tokens: [String: Token] = [:]
    private let session: URLSession
    private let now: @Sendable () -> Date

    init(session: URLSession = CloudTextProviderTransport.session, now: @escaping @Sendable () -> Date = { Date() }) {
        self.session = session
        self.now = now
    }

    private func identity(_ provider: CloudTextProvider, credential: String, options: [String: String]) -> String {
        let fields = [provider.id, credential] + options.keys.sorted().flatMap { [$0, options[$0] ?? ""] }
        let data = (try? JSONEncoder().encode(fields)) ?? Data()
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    func headers(for provider: CloudTextProvider, credential: String, options: [String: String], rejecting: String? = nil) async throws -> [String: String] {
        try Task.checkCancellation()
        let options = try provider.normalizedOptions(options)
        try CloudTextProvider.validateCredential(credential)
        var headers: [String: String] = [:]
        if let projectHeader = provider.projectHeader { headers[projectHeader] = options["project"] }
        switch provider.authorization {
        case let .apiKey(scheme): headers["Authorization"] = "\(scheme) \(credential)"
        case let .oauth(tokenURL):
            let identity = self.identity(provider, credential: credential, options: options)
            if let cached = self.tokens[identity], cached.expiry.timeIntervalSince(self.now()) > 60,
               "Bearer \(cached.value)" != rejecting {
                headers["Authorization"] = "Bearer \(cached.value)"
                return headers
            }
            var request = URLRequest(url: tokenURL)
            request.httpMethod = "POST"
            request.setValue("Basic \(credential)", forHTTPHeaderField: "Authorization")
            request.setValue(UUID().uuidString, forHTTPHeaderField: "RqUID")
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
            // Scope is a descriptor-validated protocol value, never user-supplied form syntax.
            request.httpBody = Data("scope=\(options["scope"] ?? "")".utf8)
            var data = Data()
            do {
                let (bytes, response) = try await self.session.bytes(for: request)
                defer { bytes.task.cancel() }
                guard let http = response as? HTTPURLResponse else { throw CloudTextProviderError.invalidToken }
                guard http.statusCode == 200 else { throw CloudTextProviderError.http(http.statusCode) }
                for try await byte in bytes {
                    guard data.count < 64_000 else { throw CloudTextProviderError.invalidToken }
                    data.append(byte)
                }
            } catch {
                if Task.isCancelled { throw CancellationError() }
                throw error
            }
            try Task.checkCancellation()
            struct Reply: Decodable { let access_token: String; let expires_at: Double }
            guard data.count <= 64_000, let reply = try? JSONDecoder().decode(Reply.self, from: data),
                  !reply.access_token.isEmpty, reply.access_token.utf8.count <= 16_384,
                  !reply.access_token.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }), reply.expires_at.isFinite
            else { throw CloudTextProviderError.invalidToken }
            // The service uses Unix milliseconds. Accept seconds from compatible
            // deployments too, then cap lifetime to the documented 30 minutes.
            let seconds = reply.expires_at > 10_000_000_000 ? reply.expires_at / 1000 : reply.expires_at
            let expiry = min(Date(timeIntervalSince1970: seconds), self.now().addingTimeInterval(1800))
            guard expiry.timeIntervalSince(self.now()) > 60 else { throw CloudTextProviderError.invalidToken }
            self.tokens = self.tokens.filter { $0.value.expiry > self.now() }
            if self.tokens.count >= 16 { self.tokens.removeAll(keepingCapacity: true) }
            self.tokens[identity] = .init(value: reply.access_token, expiry: expiry)
            headers["Authorization"] = "Bearer \(reply.access_token)"
        }
        return headers
    }
}
