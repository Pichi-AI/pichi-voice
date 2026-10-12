import CryptoKit
import Foundation

/// The native adapter reads this policy from its concurrent request builder.
/// Retain only hashed endpoint/model identities, never provider credentials.
nonisolated final class LocalAIModelResidencyPolicy: @unchecked Sendable {
    static let shared = LocalAIModelResidencyPolicy()
    private let lock = NSLock()
    private var pins: Set<String> = []

    func pin(baseURL: String, model: String) {
        guard let key = Self.identity(baseURL: baseURL, model: model) else { return }
        self.lock.withLock { _ = self.pins.insert(key) }
    }

    func unpin(baseURL: String, model: String) {
        guard let key = Self.identity(baseURL: baseURL, model: model) else { return }
        self.lock.withLock { _ = self.pins.remove(key) }
    }

    func isPinned(baseURL: String, model: String) -> Bool {
        guard let key = Self.identity(baseURL: baseURL, model: model) else { return false }
        return self.lock.withLock { self.pins.contains(key) }
    }

    static func canonicalModel(_ model: String) -> String {
        let model = model.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !model.isEmpty else { return "" }
        return model.split(separator: "/").last?.contains(":") == true ? model : "\(model):latest"
    }

    static func identity(baseURL: String, model: String) -> String? {
        guard OllamaChatAdapter.supports(baseURL), !self.canonicalModel(model).isEmpty,
              var endpoint = URLComponents(string: baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { return nil }
        endpoint.scheme = endpoint.scheme?.lowercased()
        // supports() accepts only the standard on-device daemon on port 11434.
        // Its loopback aliases must share retention when a command/rewrite uses
        // the built-in connection and dictation uses a saved connection.
        endpoint.host = "localhost"
        endpoint.path = "/v1"
        guard let normalized = endpoint.string else { return nil }
        return SHA256.hash(data: Data("\(normalized)\n\(self.canonicalModel(model))".utf8))
            .map { String(format: "%02x", $0) }.joined()
    }
}

/// One owner for the lifetime of the app, including while its main window is hidden.
/// Polling reads residency only; generation happens on selection, eviction or drift.
@MainActor
final class LocalAIModelResidencyController {
    struct Dependencies {
        var selectedRoute: () -> DictationProviderRoute?
        var canWarm: () -> Bool
        var warm: (DictationProviderRoute) async throws -> Void
        var isReady: (DictationProviderRoute) async throws -> Bool
        var release: (DictationProviderRoute) async -> Bool
        var releaseForTermination: ((DictationProviderRoute) async -> Bool)? = nil
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
        var interval: TimeInterval = 60
    }

    private let dependencies: Dependencies
    private let policy: LocalAIModelResidencyPolicy
    private var events: AsyncStream<Void>.Continuation?
    private var runner: Task<Void, Never>?
    private var ticker: Task<Void, Never>?
    private var warmup: Task<Void, Error>?
    private var probe: Task<Bool, Error>?
    private var selected: DictationProviderRoute?
    private var pendingReleases: [String: DictationProviderRoute] = [:]
    private var ready = false
    private var lastProbe: TimeInterval = -.infinity
    private var retryAfter: TimeInterval = 0
    private var failures = 0
    private var terminating = false

    /// A read-only lifetime diagnostic; completion includes the joined transport.
    var hasPendingOperation: Bool { self.warmup != nil || self.probe != nil }

    init(dependencies: Dependencies, policy: LocalAIModelResidencyPolicy = .shared) {
        self.dependencies = dependencies
        self.policy = policy
    }

    func start() {
        guard self.runner == nil, !self.terminating else { return }
        let stream = AsyncStream<Void>(bufferingPolicy: .bufferingNewest(1)) { self.events = $0 }
        self.runner = Task { [weak self] in
            for await _ in stream {
                guard let self, !Task.isCancelled else { break }
                await self.reconcile()
            }
        }
        let sleep = self.dependencies.sleep
        let interval = self.dependencies.interval
        self.ticker = Task { [weak self] in
            while !Task.isCancelled {
                do { try await sleep(interval) } catch { break }
                guard !Task.isCancelled else { break }
                self?.refresh()
            }
        }
        self.refresh()
    }

    func refresh() {
        guard !self.terminating else { return }
        if self.identity(self.dependencies.selectedRoute()) != self.identity(self.selected) {
            // Remove retention immediately, but never admit another runner until
            // the old warmup and its owned native transport have actually drained.
            if let selected { self.policy.unpin(baseURL: selected.baseURL, model: selected.model) }
            self.warmup?.cancel()
            self.probe?.cancel()
        }
        self.events?.yield(())
    }

    func shutdown() async {
        guard !self.terminating else { return }
        self.terminating = true
        self.events?.finish()
        self.ticker?.cancel()
        self.runner?.cancel()
        self.warmup?.cancel()
        self.probe?.cancel()
        if let selected { self.policy.unpin(baseURL: selected.baseURL, model: selected.model) }
        await self.runner?.value
        await self.ticker?.value
        if let selected, let key = self.identity(selected) { self.pendingReleases[key] = selected }
        // Each native handback has a five-second overall budget. Begin them in
        // parallel so past selections cannot multiply the termination deadline.
        let releaseTasks = self.pendingReleases.values.map { route in
            Task { await (self.dependencies.releaseForTermination ?? self.dependencies.release)(route) }
        }
        for task in releaseTasks { _ = await task.value }
        self.pendingReleases.removeAll()
        self.selected = nil
        self.runner = nil
        self.ticker = nil
        self.events = nil
    }

    private func identity(_ route: DictationProviderRoute?) -> String? {
        route.flatMap { LocalAIModelResidencyPolicy.identity(baseURL: $0.baseURL, model: $0.model) }
    }

    private func reconcile() async {
        let desired = self.dependencies.selectedRoute()
        let desiredID = self.identity(desired)
        if desiredID != self.identity(self.selected) {
            let previous = self.selected
            self.selected = desiredID == nil ? nil : desired
            self.ready = false
            self.lastProbe = -.infinity
            self.retryAfter = 0
            self.failures = 0
            if let previous {
                self.policy.unpin(baseURL: previous.baseURL, model: previous.model)
                if let key = self.identity(previous) { self.pendingReleases[key] = previous }
            }
        } else if desiredID != nil {
            // Credential or nonsecret connection metadata changes update the next
            // request without downgrading the same selected artifact's retention.
            self.selected = desired
        }
        guard !Task.isCancelled, !self.terminating,
              self.identity(self.dependencies.selectedRoute()) == desiredID else { return }
        if let route = self.selected { self.policy.pin(baseURL: route.baseURL, model: route.model) }
        guard self.dependencies.canWarm() else { return }
        self.pendingReleases.removeValue(forKey: desiredID ?? "")
        for (key, previous) in self.pendingReleases {
            guard self.dependencies.canWarm(), !Task.isCancelled else { return }
            let released = await self.dependencies.release(previous)
            if released, !Task.isCancelled { self.pendingReleases.removeValue(forKey: key) }
        }
        guard !Task.isCancelled, let route = self.selected,
              self.identity(self.dependencies.selectedRoute()) == desiredID,
              self.dependencies.now() >= self.retryAfter else { return }

        if self.ready {
            guard self.dependencies.now() - self.lastProbe >= self.dependencies.interval else { return }
            self.lastProbe = self.dependencies.now()
            let task = Task { try await self.dependencies.isReady(route) }
            self.probe = task
            let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
            self.probe = nil
            guard !Task.isCancelled, !self.terminating,
                  self.identity(self.dependencies.selectedRoute()) == desiredID else { return }
            switch result {
            case .success(true):
                self.failures = 0
                return
            case .success(false):
                self.ready = false
                DebugLogger.shared.info("resident_health ready=0", source: "LocalAIModelResidency")
            case .failure(let error):
                if !(error is CancellationError) { self.deferRetry() }
                return // An unavailable server is not proof that its runner was evicted.
            }
        }
        guard self.dependencies.canWarm(), !Task.isCancelled else { return }
        DebugLogger.shared.info("warm_start", source: "LocalAIModelResidency")
        let task = Task { try await self.dependencies.warm(route) }
        self.warmup = task
        let result = await withTaskCancellationHandler { await task.result } onCancel: { task.cancel() }
        self.warmup = nil
        guard !Task.isCancelled, !self.terminating,
              self.identity(self.dependencies.selectedRoute()) == desiredID else { return }
        switch result {
        case .success:
            self.ready = true
            self.lastProbe = self.dependencies.now()
            self.failures = 0
            self.retryAfter = 0
            DebugLogger.shared.info("warm_complete", source: "LocalAIModelResidency")
        case .failure(let error):
            if error is CancellationError || error is MeetingModelResidencyError { return }
            self.deferRetry()
        }
    }

    private func deferRetry() {
        self.failures = min(self.failures + 1, 5)
        let delay = min(900, self.dependencies.interval * pow(2, Double(self.failures - 1)))
        self.retryAfter = self.dependencies.now() + delay
        DebugLogger.shared.debug("resident_health available=0 retrySeconds=\(Int(delay))", source: "LocalAIModelResidency")
    }
}

/// Read-only native inspection and bounded retention handback. A missing runner
/// is never loaded solely to release it, and shared daemon models are not unloaded.
nonisolated enum LocalAIModelResidencyTransport {
    struct RunningModel: Decodable, Sendable {
        let name: String?
        let model: String?
        let context_length: Int?
        let expires_at: String?
    }

    static func isReady(_ route: DictationProviderRoute) async throws -> Bool {
        let models = try await self.runningModels(route)
        return self.isReady(models, model: route.model, now: Date())
    }

    static func isReady(_ models: [RunningModel], model: String, now: Date) -> Bool {
        models.contains {
            guard self.matches($0, model: model), $0.context_length == OllamaChatAdapter.defaultContextTokens,
                  let rawExpiry = $0.expires_at else { return false }
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            let fractional = formatter.date(from: rawExpiry)
            formatter.formatOptions = [.withInternetDateTime]
            guard let expiry = fractional ?? formatter.date(from: rawExpiry) else { return false }
            return expiry.timeIntervalSince(now) > 24 * 60 * 60
        }
    }

    /// Ordinary selection changes keep admission across both the read-only ps
    /// probe and the native empty chat. Summary takeover cancels and joins that
    /// entire handback before it can resize or load a shared runner.
    @MainActor
    static func releaseWhileIdle(
        _ route: DictationProviderRoute,
        residency: MeetingModelResidencyCoordinator = .shared,
        activity: MeetingSummaryActivityCoordinator = .shared,
        work: @escaping @MainActor (DictationProviderRoute) async -> Bool = { await Self.release($0) }
    ) async -> Bool {
        let pending = Task {
            try await residency.withBackgroundOperation(owner: "local-text", modelID: route.model) {
                await work(route)
            }
        }
        guard let token = activity.beginOptionalProcessing(cancelAndJoin: {
            pending.cancel()
            _ = await pending.result
        }) else {
            pending.cancel()
            _ = await pending.result
            return false
        }
        defer { activity.endProcessing(token) }
        let result = await withTaskCancellationHandler { await pending.result } onCancel: { pending.cancel() }
        guard case .success(let released) = result, !Task.isCancelled else { return false }
        return released
    }

    static func release(_ route: DictationProviderRoute, client: LLMClient = .shared) async -> Bool {
        guard LocalAIModelResidencyPolicy.identity(baseURL: route.baseURL, model: route.model) != nil else { return false }
        let work = Task { () -> Bool in
            do {
                let models = try await self.runningModels(route)
                guard let resident = models.first(where: { self.matches($0, model: route.model) }) else { return true }
                guard let context = resident.context_length,
                      (512...OllamaChatAdapter.maximumContextTokens).contains(context),
                      !LocalAIModelResidencyPolicy.shared.isPinned(baseURL: route.baseURL, model: route.model)
                else { return false }
                try Task.checkCancellation()
                var config = LLMClient.Config(messages: [], model: route.model, baseURL: route.baseURL,
                                              apiKey: route.apiKey, streaming: false,
                                              extraParameters: ["keep_alive": 60, "think": false,
                                                                "options": ["num_ctx": context]])
                config.providerOptions = route.connectionOptions
                config.timeoutSeconds = 5
                config.maxRetries = 1
                _ = try await client.call(config)
                try Task.checkCancellation()
                return true
            } catch {
                DebugLogger.shared.debug("retention_release available=0", source: "LocalAIModelResidency")
                return false
            }
        }
        let deadline = Task {
            do { try await Task.sleep(for: .seconds(5)) } catch { return }
            work.cancel()
        }
        let released = await withTaskCancellationHandler { await work.value } onCancel: { work.cancel() }
        deadline.cancel()
        return released && !Task.isCancelled
    }

    private static func matches(_ running: RunningModel, model: String) -> Bool {
        let selected = LocalAIModelResidencyPolicy.canonicalModel(model)
        return [running.model, running.name].compactMap { $0 }.contains {
            LocalAIModelResidencyPolicy.canonicalModel($0) == selected
        }
    }

    private static func runningModels(_ route: DictationProviderRoute) async throws -> [RunningModel] {
        guard OllamaChatAdapter.supports(route.baseURL),
              var endpoint = URLComponents(string: route.baseURL.trimmingCharacters(in: .whitespacesAndNewlines))
        else { throw LLMError.invalidURL }
        endpoint.path = "/api/ps"
        guard let url = endpoint.url else { throw LLMError.invalidURL }
        var request = URLRequest(url: url)
        request.timeoutInterval = 5
        if !route.apiKey.isEmpty { request.setValue("Bearer \(route.apiKey)", forHTTPHeaderField: "Authorization") }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.httpShouldSetCookies = false
        configuration.httpCookieStorage = nil
        configuration.timeoutIntervalForRequest = 5
        configuration.timeoutIntervalForResource = 5
        let lifetime = LLMClientSessionLifetime()
        let session = URLSession(configuration: configuration, delegate: lifetime, delegateQueue: nil)
        do {
            try Task.checkCancellation()
            let (data, response) = try await session.data(for: request)
            await lifetime.invalidateAndWait(for: session)
            try Task.checkCancellation()
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  data.count <= 1_048_576 else { throw LLMError.invalidResponse }
            struct Response: Decodable { let models: [RunningModel] }
            return try JSONDecoder().decode(Response.self, from: data).models
        } catch {
            await lifetime.invalidateAndWait(for: session)
            if Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
