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
    static let maximumLedgerSchemaEnumValues = 1000
    static let redirectPolicy = PichiMeetingSummaryRedirectPolicy()
    static let session: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 180
        configuration.timeoutIntervalForResource = 3600
        return URLSession(configuration: configuration, delegate: redirectPolicy, delegateQueue: nil)
    }()
    static let client = LLMClient(session: session)

    static func usesNativeOllama(_ config: LLMClient.Config) -> Bool {
        OllamaChatAdapter.supports(config.baseURL)
    }

    static func complete(_ config: LLMClient.Config) async throws -> String {
        guard self.usesNativeOllama(config) else { return try await self.client.call(config).content }
        return try await self.completeOllama(config, inference: { try await self.session.data(for: $0) },
                                             management: { try await self.managementSession.data(for: $0) })
    }

    // The native adapter owns its existing inference and management sessions.
    // Injected requests exercise admission and artifact checks without a runner.
    static func completeOllama(_ config: LLMClient.Config, inference: ManagementRequest,
                              management: @escaping ManagementRequest) async throws -> String {
        guard self.usesNativeOllama(config) else { throw LLMError.invalidURL }
        if let artifact = config.extraParameters["summary_artifact_id"] as? String {
            try await self.verifyArtifact(artifact, model: config.model, baseURL: config.baseURL, apiKey: config.apiKey, load: management)
        }
        try await OllamaChatAdapter.requireOverflowRejection(config, load: management)
        let request = try self.ollamaRequest(config)
        let (data, response) = try await inference(request)
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard http.statusCode == 200 else { throw LLMError.httpError(http.statusCode, "Local summary request failed.") }
        if let artifact = config.extraParameters["summary_artifact_id"] as? String {
            try await self.verifyArtifact(artifact, model: config.model, baseURL: config.baseURL, apiKey: config.apiKey, load: management)
        }
        return try self.ollamaContent(data)
    }

    typealias ManagementRequest = @Sendable (URLRequest) async throws -> (Data, URLResponse)
    // Management operations have their own total deadline. In particular a copy's
    // acknowledgement and deletion must be joined even when inference is cancelled.
    private static let managementSession: URLSession = {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        return URLSession(configuration: configuration, delegate: redirectPolicy, delegateQueue: nil)
    }()

    static func artifactID(_ configuration: PichiMeetingSummaryConfiguration,
                           load: @escaping ManagementRequest = { try await managementSession.data(for: $0) }) async throws -> String? {
        let config = LLMClient.Config(messages: [], model: configuration.modelID,
                                      baseURL: configuration.baseURL, apiKey: configuration.apiKey)
        guard self.usesNativeOllama(config) else { return nil }
        let models = try await self.artifacts(baseURL: config.baseURL, apiKey: config.apiKey, load: load)
        guard let digest = models[self.canonicalModel(config.model)] else { throw LLMError.invalidResponse }
        return digest
    }

    static func snapshot(_ configuration: PichiMeetingSummaryConfiguration,
                         load: @escaping ManagementRequest = { try await managementSession.data(for: $0) }) async throws -> PichiMeetingSummaryModelSnapshot {
        guard let digest = try await self.artifactID(configuration, load: load) else {
            return .init(configuration: configuration, release: {})
        }
        try Task.checkCancellation()
        let alias = "summary-attempt-" + UUID().uuidString.lowercased() + ":snapshot"
        let existing = try await self.artifacts(baseURL: configuration.baseURL, apiKey: configuration.apiKey, load: load)
        guard existing[alias] == nil else { throw LLMError.invalidResponse }
        try Task.checkCancellation()
        let release = PichiMeetingSummarySnapshotRelease {
            let request = try self.managementRequest(configuration.baseURL, apiKey: configuration.apiKey,
                                                      path: "/api/delete", method: "DELETE", body: ["model": alias])
            let (_, response) = try await load(request)
            // Missing is already released. Never enumerate/delete other aliases and
            // never issue a global runner unload on this shared local server.
            guard let http = response as? HTTPURLResponse, [200, 404].contains(http.statusCode) else { throw LLMError.invalidResponse }
        }
        // Detached only for non-cancellable acknowledgement; the client task is
        // always joined before cleanup. A server may finish a timed-out copy after
        // DELETE returned 404; bounded client cleanup cannot guarantee its absence.
        let copy = Task.detached {
            let request = try self.managementRequest(configuration.baseURL, apiKey: configuration.apiKey,
                                                      path: "/api/copy", method: "POST",
                                                      body: ["source": configuration.modelID, "destination": alias])
            let (_, response) = try await load(request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw LLMError.invalidResponse }
        }
        do {
            try await copy.value
            try Task.checkCancellation()
            try await self.verifyArtifact(digest, model: alias, baseURL: configuration.baseURL, apiKey: configuration.apiKey, load: load)
            var frozen = configuration
            frozen.modelArtifactID = digest
            frozen.inferenceModelID = alias
            return .init(configuration: frozen, release: { try await release.run() })
        } catch {
            // A failed HTTP acknowledgement can still have committed the copy.
            // Cleanup is confined to the unpredictable name reserved by this attempt.
            try await release.run()
            throw error
        }
    }

    static func verifyArtifact(_ expected: String, model: String, baseURL: String, apiKey: String,
                               load: @escaping ManagementRequest = { try await managementSession.data(for: $0) }) async throws {
        let models = try await self.artifacts(baseURL: baseURL, apiKey: apiKey, load: load)
        guard models[self.canonicalModel(model)] == expected else { throw LLMError.invalidResponse }
    }

    private static func canonicalModel(_ model: String) -> String {
        model.split(separator: "/").last?.contains(":") == true ? model : model + ":latest"
    }

    private static func artifacts(baseURL: String, apiKey: String, load: ManagementRequest) async throws -> [String: String] {
        let request = try self.managementRequest(baseURL, apiKey: apiKey, path: "/api/tags", method: "GET")
        let (data, response) = try await load(request)
        guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw LLMError.invalidResponse }
        struct Listing: Decodable {
            struct Model: Decodable { let name: String; let digest: String }
            let models: [Model]
        }
        let listing = try JSONDecoder().decode(Listing.self, from: data)
        var result: [String: String] = [:]
        for model in listing.models {
            let digest = model.digest.hasPrefix("sha256:") ? String(model.digest.dropFirst(7)) : model.digest
            guard digest.count == 64, digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  result[self.canonicalModel(model.name)] == nil else { throw LLMError.invalidResponse }
            result[self.canonicalModel(model.name)] = digest
        }
        return result
    }

    private static func managementRequest(_ baseURL: String, apiKey: String, path: String, method: String,
                                          body: [String: String]? = nil) throws -> URLRequest {
        guard var components = URLComponents(string: baseURL) else { throw LLMError.invalidURL }
        components.path = path
        guard let url = components.url else { throw LLMError.invalidURL }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 15
        if !apiKey.isEmpty { request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization") }
        if let body {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        return request
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
            "truncate": false, "shift": false,
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

    static func schema(ledger: Bool, sourceIndexes: [Int]? = nil, candidateIndexes: [Int]? = nil, candidateSourceIndexes: [Int: [Int]]? = nil,
                       actionStates: Bool = false, recapOnly: Bool = false) -> [String: Any] {
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
            var updateProperties: [String: Any] = ["index": index, "evidence": citations]
            var required = ["index", "evidence"]
            if actionStates {
                updateProperties["status"] = ["anyOf": [["type": "null"], ["type": "string", "enum": PichiMeetingSummaryActionStatus.allCases.map(\.rawValue)]]]
                required.append("status")
            }
            let update: [String: Any] = ["type": "object", "additionalProperties": false,
                                         "required": required, "properties": updateProperties]
            updates["items"] = update
            if let candidateSourceIndexes {
                let sourceSet = Set(sourceIndexes ?? [])
                let candidates = Array(Set(candidateIndexes ?? candidateSourceIndexes.keys.map { $0 })).sorted()
                let branches: [[String: Any]] = candidates.compactMap { candidate in
                    let legal = Array(Set(candidateSourceIndexes[candidate] ?? []).intersection(sourceSet)).sorted()
                    guard !legal.isEmpty else { return nil }
                    var properties = updateProperties
                    properties["index"] = ["type": "integer", "enum": [candidate]]
                    var scopedEvidence = evidence
                    scopedEvidence["properties"] = ["sourceIndex": ["type": "integer", "enum": legal]]
                    scopedEvidence["required"] = ["sourceIndex"]
                    var scopedCitations = citations
                    scopedCitations["items"] = scopedEvidence
                    properties["evidence"] = scopedCitations
                    return ["type": "object", "additionalProperties": false, "required": required, "properties": properties]
                }
                updates["maxItems"] = branches.count
                // Empty anyOf/enum is not portable. Runtime skips batches without
                // legal candidates; the standalone empty schema allows no updates.
                if !branches.isEmpty { updates["items"] = ["anyOf": branches] }
            }
            return definitions.merging(["type": "object", "additionalProperties": false, "required": ["updates"],
                                        "properties": ["updates": updates]]) { _, new in new }
        }
        let properties: [String: Any] = ["text": ["type": "string", "minLength": 1, "maxLength": 2000], "evidence": citations]
        let item: [String: Any] = ["type": "object", "additionalProperties": false, "required": ["text", "evidence"], "properties": properties]
        var actionProperties = properties
        let nullableText: [[String: Any]] = [["type": "null"], ["type": "string", "minLength": 1, "maxLength": 200]]
        actionProperties["owner"] = ["anyOf": nullableText, "description": "Exact original name, or JSON null without quotes when unspecified."]
        actionProperties["deadline"] = ["anyOf": nullableText, "description": "Exact source speech substring including prepositions and grammatical case. Never normalize; use JSON null without quotes if unspecified."]
        actionProperties["title"] = ["type": "string", "minLength": 1, "maxLength": 160]
        actionProperties["status"] = ["type": "string", "enum": PichiMeetingSummaryActionStatus.allCases.map(\.rawValue)]
        actionProperties["urgency"] = ["type": "string", "enum": PichiMeetingSummaryActionUrgency.allCases.map(\.rawValue)]
        let action: [String: Any] = ["type": "object", "additionalProperties": false,
                                     "required": ["title", "text", "status", "urgency", "evidence", "owner", "deadline"], "properties": actionProperties]
        var fields: [String: Any] = [:]
        for name in ["summary", "decisions", "actions", "openQuestions", "changes", "answers"] {
            fields[name] = ["type": "array", "items": name == "actions" ? action : item,
                            "minItems": name == "summary" ? 1 : 0, "maxItems": name == "summary" ? 8 : (recapOnly ? 0 : 30)]
        }
        return definitions.merging(["type": "object", "additionalProperties": false, "required": Array(fields.keys).sorted(), "properties": fields]) { _, new in new }
    }
}

// One joined release even when both failure unwinding and cancellation converge.
private actor PichiMeetingSummarySnapshotRelease {
    private let operation: @Sendable () async throws -> Void
    private var task: Task<Void, Error>?

    init(operation: @escaping @Sendable () async throws -> Void) { self.operation = operation }

    func run() async throws {
        do {
            if let task { return try await task.value }
            let task = Task.detached { try await self.operation() }
            self.task = task
            try await task.value
        } catch { throw PichiMeetingSummaryCleanupError(underlying: error) }
    }
}
