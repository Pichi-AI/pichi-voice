@testable import FluidVoice_Debug
import Foundation
import XCTest

@MainActor
final class OllamaChatTransportTests: XCTestCase {
    func testStandardLoopbackEndpointsUseBoundedNativeChatRequests() throws {
        for baseURL in ["http://localhost:11434/v1", "http://127.0.0.1:11434/v1/", "http://[::1]:11434/v1"] {
            let context = OllamaTransportContext()
            defer { context.cleanup() }
            let request = try context.client.buildRequest(self.config(baseURL: baseURL, streaming: false))
            XCTAssertEqual(request.url?.path, "/api/chat")
            XCTAssertEqual(request.url?.port, 11434)
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-local-key")
            let body = try OllamaTransportFixture.body(request)
            XCTAssertEqual(body["model"] as? String, "synthetic-small:latest")
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertEqual(body["keep_alive"] as? String, "60s")
            XCTAssertEqual(body["truncate"] as? Bool, false)
            XCTAssertEqual(body["shift"] as? Bool, false)
            let options = try XCTUnwrap(body["options"] as? [String: Any])
            XCTAssertEqual(options["num_ctx"] as? Int, 8192)
            XCTAssertEqual(options["num_predict"] as? Int, 2048)
            XCTAssertNil(body["max_tokens"])
            XCTAssertNil(body["max_completion_tokens"])
            let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
            XCTAssertEqual(messages.first?["content"] as? String, "Сократи текст, сохрани имена и факты.")
        }
    }

    func testExplicitNativeOptionsAndCompletionLimitStayBounded() throws {
        let context = OllamaTransportContext()
        defer { context.cleanup() }
        var config = self.config(streaming: true, temperature: 0.2)
        config.maxTokens = 99999
        config.extraParameters = ["options": ["num_ctx": 16384, "seed": 1729, "top_p": 0.85], "think": true, "stop": "Конец"]
        let body = try OllamaTransportFixture.body(context.client.buildRequest(config))
        XCTAssertEqual(body["stream"] as? Bool, true)
        XCTAssertEqual(body["think"] as? Bool, true)
        let options = try XCTUnwrap(body["options"] as? [String: Any])
        XCTAssertEqual(options["num_ctx"] as? Int, 16384)
        XCTAssertEqual(options["num_predict"] as? Int, 8192)
        XCTAssertEqual(options["temperature"] as? Double, 0.2)
        XCTAssertEqual(options["seed"] as? Int, 1729)
        XCTAssertEqual(options["top_p"] as? Double, 0.85)
        XCTAssertEqual(options["stop"] as? [String], ["Конец"])

        config.extraParameters = ["options": ["num_ctx": 8192]]
        let lowerContext = try OllamaTransportFixture.body(context.client.buildRequest(config))
        let lowerOptions = try XCTUnwrap(lowerContext["options"] as? [String: Any])
        XCTAssertEqual(lowerOptions["num_predict"] as? Int, 7936, "Output must leave room inside the admitted context")
    }

    func testInvalidNativeBudgetsFailBeforeSendingARequest() throws {
        let context = OllamaTransportContext()
        defer { context.cleanup() }
        for invalidContext in [511, 65536] {
            var config = self.config()
            config.extraParameters = ["options": ["num_ctx": invalidContext]]
            XCTAssertThrowsError(try context.client.buildRequest(config)) { self.assertInvalidRequest($0) }
        }
        for invalidContext in [true, 8192.5] as [Any] {
            var config = self.config()
            config.extraParameters = ["options": ["num_ctx": invalidContext]]
            XCTAssertThrowsError(try context.client.buildRequest(config)) { self.assertInvalidRequest($0) }
        }
        for invalidOutput in [true, 1024.5] as [Any] {
            var config = self.config()
            config.extraParameters = ["options": ["num_predict": invalidOutput]]
            XCTAssertThrowsError(try context.client.buildRequest(config)) { self.assertInvalidRequest($0) }
        }
        for invalidOutput in [0, -1] {
            var config = self.config()
            config.maxTokens = invalidOutput
            XCTAssertThrowsError(try context.client.buildRequest(config)) { self.assertInvalidRequest($0) }
        }
        var topLevelContext = self.config()
        topLevelContext.extraParameters = ["num_ctx": 8192]
        XCTAssertThrowsError(try context.client.buildRequest(topLevelContext)) { self.assertInvalidRequest($0) }
        XCTAssertTrue(context.fixture.requests.isEmpty)
    }

    func testNativeToolConversationNormalizesArgumentsAndResponseName() throws {
        let context = OllamaTransportContext()
        defer { context.cleanup() }
        let config = LLMClient.Config(
            messages: [
                ["role": "user", "content": "Открой заметку Итоги."],
                ["role": "assistant", "content": "", "tool_calls": [
                    ["id": "call_synthetic", "type": "function", "function": ["name": "lookup_note", "arguments": #"{"title":"Итоги"}"#]],
                ]],
                ["role": "tool", "tool_call_id": "call_synthetic", "content": "Заметка найдена."],
            ],
            model: "synthetic-small:latest", baseURL: "http://localhost:11434/v1", apiKey: "", streaming: false,
            tools: [["type": "function", "function": ["name": "lookup_note", "parameters": ["type": "object", "properties": ["title": ["type": "string"]]]]]]
        )
        let body = try OllamaTransportFixture.body(context.client.buildRequest(config))
        let messages = try XCTUnwrap(body["messages"] as? [[String: Any]])
        let calls = try XCTUnwrap(messages[1]["tool_calls"] as? [[String: Any]])
        let function = try XCTUnwrap(calls.first?["function"] as? [String: Any])
        XCTAssertEqual(function["name"] as? String, "lookup_note")
        XCTAssertEqual((function["arguments"] as? [String: Any])?["title"] as? String, "Итоги")
        XCTAssertEqual(messages[2]["role"] as? String, "tool")
        XCTAssertEqual(messages[2]["tool_name"] as? String, "lookup_note")
        XCTAssertEqual(messages[2]["content"] as? String, "Заметка найдена.")
        XCTAssertEqual((body["tools"] as? [[String: Any]])?.count, 1)
    }

    func testNativeStructuredOutputKeepsTheCallerSchema() throws {
        let context = OllamaTransportContext()
        defer { context.cleanup() }
        let schema: [String: Any] = ["type": "object", "required": ["summary"], "properties": ["summary": ["type": "string"]]]
        var config = self.config()
        config.extraParameters = ["response_format": ["type": "json_schema", "json_schema": ["name": "synthetic_summary", "strict": true, "schema": schema]]]
        let body = try OllamaTransportFixture.body(context.client.buildRequest(config))
        let nativeSchema = try XCTUnwrap(body["format"] as? [String: Any])
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: nativeSchema, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: schema, options: .sortedKeys))
        XCTAssertNil(body["response_format"], "OpenAI envelope must not be sent to the native server")
    }

    func testNativeNonStreamingResponsePreservesRussianThinkingAndTools() async throws {
        let context = OllamaTransportContext(body: #"{"message":{"role":"assistant","thinking":"Проверяю имена и факты.","content":"Ёжик подготовит отчёт.","tool_calls":[{"function":{"name":"save_note","arguments":{"title":"Итоги","urgent":false}}}]},"done":true,"done_reason":"stop"}"#)
        defer { context.cleanup() }
        let result = try await context.client.call(self.config(streaming: false))
        XCTAssertEqual(result.content, "Ёжик подготовит отчёт.")
        XCTAssertEqual(result.thinking, "Проверяю имена и факты.")
        XCTAssertEqual(result.toolCalls.count, 1)
        XCTAssertEqual(result.toolCalls.first?.name, "save_note")
        XCTAssertEqual(result.toolCalls.first?.getString("title"), "Итоги")
        XCTAssertEqual(result.toolCalls.first?.arguments["urgent"] as? Bool, false)
        XCTAssertFalse(result.toolCalls.first?.id.isEmpty ?? true)
        let request = try XCTUnwrap(context.fixture.requests.first)
        XCTAssertEqual(request.url?.path, "/api/chat")
        XCTAssertEqual(request.timeoutInterval, 120)
        XCTAssertEqual(context.fixture.requests.count, 1)
        XCTAssertEqual(context.fixture.metadataRequests.map { $0.url?.path }, ["/api/version"])
        XCTAssertEqual(context.fixture.metadataRequests.first?.httpMethod, "GET")
        XCTAssertEqual(context.fixture.metadataRequests.first?.timeoutInterval, 5)
    }

    func testNativeInlineThinkingTagsDoNotLeakIntoFinalContent() async throws {
        let context = OllamaTransportContext(body: #"{"message":{"role":"assistant","content":"<think>Проверяю источник.</think>Итоги встречи на русском."},"done":true,"done_reason":"stop"}"#)
        defer { context.cleanup() }
        let result = try await context.client.call(self.config(streaming: false))
        XCTAssertEqual(result.thinking, "Проверяю источник.")
        XCTAssertEqual(result.content, "Итоги встречи на русском.")
        XCTAssertFalse(result.content.contains("<think>"))
    }

    func testNativeNDJSONStreamingUsesExistingCallbacksAndStripsThinking() async throws {
        let context = OllamaTransportContext(body: """
        {"message":{"role":"assistant","thinking":"Проверяю "},"done":false}
        {"message":{"role":"assistant","thinking":"источники.","content":"Ёжик "},"done":false}
        {"message":{"role":"assistant","content":"подготовит отчёт.","tool_calls":[{"function":{"name":"save_note","arguments":{"title":"Итоги"}}}]},"done":false}
        {"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}

        """, chunkSize: 7)
        defer { context.cleanup() }
        let callbacks = OllamaCallbackProbe()
        var config = self.config(streaming: true)
        config.onThinkingStart = { callbacks.append(.thinkingStart) }
        config.onThinkingChunk = { callbacks.append(.thinking($0)) }
        config.onThinkingEnd = { callbacks.append(.thinkingEnd) }
        config.onContentChunk = { callbacks.append(.content($0)) }
        config.onToolCallStart = { callbacks.append(.tool($0)) }
        let result = try await context.client.call(config)
        XCTAssertEqual(result.thinking, "Проверяю источники.")
        XCTAssertEqual(result.content, "Ёжик подготовит отчёт.")
        XCTAssertEqual(result.toolCalls.first?.name, "save_note")
        XCTAssertEqual(result.toolCalls.first?.getString("title"), "Итоги")
        XCTAssertEqual(callbacks.thinkingText, result.thinking)
        XCTAssertEqual(callbacks.contentText, result.content)
        XCTAssertEqual(callbacks.events.filter { $0 == .thinkingStart }.count, 1)
        XCTAssertEqual(callbacks.events.filter { $0 == .thinkingEnd }.count, 1)
        XCTAssertTrue(callbacks.events.contains(.tool("save_note")))
        XCTAssertFalse(callbacks.sawMainThread, "Streaming decode must not block the UI executor")
        let body = try OllamaTransportFixture.body(XCTUnwrap(context.fixture.requests.first))
        XCTAssertEqual(body["stream"] as? Bool, true)
    }

    func testNativeStreamingSplitThinkingTagsStayOutOfContentCallbacks() async throws {
        let context = OllamaTransportContext(body: """
        {"message":{"role":"assistant","content":"<thi"},"done":false}
        {"message":{"role":"assistant","content":"nk>Проверка источника."},"done":false}
        {"message":{"role":"assistant","content":"</think>Готово."},"done":false}
        {"message":{"role":"assistant","content":""},"done":true,"done_reason":"stop"}

        """, chunkSize: 5)
        defer { context.cleanup() }
        let callbacks = OllamaCallbackProbe()
        var config = self.config(streaming: true)
        config.onContentChunk = { callbacks.append(.content($0)) }
        config.onThinkingChunk = { callbacks.append(.thinking($0)) }
        let result = try await context.client.call(config)
        XCTAssertEqual(result.content, "Готово.")
        XCTAssertEqual(result.thinking, "Проверка источника.")
        XCTAssertEqual(callbacks.contentText, "Готово.")
        XCTAssertEqual(callbacks.thinkingText, "Проверка источника.")
    }

    func testNativeNonStreamingLengthLimitCannotReturnPartialSuccess() async throws {
        let context = OllamaTransportContext(body: #"{"message":{"role":"assistant","content":"Незавершённый ответ"},"done":true,"done_reason":"length"}"#)
        defer { context.cleanup() }
        var config = self.config(streaming: false)
        config.maxRetries = 3
        do {
            _ = try await context.client.call(config)
            XCTFail("A length-limited completion must fail rather than publish partial text")
        } catch { self.assertInvalidRequest(error) }
        XCTAssertEqual(context.fixture.requests.count, 1, "A truncated result must not start duplicate fallback generation")
    }

    func testNativeStreamingLengthLimitCannotReturnPartialSuccess() async throws {
        let context = OllamaTransportContext(body: """
        {"message":{"role":"assistant","content":"Незавершённый ответ"},"done":false}
        {"done":true,"done_reason":"length"}

        """)
        defer { context.cleanup() }
        var config = self.config(streaming: true)
        config.maxRetries = 3
        do {
            _ = try await context.client.call(config)
            XCTFail("Native streaming must reject length termination too")
        } catch { self.assertInvalidRequest(error) }
        XCTAssertEqual(context.fixture.requests.count, 1)
    }

    func testNativeMissingTerminalDoneFailsInBothModes() async throws {
        for streaming in [false, true] {
            let context = OllamaTransportContext(body: #"{"message":{"role":"assistant","content":"Черновик"},"done":false}"# + "\n")
            defer { context.cleanup() }
            do {
                _ = try await context.client.call(self.config(streaming: streaming))
                XCTFail("Connection EOF is not a completed native response")
            } catch {
                guard case LLMError.invalidResponse = error else {
                    XCTFail("Expected invalidResponse, got \(error)")
                    continue
                }
            }
            XCTAssertEqual(context.fixture.requests.count, 1)
        }
    }

    func testNativeHTTP200ErrorPayloadFailsInBothModes() async throws {
        for streaming in [false, true] {
            let context = OllamaTransportContext(body: #"{"error":"synthetic model was not found"}"# + "\n")
            defer { context.cleanup() }
            var config = self.config(streaming: streaming)
            config.maxRetries = 3
            do {
                _ = try await context.client.call(config)
                XCTFail("HTTP success must not hide a native server error")
            } catch { self.assertInvalidRequest(error) }
            XCTAssertEqual(context.fixture.requests.count, 1)
        }
    }

    func testNativeHTTPFailurePreservesStatusAndRespectsExplicitTimeout() async throws {
        let context = OllamaTransportContext(status: 503, body: #"{"error":"synthetic unavailable"}"#)
        defer { context.cleanup() }
        var config = self.config(streaming: false)
        config.timeoutSeconds = 15
        do {
            _ = try await context.client.call(config)
            XCTFail("HTTP failure must be returned")
        } catch {
            guard case let LLMError.httpError(code, _) = error else {
                return XCTFail("Expected httpError, got \(error)")
            }
            XCTAssertEqual(code, 503)
        }
        XCTAssertEqual(context.fixture.requests.first?.timeoutInterval, 15)
        XCTAssertEqual(context.fixture.requests.count, 1)
    }

    func testNativeCancellationStopsOwnedRequestWithoutFinalResponse() async throws {
        for streaming in [false, true] {
            let context = OllamaTransportContext(body: "", held: true)
            defer { context.cleanup() }
            let client = context.client
            let config = self.config(streaming: streaming)
            let pending = Task { try await client.call(config) }
            for _ in 0..<100 where context.fixture.requests.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
            XCTAssertEqual(context.fixture.requests.count, 1)
            pending.cancel()
            do {
                _ = try await pending.value
                XCTFail("A cancelled transport cannot publish a final response")
            } catch {
                let cancelledNetwork = if case let LLMError.networkError(underlying) = error {
                    (underlying as? URLError)?.code == .cancelled
                } else { false }
                XCTAssertTrue(error is CancellationError || cancelledNetwork, "Unexpected cancellation error: \(error)")
            }
            XCTAssertGreaterThanOrEqual(context.fixture.stops, 1, "The caller must cancel its owned URLSession task")
            XCTAssertGreaterThanOrEqual(context.fixture.stops(for: "/api/chat"), 1)
            XCTAssertEqual(context.fixture.requests.count, 1)
        }
    }

    func testNativeLongTimeoutCannotExtendTheAdmittedRequestBudget() async throws {
        let context = OllamaTransportContext(body: #"{"message":{"role":"assistant","content":"Готово."},"done":true,"done_reason":"stop"}"#)
        defer { context.cleanup() }
        var config = self.config()
        config.timeoutSeconds = 900
        _ = try await context.client.call(config)
        XCTAssertEqual(context.fixture.requests.first?.timeoutInterval, 120)
    }

    func testNativeReasoningCapabilitiesNormalizeLegacyAliasesAndSupportedLevels() async throws {
        let scenarios: [(String, String, String?, Bool?)] = [
            ("ultra", "{}", "max", nil),
            ("high", #"{"thinking":{"values":[true,false],"default":false}}"#, nil, true),
            ("max", #"{"thinking":{"values":["low","medium","high","max"],"default":"medium"}}"#, "max", nil),
        ]
        for (effort, metadata, expectedLevel, expectedBoolean) in scenarios {
            let context = OllamaTransportContext(body: #"{"message":{"role":"assistant","content":"Готово."},"done":true,"done_reason":"stop"}"#, showBody: metadata)
            defer { context.cleanup() }
            var config = self.config()
            config.extraParameters = ["reasoning_effort": effort]
            _ = try await context.client.call(config)
            XCTAssertEqual(context.fixture.requests.count, 1)
            XCTAssertEqual(context.fixture.metadataRequests.map { $0.url?.path }, ["/api/version", "/api/show"])
            let show = try XCTUnwrap(context.fixture.metadataRequests.last)
            XCTAssertEqual(show.httpMethod, "POST")
            XCTAssertEqual(show.value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-local-key")
            XCTAssertEqual(try OllamaTransportFixture.body(show)["model"] as? String, "synthetic-small:latest")
            let body = try OllamaTransportFixture.body(XCTUnwrap(context.fixture.requests.first))
            if let expectedLevel { XCTAssertEqual(body["think"] as? String, expectedLevel) }
            if let expectedBoolean { XCTAssertEqual(body["think"] as? Bool, expectedBoolean) }
        }
    }

    func testNativeUnsupportedNamedThinkingLevelFailsBeforeInference() async throws {
        let context = OllamaTransportContext(showBody: #"{"thinking":{"values":["low","max"],"default":"low"}}"#)
        defer { context.cleanup() }
        var config = self.config()
        config.extraParameters = ["reasoning_effort": "medium"]
        do {
            _ = try await context.client.call(config)
            XCTFail("Unsupported named reasoning level must not silently become a boolean")
        } catch { self.assertInvalidRequest(error) }
        XCTAssertTrue(context.fixture.requests.isEmpty)
        XCTAssertEqual(context.fixture.metadataRequests.map { $0.url?.path }, ["/api/version", "/api/show"])
    }

    func testNativeOldServerFailsBeforeInference() async throws {
        let context = OllamaTransportContext(version: "0.15.9")
        defer { context.cleanup() }
        do {
            _ = try await context.client.call(self.config())
            XCTFail("Older servers cannot guarantee explicit overflow rejection")
        } catch { self.assertInvalidRequest(error) }
        XCTAssertTrue(context.fixture.requests.isEmpty)
        XCTAssertEqual(context.fixture.metadataRequests.map { $0.url?.path }, ["/api/version"])
    }

    func testNativeMetadataCancellationNeverStartsInference() async throws {
        for path in ["/api/version", "/api/show"] {
            let context = OllamaTransportContext(heldMetadataPath: path)
            defer { context.cleanup() }
            var config = self.config()
            if path == "/api/show" { config.extraParameters = ["reasoning_effort": "high"] }
            let client = context.client
            let capturedConfig = config
            let pending = Task { try await client.call(capturedConfig) }
            for _ in 0..<100 where !context.fixture.metadataRequests.contains(where: { $0.url?.path == path }) {
                try await Task.sleep(for: .milliseconds(10))
            }
            XCTAssertTrue(context.fixture.metadataRequests.contains { $0.url?.path == path })
            pending.cancel()
            do {
                _ = try await pending.value
                XCTFail("Cancelled metadata cannot admit inference")
            } catch {
                let networkCancelled = if case let LLMError.networkError(underlying) = error {
                    (underlying as? URLError)?.code == .cancelled
                } else { false }
                XCTAssertTrue(error is CancellationError || (error as? URLError)?.code == .cancelled || networkCancelled)
            }
            XCTAssertGreaterThanOrEqual(context.fixture.stops, 1)
            XCTAssertGreaterThanOrEqual(context.fixture.stops(for: path), 1, "Cancellation must stop the held metadata request itself")
            XCTAssertTrue(context.fixture.requests.isEmpty)
            XCTAssertEqual(context.fixture.metadataRequests.count, path == "/api/version" ? 1 : 2)
        }
    }

    func testCloudRemoteAndCustomLocalEndpointsKeepTheirExistingProtocol() async throws {
        for baseURL in ["https://api.openai.com/v1", "https://synthetic-cloud.example/v1", "http://localhost:1234/v1", "http://127.0.0.1:11434/custom/v1", "http://192.0.2.1:11434/v1"] {
            let context = OllamaTransportContext(body: #"{"choices":[{"message":{"role":"assistant","content":"Русский ответ по OpenAI-совместимому протоколу."}}]}"#)
            defer { context.cleanup() }
            let result = try await context.client.call(self.config(baseURL: baseURL, streaming: false))
            XCTAssertEqual(result.content, "Русский ответ по OpenAI-совместимому протоколу.")
            let request = try XCTUnwrap(context.fixture.requests.first)
            XCTAssertTrue(request.url?.path.hasSuffix("/chat/completions") == true)
            let body = try OllamaTransportFixture.body(request)
            XCTAssertNil(body["keep_alive"])
            XCTAssertNil(body["options"])
            XCTAssertEqual(body["stream"] as? Bool, false)
            XCTAssertTrue(context.fixture.metadataRequests.isEmpty, "Other providers must not contact Ollama metadata endpoints")
        }
    }

    func testCredentialsQueryFragmentAndCustomPortDoNotOptIntoNativeProtocol() throws {
        for baseURL in ["http://synthetic-user@localhost:11434/v1", "http://localhost:11434/v1?route=custom", "http://localhost:11434/v1#custom", "http://localhost:11435/v1"] {
            let context = OllamaTransportContext()
            defer { context.cleanup() }
            let request = try context.client.buildRequest(self.config(baseURL: baseURL))
            XCTAssertNotEqual(request.url?.path, "/api/chat")
            let body = try OllamaTransportFixture.body(request)
            XCTAssertNil(body["options"])
            XCTAssertNil(body["keep_alive"])
        }
    }

    private func config(baseURL: String = "http://127.0.0.1:11434/v1", streaming: Bool = false, temperature: Double? = nil) -> LLMClient.Config {
        var config = LLMClient.Config(messages: [["role": "user", "content": "Сократи текст, сохрани имена и факты."]],
                                     model: "synthetic-small:latest", baseURL: baseURL,
                                     apiKey: "synthetic-local-key", streaming: streaming, temperature: temperature)
        config.maxRetries = 1
        return config
    }

    private func assertInvalidRequest(_ error: Error, file: StaticString = #filePath, line: UInt = #line) {
        guard case LLMError.invalidRequest = error else {
            return XCTFail("Expected invalidRequest, got \(error)", file: file, line: line)
        }
    }
}

@MainActor
private final class OllamaTransportContext {
    let token = UUID().uuidString
    let fixture: OllamaTransportFixture
    let session: URLSession
    let client: LLMClient

    init(status: Int = 200, body: String = "{}", chunkSize: Int? = nil, held: Bool = false,
         version: String = "0.34.2", showBody: String = #"{"thinking":{"values":[true,false],"default":false}}"#,
         heldMetadataPath: String? = nil) {
        self.fixture = OllamaTransportFixture(status: status, body: body, chunkSize: chunkSize, held: held,
                                             version: version, showBody: showBody, heldMetadataPath: heldMetadataPath)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [OllamaTransportURLProtocol.self]
        configuration.httpAdditionalHeaders = ["X-Ollama-Transport-Test": self.token]
        self.session = URLSession(configuration: configuration)
        self.client = LLMClient(session: self.session)
        OllamaTransportURLProtocol.register(self.fixture, token: self.token)
    }

    func cleanup() {
        self.session.invalidateAndCancel()
        OllamaTransportURLProtocol.remove(token: self.token)
    }
}

private nonisolated final class OllamaTransportFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let status: Int
    private let data: Data
    private let chunkSize: Int?
    private let held: Bool
    private let version: String
    private let showBody: Data
    private let heldMetadataPath: String?
    private var recordedRequests: [URLRequest] = []
    private var recordedMetadataRequests: [URLRequest] = []
    private var stopCount = 0
    private var stoppedPaths: [String: Int] = [:]

    var requests: [URLRequest] { self.lock.withLock { self.recordedRequests } }
    var metadataRequests: [URLRequest] { self.lock.withLock { self.recordedMetadataRequests } }
    var stops: Int { self.lock.withLock { self.stopCount } }
    func stops(for path: String) -> Int { self.lock.withLock { self.stoppedPaths[path] ?? 0 } }

    init(status: Int, body: String, chunkSize: Int?, held: Bool, version: String, showBody: String, heldMetadataPath: String?) {
        self.status = status
        self.data = Data(body.utf8)
        self.chunkSize = chunkSize
        self.held = held
        self.version = version
        self.showBody = Data(showBody.utf8)
        self.heldMetadataPath = heldMetadataPath
    }

    func receive(_ loading: OllamaTransportURLProtocol) {
        // URLSession may supply a one-shot body stream. Snapshot it before finishing
        // the synthetic load so later assertions never depend on stream lifetime.
        var recordedRequest = loading.request
        recordedRequest.httpBody = Self.bodyData(loading.request)
        let path = loading.request.url?.path
        let metadata = path == "/api/version" || path == "/api/show"
        self.lock.withLock {
            if metadata { self.recordedMetadataRequests.append(recordedRequest) }
            else { self.recordedRequests.append(recordedRequest) }
        }
        // Holding an inference fixture never holds the read-only admission probes.
        guard metadata ? path != self.heldMetadataPath : !self.held else { return }
        let status = metadata ? 200 : self.status
        let data = if path == "/api/version" { Data("{\"version\":\"\(self.version)\"}".utf8) }
                   else if path == "/api/show" { self.showBody } else { self.data }
        guard let url = loading.request.url,
              let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": metadata ? "application/json" : "application/x-ndjson"])
        else { loading.client?.urlProtocol(loading, didFailWithError: URLError(.badURL)); return }
        loading.client?.urlProtocol(loading, didReceive: response, cacheStoragePolicy: .notAllowed)
        let width = self.chunkSize ?? max(1, data.count)
        for offset in stride(from: 0, to: data.count, by: width) {
            loading.client?.urlProtocol(loading, didLoad: data.subdata(in: offset..<min(offset + width, data.count)))
        }
        loading.client?.urlProtocolDidFinishLoading(loading)
    }

    func stopped(path: String) {
        self.lock.withLock {
            self.stopCount += 1
            self.stoppedPaths[path, default: 0] += 1
        }
    }

    static func body(_ request: URLRequest) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: self.bodyData(request)) as? [String: Any])
    }

    private static func bodyData(_ request: URLRequest) -> Data {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                guard count > 0 else { break }
                data.append(contentsOf: buffer.prefix(count))
            }
        }
        return data
    }
}

private nonisolated final class OllamaTransportURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: OllamaTransportFixture] = [:]
    private let activeLock = NSLock()
    private var fixture: OllamaTransportFixture?

    static func register(_ fixture: OllamaTransportFixture, token: String) { self.lock.withLock { self.fixtures[token] = fixture } }
    static func remove(token: String) { _ = self.lock.withLock { self.fixtures.removeValue(forKey: token) } }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = self.request.value(forHTTPHeaderField: "X-Ollama-Transport-Test"),
              let fixture = Self.lock.withLock({ Self.fixtures[token] })
        else {
            XCTFail("Unexpected network request outside the synthetic fixture")
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        self.activeLock.withLock { self.fixture = fixture }
        fixture.receive(self)
    }

    override func stopLoading() { self.activeLock.withLock { self.fixture }?.stopped(path: self.request.url?.path ?? "") }
}

private nonisolated final class OllamaCallbackProbe: @unchecked Sendable {
    enum Event: Equatable {
        case thinkingStart, thinking(String), thinkingEnd, content(String), tool(String)
    }
    private let lock = NSLock()
    private var recorded: [Event] = []
    private var recordedMainThread = false
    var events: [Event] { self.lock.withLock { self.recorded } }
    var sawMainThread: Bool { self.lock.withLock { self.recordedMainThread } }
    var thinkingText: String { self.events.compactMap { if case let .thinking(text) = $0 { text } else { nil } }.joined() }
    var contentText: String { self.events.compactMap { if case let .content(text) = $0 { text } else { nil } }.joined() }

    func append(_ event: Event) {
        self.lock.withLock {
            self.recorded.append(event)
            self.recordedMainThread = self.recordedMainThread || Thread.isMainThread
        }
    }
}
