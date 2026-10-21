import Combine
import Foundation

@MainActor
final class PichiMeetingSummarySettings: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case local, configuredProvider
        var id: String { self.rawValue }
        var title: String { self == .local ? PichiLocalization.text("Local API endpoint") : PichiLocalization.text("Configured AI provider") }
    }

    enum TimeBudget: String, CaseIterable, Identifiable {
        case standard, extended
        var id: String { self.rawValue }
        var title: String {
            self == .standard ? PichiLocalization.text("Standard: up to 10 minutes") : PichiLocalization.text("Extended: up to 60 minutes")
        }
        var execution: PichiMeetingSummaryExecution { self == .standard ? .standard : .extended }
    }

    private let defaults: UserDefaults
    @Published var mode: Mode { didSet { self.defaults.set(self.mode.rawValue, forKey: "PichiMeetingSummaryMode") } }
    @Published var baseURL: String {
        didSet {
            self.defaults.set(self.baseURL, forKey: "PichiMeetingSummaryBaseURL")
            self.models = []
            self.discoveryIssue = nil
        }
    }
    @Published var modelID: String { didSet { self.defaults.set(self.modelID, forKey: "PichiMeetingSummaryModelID") } }
    @Published var timeBudget: TimeBudget { didSet { self.defaults.set(self.timeBudget.rawValue, forKey: "PichiMeetingSummaryTimeBudget") } }
    @Published var language: String { didSet { self.defaults.set(self.language, forKey: "PichiMeetingSummaryLanguage") } }
    @Published private(set) var models: [String] = []
    @Published private(set) var discovering = false
    @Published private(set) var discoveryIssue: PichiMeetingSummaryDiscoveryIssue?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = Mode(rawValue: defaults.string(forKey: "PichiMeetingSummaryMode") ?? "") ?? .local
        self.baseURL = defaults.string(forKey: "PichiMeetingSummaryBaseURL") ?? "http://127.0.0.1:11434/v1"
        self.modelID = defaults.string(forKey: "PichiMeetingSummaryModelID") ?? "qwen3.5:4b"
        self.timeBudget = TimeBudget(rawValue: defaults.string(forKey: "PichiMeetingSummaryTimeBudget") ?? "") ?? .standard
        self.language = defaults.string(forKey: "PichiMeetingSummaryLanguage") ?? "ru"
    }

    var selectionIdentity: String { "\(self.mode.rawValue)|\(self.baseURL)|\(self.modelID)|\(self.language)|\(self.timeBudget.rawValue)" }

    func configuration(sessionLanguage: String, settings: SettingsStore? = nil) throws -> PichiMeetingSummaryConfiguration {
        let settings = settings ?? .shared
        let outputLanguage = self.language == "transcript" ? sessionLanguage : self.language
        if self.mode == .local {
            guard PichiMeetingSummaryConfiguration.isLoopback(self.baseURL) else { throw PichiMeetingSummaryError.localEndpointRequired }
            let provider = ModelRepository.shared.localTextModelProvider(for: self.baseURL) ?? "pichi-local"
            let config = PichiMeetingSummaryConfiguration(providerID: "pichi-local", modelID: self.modelID,
                                                         baseURL: self.baseURL, apiKey: "", language: outputLanguage,
                                                         execution: self.execution(model: self.modelID, provider: provider, settings: settings))
            try config.validate()
            return config
        }
        let id = settings.selectedProviderID
        guard !id.isEmpty else { throw PichiMeetingSummaryError.notConfigured }
        guard id != "anthropic", id != PrivateAIProviderFeature.shared.providerID else { throw PichiMeetingSummaryError.unsupportedProvider }
        let preferred = ModelRepository.shared.providerKeys(for: id).compactMap { settings.selectedModelByProvider[$0] }
            .first { !$0.isEmpty } ?? settings.selectedModel
        let model = preferred ?? ModelRepository.shared.defaultModels(for: id).first ?? ""
        let selection = MeetingSummarySelection(providerID: id,
            modelsByProvider: [ModelRepository.shared.providerKey(for: id): model])
        let route = try MeetingSummaryRoute.resolve(selection, settings: settings)
        return try route.groundedConfiguration(language: outputLanguage,
            execution: self.execution(model: model, provider: id, settings: settings))
    }

    private func execution(model: String, provider: String, settings: SettingsStore) -> PichiMeetingSummaryExecution {
        var execution = self.timeBudget.execution
        if let reasoning = settings.getReasoningConfig(forModel: model, provider: provider), reasoning.isEnabled {
            execution.reasoningParameter = reasoning.parameterName
            execution.reasoningValue = reasoning.parameterValue
        }
        return execution
    }

    func localReasoningSelection(settings: SettingsStore) -> String {
        guard let provider = ModelRepository.shared.localTextModelProvider(for: self.baseURL) else { return "default" }
        let key = "\(provider):\(self.modelID)"
        guard let config = settings.modelReasoningConfigs[key] else { return "default" }
        if !config.isEnabled { return "disabled" }
        if ["think", "enable_thinking", "thinking"].contains(config.parameterName), config.parameterValue == "true" { return "enabled" }
        return "configured"
    }

    func setLocalReasoningSelection(_ selection: String, settings: SettingsStore) {
        guard let provider = ModelRepository.shared.localTextModelProvider(for: self.baseURL) else { return }
        switch selection {
        case "default": settings.setReasoningConfig(nil, forModel: self.modelID, provider: provider)
        case "enabled": settings.setReasoningConfig(.init(parameterName: "enable_thinking", parameterValue: "true"), forModel: self.modelID, provider: provider)
        case "disabled": settings.setReasoningConfig(.disabled, forModel: self.modelID, provider: provider)
        default: break
        }
    }

    func discoverModels() async {
        guard !self.discovering else { return }
        self.discovering = true
        self.discoveryIssue = nil
        defer { self.discovering = false }
        let endpoint = self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard PichiMeetingSummaryConfiguration.isLoopback(endpoint), let base = URL(string: endpoint),
                  ["http", "https"].contains(base.scheme), base.user == nil, base.password == nil,
                  base.query == nil, base.fragment == nil
            else { throw PichiMeetingSummaryError.localEndpointRequired }
            let models = try await ModelRepository.shared.fetchModels(
                for: "local", baseURL: base.absoluteString, apiKey: nil,
                session: PichiMeetingSummaryTransport.session
            )
            try Task.checkCancellation()
            guard endpoint == self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self.models = models
            if self.models.isEmpty { self.discoveryIssue = .noInstalledModels }
        } catch is CancellationError {
            self.discoveryIssue = nil
        } catch {
            guard endpoint == self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            self.models = []
            self.discoveryIssue = .localServerUnavailable
        }
    }
}

/// Store UI intent, not a translation chosen when discovery happened.
nonisolated enum PichiMeetingSummaryDiscoveryIssue: Equatable, Sendable {
    case noInstalledModels, localServerUnavailable

    func text(language: PichiInterfaceLanguage = PichiLocalization.language, bundle: Bundle = .main) -> String {
        switch self {
        case .noInstalledModels:
            return PichiLocalization.text("No installed models found. Install a model in Ollama or LM Studio, then refresh.", language: language, bundle: bundle)
        case .localServerUnavailable:
            return PichiLocalization.text("Could not list local models. Start Ollama or LM Studio's local server and check the endpoint.", language: language, bundle: bundle)
        }
    }
}

nonisolated struct PichiMeetingSummaryProgress: Equatable, Sendable {
    let index: Int
    let total: Int

    func text(language: PichiInterfaceLanguage = PichiLocalization.language, bundle: Bundle = .main) -> String {
        PichiLocalization.format("Processing transcript part %lld of %lld…", language: language, bundle: bundle, arguments: [self.index, self.total])
    }
}

/// Preserve typed application errors and external error data until the view renders.
private enum PichiMeetingSummaryFailure {
    case noSavedDirectory
    case underlying(any Error)

    var text: String {
        switch self {
        case .noSavedDirectory:
            return PichiLocalization.text("The summary is ready, but this meeting has no saved directory yet.")
        case let .underlying(error):
            return String(error.localizedDescription.prefix(500))
        }
    }
}


@MainActor
final class PichiMeetingSummaryController: ObservableObject {
    @Published private(set) var document: PichiMeetingSummaryDocument?
    @Published private(set) var generating = false
    @Published private(set) var checking = false
    @Published private(set) var documentIsHistorical = false
    @Published private(set) var progressState: PichiMeetingSummaryProgress?
    @Published private var failure: PichiMeetingSummaryFailure?
    // Keep source state until presentation so a language change never restarts inference.
    var progress: String { self.progressState?.text() ?? "" }
    var error: String? { self.failure?.text }
    /// The app owns active work; views may disappear and later reattach by session ID.
    var generationStateChanged: ((PichiMeetingSummaryController) -> Void)?
    let sessionID: UUID?
    var presentedConfiguration: PichiMeetingSummaryConfiguration? { self.activeConfiguration ?? self.documentConfiguration }
    var sourceSession: MeetingSession? { self.activeSourceSession ?? self.documentSourceSession }
    private var activeConfiguration: PichiMeetingSummaryConfiguration?
    private var activeSourceSession: MeetingSession?
    private(set) var documentConfiguration: PichiMeetingSummaryConfiguration?
    private(set) var documentSourceSession: MeetingSession?
    private var operation: Task<Void, Never>?
    private var generationID = UUID()
    private let generator: PichiMeetingSummaryGenerator

    init(sessionID: UUID? = nil, generator: PichiMeetingSummaryGenerator = .init()) {
        self.sessionID = sessionID
        self.generator = generator
    }

    /// Destination disclosure and the next action must use the same configuration.
    /// A saved document's provenance never authorizes a new request to its old endpoint.
    func requestConfiguration(current: PichiMeetingSummaryConfiguration?) -> PichiMeetingSummaryConfiguration? {
        self.generating ? self.activeConfiguration : current
    }

    func refresh(session: MeetingSession?, configuration: PichiMeetingSummaryConfiguration?) async {
        // Navigation and settings edits must not cancel or retarget an admitted attempt.
        guard !self.generating, self.sessionID == nil || session?.id == self.sessionID else { return }
        let generationID = UUID()
        self.generationID = generationID
        self.documentConfiguration = configuration
        self.documentSourceSession = session
        self.document = nil
        self.documentIsHistorical = false
        self.failure = nil
        self.checking = false
        guard let session, let configuration else { return }
        self.checking = true
        defer { if self.generationID == generationID { self.checking = false } }
        let hash = PichiMeetingSummaryInput.fingerprint(session)
        var resolved = configuration
        var historical = false
        do { resolved.modelArtifactID = try await self.generator.resolveArtifact(configuration) }
        catch let error as URLError where [.cannotConnectToHost, .cannotFindHost, .networkConnectionLost, .notConnectedToInternet, .timedOut].contains(error.code) {
            historical = true
        } catch { return }
        guard self.generationID == generationID, !Task.isCancelled else { return }
        let identity = resolved.cacheIdentity
        let baseIdentity = configuration.baseCacheIdentity
        let offline = historical
        let cached = await Task.detached(priority: .utility) { () -> PichiMeetingSummaryArtifact? in
            guard let directory = try? await MeetingSessionStore.shared.existingSessionDirectory(for: session.id),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("pichi-meeting-summary.json")),
                  let artifact = try? JSONDecoder().decode(PichiMeetingSummaryArtifact.self, from: data),
                  artifact.transcriptHash == hash,
                  artifact.baseConfigurationIdentity == baseIdentity,
                  (offline || artifact.configurationIdentity == identity),
                  let validated = try? artifact.validated(for: session)
            else { return nil }
            return validated
        }.value
        guard self.generationID == generationID, !Task.isCancelled else { return }
        if let cached {
            resolved.modelArtifactID = cached.modelArtifactID
            self.documentConfiguration = resolved
        }
        self.document = cached?.document
        self.documentIsHistorical = historical && cached != nil
    }

    func summarize(session: MeetingSession, configuration: PichiMeetingSummaryConfiguration, asr: ASRService) {
        guard !self.generating, !self.checking,
              self.sessionID == nil || session.id == self.sessionID,
              let lock = MeetingSummaryActivityCoordinator.shared.lockSelection() else { return }
        self.activeConfiguration = configuration
        self.activeSourceSession = session
        self.generating = true
        self.generationStateChanged?(self)
        self.failure = nil
        let generationID = self.generationID
        self.operation = Task { [weak self] in
            guard let self else { MeetingSummaryActivityCoordinator.shared.unlockSelection(lock); return }
            defer {
                self.activeConfiguration = nil
                self.activeSourceSession = nil
                self.generating = false
                self.operation = nil
                self.progressState = nil
                MeetingSummaryActivityCoordinator.shared.unlockSelection(lock)
                self.generationStateChanged?(self)
            }
            do {
                try Task.checkCancellation()
                let result = try await self.generateWithProvenance(session: session, configuration: configuration, asr: asr)
                let output = result.document
                try Task.checkCancellation()
                guard self.generationID == generationID else { return }
                self.documentConfiguration = result.configuration
                self.documentIsHistorical = false
                self.documentSourceSession = session
                self.document = output
                let hash = PichiMeetingSummaryInput.fingerprint(session)
                let artifact = PichiMeetingSummaryArtifact(version: 6, transcriptHash: hash,
                                                          configurationIdentity: result.configuration.cacheIdentity,
                                                          generatedAt: Date(), document: output,
                                                          baseConfigurationIdentity: configuration.baseCacheIdentity,
                                                          modelArtifactID: result.configuration.modelArtifactID)
                guard let directory = try await MeetingSessionStore.shared.existingSessionDirectory(for: session.id) else {
                    self.failure = .noSavedDirectory
                    return
                }
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) {
                    try JSONEncoder().encode(artifact).write(to: directory.appendingPathComponent("pichi-meeting-summary.json"), options: .atomic)
                }.value
            } catch let error as PichiMeetingSummaryCleanupError {
                if self.generationID == generationID { self.failure = .underlying(error) }
            } catch is CancellationError {
                self.failure = nil
            } catch {
                if self.generationID == generationID, !Task.isCancelled { self.failure = .underlying(error) }
            }
        }
    }

    func generate(session: MeetingSession, configuration: PichiMeetingSummaryConfiguration, asr: ASRService) async throws -> PichiMeetingSummaryDocument {
        try await self.generateWithProvenance(session: session, configuration: configuration, asr: asr).document
    }

    private func generateWithProvenance(session: MeetingSession, configuration: PichiMeetingSummaryConfiguration, asr: ASRService) async throws -> PichiMeetingSummaryGeneration {
        try await MeetingSummaryActivityCoordinator.shared.withSummary(activity: asr) {
            try await asr.withMeetingModelResidency(attemptID: UUID()) {
                try asr.markMeetingSummaryPhase()
                return try await self.generator.generateWithProvenance(session: session, configuration: configuration) { [weak self] index, total in
                    await self?.updateProgress(index: index, total: total)
                }
            }
        }
    }

    private func updateProgress(index: Int, total: Int) { self.progressState = .init(index: index, total: total) }
    func cancel() { self.operation?.cancel() }
}
