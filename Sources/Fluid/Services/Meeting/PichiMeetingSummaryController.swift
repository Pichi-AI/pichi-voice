import Combine
import Foundation

@MainActor
final class PichiMeetingSummarySettings: ObservableObject {
    enum Mode: String, CaseIterable, Identifiable {
        case local, configuredProvider
        var id: String { self.rawValue }
        var title: String { self == .local ? "Local model on this Mac" : "Configured AI provider" }
    }

    private let defaults: UserDefaults
    @Published var mode: Mode { didSet { self.defaults.set(self.mode.rawValue, forKey: "PichiMeetingSummaryMode") } }
    @Published var baseURL: String {
        didSet {
            self.defaults.set(self.baseURL, forKey: "PichiMeetingSummaryBaseURL")
            self.models = []
            self.discoveryError = nil
        }
    }
    @Published var modelID: String { didSet { self.defaults.set(self.modelID, forKey: "PichiMeetingSummaryModelID") } }
    @Published var language: String { didSet { self.defaults.set(self.language, forKey: "PichiMeetingSummaryLanguage") } }
    @Published private(set) var models: [String] = []
    @Published private(set) var discovering = false
    @Published private(set) var discoveryError: String?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.mode = Mode(rawValue: defaults.string(forKey: "PichiMeetingSummaryMode") ?? "") ?? .local
        self.baseURL = defaults.string(forKey: "PichiMeetingSummaryBaseURL") ?? "http://127.0.0.1:11434/v1"
        self.modelID = defaults.string(forKey: "PichiMeetingSummaryModelID") ?? "qwen3.5:4b"
        self.language = defaults.string(forKey: "PichiMeetingSummaryLanguage") ?? "ru"
    }

    var selectionIdentity: String { "\(self.mode.rawValue)|\(self.baseURL)|\(self.modelID)|\(self.language)" }

    func configuration(sessionLanguage: String, settings: SettingsStore? = nil) throws -> PichiMeetingSummaryConfiguration {
        let outputLanguage = self.language == "transcript" ? sessionLanguage : self.language
        if self.mode == .local {
            guard PichiMeetingSummaryConfiguration.isLoopback(self.baseURL) else { throw PichiMeetingSummaryError.localEndpointRequired }
            let config = PichiMeetingSummaryConfiguration(providerID: "pichi-local", modelID: self.modelID,
                                                         baseURL: self.baseURL, apiKey: "", language: outputLanguage)
            try config.validate()
            return config
        }
        let settings = settings ?? .shared
        let id = settings.selectedProviderID
        guard !id.isEmpty else { throw PichiMeetingSummaryError.notConfigured }
        guard id != "anthropic", id != PrivateAIProviderFeature.shared.providerID else { throw PichiMeetingSummaryError.unsupportedProvider }
        let savedID = id.hasPrefix("custom:") ? String(id.dropFirst(7)) : id
        let endpoint = settings.savedProviders.first(where: { $0.id == savedID })?.baseURL
            ?? ModelRepository.shared.defaultBaseURL(for: id)
        let preferred = ModelRepository.shared.providerKeys(for: id).compactMap { settings.selectedModelByProvider[$0] }
            .first { !$0.isEmpty } ?? settings.selectedModel
        let model = preferred ?? ModelRepository.shared.defaultModels(for: id).first ?? ""
        let apiKey = settings.getAPIKey(for: id) ?? ""
        let config = PichiMeetingSummaryConfiguration(providerID: id, modelID: model, baseURL: endpoint,
                                                     apiKey: apiKey, language: outputLanguage)
        try config.validate()
        guard config.isOnDevice || !apiKey.isEmpty else { throw PichiMeetingSummaryError.notConfigured }
        return config
    }

    func discoverModels() async {
        guard !self.discovering else { return }
        self.discovering = true
        self.discoveryError = nil
        defer { self.discovering = false }
        let endpoint = self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            guard PichiMeetingSummaryConfiguration.isLoopback(endpoint), let base = URL(string: endpoint),
                  ["http", "https"].contains(base.scheme), base.user == nil, base.password == nil,
                  base.query == nil, base.fragment == nil
            else { throw PichiMeetingSummaryError.localEndpointRequired }
            struct Models: Decodable { struct Model: Decodable { let id: String }; let data: [Model] }
            var request = URLRequest(url: base.appendingPathComponent("models"))
            request.timeoutInterval = 10
            let (data, response) = try await PichiMeetingSummaryTransport.session.data(for: request)
            try Task.checkCancellation()
            guard endpoint == self.baseURL.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { throw LLMError.invalidResponse }
            self.models = try JSONDecoder().decode(Models.self, from: data).data.map(\.id).sorted()
            if self.models.isEmpty { self.discoveryError = "No installed models found. Install a model in Ollama or LM Studio, then refresh." }
        } catch is CancellationError {
            self.discoveryError = nil
        } catch {
            self.models = []
            self.discoveryError = "Could not list local models. Start Ollama or LM Studio's local server and check the endpoint."
        }
    }
}

nonisolated struct PichiMeetingSummaryArtifact: Codable, Sendable {
    let version: Int
    let transcriptHash: String
    let configurationIdentity: String
    let generatedAt: Date
    let document: PichiMeetingSummaryDocument
}

@MainActor
final class PichiMeetingSummaryController: ObservableObject {
    @Published private(set) var document: PichiMeetingSummaryDocument?
    @Published private(set) var generating = false
    @Published private(set) var checking = false
    @Published private(set) var progress = ""
    @Published private(set) var error: String?
    private var operation: Task<Void, Never>?
    private var generationID = UUID()
    private let generator: PichiMeetingSummaryGenerator

    init(generator: PichiMeetingSummaryGenerator = .init()) { self.generator = generator }

    func refresh(session: MeetingSession?, configuration: PichiMeetingSummaryConfiguration?) async {
        let generationID = UUID()
        self.generationID = generationID
        self.operation?.cancel()
        self.document = nil
        self.error = nil
        self.checking = false
        guard let session, let configuration else { return }
        self.checking = true
        defer { if self.generationID == generationID { self.checking = false } }
        let hash = PichiMeetingSummaryInput.fingerprint(session)
        let identity = configuration.cacheIdentity
        let cached = await Task.detached(priority: .utility) { () -> PichiMeetingSummaryDocument? in
            guard let directory = try? await MeetingSessionStore.shared.existingSessionDirectory(for: session.id),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("pichi-meeting-summary.json")),
                  let artifact = try? JSONDecoder().decode(PichiMeetingSummaryArtifact.self, from: data),
                  artifact.version == 3, artifact.transcriptHash == hash, artifact.configurationIdentity == identity,
                  let validated = try? artifact.document.validated(against: PichiMeetingSummaryInput.turns(for: session))
            else { return nil }
            return validated
        }.value
        guard self.generationID == generationID, !Task.isCancelled else { return }
        self.document = cached
    }

    func summarize(session: MeetingSession, configuration: PichiMeetingSummaryConfiguration, asr: ASRService) {
        guard !self.generating, !self.checking,
              let lock = MeetingSummaryActivityCoordinator.shared.lockSelection() else { return }
        self.generating = true
        self.error = nil
        let generationID = self.generationID
        self.operation = Task { [weak self] in
            guard let self else { MeetingSummaryActivityCoordinator.shared.unlockSelection(lock); return }
            defer {
                self.generating = false
                self.operation = nil
                self.progress = ""
                MeetingSummaryActivityCoordinator.shared.unlockSelection(lock)
            }
            do {
                let output = try await MeetingSummaryActivityCoordinator.shared.withSummary(activity: asr) {
                    try await self.generator.generate(session: session, configuration: configuration) { [weak self] index, total in
                        await self?.updateProgress(index: index, total: total)
                    }
                }
                try Task.checkCancellation()
                guard self.generationID == generationID else { return }
                self.document = output
                let hash = PichiMeetingSummaryInput.fingerprint(session)
                let artifact = PichiMeetingSummaryArtifact(version: 3, transcriptHash: hash,
                                                          configurationIdentity: configuration.cacheIdentity,
                                                          generatedAt: Date(), document: output)
                guard let directory = try await MeetingSessionStore.shared.existingSessionDirectory(for: session.id) else {
                    self.error = "The summary is ready, but this meeting has no saved directory yet."
                    return
                }
                try Task.checkCancellation()
                try await Task.detached(priority: .utility) {
                    try JSONEncoder().encode(artifact).write(to: directory.appendingPathComponent("pichi-meeting-summary.json"), options: .atomic)
                }.value
            } catch is CancellationError {
                self.error = nil
            } catch {
                if self.generationID == generationID, !Task.isCancelled { self.error = String(error.localizedDescription.prefix(500)) }
            }
        }
    }

    private func updateProgress(index: Int, total: Int) { self.progress = "Processing transcript part \(index) of \(total)…" }
    func cancel() { self.operation?.cancel() }
}
