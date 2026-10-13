@testable import FluidVoice_Debug
import XCTest

// Temperature support is learned per provider endpoint and model ID instead of only
// from a hand-kept name list, which broke on each new model release (Opus 4.7,
// Sonnet 5, Haiku 5.5). Sources: provider /models metadata, then HTTP 400 rejections
// at request time. Keyed by endpoint because two providers can serve the same model ID
// with different parameter support (e.g. generic local IDs like "llama3").

final class ModelTemperatureSupportTests: XCTestCase {
    private var suiteName: String!
    private var defaults: UserDefaults!

    override func setUp() {
        super.setUp()
        self.suiteName = "ModelTemperatureSupportTests.\(UUID().uuidString)"
        self.defaults = UserDefaults(suiteName: self.suiteName)
    }

    override func tearDown() {
        self.defaults.removePersistentDomain(forName: self.suiteName)
        super.tearDown()
    }

    // MARK: - Parsing /models responses

    func testEntries_openRouterSupportedParameters() throws {
        // Shape verified against openrouter.ai/api/v1/models on 2026-10-08.
        let json = try self.json(#"""
        {"data": [
          {"id": "anthropic/claude-haiku-5.5", "supported_parameters": ["max_tokens", "reasoning", "tools"]},
          {"id": "openai/gpt-4o", "supported_parameters": ["max_tokens", "temperature", "top_p"]},
          {"id": "some/model-without-metadata"}
        ]}
        """#)

        let entries = ModelTemperatureSupport.entries(fromModelsResponse: json)

        XCTAssertEqual(entries, ["anthropic/claude-haiku-5.5": false, "openai/gpt-4o": true])
    }

    func testEntries_anthropicBudgetThinkingCapability() throws {
        // Anthropic has no sampling capability; models that dropped `budget_tokens`
        // thinking (thinking.types.enabled) also dropped `temperature`.
        let json = try self.json(#"""
        {"data": [
          {"id": "claude-haiku-5-5", "capabilities": {"thinking": {"supported": true, "types": {"enabled": {"supported": false}, "adaptive": {"supported": true}}}}},
          {"id": "claude-sonnet-4-6", "capabilities": {"thinking": {"supported": true, "types": {"enabled": {"supported": true}, "adaptive": {"supported": true}}}}}
        ]}
        """#)

        let entries = ModelTemperatureSupport.entries(fromModelsResponse: json)

        XCTAssertEqual(entries, ["claude-haiku-5-5": false, "claude-sonnet-4-6": true])
    }

    func testEntries_plainOpenAIListingRecordsNothing() throws {
        let json = try self.json(#"{"data": [{"id": "gpt-4.1", "object": "model"}]}"#)

        XCTAssertTrue(ModelTemperatureSupport.entries(fromModelsResponse: json).isEmpty)
    }

    @MainActor
    func testFetchModels_recordsTemperatureSupportFromListing() async throws {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        URLProtocol.registerClass(ModelsListingURLProtocol.self)
        defer { URLProtocol.unregisterClass(ModelsListingURLProtocol.self) }

        let models = try await ModelRepository.shared.fetchModels(
            for: "openrouter",
            baseURL: "https://models-listing.test/api/v1",
            apiKey: nil,
            temperatureSupport: store
        )

        XCTAssertEqual(models, ["anthropic/claude-haiku-5.5", "openai/gpt-4o"])
        let baseURL = "https://models-listing.test/api/v1"
        XCTAssertEqual(store.isSupported("anthropic/claude-haiku-5.5", baseURL: baseURL), false)
        XCTAssertEqual(store.isSupported("openai/gpt-4o", baseURL: baseURL), true)
    }

    // MARK: - Store

    func testStore_normalizesOnlySchemeHostAndTrailingPathSlash() {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        store.record(["Vendor/New-Model": false], baseURL: "https://api.vendor.test/TeamA/v1/?Scope=AbC")
        XCTAssertEqual(store.isSupported("Vendor/New-Model", baseURL: " HTTPS://API.VENDOR.TEST/TeamA/v1?Scope=AbC "), false)
        XCTAssertNil(store.isSupported("vendor/new-model", baseURL: "https://api.vendor.test/TeamA/v1?Scope=AbC"))
        XCTAssertNil(store.isSupported("Vendor/New-Model", baseURL: "https://api.vendor.test/teama/v1?Scope=AbC"))
        XCTAssertNil(store.isSupported("Vendor/New-Model", baseURL: "https://api.vendor.test/TeamA/V1?Scope=AbC"))
        XCTAssertNil(store.isSupported("Vendor/New-Model", baseURL: "https://api.vendor.test/TeamA/v1?scope=AbC"))
        XCTAssertNil(store.isSupported("Vendor/New-Model", baseURL: "https://api.vendor.test/TeamA/v1?Scope=abc"))
        XCTAssertNil(store.isSupported("Vendor/New-Model", baseURL: "https://api.vendor.test/TeamA/v1?Scope=AbC/"))
        XCTAssertNil(store.isSupported("Vendor/New-Model", baseURL: "https://api.vendor.test/TeamA/v1%2F?Scope=AbC"))
        XCTAssertEqual(ModelTemperatureSupport(defaults: self.defaults).isSupported("Vendor/New-Model", baseURL: "https://api.vendor.test/TeamA/v1?Scope=AbC"), false)
    }

    func testStore_keepsProvidersWithSameModelIDSeparate() {
        let store = ModelTemperatureSupport(defaults: self.defaults)

        store.record(["llama3": false], baseURL: "https://strict-gateway.test/v1")

        XCTAssertEqual(store.isSupported("llama3", baseURL: "https://strict-gateway.test/v1"), false)
        XCTAssertNil(store.isSupported("llama3", baseURL: "http://localhost:11434/v1"))
    }

    // MARK: - SettingsStore resolution order

    @MainActor
    func testIsTemperatureUnsupported_usesLearnedValueForUnknownModel() {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let baseURL = "https://gateway.test/v1"
        XCTAssertFalse(SettingsStore.shared.isTemperatureUnsupported("vendor/future-model", baseURL: baseURL, support: store))

        store.record(["vendor/future-model": false], baseURL: baseURL)

        XCTAssertTrue(SettingsStore.shared.isTemperatureUnsupported("vendor/future-model", baseURL: baseURL, support: store))
        XCTAssertFalse(
            SettingsStore.shared.isTemperatureUnsupported("vendor/future-model", baseURL: "https://other.test/v1", support: store),
            "Another provider serving the same model ID keeps its own setting"
        )
    }

    @MainActor
    func testIsTemperatureUnsupported_learnedValueOverridesNameList() {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        store.record(["claude-sonnet-5": true], baseURL: "https://gateway.test/v1")

        XCTAssertFalse(SettingsStore.shared.isTemperatureUnsupported("claude-sonnet-5", baseURL: "https://gateway.test/v1", support: store))
    }

    @MainActor
    func testIsTemperatureUnsupported_reasoningModelsIgnoreLearnedValue() {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        store.record(["o3": true], baseURL: "https://gateway.test/v1")

        XCTAssertTrue(SettingsStore.shared.isTemperatureUnsupported("o3", baseURL: "https://gateway.test/v1", support: store))
    }

    // MARK: - Learning from HTTP 400 at request time

    func testCall_retriesWithoutTemperatureAndRemembersModel() async throws {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let client = self.makeClient(store: store)
        TemperatureRejectingURLProtocol.reset()

        let response = try await client.call(self.config(streaming: false))

        XCTAssertEqual(response.content, "Summary.")
        XCTAssertEqual(TemperatureRejectingURLProtocol.sentTemperatures, [true, false])
        XCTAssertEqual(store.isSupported("claude-haiku-5-5", baseURL: "https://temperature-reject.test/v1"), false)
    }

    func testCall_streamingRetriesWithoutTemperature() async throws {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let client = self.makeClient(store: store)
        TemperatureRejectingURLProtocol.reset()

        let response = try await client.call(self.config(streaming: true))

        XCTAssertEqual(response.content, "Summary.")
        XCTAssertEqual(TemperatureRejectingURLProtocol.sentTemperatures, [true, false])
        XCTAssertEqual(store.isSupported("claude-haiku-5-5", baseURL: "https://temperature-reject.test/v1"), false)
    }

    func testCall_unrelated400IsNotRetried() async {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let client = self.makeClient(store: store)
        TemperatureRejectingURLProtocol.reset()
        var config = self.config(streaming: false)
        config.extraParameters = ["fail_unrelated": true]

        do {
            _ = try await client.call(config)
            XCTFail("An unrelated 400 must surface to the caller")
        } catch let LLMError.httpError(status, _) {
            XCTAssertEqual(status, 400)
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        XCTAssertEqual(TemperatureRejectingURLProtocol.sentTemperatures, [true])
        XCTAssertNil(store.isSupported("claude-haiku-5-5", baseURL: "https://temperature-reject.test/v1"))
    }

    // MARK: - Registered cloud rejection classification before redaction

    func testCloudCall_retriesForRegisteredProvidersInBothModesWithoutChangingAuthorizationOrInput() async throws {
        for provider in CloudTextProvider.registered {
            for streaming in [false, true] {
                let store = ModelTemperatureSupport(defaults: self.defaults)
                let context = CloudTemperatureContext(provider: provider, scenario: .recover, store: store)
                defer { context.cleanup() }
                let config = context.config(streaming: streaming)
                let response = try await context.client.call(config)
                XCTAssertEqual(response.content, "Synthetic cloud summary.")
                XCTAssertEqual(context.fixture.temperatures, [true, false])
                XCTAssertEqual(context.fixture.authorizationHeaders, [context.expectedAuthorization, context.expectedAuthorization])
                XCTAssertEqual(context.fixture.projectHeaders, [config.providerOptions["project"], config.providerOptions["project"]])
                XCTAssertEqual(context.fixture.oauthRequests, context.requiresOAuth ? 1 : 0)
                XCTAssertEqual(store.isSupported(config.model, baseURL: config.baseURL), false)
                XCTAssertTrue(context.fixture.unexpectedRequests.isEmpty)
                let bodies = try context.fixture.bodies.map {
                    try XCTUnwrap(try JSONSerialization.jsonObject(with: $0) as? [String: Any])
                }
                var first = try XCTUnwrap(bodies.first)
                let second = try XCTUnwrap(bodies.last)
                XCTAssertEqual(first.removeValue(forKey: "temperature") as? Double, 0.2)
                XCTAssertEqual(try JSONSerialization.data(withJSONObject: first, options: .sortedKeys),
                               try JSONSerialization.data(withJSONObject: second, options: .sortedKeys))
            }
        }
    }

    func testCloudCall_unrelated400DoesNotLearnFromAnEchoedTemperatureRejection() async {
        for provider in CloudTextProvider.registered {
            for streaming in [false, true] {
                let store = ModelTemperatureSupport(defaults: self.defaults)
                let context = CloudTemperatureContext(provider: provider, scenario: .unrelated, store: store)
                defer { context.cleanup() }
                let config = context.config(streaming: streaming)
                await self.assertSafeCloud400(context, config: config)
                XCTAssertEqual(context.fixture.temperatures, [true])
                XCTAssertNil(store.isSupported(config.model, baseURL: config.baseURL))
                XCTAssertTrue(context.fixture.unexpectedRequests.isEmpty)
            }
        }
    }

    func testCloudCall_invalidTemperatureValueIsNotLearnedAsAnUnsupportedCapability() async {
        for provider in CloudTextProvider.registered {
            for streaming in [false, true] {
                let store = ModelTemperatureSupport(defaults: self.defaults)
                let context = CloudTemperatureContext(provider: provider, scenario: .invalidValue, store: store)
                defer { context.cleanup() }
                let config = context.config(streaming: streaming)
                await self.assertSafeCloud400(context, config: config)
                XCTAssertEqual(context.fixture.temperatures, [true])
                XCTAssertNil(store.isSupported(config.model, baseURL: config.baseURL))
                XCTAssertTrue(context.fixture.unexpectedRequests.isEmpty)
            }
        }
    }

    func testCloudCall_second400StopsAfterTwoAttemptsAndKeepsThePublicErrorRedacted() async {
        for provider in CloudTextProvider.registered {
            for streaming in [false, true] {
                let store = ModelTemperatureSupport(defaults: self.defaults)
                let context = CloudTemperatureContext(provider: provider, scenario: .rejectBoth, store: store)
                defer { context.cleanup() }
                let config = context.config(streaming: streaming)
                await self.assertSafeCloud400(context, config: config)
                XCTAssertEqual(context.fixture.temperatures, [true, false])
                XCTAssertEqual(context.fixture.oauthRequests, context.requiresOAuth ? 1 : 0)
                XCTAssertEqual(store.isSupported(config.model, baseURL: config.baseURL), false)
                XCTAssertTrue(context.fixture.unexpectedRequests.isEmpty)
            }
        }
    }

    func testCloudCall_oversizedErrorIsRedactedWithoutLearningFromItsCompleteJSONPrefix() async {
        for provider in CloudTextProvider.registered {
            for streaming in [false, true] {
                let store = ModelTemperatureSupport(defaults: self.defaults)
                let context = CloudTemperatureContext(provider: provider, scenario: .oversized, store: store)
                defer { context.cleanup() }
                let config = context.config(streaming: streaming)
                await self.assertSafeCloud400(context, config: config)
                XCTAssertEqual(context.fixture.temperatures, [true])
                XCTAssertNil(store.isSupported(config.model, baseURL: config.baseURL))
                XCTAssertTrue(context.fixture.unexpectedRequests.isEmpty)
            }
        }
    }

    func testCloudCall_cancellationDuringHeldErrorDoesNotRetryOrLearn() async {
        for provider in CloudTextProvider.registered {
            for streaming in [false, true] {
                let started = expectation(description: "Registered error body is held")
                let stopped = expectation(description: "Registered held request stopped")
                let store = ModelTemperatureSupport(defaults: self.defaults)
                let context = CloudTemperatureContext(provider: provider, scenario: .held, store: store,
                                                      started: started, stopped: stopped)
                defer { context.cleanup() }
                let config = context.config(streaming: streaming)
                let client = context.client
                let pending = Task { try await client.call(config) }
                await fulfillment(of: [started], timeout: 2)
                pending.cancel()
                do {
                    _ = try await pending.value
                    XCTFail("Cancelled cloud inference cannot return a response")
                } catch is CancellationError {
                } catch let LLMError.networkError(error) {
                    XCTAssertEqual((error as? URLError)?.code, .cancelled)
                } catch {
                    XCTFail("Unexpected cancellation error: \(error)")
                }
                await fulfillment(of: [stopped], timeout: 2)
                XCTAssertEqual(context.fixture.temperatures, [true])
                XCTAssertNil(store.isSupported(config.model, baseURL: config.baseURL))
                XCTAssertTrue(context.fixture.unexpectedRequests.isEmpty)
            }
        }
    }

    private func assertSafeCloud400(_ context: CloudTemperatureContext, config: LLMClient.Config) async {
        do {
            _ = try await context.client.call(config)
            XCTFail("Cloud rejection must remain an HTTP error")
        } catch let LLMError.httpError(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertEqual(body, PichiLocalization.text("Cloud provider request failed."))
            XCTAssertFalse(body.contains(CloudTemperatureFixture.secretMarker))
            XCTAssertFalse(body.contains(config.apiKey))
        } catch {
            XCTFail("Internal rejection leaked instead of LLMError.httpError: \(error)")
        }
    }

    // MARK: - Native local retry resource ownership

    func testNativeCall_temperatureRetryJoinsPreviousSessionsAndKeepsTheFrozenRequest() async throws {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let context = NativeTemperatureContext(store: store)
        defer { context.cleanup() }
        let response = try await context.client.call(self.nativeConfig())

        XCTAssertEqual(response.content, "Synthetic summary.")
        XCTAssertEqual(context.fixture.temperatures, [true, false])
        XCTAssertEqual(context.fixture.versionRequests, 2)
        XCTAssertEqual(context.fixture.priorInvalidations, [[], [true], [true, true], [true, true, true]],
                       "Every owned preparation/inference session must join before the next is created")
        XCTAssertEqual(context.fixture.lifetimes.count, 4)
        XCTAssertTrue(context.fixture.lifetimes.allSatisfy(\.hasInvalidated), "Returning includes all owned session invalidations")
        XCTAssertEqual(store.isSupported("synthetic-temperature:latest", baseURL: "http://127.0.0.1:11434/v1"), false)
        XCTAssertEqual(context.fixture.unexpectedRequests, [])

        let bodies = try context.fixture.chatRequests.map {
            try XCTUnwrap(try JSONSerialization.jsonObject(with: $0) as? [String: Any])
        }
        XCTAssertEqual(bodies.count, 2)
        var first = try XCTUnwrap(bodies.first)
        let second = try XCTUnwrap(bodies.last)
        var options = try XCTUnwrap(first["options"] as? [String: Any])
        XCTAssertEqual(options.removeValue(forKey: "temperature") as? Double, 0.2)
        first["options"] = options
        XCTAssertEqual(try JSONSerialization.data(withJSONObject: first, options: .sortedKeys),
                       try JSONSerialization.data(withJSONObject: second, options: .sortedKeys),
                       "Retry changes only temperature, keeping model, messages, context and output budgets")
    }

    func testNativeCall_secondTemperature400StopsAfterTwoAttemptsAndJoinsEverySession() async {
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let context = NativeTemperatureContext(store: store, rejectEveryChat: true)
        defer { context.cleanup() }
        do {
            _ = try await context.client.call(self.nativeConfig())
            XCTFail("A second temperature rejection must surface")
        } catch let LLMError.httpError(status, body) {
            XCTAssertEqual(status, 400)
            XCTAssertTrue(body.contains("temperature"))
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(context.fixture.temperatures, [true, false])
        XCTAssertEqual(context.fixture.versionRequests, 2)
        XCTAssertEqual(context.fixture.lifetimes.count, 4)
        XCTAssertEqual(context.fixture.priorInvalidations, [[], [true], [true, true], [true, true, true]])
        XCTAssertTrue(context.fixture.lifetimes.allSatisfy(\.hasInvalidated))
        XCTAssertEqual(context.fixture.unexpectedRequests, [])
    }

    func testNativeCall_cancellationJoinsTheHeldAttemptWithoutStartingARetry() async {
        let started = expectation(description: "Synthetic native chat is held")
        let stopped = expectation(description: "Synthetic held chat was stopped")
        let store = ModelTemperatureSupport(defaults: self.defaults)
        let context = NativeTemperatureContext(store: store, holdChat: true, chatStarted: started, chatStopped: stopped)
        defer { context.cleanup() }
        let client = context.client
        let config = self.nativeConfig()
        let pending = Task { try await client.call(config) }
        await fulfillment(of: [started], timeout: 2)
        pending.cancel()
        do {
            _ = try await pending.value
            XCTFail("Cancelled native inference cannot succeed")
        } catch is CancellationError {
        } catch let LLMError.networkError(error) {
            XCTAssertEqual((error as? URLError)?.code, .cancelled)
        } catch {
            XCTFail("Unexpected cancellation error: \(error)")
        }
        await fulfillment(of: [stopped], timeout: 2)
        XCTAssertEqual(context.fixture.temperatures, [true])
        XCTAssertEqual(context.fixture.versionRequests, 1)
        XCTAssertEqual(context.fixture.lifetimes.count, 2)
        XCTAssertEqual(context.fixture.priorInvalidations, [[], [true]])
        XCTAssertTrue(context.fixture.lifetimes.allSatisfy(\.hasInvalidated))
        XCTAssertGreaterThanOrEqual(context.fixture.chatStops, 1)
        XCTAssertNil(store.isSupported("synthetic-temperature:latest", baseURL: config.baseURL),
                     "Cancellation is not evidence that the model rejects temperature")
        XCTAssertEqual(context.fixture.unexpectedRequests, [])
    }

    private func nativeConfig() -> LLMClient.Config {
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Synthetic request only."]],
            model: "synthetic-temperature:latest", baseURL: "http://127.0.0.1:11434/v1", apiKey: "",
            streaming: false, temperature: 0.2, maxTokens: 128,
            extraParameters: ["options": ["num_ctx": 1024], "keep_alive": 60]
        )
        config.maxRetries = 3
        config.retryDelayMs = 0
        config.timeoutSeconds = 5
        return config
    }

    // MARK: - Helpers

    private func json(_ text: String) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any])
    }

    private func makeClient(store: ModelTemperatureSupport) -> LLMClient {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [TemperatureRejectingURLProtocol.self]
        return LLMClient(session: URLSession(configuration: configuration), temperatureSupport: store)
    }

    private func config(streaming: Bool) -> LLMClient.Config {
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Summarize"]],
            model: "claude-haiku-5-5",
            baseURL: "https://temperature-reject.test/v1",
            apiKey: "test",
            streaming: streaming,
            temperature: 0.2
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5
        return config
    }
}

/// Rejects any request body that carries `temperature` the way Anthropic does,
/// and answers normally otherwise.
private final class TemperatureRejectingURLProtocol: URLProtocol {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var recorded: [Bool] = []

    static var sentTemperatures: [Bool] {
        self.lock.withLock { self.recorded }
    }

    static func reset() {
        self.lock.withLock { self.recorded = [] }
    }

    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "temperature-reject.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let body = Self.bodyJSON(of: request)
        let hasTemperature = body["temperature"] != nil
        Self.lock.withLock { Self.recorded.append(hasTemperature) }

        let streaming = body["stream"] as? Bool ?? false
        let failUnrelated = body["fail_unrelated"] as? Bool ?? false
        let status: Int
        let payload: String
        let contentType: String
        if failUnrelated {
            status = 400
            payload = #"{"error":{"message":"max_tokens is too large"}}"#
            contentType = "application/json"
        } else if hasTemperature {
            status = 400
            payload = #"{"error":{"code":"invalid_request_error","message":"`temperature` is deprecated for this model."}}"#
            contentType = "application/json"
        } else if streaming {
            status = 200
            payload = "data: {\"choices\":[{\"index\":0,\"delta\":{\"content\":\"Summary.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
            contentType = "text/event-stream"
        } else {
            status = 200
            payload = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Summary."},"finish_reason":"stop"}]}"#
            contentType = "application/json"
        }

        guard let url = request.url,
              let response = HTTPURLResponse(
                  url: url,
                  statusCode: status,
                  httpVersion: "HTTP/1.1",
                  headerFields: ["Content-Type": contentType]
              )
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}

    fileprivate static func bodyJSON(of request: URLRequest) -> [String: Any] {
        var data = request.httpBody ?? Data()
        if data.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            defer { stream.close() }
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                data.append(buffer, count: count)
            }
        }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }
}

/// Serves a fixed OpenRouter-style `/models` listing.
private final class ModelsListingURLProtocol: URLProtocol {
    override static func canInit(with request: URLRequest) -> Bool {
        request.url?.host == "models-listing.test"
    }

    override static func canonicalRequest(for request: URLRequest) -> URLRequest {
        request
    }

    override func startLoading() {
        let payload = #"""
        {"data": [
          {"id": "openai/gpt-4o", "supported_parameters": ["temperature"]},
          {"id": "anthropic/claude-haiku-5.5", "supported_parameters": ["tools"]}
        ]}
        """#
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)
        else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(payload.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// One fixture per injected session. Unknown requests are intercepted and rejected,
/// so a missing header or an unexpected path can never reach a real local server.
private final class NativeTemperatureContext {
    let fixture: NativeTemperatureFixture
    let session: URLSession
    let client: LLMClient
    private let token = UUID().uuidString

    init(store: ModelTemperatureSupport, rejectEveryChat: Bool = false, holdChat: Bool = false,
         chatStarted: XCTestExpectation? = nil, chatStopped: XCTestExpectation? = nil) {
        let fixture = NativeTemperatureFixture(rejectEveryChat: rejectEveryChat, holdChat: holdChat,
                                              chatStarted: chatStarted, chatStopped: chatStopped)
        self.fixture = fixture
        NativeTemperatureURLProtocol.register(fixture, token: self.token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [NativeTemperatureURLProtocol.self]
        configuration.httpAdditionalHeaders = [NativeTemperatureURLProtocol.tokenHeader: self.token]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        self.session = session
        self.client = LLMClient(session: session, temperatureSupport: store,
                               ownedSessionDidCreate: { fixture.observe($0) })
    }

    func cleanup() {
        self.session.invalidateAndCancel()
        NativeTemperatureURLProtocol.unregister(token: self.token)
    }
}

private final class NativeTemperatureFixture: @unchecked Sendable {
    private let lock = NSLock()
    private var recordedLifetimes: [LLMClientSessionLifetime] = []
    private var recordedInvalidations: [[Bool]] = []
    private var recordedBodies: [Data] = []
    private var recordedTemperatures: [Bool] = []
    private var versions = 0
    private var stops = 0
    private var unexpected: [String] = []
    let rejectEveryChat: Bool
    let holdChat: Bool
    let chatStarted: XCTestExpectation?
    let chatStopped: XCTestExpectation?

    init(rejectEveryChat: Bool, holdChat: Bool, chatStarted: XCTestExpectation?, chatStopped: XCTestExpectation?) {
        self.rejectEveryChat = rejectEveryChat
        self.holdChat = holdChat
        self.chatStarted = chatStarted
        self.chatStopped = chatStopped
    }

    var lifetimes: [LLMClientSessionLifetime] { self.lock.withLock { self.recordedLifetimes } }
    var priorInvalidations: [[Bool]] { self.lock.withLock { self.recordedInvalidations } }
    var chatRequests: [Data] { self.lock.withLock { self.recordedBodies } }
    var temperatures: [Bool] { self.lock.withLock { self.recordedTemperatures } }
    var versionRequests: Int { self.lock.withLock { self.versions } }
    var chatStops: Int { self.lock.withLock { self.stops } }
    var unexpectedRequests: [String] { self.lock.withLock { self.unexpected } }

    func observe(_ lifetime: LLMClientSessionLifetime) {
        self.lock.withLock {
            self.recordedInvalidations.append(self.recordedLifetimes.map(\.hasInvalidated))
            self.recordedLifetimes.append(lifetime)
        }
    }

    func recordVersion() { self.lock.withLock { self.versions += 1 } }
    func recordUnexpected(_ path: String) { self.lock.withLock { self.unexpected.append(path) } }
    func recordChat(_ request: URLRequest) -> Bool {
        let body = TemperatureRejectingURLProtocol.bodyJSON(of: request)
        let temperature = (body["options"] as? [String: Any])?["temperature"] != nil
        self.lock.withLock {
            self.recordedTemperatures.append(temperature)
            self.recordedBodies.append((try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)) ?? Data())
        }
        self.chatStarted?.fulfill()
        return temperature
    }

    func stoppedChat() {
        let first = self.lock.withLock {
            self.stops += 1
            return self.stops == 1
        }
        if first { self.chatStopped?.fulfill() }
    }
}

private final class NativeTemperatureURLProtocol: URLProtocol {
    static let tokenHeader = "X-Native-Temperature-Fixture"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: NativeTemperatureFixture] = [:]
    private var activeFixture: NativeTemperatureFixture?
    private var activeChat = false

    static func register(_ fixture: NativeTemperatureFixture, token: String) {
        self.lock.withLock { self.fixtures[token] = fixture }
    }
    static func unregister(token: String) {
        self.lock.withLock { _ = self.fixtures.removeValue(forKey: token) }
    }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = self.request.value(forHTTPHeaderField: Self.tokenHeader),
              let fixture = Self.lock.withLock({ Self.fixtures[token] }),
              let url = self.request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        self.activeFixture = fixture
        guard url.scheme == "http", url.host == "127.0.0.1", url.port == 11434 else {
            fixture.recordUnexpected(url.absoluteString)
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let status: Int
        let payload: String
        switch url.path {
        case "/api/version":
            fixture.recordVersion()
            status = 200
            payload = #"{"version":"0.16.1"}"#
        case "/api/chat":
            self.activeChat = true
            let hasTemperature = fixture.recordChat(self.request)
            if fixture.holdChat { return }
            status = hasTemperature || fixture.rejectEveryChat ? 400 : 200
            payload = status == 400
                ? #"{"error":"temperature is unsupported for this synthetic model"}"#
                : #"{"message":{"role":"assistant","content":"Synthetic summary."},"done":true,"done_reason":"stop"}"#
        default:
            fixture.recordUnexpected(url.path)
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": "application/json"]) else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(payload.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {
        if self.activeChat { self.activeFixture?.stoppedChat() }
    }
}

private final class CloudTemperatureContext {
    let fixture: CloudTemperatureFixture
    let session: URLSession
    let client: LLMClient
    let provider: CloudTextProvider
    private let token = UUID().uuidString
    var requiresOAuth: Bool { if case .oauth = self.provider.authorization { return true }; return false }
    var expectedAuthorization: String {
        if case let .apiKey(scheme) = self.provider.authorization { return "\(scheme) synthetic-key-A16B" }
        return "Bearer synthetic-token-CC19"
    }

    init(provider: CloudTextProvider, scenario: CloudTemperatureFixture.Scenario, store: ModelTemperatureSupport,
         started: XCTestExpectation? = nil, stopped: XCTestExpectation? = nil) {
        self.provider = provider
        let fixture = CloudTemperatureFixture(provider: provider, scenario: scenario, started: started, stopped: stopped)
        self.fixture = fixture
        CloudTemperatureURLProtocol.register(fixture, token: self.token)
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [CloudTemperatureURLProtocol.self]
        configuration.httpAdditionalHeaders = [CloudTemperatureURLProtocol.tokenHeader: self.token]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        let session = URLSession(configuration: configuration)
        self.session = session
        self.client = LLMClient(session: session, temperatureSupport: store)
    }

    func config(streaming: Bool) -> LLMClient.Config {
        let model = self.provider.projectHeader == nil ? "synthetic-model" : "gpt://synthetic-folder/synthetic-model"
        var config = LLMClient.Config(messages: [["role": "user", "content": "Synthetic prompt only."]],
                                      model: model, baseURL: self.provider.baseURL, apiKey: "synthetic-key-A16B",
                                      streaming: streaming, temperature: 0.2, maxTokens: 128)
        config.providerOptions = Dictionary(uniqueKeysWithValues: self.provider.fields.map {
            ($0.id, $0.defaultValue.isEmpty ? "synthetic-folder" : $0.defaultValue)
        })
        config.maxRetries = 3
        config.retryDelayMs = 0
        config.timeoutSeconds = 5
        return config
    }

    func cleanup() {
        self.session.invalidateAndCancel()
        CloudTemperatureURLProtocol.unregister(token: self.token)
    }
}

private final class CloudTemperatureFixture: @unchecked Sendable {
    enum Scenario { case recover, unrelated, invalidValue, rejectBoth, oversized, held }
    static let secretMarker = "SyntheticSecretEchoMustStayPrivate771C"
    let provider: CloudTextProvider
    let scenario: Scenario
    let started: XCTestExpectation?
    let stopped: XCTestExpectation?
    private let lock = NSLock()
    private var recordedTemperatures: [Bool] = []
    private var recordedBodies: [Data] = []
    private var recordedAuthorizations: [String?] = []
    private var recordedProjects: [String?] = []
    private var exchanges = 0
    private var stoppedCount = 0
    private var unexpected: [String] = []

    init(provider: CloudTextProvider, scenario: Scenario, started: XCTestExpectation?, stopped: XCTestExpectation?) {
        self.provider = provider
        self.scenario = scenario
        self.started = started
        self.stopped = stopped
    }
    var temperatures: [Bool] { self.lock.withLock { self.recordedTemperatures } }
    var bodies: [Data] { self.lock.withLock { self.recordedBodies } }
    var authorizationHeaders: [String?] { self.lock.withLock { self.recordedAuthorizations } }
    var projectHeaders: [String?] { self.lock.withLock { self.recordedProjects } }
    var oauthRequests: Int { self.lock.withLock { self.exchanges } }
    var unexpectedRequests: [String] { self.lock.withLock { self.unexpected } }
    func recordUnexpected(_ message: String) { self.lock.withLock { self.unexpected.append(message) } }
    func recordOAuth() { self.lock.withLock { self.exchanges += 1 } }
    func recordChat(_ request: URLRequest, body: [String: Any]) -> Bool {
        let temperature = body["temperature"] != nil
        self.lock.withLock {
            self.recordedTemperatures.append(temperature)
            self.recordedBodies.append((try? JSONSerialization.data(withJSONObject: body, options: .sortedKeys)) ?? Data())
            self.recordedAuthorizations.append(request.value(forHTTPHeaderField: "Authorization"))
            self.recordedProjects.append(request.value(forHTTPHeaderField: "OpenAI-Project"))
        }
        return temperature
    }
    func stoppedChat() {
        let first = self.lock.withLock { self.stoppedCount += 1; return self.stoppedCount == 1 }
        if first { self.stopped?.fulfill() }
    }
}

/// Fully intercepted session fixture, including the descriptor's OAuth exchange.
/// A missing token or unexpected request fails locally instead of reaching a server.
private final class CloudTemperatureURLProtocol: URLProtocol {
    static let tokenHeader = "X-Cloud-Temperature-Fixture"
    private static let lock = NSLock()
    private nonisolated(unsafe) static var fixtures: [String: CloudTemperatureFixture] = [:]
    private var fixture: CloudTemperatureFixture?
    private var activeChat = false
    static func register(_ fixture: CloudTemperatureFixture, token: String) { self.lock.withLock { self.fixtures[token] = fixture } }
    static func unregister(token: String) { self.lock.withLock { _ = self.fixtures.removeValue(forKey: token) } }
    override static func canInit(with request: URLRequest) -> Bool { true }
    override static func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        guard let token = self.request.value(forHTTPHeaderField: Self.tokenHeader),
              let fixture = Self.lock.withLock({ Self.fixtures[token] }), let url = self.request.url else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
        }
        self.fixture = fixture
        let status: Int
        var data: Data
        let contentType: String
        if case let .oauth(tokenURL) = fixture.provider.authorization, url == tokenURL {
            fixture.recordOAuth()
            status = 200
            data = try! JSONSerialization.data(withJSONObject: ["access_token": "synthetic-token-CC19", "expires_at": Date().addingTimeInterval(1800).timeIntervalSince1970 * 1000])
            contentType = "application/json"
        } else {
            guard let base = URL(string: fixture.provider.baseURL), url.host == base.host, url.path == "/v1/chat/completions" else {
                fixture.recordUnexpected("Unexpected request route")
                self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL)); return
            }
            self.activeChat = true
            let body = TemperatureRejectingURLProtocol.bodyJSON(of: self.request)
            let hasTemperature = fixture.recordChat(self.request, body: body)
            let rejected = hasTemperature || fixture.scenario == .rejectBoth
            status = rejected ? 400 : 200
            if status == 400 {
                let message = "temperature is unsupported. " + CloudTemperatureFixture.secretMarker + " synthetic-key-A16B"
                let error: [String: Any]
                if fixture.scenario == .unrelated {
                    error = ["error": ["param": "max_tokens", "message": message]]
                } else if fixture.scenario == .invalidValue {
                    error = ["error": ["param": "temperature", "code": "invalid_value",
                                       "message": "The supplied temperature value is unsupported because it is out of range. " + CloudTemperatureFixture.secretMarker]]
                } else if fixture.provider.projectHeader != nil {
                    error = ["error": ["param": "temperature", "type": "invalid_request_error", "message": message]]
                } else {
                    error = ["status": 400, "message": message]
                }
                data = try! JSONSerialization.data(withJSONObject: error)
                if fixture.scenario == .oversized { data.append(Data(repeating: 0x20, count: 70 * 1024)) }
                contentType = "application/json"
            } else if body["stream"] as? Bool == true {
                data = Data("data: {\"choices\":[{\"delta\":{\"content\":\"Synthetic cloud summary.\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n".utf8)
                contentType = "text/event-stream"
            } else {
                data = Data(#"{"choices":[{"message":{"role":"assistant","content":"Synthetic cloud summary."},"finish_reason":"stop"}]}"#.utf8)
                contentType = "application/json"
            }
        }
        guard let response = HTTPURLResponse(url: url, statusCode: status, httpVersion: "HTTP/1.1",
                                             headerFields: ["Content-Type": contentType]) else {
            self.client?.urlProtocol(self, didFailWithError: URLError(.badURL)); return
        }
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if self.activeChat && fixture.scenario == .held {
            self.client?.urlProtocol(self, didLoad: data.prefix(32))
            fixture.started?.fulfill()
            return
        }
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() { if self.activeChat { self.fixture?.stoppedChat() } }
}
