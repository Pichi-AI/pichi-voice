@testable import FluidVoice_Debug
import Foundation
import XCTest

private nonisolated final class CloudFixtureCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { self.lock.withLock { self.count } }
    func next() -> Int { self.lock.withLock { self.count += 1; return self.count } }
}

private nonisolated final class CloudFixturePaths: @unchecked Sendable {
    private let lock = NSLock()
    private var paths: [String] = []
    var value: [String] { self.lock.withLock { self.paths } }
    func append(_ path: String) { self.lock.withLock { self.paths.append(path) } }
}

private nonisolated final class CloudFixtureClock: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date
    init(_ date: Date) { self.date = date }
    var value: Date { self.lock.withLock { self.date } }
    func advance(_ seconds: Double) { self.lock.withLock { self.date.addTimeInterval(seconds) } }
}

private nonisolated final class CloudProviderFixtureProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var handler: (@Sendable (URLRequest) throws -> (Int, Data)?)?
    nonisolated(unsafe) static var stops = CloudFixtureCounter()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        do {
            guard let (status, data) = try Self.handler!(self.request) else { return }
            self.client?.urlProtocol(self, didReceive: HTTPURLResponse(url: self.request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!, cacheStoragePolicy: .notAllowed)
            self.client?.urlProtocol(self, didLoad: data)
            self.client?.urlProtocolDidFinishLoading(self)
        } catch { self.client?.urlProtocol(self, didFailWithError: error) }
    }
    override func stopLoading() { _ = Self.stops.next() }
}

@MainActor
final class CloudTextProviderTests: XCTestCase {
    private func session() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [CloudProviderFixtureProtocol.self]
        return URLSession(configuration: config)
    }
    nonisolated private func token(_ value: String, expiry: Double = Date().addingTimeInterval(1800).timeIntervalSince1970 * 1000) throws -> Data {
        try JSONSerialization.data(withJSONObject: ["access_token": value, "expires_at": expiry])
    }
    nonisolated private func response() -> Data { Data(#"{"choices":[{"message":{"role":"assistant","content":"Synthetic result."}}]}"#.utf8) }

    nonisolated override func tearDown() { CloudProviderFixtureProtocol.handler = nil; super.tearDown() }

    func testRegisteredProvidersUseCurrentEndpointsAndNoInventedModels() {
        for id in ["gigachat", "yandex"] {
            XCTAssertTrue(ModelRepository.shared.isBuiltIn(id))
            XCTAssertTrue(ModelRepository.shared.defaultModels(for: id).isEmpty)
            XCTAssertTrue(ModelRepository.shared.builtInProvidersList().contains { $0.id == id })
        }
        XCTAssertEqual(ModelRepository.shared.defaultBaseURL(for: "gigachat"), "https://api.giga.chat/v1")
        XCTAssertEqual(ModelRepository.shared.defaultBaseURL(for: "yandex"), "https://ai.api.cloud.yandex.net/v1")
        for endpoint in ["http://api.giga.chat/v1", "https://api.giga.chat.evil.example/v1", "https://key@api.giga.chat/v1", "https://api.giga.chat:444/v1"] {
            XCTAssertNil(CloudTextProvider.descriptor(forEndpoint: endpoint))
        }
    }

    func testOAuthExchangeCacheExpiryAndScopes() async throws {
        let session = self.session()
        defer { session.invalidateAndCancel() }
        let fixed = Date(timeIntervalSince1970: 1_800_000_000)
        let authorization = CloudTextProviderAuthorization(session: session, now: { fixed })
        let provider = try XCTUnwrap(CloudTextProvider.descriptor(for: "gigachat"))
        let exchanges = CloudFixtureCounter()
        CloudProviderFixtureProtocol.handler = { request in
            let exchange = exchanges.next()
            XCTAssertEqual(request.url?.absoluteString, "https://ngw.devices.sberbank.ru:9443/api/v2/oauth")
            XCTAssertEqual(request.httpMethod, "POST")
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic " + (exchange == 3 ? "different-key" : "synthetic-authorization-key"))
            XCTAssertNotNil(UUID(uuidString: request.value(forHTTPHeaderField: "RqUID") ?? ""))
            XCTAssertEqual(request.value(forHTTPHeaderField: "Content-Type"), "application/x-www-form-urlencoded")
            // URLSession may expose a body stream to URLProtocol rather than Data.
            var body = request.httpBody ?? Data()
            if body.isEmpty, let stream = request.httpBodyStream {
                stream.open(); defer { stream.close() }
                var buffer = [UInt8](repeating: 0, count: 1024)
                while stream.hasBytesAvailable {
                    let count = stream.read(&buffer, maxLength: buffer.count)
                    guard count > 0 else { break }
                    body.append(contentsOf: buffer.prefix(count))
                }
            }
            XCTAssertEqual(String(decoding: body, as: UTF8.self), "scope=" + (exchange == 2 ? "GIGACHAT_API_CORP" : "GIGACHAT_API_B2B"))
            return (200, try self.token("synthetic-token-\(exchange)", expiry: fixed.addingTimeInterval(1800).timeIntervalSince1970 * 1000))
        }
        let first = try await authorization.headers(for: provider, credential: "synthetic-authorization-key", options: ["scope": "GIGACHAT_API_B2B"])
        let cached = try await authorization.headers(for: provider, credential: "synthetic-authorization-key", options: ["scope": "GIGACHAT_API_B2B"])
        XCTAssertEqual(first, cached)
        XCTAssertEqual(exchanges.value, 1)
        _ = try await authorization.headers(for: provider, credential: "synthetic-authorization-key", options: ["scope": "GIGACHAT_API_CORP"])
        XCTAssertEqual(exchanges.value, 2, "Scopes never share an access token")
        _ = try await authorization.headers(for: provider, credential: "different-key", options: ["scope": "GIGACHAT_API_B2B"])
        XCTAssertEqual(exchanges.value, 3, "Credential changes never reuse the old token")
        let renewed = try await authorization.headers(for: provider, credential: "synthetic-authorization-key", options: ["scope": "GIGACHAT_API_B2B"], rejecting: first["Authorization"])
        XCTAssertNotEqual(first, renewed)
        XCTAssertEqual(exchanges.value, 4)
    }

    func testCacheRefreshesBeforeExpiryAndCancellationStopsOwnedExchange() async throws {
        let session = self.session(); defer { session.invalidateAndCancel() }
        let clock = CloudFixtureClock(Date(timeIntervalSince1970: 1_800_000_000))
        let authorization = CloudTextProviderAuthorization(session: session, now: { clock.value })
        let provider = try XCTUnwrap(CloudTextProvider.descriptor(for: "gigachat"))
        let exchanges = CloudFixtureCounter()
        CloudProviderFixtureProtocol.handler = { _ in
            let count = exchanges.next()
            return (200, try self.token("token-\(count)", expiry: clock.value.addingTimeInterval(count == 1 ? 62 : 1800).timeIntervalSince1970 * 1000))
        }
        _ = try await authorization.headers(for: provider, credential: "synthetic", options: [:])
        clock.advance(3)
        _ = try await authorization.headers(for: provider, credential: "synthetic", options: [:])
        XCTAssertEqual(exchanges.value, 2, "Refresh before the token expires instead of waiting for an API failure")
        let started = CloudFixtureCounter()
        CloudProviderFixtureProtocol.stops = CloudFixtureCounter()
        CloudProviderFixtureProtocol.handler = { _ in _ = started.next(); return nil }
        let pending = Task { try await authorization.headers(for: provider, credential: "different", options: [:]) }
        for _ in 0..<100 where started.value == 0 { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(started.value, 1)
        pending.cancel()
        do { _ = try await pending.value; XCTFail("Canceled exchange must not return a token") } catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(CloudProviderFixtureProtocol.stops.value, 1, "Cancellation joins the owned URLSession request")
    }

    func testExpiredTokenAndCredentialInjectionFailClosed() async throws {
        let session = self.session(); defer { session.invalidateAndCancel() }
        let auth = CloudTextProviderAuthorization(session: session)
        let provider = try XCTUnwrap(CloudTextProvider.descriptor(for: "gigachat"))
        CloudProviderFixtureProtocol.handler = { _ in (200, try self.token("expired", expiry: Date().addingTimeInterval(-1).timeIntervalSince1970 * 1000)) }
        do { _ = try await auth.headers(for: provider, credential: "synthetic", options: [:]); XCTFail("Expired token must be rejected") } catch { XCTAssertTrue(error is CloudTextProviderError) }
        do { _ = try await auth.headers(for: provider, credential: "synthetic\r\nX-Test: injected", options: [:]); XCTFail("Header injection must be rejected") } catch { XCTAssertTrue(error is CloudTextProviderError) }
        XCTAssertThrowsError(try provider.normalizedOptions(["scope": "GIGACHAT_API_PERS&scope=other"]))
    }

    func testYandexProjectAndAPIKeyAreSharedByDiscoveryAndCompletion() async throws {
        let session = self.session(); defer { session.invalidateAndCancel() }
        let paths = CloudFixturePaths()
        let model = "gpt://synthetic-folder/aliceai-llm-flash"
        CloudProviderFixtureProtocol.handler = { request in
            paths.append(request.url!.path)
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Api-Key synthetic-key")
            XCTAssertEqual(request.value(forHTTPHeaderField: "OpenAI-Project"), "synthetic-folder")
            if request.httpMethod == "GET" { return (200, Data("{\"data\":[{\"id\":\"\(model)\"}]}".utf8)) }
            return (200, self.response())
        }
        let models = try await ModelRepository.shared.fetchModels(for: "yandex", baseURL: ModelRepository.shared.defaultBaseURL(for: "yandex"), apiKey: "synthetic-key", session: session, connectionOptions: ["project": "synthetic-folder"])
        XCTAssertEqual(models, [model])
        var config = LLMClient.Config(messages: [["role": "user", "content": "Synthetic prompt"]], model: model, baseURL: ModelRepository.shared.defaultBaseURL(for: "yandex"), apiKey: "synthetic-key", streaming: false)
        config.providerOptions = ["project": "synthetic-folder"]
        let result = try await LLMClient(session: session).call(config)
        XCTAssertEqual(result.content, "Synthetic result.")
        XCTAssertEqual(paths.value, ["/v1/models", "/v1/chat/completions"])
        config.providerOptions = ["project": "different-folder"]
        XCTAssertThrowsError(try LLMClient.shared.buildRequest(config), "An immutable model URI cannot silently switch folders")
    }

    func testOAuthCompletionRefreshesUnauthorizedOnceAndDoesNotLeakKeys() async throws {
        let session = self.session(); defer { session.invalidateAndCancel() }
        let exchanges = CloudFixtureCounter()
        let completions = CloudFixtureCounter()
        CloudProviderFixtureProtocol.handler = { request in
            if request.url?.path == "/api/v2/oauth" {
                let exchange = exchanges.next()
                XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Basic synthetic-secret")
                return (200, try self.token("token-\(exchange)"))
            }
            let completion = completions.next()
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token-\(exchanges.value)")
            return completion == 1 ? (401, Data("secret echo: synthetic-secret".utf8)) : (200, self.response())
        }
        var config = LLMClient.Config(messages: [["role": "user", "content": "Synthetic prompt"]], model: "GigaChat-2", baseURL: ModelRepository.shared.defaultBaseURL(for: "gigachat"), apiKey: "synthetic-secret", streaming: false)
        config.maxRetries = 1
        let result = try await LLMClient(session: session).call(config)
        XCTAssertEqual(result.content, "Synthetic result.")
        XCTAssertEqual(exchanges.value, 2)
        XCTAssertEqual(completions.value, 2)
    }

    func testOAuthDiscoveryAndFailureRedaction() async throws {
        let session = self.session(); defer { session.invalidateAndCancel() }
        let exchanges = CloudFixtureCounter()
        CloudProviderFixtureProtocol.handler = { request in
            if request.url?.path == "/api/v2/oauth" { _ = exchanges.next(); return (200, try self.token("token")) }
            XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer token")
            return (403, Data("secret echo: synthetic-secret".utf8))
        }
        do {
            _ = try await ModelRepository.shared.fetchModels(for: "gigachat", baseURL: ModelRepository.shared.defaultBaseURL(for: "gigachat"), apiKey: "synthetic-secret", session: session)
            XCTFail("Authorization failure must be returned")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("synthetic-secret"))
            XCTAssertFalse(error.localizedDescription.contains("secret echo"))
        }
        XCTAssertEqual(exchanges.value, 1)
    }

    func testMalformedSuccessfulCloudDiscoveryDoesNotExposeEchoedCredentials() async throws {
        let session = self.session(); defer { session.invalidateAndCancel() }
        for body in ["echoed synthetic-secret", "{\"synthetic-secret\": true}"] {
            CloudProviderFixtureProtocol.handler = { _ in (200, Data(body.utf8)) }
            do {
                _ = try await ModelRepository.shared.fetchModels(for: "yandex", baseURL: ModelRepository.shared.defaultBaseURL(for: "yandex"), apiKey: "synthetic-secret", session: session, connectionOptions: ["project": "synthetic-folder"])
                XCTFail("Malformed model discovery must fail safely")
            } catch {
                XCTAssertTrue(error is CloudTextProviderError)
                XCTAssertFalse(error.localizedDescription.contains("synthetic-secret"))
            }
        }
    }

    func testLegacyConfiguredProviderGateIncludesMetadataAndKeepsOldHashes() throws {
        let base = "https://ai.api.cloud.yandex.net/v1"
        let metadata = ["project": "synthetic-folder"]
        let expected = try XCTUnwrap(CloudTextProvider.connectionFingerprint(baseURL: base, apiKey: "synthetic-key", options: metadata))
        XCTAssertEqual(DictationAIPostProcessingGate.providerFingerprint(baseURL: base, apiKey: "synthetic-key", connectionOptions: metadata), expected)
        XCTAssertNotEqual(DictationAIPostProcessingGate.providerFingerprint(baseURL: base, apiKey: "synthetic-key", connectionOptions: ["project": "other-folder"]), expected)
        XCTAssertEqual(CloudTextProvider.connectionFingerprint(baseURL: "http://localhost:11434/v1", apiKey: ""),
                       DictationAIPostProcessingGate.providerFingerprint(baseURL: "http://localhost:11434/v1", apiKey: ""))
    }

    func testConnectionMetadataChangesInvalidateVerificationAndDraftDiscovery() throws {
        let first = ProviderModelVerificationStore.identity(providerID: "yandex", baseURL: "https://ai.api.cloud.yandex.net/v1", apiKey: "synthetic", model: "model", connectionOptions: ["project": "one"])
        let second = ProviderModelVerificationStore.identity(providerID: "yandex", baseURL: "https://ai.api.cloud.yandex.net/v1", apiKey: "synthetic", model: "model", connectionOptions: ["project": "two"])
        XCTAssertNotEqual(first, second)
        var draft = ProviderSetupDraft(providerID: "yandex", name: "Yandex AI Studio", baseURL: "https://ai.api.cloud.yandex.net/v1", apiKey: "synthetic")
        XCTAssertFalse(draft.isValid)
        draft.connectionOptions = ["project": "one"]
        XCTAssertTrue(draft.isValid)
        let identity = draft.connectionIdentity
        draft.applyFetchedModels(["model"], for: identity)
        draft.selectFetchedModel("model")
        draft.connectionOptions = ["project": "two"]
        XCTAssertTrue(draft.fetchedModels.isEmpty)
        XCTAssertTrue(draft.model.isEmpty)
        XCTAssertFalse(draft.applyFetchedModels(["old-model"], for: identity))
    }

    func testToolIncompatibilityFailsBeforeOAuthAndLocalTransportIsUnchanged() throws {
        let config = LLMClient.Config(messages: [["role": "user", "content": "Synthetic prompt"]], model: "GigaChat-2", baseURL: ModelRepository.shared.defaultBaseURL(for: "gigachat"), apiKey: "synthetic-secret", tools: [["type": "function"]])
        XCTAssertThrowsError(try LLMClient.shared.buildRequest(config))
        let local = LLMClient.Config(messages: [["role": "user", "content": "hello"]], model: "small:latest", baseURL: "http://127.0.0.1:11434/v1", apiKey: "local-key", streaming: false)
        let request = try LLMClient.shared.buildRequest(local)
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer local-key")
        XCTAssertNil(request.value(forHTTPHeaderField: "OpenAI-Project"))
    }
}
