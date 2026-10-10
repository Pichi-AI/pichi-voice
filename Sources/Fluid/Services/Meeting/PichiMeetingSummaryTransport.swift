import Foundation

// Summary destinations are user-selected. Never forward private transcript bodies
// through a redirect, even if the original URL was localhost.
final nonisolated class PichiMeetingSummaryRedirectPolicy: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

nonisolated enum PichiMeetingSummaryTransport {
    static let ollamaContextTokens = 8192
    static let ollamaOutputTokens = 3000
    static let redirectPolicy = PichiMeetingSummaryRedirectPolicy()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 600
        return URLSession(configuration: configuration, delegate: redirectPolicy, delegateQueue: nil)
    }()
    static let client = LLMClient(session: session)

    static func usesNativeOllama(_ config: LLMClient.Config) -> Bool {
        guard PichiMeetingSummaryConfiguration.isLoopback(config.baseURL),
              let url = URL(string: config.baseURL), url.port == 11434,
              ["http", "https"].contains(url.scheme), url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "v1"
        else { return false }
        return true
    }

    static func complete(_ config: LLMClient.Config) async throws -> String {
        guard self.usesNativeOllama(config) else { return try await self.client.call(config).content }
        let request = try self.ollamaRequest(config)
        let (data, response) = try await self.session.data(for: request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard http.statusCode == 200 else { throw LLMError.httpError(http.statusCode, "Local summary request failed.") }
        struct Response: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
            let done: Bool
            let done_reason: String?
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard result.done, result.done_reason != "length", !result.message.content.isEmpty else {
            throw LLMError.invalidRequest("The local model could not complete its structured result within the output limit. The transcript is safe.")
        }
        return result.message.content
    }

    // OpenAI compatibility does not expose num_ctx. The native API bounds each
    // inference request without changing global settings or duplicating weights.
    static func ollamaRequest(_ config: LLMClient.Config) throws -> URLRequest {
        guard self.usesNativeOllama(config), var components = URLComponents(string: config.baseURL) else { throw LLMError.invalidURL }
        components.path = "/api/chat"
        guard let url = components.url else { throw LLMError.invalidURL }
        let ledger = (config.messages.first?["content"] as? String ?? "").contains("Reconcile meeting")
        let responseFormat = config.extraParameters["response_format"] as? [String: Any]
        let structured = responseFormat?["json_schema"] as? [String: Any]
        let schema = structured?["schema"] as? [String: Any] ?? self.schema(ledger: ledger)
        let body: [String: Any] = [
            "model": config.model, "messages": config.messages, "stream": false,
            "think": false, "keep_alive": 0, "format": schema,
            "options": ["num_ctx": self.ollamaContextTokens, "num_predict": self.ollamaOutputTokens, "temperature": 0],
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds ?? 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    static func schema(ledger: Bool, sourceIndexes: [Int]? = nil) -> [String: Any] {
        var evidence: [String: Any] = [
            "type": "object", "additionalProperties": false, "required": ["segmentID", "quote"],
            "properties": ["segmentID": ["type": "string"], "quote": ["type": "string", "minLength": 1, "maxLength": 500]],
        ]
        if let sourceIndexes, !sourceIndexes.isEmpty {
            evidence = ["type": "object", "additionalProperties": false, "required": ["sourceIndex"],
                        "properties": ["sourceIndex": ["type": "integer", "enum": sourceIndexes]]]
        }
        let definitions: [String: Any] = sourceIndexes?.isEmpty == false ? ["$defs": ["evidence": evidence]] : [:]
        let citationItem: [String: Any] = definitions.isEmpty ? evidence : ["$ref": "#/$defs/evidence"]
        let citations: [String: Any] = ["type": "array", "items": citationItem, "minItems": 1, "maxItems": 8]
        if ledger {
            return definitions.merging(["type": "object", "additionalProperties": false, "required": ["updates"], "properties": [
                "updates": ["type": "array", "items": ["type": "object", "additionalProperties": false,
                            "required": ["index", "evidence"], "properties": ["index": ["type": "integer", "minimum": 0], "evidence": citations]]],
            ]]) { _, new in new }
        }
        let properties: [String: Any] = ["text": ["type": "string", "minLength": 1, "maxLength": 2000], "evidence": citations]
        let item: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["text", "evidence"], "properties": properties]
        var actionProperties = properties
        let nullableText: [[String: Any]] = [["type": "null"], ["type": "string", "minLength": 1, "maxLength": 200]]
        actionProperties["owner"] = ["anyOf": nullableText, "description": "Exact original name, or JSON null without quotes when unspecified."]
        actionProperties["deadline"] = ["anyOf": nullableText, "description": "Exact source speech substring including prepositions and grammatical case. Never normalize; use JSON null without quotes if unspecified."]
        let action: [String: Any] = ["type": "object", "additionalProperties": false,
                                     "required": ["text", "evidence", "owner", "deadline"], "properties": actionProperties]
        var fields: [String: Any] = [:]
        for name in ["summary", "decisions", "actions", "openQuestions", "changes", "answers"] {
            fields[name] = ["type": "array", "items": name == "actions" ? action : item,
                            "minItems": name == "summary" ? 1 : 0, "maxItems": name == "summary" ? 5 : 30]
        }
        return definitions.merging(["type": "object", "additionalProperties": false, "required": Array(fields.keys).sorted(), "properties": fields]) { _, new in new }
    }
}
