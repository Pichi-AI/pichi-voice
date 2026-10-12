import Foundation
import CoreFoundation

/// Protocol adaptation for the standard on-device Ollama connection. OpenAI's
/// compatibility API cannot set context size; native chat can bound each request.
/// This shares LLMClient's execution, retry, cancellation and response handling.
nonisolated enum OllamaChatAdapter {
    static let defaultContextTokens = 8192
    static let maximumContextTokens = 16384
    static let defaultOutputTokens = 2048
    static let maximumOutputTokens = 8192
    static let maximumTimeoutSeconds: TimeInterval = 120

    enum ThinkingValue: Decodable, Hashable, Sendable {
        case boolean(Bool), level(String)
        init(from decoder: Decoder) throws {
            let value = try decoder.singleValueContainer()
            if let boolean = try? value.decode(Bool.self) { self = .boolean(boolean) }
            else { self = .level(try value.decode(String.self)) }
        }
    }
    struct ThinkingMetadata: Decodable, Sendable {
        let values: [ThinkingValue]
        let `default`: ThinkingValue
        var isValid: Bool {
            !self.values.isEmpty && self.values.count <= 32 && Set(self.values).count == self.values.count
                && self.values.contains(self.default)
                && !self.values.contains(.level(""))
        }
        var hasNamedLevels: Bool { self.values.contains { if case .level = $0 { return true }; return false } }
    }

    /// Read-only capability checks do not load a runner. Older servers may ignore
    /// unknown fields, so require a version with explicit overflow rejection.
    static func preparedRequest(_ config: LLMClient.Config,
                                load: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> URLRequest {
        try await self.requireOverflowRejection(config, load: load)
        var thinking: ThinkingMetadata?
        if config.extraParameters["reasoning_effort"] != nil || config.extraParameters["reasoning"] != nil
            || config.extraParameters["think"] is String {
            let data = try await self.metadata(config, path: "/api/show", body: ["model": config.model], load: load)
            struct Show: Decodable { let thinking: ThinkingMetadata? }
            guard let show = try? JSONDecoder().decode(Show.self, from: data) else { throw LLMError.invalidResponse }
            thinking = show.thinking
            if let thinking, !thinking.isValid { throw LLMError.invalidResponse }
        }
        try Task.checkCancellation()
        return try self.request(config, thinking: thinking)
    }

    /// Shared admission only. Callers retain their inference policy and sessions.
    static func requireOverflowRejection(_ config: LLMClient.Config,
                                         load: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws {
        guard self.supports(config.baseURL) else { throw LLMError.invalidURL }
        let versionData = try await self.metadata(config, path: "/api/version", body: nil, load: load)
        struct Version: Decodable { let version: String }
        guard let version = try? JSONDecoder().decode(Version.self, from: versionData).version else { throw LLMError.invalidResponse }
        let parts = version.split(separator: ".").prefix(2).compactMap { Int($0) }
        guard parts.count == 2, parts[0] > 0 || (parts[0] == 0 && parts[1] >= 16) else {
            throw LLMError.invalidRequest(PichiLocalization.text("Update Ollama to version 0.16 or later for bounded local processing."))
        }
    }

    private static func metadata(_ config: LLMClient.Config, path: String, body: [String: String]?,
                                 load: @Sendable (URLRequest) async throws -> (Data, URLResponse)) async throws -> Data {
        guard var components = URLComponents(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw LLMError.invalidURL }
        components.path = path
        guard let url = components.url else { throw LLMError.invalidURL }
        var request = URLRequest(url: url)
        let timeout = config.timeoutSeconds ?? 5
        guard timeout.isFinite, timeout > 0 else { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model timeout.")) }
        request.timeoutInterval = min(timeout, 5)
        if let body {
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys])
        }
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        try Task.checkCancellation()
        let data: Data
        let response: URLResponse
        do { (data, response) = try await load(request) }
        catch {
            if Task.isCancelled { throw CancellationError() }
            if let error = error as? URLError { throw LLMError.networkError(error) }
            throw error
        }
        try Task.checkCancellation()
        guard let http = response as? HTTPURLResponse else { throw LLMError.invalidResponse }
        guard http.statusCode == 200 else { throw LLMError.httpError(http.statusCode, PichiLocalization.text("Local model metadata request failed.")) }
        guard data.count <= 1_048_576 else { throw LLMError.invalidResponse }
        return data
    }

    static func supports(_ baseURL: String) -> Bool {
        guard let url = URL(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme), url.port == 11434,
              ["localhost", "127.0.0.1", "::1", "[::1]"].contains(url.host?.lowercased() ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) == "v1"
        else { return false }
        return true
    }

    static func timeout(_ config: LLMClient.Config) throws -> TimeInterval {
        let value = config.timeoutSeconds ?? self.maximumTimeoutSeconds
        guard value.isFinite, value > 0 else { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model timeout.")) }
        return min(value, self.maximumTimeoutSeconds)
    }

    static func request(_ config: LLMClient.Config, thinking metadata: ThinkingMetadata? = nil) throws -> URLRequest {
        guard self.supports(config.baseURL),
              var components = URLComponents(string: config.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw LLMError.invalidURL }
        components.path = "/api/chat"
        guard let url = components.url else { throw LLMError.invalidURL }
        if config.extraParameters["num_ctx"] != nil {
            throw LLMError.invalidRequest(PichiLocalization.text("Set local context in options.num_ctx."))
        }
        var options: [String: Any] = [:]
        if let supplied = config.extraParameters["options"] {
            guard let values = supplied as? [String: Any] else { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model options.")) }
            options = values
        }
        let context = try self.positiveInteger(options["num_ctx"] ?? self.defaultContextTokens)
        guard (512...self.maximumContextTokens).contains(context) else {
            throw LLMError.invalidRequest(PichiLocalization.text("Local model context must be between 512 and 16384 tokens."))
        }
        let requestedOutput = try self.positiveInteger((config.maxTokens as Any?) ?? config.extraParameters["max_tokens"]
            ?? config.extraParameters["max_completion_tokens"] ?? options["num_predict"] ?? self.defaultOutputTokens)
        options["num_ctx"] = context
        // Existing command/rewrite callers may request a large cloud reasoning
        // budget. A local invocation stays inside its context and generation caps.
        options["num_predict"] = min(requestedOutput, self.maximumOutputTokens, context - 256)
        if let temperature = config.temperature { options["temperature"] = temperature }
        for key in ["temperature", "top_p", "top_k", "min_p", "seed", "stop", "repeat_penalty", "frequency_penalty", "presence_penalty"] {
            if let value = config.extraParameters[key] { options[key] = value }
        }
        if let stop = options["stop"] as? String { options["stop"] = [stop] }
        if let stop = options["stop"], !(stop is [String]) { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model stop sequences.")) }
        // The app pins its selected enhancement artifact for its lifetime. A
        // command or rewrite using that artifact must not shorten the lease.
        // Unselected artifacts retain the finite caller policy. Meeting aliases
        // still own their separate transport and cleanup.
        var keepAlive: Any = "60s"
        if let requested = config.extraParameters["keep_alive"] {
            let seconds = try self.positiveInteger(requested)
            guard seconds <= 3600 else { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model options.")) }
            keepAlive = seconds
        }
        if LocalAIModelResidencyPolicy.shared.isPinned(baseURL: config.baseURL, model: config.model) {
            keepAlive = -1
        }
        var body: [String: Any] = [
            "model": config.model, "messages": try self.messages(config.messages),
            "stream": config.streaming, "options": options, "keep_alive": keepAlive,
            "truncate": false, "shift": false,
        ]
        if let choice = config.extraParameters["tool_choice"], !["auto", "none"].contains(choice as? String ?? "") {
            throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model options."))
        }
        if !config.tools.isEmpty, config.extraParameters["tool_choice"] as? String != "none" { body["tools"] = config.tools }
        if let thinking = try self.thinking(config.extraParameters, metadata: metadata) { body["think"] = thinking }
        if let format = config.extraParameters["response_format"] as? [String: Any] {
            if let schema = (format["json_schema"] as? [String: Any])?["schema"] as? [String: Any] {
                body["format"] = schema
            } else if format["type"] as? String == "json_object" { body["format"] = "json" }
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = try self.timeout(config)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if !config.apiKey.isEmpty { request.setValue("Bearer \(config.apiKey)", forHTTPHeaderField: "Authorization") }
        do { request.httpBody = try JSONSerialization.data(withJSONObject: body, options: [.sortedKeys]) }
        catch { throw LLMError.encodingError }
        return request
    }

    /// Numeric runtime diagnostics only. Never include generated text or thinking.
    static func timingDiagnostics(_ payload: [String: Any]) -> String {
        let durations = ["load_duration", "prompt_eval_duration", "eval_duration", "total_duration"].compactMap { key -> String? in
            guard let number = payload[key] as? NSNumber,
                  CFGetTypeID(number) != CFBooleanGetTypeID(),
                  number.doubleValue.isFinite, number.doubleValue >= 0,
                  number.doubleValue <= Double(Int64.max) else { return nil }
            return "\(key)Ms=\(Int64(number.doubleValue / 1_000_000))"
        }
        let counts = ["prompt_eval_count", "eval_count"].compactMap { key -> String? in
            guard let value = try? self.positiveInteger(payload[key] ?? 0) else { return nil }
            return "\(key)=\(value)"
        }
        return (durations + counts).joined(separator: " ")
    }

    /// Native thinking is separate from visible content. Function arguments are
    /// objects on the wire and strings in the existing OpenAI message parser.
    static func message(_ payload: [String: Any], completed: Bool) throws -> [String: Any] {
        if let error = payload["error"] as? String, !error.isEmpty { throw LLMError.invalidRequest(error) }
        if payload["done_reason"] as? String == "length" {
            throw LLMError.invalidRequest(PichiLocalization.text("The local model reached its output token limit."))
        }
        if completed, payload["done"] as? Bool != true { throw LLMError.invalidResponse }
        guard var message = payload["message"] as? [String: Any] else { throw LLMError.invalidResponse }
        // Native thinking frames carry an empty content field. It is not the
        // content phase until visible text arrives; keep shared SSE semantics.
        if message["content"] as? String == "", let thinking = message["thinking"] as? String, !thinking.isEmpty {
            message.removeValue(forKey: "content")
        }
        if let calls = message["tool_calls"] as? [[String: Any]] {
            message["tool_calls"] = try calls.enumerated().map { index, call -> [String: Any] in
                var call = call
                guard var function = call["function"] as? [String: Any],
                      let arguments = function["arguments"] as? [String: Any]
                else { throw LLMError.invalidResponse }
                let data = try JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys])
                function["arguments"] = String(decoding: data, as: UTF8.self)
                call["function"] = function
                call["id"] = call["id"] ?? "call_\(UUID().uuidString)_\(index)"
                return call
            }
        }
        return message
    }

    private static func positiveInteger(_ value: Any) throws -> Int {
        if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() {
            throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model token budget."))
        }
        guard let value = value as? Int, value > 0 else {
            throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model token budget."))
        }
        return value
    }

    private static func thinking(_ parameters: [String: Any], metadata: ThinkingMetadata?) throws -> Any? {
        for key in ["think", "enable_thinking", "thinking"] {
            if let value = parameters[key] {
                if value is NSNull { return nil }
                if let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() { return number.boolValue }
                if let value = value as? String {
                    if let boolean = Bool(value.lowercased()) { return boolean }
                    if key == "think", !value.isEmpty {
                        if let metadata {
                            guard metadata.values.contains(.level(value)) else { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model thinking setting.")) }
                            return value
                        }
                        if ["low", "medium", "high", "max"].contains(value) { return value }
                    }
                }
                throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model thinking setting."))
            }
        }
        if let value = (parameters["reasoning"] as? [String: Any])?["effort"] ?? parameters["reasoning_effort"] {
            guard let value = value as? String else { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model thinking setting.")) }
            if value.isEmpty { return nil }
            if value == "none" { return false }
            let recognized = ["minimal", "low", "medium", "high", "xhigh", "ultra", "max"].contains(value)
            if let metadata {
                if recognized, metadata.values.contains(.boolean(true)), !metadata.hasNamedLevels { return true }
                guard metadata.values.contains(.level(value)) else { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model thinking setting.")) }
                return value
            }
            switch value {
            case "low", "medium", "high", "max": return value
            case "minimal": return "low"
            case "xhigh", "ultra": return "max"
            default: throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model thinking setting."))
            }
        }
        // Preserve the selected artifact's default, rather than infer capability
        // from a mutable model name or silently enable reasoning.
        return nil
    }

    private static func messages(_ messages: [[String: Any]]) throws -> [[String: Any]] {
        var toolNames: [String: String] = [:]
        return try messages.map { original in
            var message = original
            if let calls = original["tool_calls"] as? [[String: Any]] {
                message["tool_calls"] = try calls.map { originalCall in
                    var call = originalCall
                    guard var function = call["function"] as? [String: Any], let name = function["name"] as? String else {
                        throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model tool message."))
                    }
                    if let id = call["id"] as? String { toolNames[id] = name }
                    if let text = function["arguments"] as? String {
                        guard let data = text.data(using: .utf8),
                              let arguments = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                        else { throw LLMError.invalidRequest(PichiLocalization.text("Invalid local model tool arguments.")) }
                        function["arguments"] = arguments
                    }
                    call["function"] = function
                    return call
                }
            }
            if original["role"] as? String == "tool" {
                if let name = original["name"] as? String, !name.isEmpty { message["tool_name"] = name }
                else if let id = original["tool_call_id"] as? String, let name = toolNames[id] { message["tool_name"] = name }
            }
            return message
        }
    }
}
