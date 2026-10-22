@testable import FluidVoice_Debug
import Foundation
import Network
import XCTest

// Regression tests for https://github.com/altic-dev/FluidVoice/issues/1016
// A pooled connection that sat idle can be dead on some network paths, and the first
// request on it stalls ~6.5 s before failing with -1005. After an idle gap the client
// must open a fresh connection; back-to-back requests must keep reusing one.

final class LLMClientIdleConnectionTests: XCTestCase {
    private var server: KeepAliveServer!

    override func setUpWithError() throws {
        self.server = try KeepAliveServer()
    }

    override func tearDown() {
        self.server.stop()
    }

    func testRequestAfterIdleGapOpensFreshConnection() async throws {
        let client = self.makeClient(idleConnectionLimit: 0.2)

        _ = try await client.call(self.config())
        try await Task.sleep(nanoseconds: 500_000_000)
        _ = try await client.call(self.config())

        XCTAssertEqual(self.server.requestCount, 2)
        XCTAssertEqual(self.server.connectionCount, 2)
    }

    func testBackToBackRequestsReuseConnection() async throws {
        let client = self.makeClient(idleConnectionLimit: 60)

        _ = try await client.call(self.config())
        _ = try await client.call(self.config())

        XCTAssertEqual(self.server.requestCount, 2)
        XCTAssertEqual(self.server.connectionCount, 1)
    }

    // MARK: - Helpers

    private func makeClient(idleConnectionLimit: TimeInterval) -> LLMClient {
        LLMClient(
            session: URLSession(configuration: .ephemeral),
            idleConnectionLimit: idleConnectionLimit
        )
    }

    private func config() -> LLMClient.Config {
        var config = LLMClient.Config(
            messages: [["role": "user", "content": "Hello"]],
            model: "test-model",
            baseURL: "http://127.0.0.1:\(self.server.port)/v1",
            apiKey: "test",
            streaming: false
        )
        config.maxRetries = 1
        config.timeoutSeconds = 5
        return config
    }
}

/// Minimal HTTP/1.1 server that keeps connections alive and counts how many it accepts.
private final class KeepAliveServer: @unchecked Sendable {
    private let listener: NWListener
    private let queue = DispatchQueue(label: "LLMClientIdleConnectionTests.server")
    private let lock = NSLock()
    private var accepted: [NWConnection] = []
    private var requests = 0
    private(set) var port: UInt16 = 0

    var connectionCount: Int {
        self.lock.withLock { self.accepted.count }
    }

    var requestCount: Int {
        self.lock.withLock { self.requests }
    }

    init() throws {
        let parameters = NWParameters.tcp
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        self.listener = try NWListener(using: parameters)
        self.listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return }
            self.lock.withLock { self.accepted.append(connection) }
            connection.start(queue: self.queue)
            self.receive(on: connection, buffer: Data())
        }

        let ready = DispatchSemaphore(value: 0)
        self.listener.stateUpdateHandler = { state in
            if case .ready = state {
                ready.signal()
            }
        }
        self.listener.start(queue: self.queue)
        guard ready.wait(timeout: .now() + 5) == .success, let port = self.listener.port?.rawValue else {
            throw URLError(.cannotConnectToHost)
        }
        self.port = port
    }

    func stop() {
        self.listener.cancel()
        self.lock.withLock { self.accepted }.forEach { $0.cancel() }
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            var buffer = buffer
            if let data {
                buffer.append(data)
            }
            if let request = Self.completeRequestLength(in: buffer) {
                buffer.removeFirst(request)
                self.lock.withLock { self.requests += 1 }
                self.respond(on: connection)
            }
            if isComplete || error != nil {
                connection.cancel()
                return
            }
            self.receive(on: connection, buffer: buffer)
        }
    }

    private func respond(on connection: NWConnection) {
        let body = #"{"choices":[{"index":0,"message":{"role":"assistant","content":"Hi."},"finish_reason":"stop"}]}"#
        let head = "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(body.utf8.count)\r\nConnection: keep-alive\r\n\r\n"
        connection.send(content: Data((head + body).utf8), completion: .contentProcessed { _ in })
    }

    /// Byte length of the first full request (headers plus Content-Length body), or nil if incomplete.
    private static func completeRequestLength(in buffer: Data) -> Int? {
        guard let headerEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return nil }
        let headers = (String(bytes: buffer[..<headerEnd.lowerBound], encoding: .utf8) ?? "").lowercased()
        let contentLength = headers
            .components(separatedBy: "\r\n")
            .first { $0.hasPrefix("content-length:") }
            .flatMap { Int($0.dropFirst("content-length:".count).trimmingCharacters(in: .whitespaces)) } ?? 0
        let total = buffer.distance(from: buffer.startIndex, to: headerEnd.upperBound) + contentLength
        return buffer.count >= total ? total : nil
    }
}

/// The fixture intercepts every URL before networking. It records the actual session
/// passed to the URLSession delegate, including sessions recreated by the idle pool.
private nonisolated final class IdlePoolReceipt: @unchecked Sendable {
    private let lock = NSLock()
    private var completed: [URLSession] = []
    private var pending: IdlePoolProtocol?
    let heldStarted = XCTestExpectation(description: "Owned held request started")
    let firstCompleted = XCTestExpectation(description: "First owned request completed")
    let completions: XCTestExpectation

    init(completions: Int) {
        self.completions = XCTestExpectation(description: "Owned session completions")
        self.completions.expectedFulfillmentCount = completions
    }
    var sessions: [URLSession] { self.lock.withLock { self.completed } }
    func completed(_ session: URLSession) {
        let first = self.lock.withLock { self.completed.append(session); return self.completed.count == 1 }
        if first { self.firstCompleted.fulfill() }
        self.completions.fulfill()
    }
    func hold(_ request: IdlePoolProtocol) {
        self.lock.withLock { self.pending = request }
        self.heldStarted.fulfill()
    }
    func finishHeld() {
        let request = self.lock.withLock { let value = self.pending; self.pending = nil; return value }
        request?.reply()
    }
}

private nonisolated final class IdlePoolProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var receipt: IdlePoolReceipt?
    private let owner = IdlePoolProtocol.receipt
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        if self.request.url?.path.contains("/held/") == true { self.owner?.hold(self) }
        else { self.reply() }
    }
    func reply() {
        let response = HTTPURLResponse(url: self.request.url!, statusCode: 200,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: Data(#"{"choices":[{"message":{"role":"assistant","content":"Synthetic result."}}]}"#.utf8))
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private nonisolated final class IdlePoolDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    let receipt: IdlePoolReceipt
    init(_ receipt: IdlePoolReceipt) { self.receipt = receipt }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.receipt.completed(session)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        CloudTextProviderTransport.redirectPolicy.urlSession(session, task: task,
            willPerformHTTPRedirection: response, newRequest: request, completionHandler: completionHandler)
    }
}

final class LLMClientIdleOwnershipTests: XCTestCase {
    private func interceptedClient(_ receipt: IdlePoolReceipt) -> (LLMClient, URLSession) {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [IdlePoolProtocol.self]
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        IdlePoolProtocol.receipt = receipt
        let session = URLSession(configuration: configuration, delegate: IdlePoolDelegate(receipt), delegateQueue: nil)
        // A negative threshold deterministically expires an idle pool, without sleeps.
        return (LLMClient(session: session, idleConnectionLimit: -1), session)
    }

    private func interceptedConfig(_ baseURL: String, cloud: Bool = false) -> LLMClient.Config {
        var config = LLMClient.Config(messages: [["role": "user", "content": "Synthetic test."]],
            model: cloud ? "gpt://synthetic-folder/test-model" : "test-model", baseURL: baseURL,
            apiKey: "synthetic-key", streaming: false)
        config.maxRetries = 1
        config.timeoutSeconds = 5
        if cloud { config.providerOptions = ["project": "synthetic-folder"] }
        return config
    }

    func testCloudPoolIdleRotationPreservesRedirectDenialAndConfiguration() async throws {
        let receipt = IdlePoolReceipt(completions: 2)
        let (client, seed) = self.interceptedClient(receipt)
        defer { seed.invalidateAndCancel(); IdlePoolProtocol.receipt = nil }
        let config = self.interceptedConfig("https://ai.api.cloud.yandex.net/v1", cloud: true)
        _ = try await client.call(config)
        await self.fulfillment(of: [receipt.firstCompleted], timeout: 2)
        _ = try await client.call(config)
        await self.fulfillment(of: [receipt.completions], timeout: 2)
        let sessions = receipt.sessions
        XCTAssertEqual(sessions.count, 2)
        guard sessions.count == 2 else { return }
        defer { sessions.forEach { $0.invalidateAndCancel() } }
        XCTAssertFalse(sessions[0] === sessions[1], "The actual cloud pool rotated after idle")
        for session in sessions {
            XCTAssertTrue(session.configuration.protocolClasses?.contains { $0 == IdlePoolProtocol.self } == true)
            XCTAssertFalse(session.configuration.httpShouldSetCookies)
            let delegate = try XCTUnwrap(session.delegate as? IdlePoolDelegate,
                "Idle recreation must retain the credential-safe delegate")
            let request = URLRequest(url: URL(string: "https://attacker.invalid/redirect-target")!)
            let response = HTTPURLResponse(url: URL(string: config.baseURL)!, statusCode: 302,
                httpVersion: nil, headerFields: ["Location": request.url!.absoluteString])!
            let task = session.dataTask(with: URL(string: config.baseURL)!)
            defer { task.cancel() }
            delegate.urlSession(session, task: task, willPerformHTTPRedirection: response, newRequest: request) {
                XCTAssertNil($0, "The actual rotated session's delegate must reject forwarding credentials")
            }
        }
    }

    func testIdleRotationNeverInvalidatesAnActiveRequest() async throws {
        let receipt = IdlePoolReceipt(completions: 3)
        let (client, seed) = self.interceptedClient(receipt)
        defer { seed.invalidateAndCancel(); IdlePoolProtocol.receipt = nil }
        _ = try await client.call(self.interceptedConfig("https://idle.pool.invalid/v1"))
        await self.fulfillment(of: [receipt.firstCompleted], timeout: 2)
        let held = Task { try await client.call(self.interceptedConfig("https://idle.pool.invalid/held/v1")) }
        await self.fulfillment(of: [receipt.heldStarted], timeout: 2)
        do {
            _ = try await client.call(self.interceptedConfig("https://idle.pool.invalid/v1"))
            receipt.finishHeld()
            let result = try await held.value
            XCTAssertEqual(result.content, "Synthetic result.")
        } catch {
            receipt.finishHeld()
            held.cancel()
            _ = await held.result
            throw error
        }
        await self.fulfillment(of: [receipt.completions], timeout: 2)
        let sessions = receipt.sessions
        defer { sessions.forEach { $0.invalidateAndCancel() } }
        XCTAssertEqual(sessions.count, 3)
        guard sessions.count == 3 else { return }
        XCTAssertFalse(sessions[0] === sessions[1], "The idle pool must rotate before the held request")
        XCTAssertTrue(sessions[1] === sessions[2], "Overlapping calls retain the same active pool")
    }
}
