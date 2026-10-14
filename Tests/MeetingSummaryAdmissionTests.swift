import Combine
import Foundation

// Inert surrounding app metadata. The runner compiles production KeychainService,
// Settings snapshot/getter, catalog, resolver, RemoteService and LLMClient unchanged.
extension UserDefaults {
    func dictionary(forKey key: String) -> [String: Any]? { self.values[key] as? [String: Any] }
    func data(forKey key: String) -> Data? { self.values[key] as? Data }
}
extension SettingsStore {
    struct ModelReasoningConfig {
        let parameterName: String
        let parameterValue: String
        let isEnabled: Bool
    }
    func canonicalProviderKey(for id: String) -> String { ModelRepository.shared.providerKey(for: id) }
    func getReasoningConfig(forModel _: String, provider _: String) -> ModelReasoningConfig? { nil }
    func isTemperatureUnsupported(_: String, baseURL _: String) -> Bool { false }
    func isReasoningModel(_: String) -> Bool { false }
}
nonisolated enum AppBrand {
    static let keychainService = "synthetic-unused-service"
    static let keychainAccount = "synthetic-unused-account"
}
nonisolated enum PichiMeetingSummaryTransport {
    static let redirectPolicy = CloudTextProviderTransport.redirectPolicy
}
nonisolated enum MeetingPostProcessingError: Error { case invalidOutput }
nonisolated final class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()
    static let diagnosticsEnabled = false
    enum Level { case debug }
    func warning(_: String, source _: String) {}
    func error(_: String, source _: String) {}
    func debug(_: String, source _: String) {}
    func info(_: String, source _: String) {}
    func benchmark(_: String, message _: String, source _: String) {}
    func logLazy(level _: Level, source _: String, message _: () -> String) {}
}

@MainActor enum TerminalService {
    static let toolDefinition: [String: Any] = ["type": "function", "function": [
        "name": "execute_terminal_command", "parameters": ["type": "object", "properties": [:]],
    ]]
}
@MainActor final class NotchContentState {
    static let shared = NotchContentState()
    func updateCommandStreamingText(_: String) { fatalError("Inert command owner must not publish UI") }
}
@MainActor final class CommandAdmissionOwner {
    let llmClient: LLMClient
    init(llmClient: LLMClient) { self.llmClient = llmClient }
    struct Message {
        enum Role { case user, assistant, tool }
        struct ToolCall { let id: String; let command: String; let workingDirectory: String? }
        let role: Role
        let content: String
        let toolCall: ToolCall?
    }
    let conversationHistory: [Message] = [.init(role: .user, content: "Synthetic command only.", toolCall: nil)]
    let shouldSyncCommandNotchState = false
    var streamingText = "owned-before-request"
    var streamingThinkingText = "owned-before-request"
    var streamingBuffer = ["owned-before-request"]
    var thinkingBuffer = ["owned-before-request"]
    var lastUIUpdate = 0.0
    var lastThinkingUIUpdate = 0.0
    var responseHandlerCount = 0
    func send() async throws -> String {
        let response = try await self.callLLM(isOutputValid: { true })
        self.responseHandlerCount += 1
        return response.content
    }
}

// UI admission runs production Generate/resolveRoute bodies. The controller is
// an effect recorder, and every resulting HTTP request still uses the injected
// session below. No NSApplication, private runtime or app defaults are accessed.
@MainActor final class TemplateSummaryAdmissionOwner {
    struct Session {}
    final class Controller {
        let busy = false
        let checking = false
        var route: MeetingSummaryRoute?
        var dispatchCount = 0
        func summarize(session _: Session, kind _: MeetingSummaryKind, route: MeetingSummaryRoute, customPrompt _: String) {
            self.route = route
            self.dispatchCount += 1
        }
        func summarizeOnDevice(session _: Session, kind _: MeetingSummaryKind, customPrompt _: String, thinking _: Bool, asr _: ASRService) {
            fatalError("Template credential admission cannot invoke a private runtime")
        }
    }
    let settings: SettingsStore
    let preferences = MeetingSummaryPreferences(defaults: UserDefaults())
    let controller = Controller()
    var session: Session? = Session()
    let isQuiescent = true
    let usesOnDevice = false
    let needsCustomPrompt = false
    let asrService: ASRService? = nil
    var route: MeetingSummaryRoute?
    var readinessIssue: String?
    init(selection: MeetingSummarySelection, settings: SettingsStore) {
        self.preferences.selection = selection
        self.settings = settings
        // A previously displayed route is intentionally stale. Only a fresh
        // click-time resolver may authorize a request with current credentials.
        self.route = MeetingSummaryRoute(providerID: "stale-display", providerName: "Synthetic display",
            modelID: "stale-model", baseURL: "https://api.openai.com/v1", apiKey: "stale-display-key",
            reasoning: nil, supportsTemperature: true)
    }
}

final class AdmissionBackend: @unchecked Sendable {
    enum Failure: Error { case synthetic }
    private let lock = NSLock()
    private let release = DispatchSemaphore(value: 0)
    private var storage: [String: String]
    private var shouldBlockAndFail = false
    private var blocked = false
    private var reads = 0
    private var access: [Bool] = []
    init(_ keys: [String: String]) { self.storage = keys }
    var readCount: Int { self.lock.withLock { self.reads } }
    var isBlocked: Bool { self.lock.withLock { self.blocked } }
    var interactiveAccessCount: Int { self.lock.withLock { self.access.filter { $0 }.count } }
    func recordAccess(_ interactive: Bool) { self.lock.withLock { self.access.append(interactive) } }
    func failNextReadWhileBlocked() { self.lock.withLock { self.shouldBlockAndFail = true } }
    func unblockFailure() { self.release.signal() }
    func replace(_ keys: [String: String]) { self.lock.withLock { self.storage = keys } }
    func load() throws -> [String: String] {
        let fails = self.lock.withLock {
            self.reads += 1
            let fails = self.shouldBlockAndFail
            self.shouldBlockAndFail = false
            self.blocked = fails
            return fails
        }
        if fails {
            guard self.release.wait(timeout: .now() + 5) == .success else { throw Failure.synthetic }
            self.lock.withLock { self.blocked = false }
            throw Failure.synthetic
        }
        return self.lock.withLock { self.storage }
    }
    func service() -> KeychainService {
        KeychainService(testingLoad: { try self.load() },
            testingSave: { _ in fatalError("Admission must never persist credentials") },
            testingLegacyLoad: { [:] },
            testingLegacyRemove: { _ in fatalError("Admission must not remove credentials") },
            testingAccess: { self.recordAccess($0) })
    }
}

final class AdmissionURLProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var authorizationHeaders: [String?] = []
    private static var models: [String?] = []
    private static var urls: [String?] = []
    private static var systemPrompts: [String?] = []
    private static var holdNext = false
    private static var deferredResponse: (() -> Void)?
    private static var unexpectedURLs = 0
    private static let allowedURLs: Set<String> = [
        "https://api.openai.com/v1/chat/completions", "https://keyless.example/v1/chat/completions",
        "https://192.168.1.40/v1/chat/completions", "https://alias.example/v1/chat/completions",
        "http://127.0.0.1:1234/v1/chat/completions",
        "http://127.0.0.1:11434/api/ps", "http://127.0.0.1:11434/api/version", "http://127.0.0.1:11434/api/chat",
    ]
    private var isStreaming = false
    static var requestCount: Int { self.lock.withLock { self.authorizationHeaders.count } }
    static var lastAuthorization: String? { self.lock.withLock { self.authorizationHeaders.last ?? nil } }
    static var lastModel: String? { self.lock.withLock { self.models.last ?? nil } }
    static var lastURL: String? { self.lock.withLock { self.urls.last ?? nil } }
    static var lastSystemPrompt: String? { self.lock.withLock { self.systemPrompts.last ?? nil } }
    static var hasDeferredResponse: Bool { self.lock.withLock { self.deferredResponse != nil } }
    static var unexpectedURLCount: Int { self.lock.withLock { self.unexpectedURLs } }
    static func holdNextResponse() { self.lock.withLock { self.holdNext = true } }
    static func releaseResponse() {
        let response = self.lock.withLock {
            let response = self.deferredResponse
            self.deferredResponse = nil
            return response
        }
        response?()
    }
    override class func canInit(with _: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let body = self.requestBody().flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] }
        self.isStreaming = body?["stream"] as? Bool == true
        Self.lock.withLock {
            Self.authorizationHeaders.append(self.request.value(forHTTPHeaderField: "Authorization"))
            Self.models.append(body?["model"] as? String)
            Self.urls.append(self.request.url?.absoluteString)
            Self.systemPrompts.append((body?["messages"] as? [[String: Any]])?.first(where: { $0["role"] as? String == "system" })?["content"] as? String)
        }
        guard let url = self.request.url?.absoluteString, Self.allowedURLs.contains(url) else {
            Self.lock.withLock { Self.unexpectedURLs += 1 }
            self.client?.urlProtocol(self, didFailWithError: URLError(.unsupportedURL))
            return
        }
        let deferred = Self.lock.withLock {
            guard Self.holdNext else { return false }
            Self.holdNext = false
            Self.deferredResponse = { self.reply() }
            return true
        }
        if !deferred { self.reply() }
    }
    private func requestBody() -> Data? {
        if let body = self.request.httpBody { return body }
        guard let stream = self.request.httpBodyStream else { return nil }
        stream.open()
        defer { stream.close() }
        var data = Data()
        var buffer = [UInt8](repeating: 0, count: 2048)
        while true {
            let count = stream.read(&buffer, maxLength: buffer.count)
            if count == 0 { return data }
            guard count > 0, data.count + count <= 128_000 else { return nil }
            data.append(contentsOf: buffer.prefix(count))
        }
    }
    private func reply() {
        let payload: String
        switch self.request.url?.path {
        case "/api/version": payload = #"{"version":"0.16.0"}"#
        case "/api/ps": payload = #"{"models":[]}"#
        case "/api/chat": payload = #"{"message":{"content":"Synthetic summary"},"done":true}"#
        default:
            payload = self.isStreaming
                ? "data: {\"choices\":[{\"delta\":{\"content\":\"Synthetic summary\"},\"finish_reason\":\"stop\"}]}\n\ndata: [DONE]\n\n"
                : #"{"choices":[{"message":{"content":"Synthetic summary"},"finish_reason":"stop"}]}"#
        }
        let response = HTTPURLResponse(url: self.request.url!, statusCode: 200, httpVersion: nil,
            headerFields: ["Content-Type": self.isStreaming ? "text/event-stream" : "application/json"])!
        let data = Data(payload.utf8)
        self.client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        self.client?.urlProtocol(self, didLoad: data)
        self.client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor @main enum MeetingSummaryAdmissionTests {
    private static var checks = 0
    static var commandClient: LLMClient!
    static func check(_ condition: Bool, _ message: String) {
        guard condition else { fputs("FAIL: \(message)\n", stderr); exit(1) }
        self.checks += 1
    }
    static func waitUntil(_ predicate: () -> Bool) async {
        let deadline = ContinuousClock.now + .seconds(3)
        while !predicate(), ContinuousClock.now < deadline { try? await Task.sleep(for: .milliseconds(5)) }
        self.check(predicate(), "Synthetic worker must settle within its deadline")
    }
    static func load(_ service: KeychainService) async {
        var finished = false
        self.check(service.loadInBackground { result in
            if case .failure = result { fputs("FAIL: synthetic successful load failed\n", stderr); exit(1) }
            finished = true
        }, "Background load admitted")
        await self.waitUntil { finished && service.readiness == .loaded }
    }
    static func fixture(_ backend: AdmissionBackend, provider: String = "openai",
                                endpoint: String? = nil, key: String = "synthetic-key",
                                options: [String: String] = [:]) -> (SettingsStore, KeychainService, MeetingSummarySelection) {
        let service = backend.service()
        let settings = SettingsStore(keychain: service)
        let base = endpoint ?? ModelRepository.shared.defaultBaseURL(for: provider)
        if endpoint != nil {
            settings.savedProviders = [.init(id: provider, name: "Synthetic provider", baseURL: base, models: ["synthetic-model"])]
        }
        let canonical = ModelRepository.shared.providerKey(for: provider)
        settings.availableModelsByProvider[canonical] = ["synthetic-model"]
        settings.selectedProviderID = provider
        settings.selectedModel = "synthetic-model"
        settings.selectedModelByProvider = [canonical: "synthetic-model"]
        settings.providerConnectionOptions[provider] = options
        settings.verifiedProviderFingerprints[canonical] = CloudTextProvider.connectionFingerprint(baseURL: base, apiKey: key, options: options)
        settings.writes = []
        return (settings, service, .init(providerID: provider, modelsByProvider: [canonical: "synthetic-model"]))
    }
    private static func sendSummary(_ selection: MeetingSummarySelection, settings: SettingsStore,
                                    remote: MeetingSummaryRemoteService) async throws -> MeetingSummaryRoute {
        let route = try MeetingSummaryRoute.resolve(selection, settings: settings)
        let result = try await remote.generate(transcript: "Synthetic meeting only.", kind: .executive, route: route)
        self.check(result == "Synthetic summary", "Actual transport must return the intercepted fixture")
        return route
    }
    private static func send(_ selection: MeetingSummarySelection, settings: SettingsStore,
                             remote: MeetingSummaryRemoteService) async throws -> MeetingSummaryRoute {
        let route = try await self.sendSummary(selection, settings: settings, remote: remote)
        _ = try await self.sendCommand(settings: settings)
        _ = try await self.sendTemplate(selection, settings: settings, remote: remote)
        return route
    }
    private static func sendTemplate(_ selection: MeetingSummarySelection, settings: SettingsStore,
                                     remote: MeetingSummaryRemoteService) async throws -> MeetingSummaryRoute {
        let owner = TemplateSummaryAdmissionOwner(selection: selection, settings: settings)
        owner.generate()
        guard let route = owner.controller.route else {
            self.check(owner.controller.dispatchCount == 0 && owner.readinessIssue != nil,
                "Rejected actual Generate click must not dispatch the controller")
            throw LLMError.invalidRequest("Synthetic template admission rejected")
        }
        self.check(owner.controller.dispatchCount == 1 && route.providerID != "stale-display",
            "Actual Generate action must replace its cached presentation route with fresh verified admission")
        let result = try await remote.generate(transcript: "Synthetic meeting only.", kind: .executive, route: route)
        self.check(result == "Synthetic summary", "Admitted template route reaches only the intercepted transport")
        return route
    }
    private static func sendCommand(settings: SettingsStore) async throws -> CommandAdmissionOwner {
        SettingsStore.shared = settings
        let owner = CommandAdmissionOwner(llmClient: self.commandClient)
        let command = try await owner.send()
        self.check(command == "Synthetic summary" && owner.responseHandlerCount == 1, "Actual Command Mode callLLM passes its intercepted result to the owned continuation")
        return owner
    }
    private static func rejects(_ selection: MeetingSummarySelection, settings: SettingsStore,
                                remote: MeetingSummaryRemoteService, reason: String,
                                callers: [String] = ["summary", "command", "template"]) async {
        for caller in callers {
            let count = AdmissionURLProtocol.requestCount
            let owner = CommandAdmissionOwner(llmClient: self.commandClient)
            SettingsStore.shared = settings
            do {
                if caller == "summary" { _ = try await self.sendSummary(selection, settings: settings, remote: remote) }
                else if caller == "template" { _ = try await self.sendTemplate(selection, settings: settings, remote: remote) }
                else { _ = try await owner.send() }
                self.check(false, "\(reason), \(caller): admitted intercepted request, authorization present=\(AdmissionURLProtocol.lastAuthorization != nil)")
            } catch {
                if case LLMError.invalidRequest = error { self.check(true, "Expected admission rejection") }
                else { self.check(false, "\(reason), \(caller): must reject before transport") }
            }
            self.check(AdmissionURLProtocol.requestCount == count, "\(reason), \(caller): no HTTP request may be posted")
            self.check(owner.responseHandlerCount == 0 && owner.streamingText == "owned-before-request",
                "Rejected admission cannot reset command stream state or run response/tool continuation")
        }
    }

    static func main() async throws {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [AdmissionURLProtocol.self]
        NormalDictationHTTPConfiguration.make = {
            let configuration = URLSessionConfiguration.ephemeral
            configuration.protocolClasses = [AdmissionURLProtocol.self]
            return configuration
        }
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        self.commandClient = LLMClient(session: session)
        let remote = MeetingSummaryRemoteService(session: session)
        if let caller = ProcessInfo.processInfo.environment["PICHI_NORMAL_DICTATION_ADMISSION_PENDING_ONLY"] {
            try await self.normalPendingProbe(caller: caller)
            print("PASS: actual normal dictation pending-credential probe; no HTTP")
            return
        }
        if ProcessInfo.processInfo.environment["PICHI_TEMPLATE_UI_ADMISSION_PENDING_ONLY"] == "1" {
            try await self.templatePendingProbe()
            self.check(AdmissionURLProtocol.requestCount == 0, "Pending click probe must post no HTTP request")
            print("PASS: actual Template Generate pending-credential probe; no controller dispatch or HTTP")
            return
        }
        try await self.templatePendingProbe()
        try await self.refreshAdmission(remote)
        try await self.keylessAdmission(remote)
        try await self.aliasAndStaleConfiguration(remote)
        try await self.localAPIAdmission()
        try await self.normalDictationAdmission()
        self.check(AdmissionURLProtocol.requestCount == 52 && AdmissionURLProtocol.unexpectedURLCount == 0,
            "All 52 expected positive requests are intercepted; unknown URLs fail closed")
        if let path = ProcessInfo.processInfo.environment["PICHI_ADMISSION_REPORT_PATH"] {
            let report: [String: Any] = [
                "status": "PASS", "admission_assertions": self.checks,
                "intercepted_requests": AdmissionURLProtocol.requestCount,
                "unexpected_urls": AdmissionURLProtocol.unexpectedURLCount,
                "credential_backend": "injected_only", "transport": "explicit_session_protocol_classes",
                "tested_callers": ["MeetingSummaryRoute.resolve + RemoteService + LLMClient", "TemplateMeetingSummaryView.generate + fresh resolveRoute + recorded controller dispatch + RemoteService + LLMClient", "CommandModeService.callLLM + LLMClient", "InferenceAPIController.handle + DictationPostProcessingService.process + LLMClient", "DictationStopSnapshot.capture + ContentView post-ASR AI/raw fallback block + processTextWithAIMetrics + LLMClient", "ContentView explicit/global processTextWithAIMetrics + LLMClient", "AppServices selectedRoute + actual prewarmLocalModel and LocalAIModelResidencyTransport.isReady"],
                "revision": ProcessInfo.processInfo.environment["PICHI_ADMISSION_SOURCE_REVISION"] ?? "unknown",
                "source_dirty": ProcessInfo.processInfo.environment["PICHI_ADMISSION_SOURCE_DIRTY"] != "0",
            ]
            try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: URL(fileURLWithPath: path))
        }
        print("PASS: \(self.checks) summary, template UI, command, API, dictation and warming credential admission checks; production storage/operations/HTTP, injected backend and intercepted requests only")
    }

    private static func templatePendingProbe() async throws {
        let backend = AdmissionBackend(["openai": "synthetic-key"])
        let (settings, service, selection) = self.fixture(backend)
        await self.load(service)
        let owner = TemplateSummaryAdmissionOwner(selection: selection, settings: settings)
        owner.route = try MeetingSummaryRoute.resolve(selection, settings: settings)
        backend.failNextReadWhileBlocked()
        var settled = false
        self.check(service.loadInBackground { _ in settled = true }, "Template pending refresh admitted")
        await self.waitUntil { backend.isBlocked }
        self.check(service.loadedKeys == nil && settings.commandModeModelCatalog().contains { $0.providerID == "openai" },
            "Actual template click starts with old verified display data but no loaded credential snapshot")
        owner.generate()
        self.check(owner.controller.dispatchCount == 0 && owner.route == nil && owner.readinessIssue != nil,
            "Actual Generate must invalidate the formerly verified cached route before any controller dispatch")
        backend.unblockFailure()
        await self.waitUntil { settled && service.readiness == .unavailable }
    }

    private static func refreshAdmission(_ remote: MeetingSummaryRemoteService) async throws {
        let backend = AdmissionBackend(["openai": "synthetic-key"])
        let (settings, service, selection) = self.fixture(backend)
        await self.load(service)
        let before = try await self.send(selection, settings: settings, remote: remote)
        self.check(before.apiKey == "synthetic-key" && AdmissionURLProtocol.lastAuthorization == "Bearer synthetic-key", "Loaded verified credential reaches the actual intercepted request")
        self.check(AdmissionURLProtocol.lastURL == "\(before.baseURL)/chat/completions", "Both callers use the fingerprint-bound endpoint")
        let reads = backend.readCount
        _ = try MeetingSummaryRoute.resolve(selection, settings: settings)
        self.check(backend.readCount == reads, "Resolution is cache-only")
        backend.failNextReadWhileBlocked()
        var failedRefreshFinished = false
        self.check(service.loadInBackground { result in
            if case .success = result { fputs("FAIL: expected synthetic refresh failure\n", stderr); exit(1) }
            failedRefreshFinished = true
        }, "Failed refresh admitted")
        await self.waitUntil { backend.isBlocked }
        self.check(service.readiness == .pending && service.loadedKeys == nil, "Blocked refresh has no authoritative snapshot")
        self.check(settings.commandModeModelCatalog().contains { $0.providerID == "openai" }, "UI preserves its verified display cache while pending")
        await self.rejects(selection, settings: settings, remote: remote, reason: "Pending refresh")
        self.check(backend.readCount == reads + 1, "Pending resolution must not enqueue a credential read")
        backend.unblockFailure()
        await self.waitUntil { failedRefreshFinished && service.readiness == .unavailable }
        self.check(service.cachedKeys == ["openai": "synthetic-key"] && service.loadedKeys == nil, "Failed refresh keeps display cache without treating failure as loaded empty")
        self.check(settings.commandModeModelCatalog().contains { $0.providerID == "openai" }, "UI remains visible after failure")
        await self.rejects(selection, settings: settings, remote: remote, reason: "Unavailable credentials")
        self.check(backend.readCount == reads + 1, "Unavailable resolution remains cache-only")
        await self.load(service)
        _ = try await self.send(selection, settings: settings, remote: remote)
        self.check(AdmissionURLProtocol.lastAuthorization == "Bearer synthetic-key", "Successful load recovery restores verified admission")
        SettingsStore.shared = settings
        let admittedOwner = CommandAdmissionOwner(llmClient: self.commandClient)
        AdmissionURLProtocol.holdNextResponse()
        let admittedTask = Task { try await admittedOwner.send() }
        await self.waitUntil { AdmissionURLProtocol.hasDeferredResponse }
        self.check(AdmissionURLProtocol.lastAuthorization == "Bearer synthetic-key", "Admitted command freezes its verified key before HTTP awaits")
        backend.replace(["openai": "replacement-key"])
        await self.load(service)
        await self.rejects(selection, settings: settings, remote: remote, reason: "Loaded credential fingerprint changed")
        AdmissionURLProtocol.releaseResponse()
        let admittedResult = try await admittedTask.value
        self.check(admittedResult == "Synthetic summary" && admittedOwner.responseHandlerCount == 1,
            "An already admitted command retains its immutable context while later admissions reject changed credentials")
        self.check(before.apiKey == "synthetic-key", "Already resolved attempts retain their immutable credential")
        self.check(backend.interactiveAccessCount == 0 && settings.writes.isEmpty, "Admission does not prompt, persist or alter verification")
    }

    private static func keylessAdmission(_ remote: MeetingSummaryRemoteService) async throws {
        for endpoint in ["https://keyless.example/v1", "https://192.168.1.40/v1"] {
            let backend = AdmissionBackend([:])
            let (settings, service, selection) = self.fixture(backend, provider: "keyless", endpoint: endpoint, key: "")
            self.check(service.loadedKeys == nil, "Cold credentials are unknown rather than loaded empty")
            let cold = try await self.send(selection, settings: settings, remote: remote)
            self.check(cold.apiKey.isEmpty && AdmissionURLProtocol.lastAuthorization == nil, "Explicit empty-key verification permits a keyless endpoint without forced credential I/O")
            self.check(AdmissionURLProtocol.lastURL == "\(endpoint)/chat/completions", "Keyless request keeps its explicitly verified endpoint")
            self.check(backend.readCount == 0, "Verified keyless cold route performs no credential read")
            await self.load(service)
            self.check(service.loadedKeys == [:], "Loaded empty is represented distinctly")
            _ = try await self.send(selection, settings: settings, remote: remote)
            self.check(backend.readCount == 1, "Loaded-empty keyless resolution performs no additional read")
            settings.verifiedProviderFingerprints = [:]
            await self.rejects(selection, settings: settings, remote: remote, reason: "Unverified keyless endpoint")
            self.check(backend.interactiveAccessCount == 0, "Keyless routes never trigger authentication")
        }
        let backend = AdmissionBackend([:])
        let (settings, _, selection) = self.fixture(backend, provider: "unknown", endpoint: "https://unknown.example/v1", key: "")
        settings.savedProviders = []
        await self.rejects(selection, settings: settings, remote: remote, reason: "Unknown provider despite forged empty-key verification")
        self.check(backend.readCount == 0, "Unknown route cannot initiate credential loading")
    }

    private static func aliasAndStaleConfiguration(_ remote: MeetingSummaryRemoteService) async throws {
        let backend = AdmissionBackend(["alias": "exact-key", "custom:alias": "stale-canonical-key"])
        let options = ["project": "verified-project"]
        let (settings, service, raw) = self.fixture(backend, provider: "alias", endpoint: "https://alias.example/v1", key: "exact-key", options: options)
        settings.providerConnectionOptions["custom:alias"] = ["project": "unverified-alias-project"]
        await self.load(service)
        let selection = MeetingSummarySelection(providerID: "custom:alias", modelsByProvider: raw.modelsByProvider)
        settings.selectedProviderID = selection.providerID
        let route = try await self.send(selection, settings: settings, remote: remote)
        self.check(route.providerID == "alias" && route.apiKey == "exact-key", "Canonical selection freezes actual registered identity and exact-ID credential precedence")
        self.check(route.connectionOptions == options, "Request options are those bound by the verified catalog, not conflicting alias values")
        self.check(AdmissionURLProtocol.lastAuthorization == "Bearer exact-key", "Actual request uses the verified exact-ID key")
        self.check(AdmissionURLProtocol.lastURL == "https://alias.example/v1/chat/completions", "Alias resolution freezes its verified registered endpoint")
        let reads = backend.readCount
        settings.providerConnectionOptions["alias"] = ["project": "changed-project"]
        await self.rejects(selection, settings: settings, remote: remote, reason: "Stale connection options")
        settings.providerConnectionOptions["alias"] = options
        settings.savedProviders = [.init(id: "alias", name: "Synthetic provider", baseURL: "https://changed.example/v1", models: ["synthetic-model"])]
        await self.rejects(selection, settings: settings, remote: remote, reason: "Stale endpoint")
        settings.savedProviders = [.init(id: "alias", name: "Synthetic provider", baseURL: "https://alias.example/v1", models: ["synthetic-model"])]
        settings.availableModelsByProvider["custom:alias"] = ["replacement-model"]
        self.check(settings.verifiedChatModelConfiguration(providerID: "alias", modelID: "synthetic-model") == nil,
            "The shared boundary refuses a stale explicit model")
        await self.rejects(selection, settings: settings, remote: remote, reason: "Selected summary model no longer belongs to provider", callers: ["summary", "template"])
        _ = try await self.sendCommand(settings: settings)
        self.check(AdmissionURLProtocol.lastModel == "replacement-model", "Command Mode retains its existing fallback to the current eligible model")
        settings.availableModelsByProvider["custom:alias"] = ["text-embedding-fixture"]
        await self.rejects(selection, settings: settings, remote: remote, reason: "Provider has no currently eligible chat model")
        self.check(backend.readCount == reads && backend.interactiveAccessCount == 0, "All stale-configuration rejections remain cache-only")
    }

    private static func localAPIRequest(settings: SettingsStore) async throws -> LocalAPI.Response {
        SettingsStore.shared = settings
        let controller = InferenceAPIController(fileTranscriber: { _ in fatalError("No audio fixture may run") },
            textPostprocessor: { try await DictationPostProcessingService.shared.process($0, client: self.commandClient) })
        let request = LocalAPI.Request(method: "POST", path: "/v1/postprocess", query: [:],
            headers: ["content-type": "application/json"],
            body: try JSONSerialization.data(withJSONObject: ["text": "Synthetic local API text."]))
        return await controller.handle(request)
    }
    private static func localAPIRejects(settings: SettingsStore, reason: String) async throws {
        let requests = AdmissionURLProtocol.requestCount
        let privateCalls = PrivateAIIntegrationService.shared.calls
        let response = try await self.localAPIRequest(settings: settings)
        self.check(response.status == 400, "\(reason): Local API rejects before request admission; new intercepted requests=\(AdmissionURLProtocol.requestCount - requests), authorization present=\(AdmissionURLProtocol.lastAuthorization != nil)")
        self.check(AdmissionURLProtocol.requestCount == requests, "\(reason): no intercepted HTTP request")
        self.check(PrivateAIIntegrationService.shared.calls == privateCalls && MeetingSummaryActivityCoordinator.shared.activeCount == 0,
            "Rejected API admission has no adapter effect or retained processing ownership")
    }
    private static func localAPIAdmission() async throws {
        let endpoint = "http://127.0.0.1:1234/v1"
        let backend = AdmissionBackend(["custom:api-local": "synthetic-local-key"])
        let (settings, service, _) = self.fixture(backend, provider: "api-local", endpoint: endpoint, key: "synthetic-local-key")
        settings.privateCapabilityReady = false
        settings.selectsPrivateCapability = false
        try await self.localAPIRejects(settings: settings, reason: "Cold pending keyed local provider")
        self.check(backend.readCount == 0 && service.loadedKeys == nil, "Cold API rejection does not load unknown credentials")
        await self.load(service)
        let loaded = try await self.localAPIRequest(settings: settings)
        self.check(loaded.status == 200 && AdmissionURLProtocol.lastAuthorization == "Bearer synthetic-local-key",
            "Actual Local API operation sends the authoritative local credential")
        self.check(AdmissionURLProtocol.lastURL == "\(endpoint)/chat/completions", "API request uses its fingerprint-bound local endpoint")
        backend.failNextReadWhileBlocked()
        var refreshFinished = false
        self.check(service.loadInBackground { _ in refreshFinished = true }, "API refresh admitted")
        await self.waitUntil { backend.isBlocked }
        let reads = backend.readCount
        try await self.localAPIRejects(settings: settings, reason: "Blocked local refresh with cached key")
        self.check(service.cachedKeys != nil && service.loadedKeys == nil && backend.readCount == reads,
            "Pending API admission ignores display cache without credential I/O")
        backend.unblockFailure()
        await self.waitUntil { refreshFinished && service.readiness == .unavailable }
        try await self.localAPIRejects(settings: settings, reason: "Failed local refresh with cached key")
        self.check(settings.providerAPIKeys["custom:api-local"] == "synthetic-local-key" && backend.readCount == reads,
            "Failed API refresh retains UI data but rejects admission without rereading")
        await self.load(service)
        let recovered = try await self.localAPIRequest(settings: settings)
        self.check(recovered.status == 200 && AdmissionURLProtocol.lastAuthorization == "Bearer synthetic-local-key",
            "Authoritative API recovery restores the verified key")
        AdmissionURLProtocol.holdNextResponse()
        let admittedTask = Task { try await self.localAPIRequest(settings: settings) }
        await self.waitUntil { AdmissionURLProtocol.hasDeferredResponse }
        let admittedRequests = AdmissionURLProtocol.requestCount
        self.check(AdmissionURLProtocol.lastAuthorization == "Bearer synthetic-local-key"
            && AdmissionURLProtocol.lastURL == "\(endpoint)/chat/completions"
            && AdmissionURLProtocol.lastModel == "synthetic-model",
            "Admitted API freezes the verified credential, endpoint and model before HTTP awaits")
        backend.replace(["custom:api-local": "replacement-local-key"])
        await self.load(service)
        self.check(settings.loadedProviderAPIKeys == ["custom:api-local": "replacement-local-key"]
            && AdmissionURLProtocol.requestCount == admittedRequests
            && MeetingSummaryActivityCoordinator.shared.activeCount == 1,
            "Credential refresh changes only future API admissions while the current operation owns processing")
        AdmissionURLProtocol.releaseResponse()
        let admittedResult = try await admittedTask.value
        let admittedBody = try JSONSerialization.jsonObject(with: admittedResult.body) as? [String: String]
        self.check(admittedResult.status == 200 && admittedBody?["text"] == "Synthetic summary"
            && admittedBody?["provider"] == "api-local" && admittedBody?["model"] == "synthetic-model"
            && MeetingSummaryActivityCoordinator.shared.activeCount == 0,
            "The already admitted API completes with its frozen result and releases processing ownership")
        try await self.localAPIRejects(settings: settings, reason: "Changed loaded local credential cannot reuse old verification")
        backend.replace([:])
        await self.load(service)
        try await self.localAPIRejects(settings: settings, reason: "Loaded empty cannot reuse old keyed verification")
        settings.verifiedProviderFingerprints["custom:api-local"] = CloudTextProvider.connectionFingerprint(baseURL: endpoint, apiKey: "")
        let keyless = try await self.localAPIRequest(settings: settings)
        self.check(service.loadedKeys == [:] && keyless.status == 200 && AdmissionURLProtocol.lastAuthorization == nil,
            "Explicitly verified loaded-empty local route remains legitimately keyless")
        settings.verifiedProviderFingerprints = [:]
        try await self.localAPIRejects(settings: settings, reason: "Unverified empty local route")
        self.check(backend.interactiveAccessCount == 0, "API never prompts for credentials")

        let privateBackend = AdmissionBackend([:])
        let (privateSettings, privateService, _) = self.fixture(privateBackend)
        privateSettings.selectsPrivateCapability = true
        privateSettings.privateCapabilityReady = true
        let requests = AdmissionURLProtocol.requestCount
        let privateResult = try await self.localAPIRequest(settings: privateSettings)
        self.check(privateResult.status == 200 && privateBackend.readCount == 0 && privateService.loadedKeys == nil,
            "Verified private dictation capability stays credential independent")
        self.check(AdmissionURLProtocol.requestCount == requests && PrivateAIIntegrationService.shared.calls == 1,
            "Private capability uses the existing adapter boundary without HTTP")
        privateSettings.privateCapabilityReady = false
        try await self.localAPIRejects(settings: privateSettings, reason: "Unverified private capability")
        privateSettings.selectsPrivateCapability = false
    }
}
