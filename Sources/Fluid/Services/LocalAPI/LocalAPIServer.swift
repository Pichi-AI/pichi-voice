import Foundation
import Network

@MainActor
final class LocalAPIServer {
    static let shared = LocalAPIServer()

    private let router: LocalAPIRouter
    private let queue = DispatchQueue(label: "fluidvoice.local-api", qos: .utility)
    private var listener: NWListener?
    private var listenerGeneration: UUID?
    private var stopTask: Task<Void, Never>?
    private var activeConnections: [ObjectIdentifier: LocalAPIConnectionHandler] = [:]
    private(set) var port: UInt16 = LocalAPI.defaultPort

    init(router: LocalAPIRouter = LocalAPIRouter()) { self.router = router }

    func start() {
        let config = LocalAPI.Configuration.current
        guard config.enabled else {
            DebugLogger.shared.info("Local API disabled", source: "LocalAPIServer")
            return
        }

        if self.listener != nil {
            return
        }

        do {
            guard let port = NWEndpoint.Port(rawValue: config.port) else {
                DebugLogger.shared.error("Local API invalid port", source: "LocalAPIServer")
                return
            }

            let parameters = NWParameters.tcp

            let listener = try NWListener(using: parameters, on: port)
            let generation = UUID()
            listener.newConnectionHandler = { [weak self] connection in
                guard Self.isLoopback(connection.endpoint) else {
                    connection.cancel()
                    return
                }

                Task { @MainActor [weak self] in
                    guard let self else {
                        connection.cancel()
                        return
                    }
                    self.handleConnection(connection, generation: generation)
                }
            }
            listener.stateUpdateHandler = { [weak self] state in
                Task { @MainActor [weak self] in
                    self?.handleState(state, generation: generation)
                }
            }

            self.port = config.port
            self.listener = listener
            self.listenerGeneration = generation
            listener.start(queue: self.queue)
        } catch {
            DebugLogger.shared.error("Local API failed to start: \(error.localizedDescription)", source: "LocalAPIServer")
        }
    }

    /// Stop admission immediately, then retain and join only this server's retiring routes.
    /// Existing synchronous callers may ignore the handle; native work still owns its lease
    /// until this drain completes, including a provider that ignores cancellation temporarily.
    @discardableResult
    func stop() -> Task<Void, Never> {
        self.listenerGeneration = nil
        self.listener?.cancel()
        self.listener = nil
        let handlers = Array(self.activeConnections.values)
        for handler in handlers {
            handler.cancel()
        }
        let previous = self.stopTask
        let drain = Task { @MainActor in
            await previous?.value
            for handler in handlers { await handler.waitForPendingRequest() }
        }
        self.stopTask = drain
        return drain
    }

    private func retain(_ handler: LocalAPIConnectionHandler) {
        let id = ObjectIdentifier(handler)
        handler.onClose = { [weak self] in self?.activeConnections[id] = nil }
        self.activeConnections[id] = handler
    }

    private func handleConnection(_ connection: NWConnection, generation: UUID) {
        guard self.listenerGeneration == generation else { connection.cancel(); return }
        let handler = LocalAPIConnectionHandler(connection: connection, router: self.router)
        self.retain(handler)
        handler.start(on: self.queue)
    }

    private func handleState(_ state: NWListener.State, generation: UUID) {
        guard self.listenerGeneration == generation else { return }
        switch state {
        case .ready:
            DebugLogger.shared.info("Local API listening on http://127.0.0.1:\(self.port)", source: "LocalAPIServer")
        case let .failed(error):
            DebugLogger.shared.error("Local API listener failed: \(error.localizedDescription)", source: "LocalAPIServer")
            self.stop()
        case .cancelled:
            self.stop()
        default:
            break
        }
    }

    #if DEBUG
    // Transport seams exercise the same ownership/state callbacks without a listening socket.
    func retainConnectionForTesting(_ handler: LocalAPIConnectionHandler) { self.retain(handler) }
    var activeConnectionCountForTesting: Int { self.activeConnections.count }
    func beginListenerGenerationForTesting() -> UUID {
        let generation = UUID()
        self.listenerGeneration = generation
        return generation
    }
    var listenerGenerationForTesting: UUID? { self.listenerGeneration }
    func handleStateForTesting(_ state: NWListener.State, generation: UUID) {
        self.handleState(state, generation: generation)
    }
    func handleConnectionForTesting(_ connection: NWConnection, generation: UUID) {
        self.handleConnection(connection, generation: generation)
    }
    #endif

    private nonisolated static func isLoopback(_ endpoint: NWEndpoint) -> Bool {
        guard case let .hostPort(host, _) = endpoint else { return false }

        switch host {
        case let .name(name, _):
            return name.caseInsensitiveCompare("localhost") == .orderedSame
        case let .ipv4(address):
            return "\(address)" == "127.0.0.1"
        case let .ipv6(address):
            return "\(address)" == "::1"
        @unknown default:
            return false
        }
    }
}

@MainActor
final class LocalAPIConnectionHandler {
    typealias ReceiveCompletion = @Sendable (Data?, Bool, NWError?) -> Void
    typealias SendCompletion = @Sendable (NWError?) -> Void
    private let connection: NWConnection
    private let router: LocalAPIRouter
    private var buffer = Data()
    private var isClosed = false
    private var readEnded = false
    private var routeTask: Task<Void, Never>?
    var onClose: (() -> Void)?

    init(connection: NWConnection, router: LocalAPIRouter) {
        self.connection = connection
        self.router = router
    }

    func start(on queue: DispatchQueue) {
        self.connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled:
                Task { @MainActor [weak self] in self?.close() }
            default:
                break
            }
        }
        self.connection.start(queue: queue)
        self.receive()
    }

    func cancel() {
        self.close()
    }

    func waitForPendingRequest() async { await self.routeTask?.value }

    private func receive() {
        self.receiveBytes { [weak self] data, isComplete, error in
            Task { @MainActor in
                guard let self, !self.isClosed else { return }
                if error != nil {
                    self.close()
                    return
                }

                if let data {
                    self.buffer.append(data)
                }
                self.readEnded = isComplete

                guard self.buffer.count <= LocalAPI.maxRequestBytes else {
                    self.send(LocalAPI.error("Request too large.", status: 413))
                    return
                }

                switch self.parseRequestIfComplete() {
                case let .request(request):
                    self.routeTask = Task { @MainActor in
                        defer {
                            self.routeTask = nil
                            self.finishCloseIfDrained()
                        }
                        guard !Task.isCancelled, !self.isClosed else { return }
                        let response = await self.router.route(request)
                        guard !Task.isCancelled, !self.isClosed else { return }
                        self.send(response)
                    }
                    if !self.readEnded { self.watchForConnectionFailure() }
                case let .failure(response):
                    self.send(response)
                case .incomplete:
                    if self.readEnded {
                        if self.buffer.isEmpty { self.close() }
                        else { self.send(LocalAPI.error("Malformed request.", status: 400)) }
                    } else {
                        self.receive()
                    }
                }
            }
        }
    }

    /// Observe definite connection errors while inference runs. TCP EOF only closes the
    /// peer's sending direction; a valid half-closed request can still receive its response.
    /// The API serves one request per connection; additional bytes are never routed again.
    private func watchForConnectionFailure() {
        self.receiveBytes { [weak self] _, isComplete, error in
            Task { @MainActor [weak self] in
                guard let self, !self.isClosed else { return }
                if error != nil { self.close() }
                else if isComplete { self.readEnded = true }
                else { self.watchForConnectionFailure() }
            }
        }
    }

    private func send(_ response: LocalAPI.Response) {
        guard !self.isClosed else { return }
        let body = response.body
        var headers = response.headers
        headers["Content-Length"] = "\(body.count)"
        headers["Connection"] = "close"

        let statusLine = "HTTP/1.1 \(response.status) \(Self.reasonPhrase(for: response.status))\r\n"
        let headerLines = headers
            .map { "\($0.key): \($0.value)\r\n" }
            .sorted()
            .joined()
        var data = Data((statusLine + headerLines + "\r\n").utf8)
        data.append(body)

        self.sendBytes(data) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.close()
            }
        }
    }

    private func close() {
        guard !self.isClosed else { return }
        self.isClosed = true
        self.cancelConnection()
        self.routeTask?.cancel()
        self.finishCloseIfDrained()
    }

    private func finishCloseIfDrained() {
        guard self.isClosed, self.routeTask == nil else { return }
        let completion = self.onClose
        self.onClose = nil
        completion?()
    }

    private func receiveBytes(_ completion: @escaping ReceiveCompletion) {
        #if DEBUG
        if let receiveForTesting { receiveForTesting(completion); return }
        #endif
        self.connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { data, _, complete, error in
            completion(data, complete, error)
        }
    }

    private func sendBytes(_ data: Data, completion: @escaping SendCompletion) {
        #if DEBUG
        if let sendForTesting { sendForTesting(data, completion); return }
        #endif
        self.connection.send(content: data, completion: .contentProcessed(completion))
    }

    private func cancelConnection() {
        #if DEBUG
        if let cancelForTesting { cancelForTesting(); return }
        #endif
        self.connection.cancel()
    }

    #if DEBUG
    var receiveForTesting: ((@escaping ReceiveCompletion) -> Void)?
    var sendForTesting: ((Data, @escaping SendCompletion) -> Void)?
    var cancelForTesting: (() -> Void)?
    var readEndedForTesting: Bool { self.readEnded }
    func startForTesting() { self.receive() }
    #endif

    private enum ParsedRequest {
        case incomplete
        case request(LocalAPI.Request)
        case failure(LocalAPI.Response)
    }

    private func parseRequestIfComplete() -> ParsedRequest {
        guard let headerEnd = self.buffer.range(of: Data("\r\n\r\n".utf8)) else {
            return .incomplete
        }

        let headerData = self.buffer[..<headerEnd.lowerBound]
        guard let headerText = String(data: headerData, encoding: .utf8) else {
            return .failure(LocalAPI.error("Malformed request.", status: 400))
        }

        let lines = headerText.components(separatedBy: "\r\n")
        guard let requestLine = lines.first else { return .incomplete }
        let parts = requestLine.split(separator: " ", maxSplits: 2).map(String.init)
        guard parts.count >= 2 else {
            return .failure(LocalAPI.error("Malformed request.", status: 400))
        }

        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = line[..<separator].trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let value = line[line.index(after: separator)...].trimmingCharacters(in: .whitespacesAndNewlines)
            headers[key] = value
        }

        let contentLength: Int
        if let rawContentLength = headers["content-length"] {
            guard let parsedContentLength = Int(rawContentLength), parsedContentLength >= 0 else {
                return .failure(LocalAPI.error("Invalid Content-Length.", status: 400))
            }
            guard parsedContentLength <= LocalAPI.maxRequestBytes else {
                return .failure(LocalAPI.error("Request too large.", status: 413))
            }
            contentLength = parsedContentLength
        } else {
            contentLength = 0
        }

        let bodyStart = headerEnd.upperBound
        let requestEnd = bodyStart + contentLength
        guard requestEnd <= LocalAPI.maxRequestBytes else {
            return .failure(LocalAPI.error("Request too large.", status: 413))
        }
        guard self.buffer.count >= requestEnd else {
            return .incomplete
        }

        let body = Data(self.buffer[bodyStart..<requestEnd])
        let parsedTarget = Self.parseTarget(parts[1])
        return .request(LocalAPI.Request(
            method: parts[0].uppercased(),
            path: parsedTarget.path,
            query: parsedTarget.query,
            headers: headers,
            body: body
        ))
    }

    private static func parseTarget(_ target: String) -> (path: String, query: [String: String]) {
        let base = target.hasPrefix("http") ? target : "http://127.0.0.1\(target)"
        guard let components = URLComponents(string: base) else {
            return (target, [:])
        }

        var query: [String: String] = [:]
        for item in components.queryItems ?? [] {
            guard !item.name.isEmpty else { continue }
            query[item.name] = item.value ?? ""
        }

        return (components.path.isEmpty ? "/" : components.path, query)
    }

    private static func reasonPhrase(for status: Int) -> String {
        switch status {
        case 200: return "OK"
        case 204: return "No Content"
        case 400: return "Bad Request"
        case 404: return "Not Found"
        case 405: return "Method Not Allowed"
        case 413: return "Payload Too Large"
        case 500: return "Internal Server Error"
        case 503: return "Service Unavailable"
        default: return "OK"
        }
    }
}
