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
        configuration.timeoutIntervalForResource = 3600
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
        return try self.ollamaContent(data)
    }

    static func ollamaContent(_ data: Data) throws -> String {
        struct Response: Decodable {
            struct Message: Decodable { let content: String }
            let message: Message
            let done: Bool
            let done_reason: String?
        }
        let result = try JSONDecoder().decode(Response.self, from: data)
        guard result.done else { throw LLMError.invalidResponse }
        if result.done_reason == "length" { throw PichiMeetingSummaryError.outputLimit }
        guard !result.message.content.isEmpty else { throw LLMError.invalidResponse }
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
        let thinking = try self.ollamaThinking(config.extraParameters)
        let outputTokens = config.maxTokens ?? self.ollamaOutputTokens
        guard (1...8192).contains(outputTokens) else { throw PichiMeetingSummaryError.notConfigured }
        var options: [String: Any] = ["num_ctx": try self.ollamaContext(config.extraParameters), "num_predict": outputTokens]
        // Thinking models may degenerate under greedy decoding. Use the selected
        // artifact's sampling defaults, which belong to its inference adapter.
        if (thinking as? Bool) == false { options["temperature"] = 0 }
        let body: [String: Any] = [
            "model": config.model, "messages": config.messages, "stream": false,
            "think": thinking, "keep_alive": 0, "format": schema, "options": options,
        ]
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = config.timeoutSeconds ?? 180
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        return request
    }

    // Protocol adaptation only: boolean thinking and effort levels are distinct
    // supported Ollama values. Never infer capability from a model's display name.
    static func ollamaThinking(_ parameters: [String: Any]) throws -> Any {
        for key in ["think", "enable_thinking", "thinking"] {
            if let value = parameters[key] {
                if let boolean = value as? Bool { return boolean }
                if let text = value as? String, let boolean = Bool(text.lowercased()) { return boolean }
                if key == "think", let text = value as? String, ["low", "medium", "high"].contains(text) { return text }
                throw PichiMeetingSummaryError.notConfigured
            }
        }
        if let value = parameters["reasoning_effort"] as? String {
            if value == "none" { return false }
            if ["low", "medium", "high"].contains(value) { return value }
            throw PichiMeetingSummaryError.notConfigured
        }
        return false
    }

    private static func ollamaContext(_ parameters: [String: Any]) throws -> Int {
        guard let options = parameters["options"] as? [String: Any] else { return self.ollamaContextTokens }
        guard let context = options["num_ctx"] as? Int, (8192...16384).contains(context) else {
            throw PichiMeetingSummaryError.notConfigured
        }
        return context
    }

    static func schema(ledger: Bool, sourceIndexes: [Int]? = nil, candidateIndexes: [Int]? = nil) -> [String: Any] {
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
            var index: [String: Any] = ["type": "integer", "minimum": 0]
            var updates: [String: Any] = ["type": "array"]
            if let candidateIndexes {
                let choices = Array(Set(candidateIndexes)).sorted()
                // An empty batch permits only empty updates; an empty enum is not
                // supported by every structured-output provider.
                if !choices.isEmpty { index["enum"] = choices }
                updates["maxItems"] = choices.count
            }
            updates["items"] = ["type": "object", "additionalProperties": false,
                                "required": ["index", "evidence"], "properties": ["index": index, "evidence": citations]]
            return definitions.merging(["type": "object", "additionalProperties": false, "required": ["updates"],
                                        "properties": ["updates": updates]]) { _, new in new }
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
                            "minItems": name == "summary" ? 1 : 0, "maxItems": name == "summary" ? 8 : 30]
        }
        return definitions.merging(["type": "object", "additionalProperties": false, "required": Array(fields.keys).sorted(), "properties": fields]) { _, new in new }
    }
}
