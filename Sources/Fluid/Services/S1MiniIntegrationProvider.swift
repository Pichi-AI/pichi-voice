import Foundation
import NativeTextInference

/// The inference adapter stays behind the existing installation, enhancement and residency APIs.
/// This internal contract allows ownership/cancellation tests without downloading model weights.
nonisolated protocol S1MiniInferenceEngine: Sendable {
    var isLoaded: Bool { get async }
    func load(modelURL: URL, contextTokenLimit: Int) async throws
    func generate(prompt: String, maxOutputTokens: Int, streamHandler: PrivateAIStreamHandler?) async throws -> String
    func unload() async
}

extension NativeTextInference: S1MiniInferenceEngine {}

actor S1MiniIntegrationProvider: PrivateAIIntegrationProviding {
    static let shared = S1MiniIntegrationProvider()
    private nonisolated let store: S1MiniModelStore
    private let engine: any S1MiniInferenceEngine
    // Reuse the existing cancellation-aware FIFO gate, with an independent lease for this engine.
    // Actor isolation alone cannot exclude unload/install while generation suspends.
    private let gate = MeetingProcessingSerializationGate()
    private var loadedSelection: Selection?
    private var state: PrivateAIRuntimeState = .configured
    private var failureMessage: String?

    private struct Selection: Codable, Equatable, Sendable {
        let modelID: String
        let version: String
        let path: String
        let contextTokenLimit: Int
    }

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        self.store = S1MiniModelStore(directoryURL: base
            .appendingPathComponent(AppBrand.storageNamespace, isDirectory: true)
            .appendingPathComponent(S1MiniProviderFeature.shared.modelDirectoryName, isDirectory: true)
            .appendingPathComponent("Models", isDirectory: true))
        self.engine = NativeTextInference()
    }

    init(store: S1MiniModelStore, engine: any S1MiniInferenceEngine) {
        self.store = store
        self.engine = engine
    }

    nonisolated var configuredModelID: String {
        let value = UserDefaults.standard.string(forKey: S1MiniProviderFeature.shared.selectedModelDefaultsKey) ?? ""
        return S1MiniProviderFeature.shared.canonicalModelID(for: value) ?? S1MiniProviderFeature.shared.defaultModelID
    }
    nonisolated var selectedModel: PrivateAIRegisteredModel { self.store.model }
    nonisolated var configuredLocalModelPath: String? {
        let path = UserDefaults.standard.string(forKey: S1MiniProviderFeature.shared.localModelPathDefaultsKey)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return path?.isEmpty == false ? path : nil
    }
    nonisolated var modelDirectoryURL: URL { self.store.directoryURL }
    nonisolated var isLocalRuntimeConfigured: Bool { self.isModelInstalled(self.selectedModel) }

    nonisolated func expectedLocalModelURL(for model: PrivateAIRegisteredModel) -> URL {
        S1MiniProviderFeature.shared.localModelURL(for: model, directoryURL: self.modelDirectoryURL)
    }
    nonisolated func localModelPath(for model: PrivateAIRegisteredModel) -> String? {
        guard self.isKnown(model) else { return nil }
        if let path = self.configuredLocalModelPath,
           S1MiniModelStore.hasExpectedFileSize(URL(fileURLWithPath: path), bytes: model.artifact.byteCount)
        { return path }
        return self.store.isInstalled() ? self.store.modelURL.path : nil
    }
    nonisolated func isModelInstalled(_ model: PrivateAIRegisteredModel) -> Bool {
        self.localModelPath(for: model) != nil
    }
    nonisolated func installedModelURLs(for model: PrivateAIRegisteredModel) -> [URL] {
        self.isKnown(model) ? self.store.removableURLs : []
    }
    nonisolated func inactiveInstalledModelURLs(keeping _: PrivateAIRegisteredModel) -> [URL] { [] }
    nonisolated func shouldHandleDictation(model: String) -> Bool { S1MiniProviderFeature.shared.matches(model: model) }

    func prepareModel(
        _ model: PrivateAIRegisteredModel, progressHandler: PrivateAIModelDownloadProgressHandler?
    ) async throws -> URL {
        guard self.isKnown(model) else { throw S1MiniError.unknownModel }
        return try await self.serialized {
            try await self.store.prepare(progressHandler: progressHandler)
        }
    }

    func modelUpdateStatus(_ model: PrivateAIRegisteredModel) async -> PrivateAIModelUpdateStatus {
        guard self.isKnown(model) else { return .init(state: .unavailable) }
        // Releases are deliberately pinned. A remote "main" revision is never silently adopted.
        return .init(
            state: self.isModelInstalled(model) ? .current : .notInstalled,
            installedVersion: self.isModelInstalled(model) ? model.artifact.version : nil,
            availableVersion: model.artifact.version
        )
    }

    func status(for runtime: PrivateAIIntegrationService.RuntimeConfiguration) async -> PrivateAIStatus {
        guard S1MiniProviderFeature.shared.isKnownModelID(runtime.model) else {
            return .init(state: .unavailable, message: S1MiniError.unknownModel.errorDescription)
        }
        guard let selection = try? self.selection(model: self.selectedModel, path: runtime.localModelPath, context: runtime.contextTokenLimit) else {
            return .init(state: .missingModel, message: S1MiniError.missingModel.errorDescription)
        }
        if self.loadedSelection == selection, await self.engine.isLoaded {
            return .init(state: .ready)
        }
        return .init(state: self.state == .failed ? .failed : .configured, message: self.failureMessage)
    }

    func loadedModelState() async -> PrivateAIIntegrationService.LoadedModelState? {
        guard let selection = self.loadedSelection else { return nil }
        return .init(modelID: selection.modelID, state: await self.engine.isLoaded ? .ready : self.state, message: self.failureMessage)
    }

    func residencySnapshot() async throws -> MeetingResidentModel? {
        try await self.serialized {
            await self.makeResidencySnapshot()
        }
    }

    private func makeResidencySnapshot() async -> MeetingResidentModel? {
        guard let selection = self.loadedSelection, await self.engine.isLoaded,
              let data = try? JSONEncoder().encode(selection), let configuration = String(data: data, encoding: .utf8)
        else { return nil }
        return MeetingResidentModel(id: selection.modelID, configuration: configuration)
    }

    func restoreResidency(_ model: MeetingResidentModel) async throws {
        guard model.id == self.selectedModel.id,
              let data = model.configuration.data(using: .utf8), data.count <= 16_384,
              let selection = try? JSONDecoder().decode(Selection.self, from: data),
              selection.modelID == model.id, selection.version == self.selectedModel.artifact.version
        else { throw MeetingModelResidencyError.unsupportedProvider }
        try await self.serialized { try await self.load(selection) }
    }

    func loadModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        let path = self.configuredLocalModelPath
        let context = await MainActor.run { SettingsStore.shared.privateAIContextTokenLimit }
        let selection = try self.selection(model: model, path: path, context: context)
        try await self.serialized { try await self.load(selection) }
        return .init(state: .ready)
    }

    func verifyModel(_ model: PrivateAIRegisteredModel) async throws -> PrivateAIStatus {
        let path = self.configuredLocalModelPath
        let context = await MainActor.run { SettingsStore.shared.privateAIContextTokenLimit }
        let selection = try self.selection(model: model, path: path, context: context)
        return try await self.serialized {
            try await self.verify(selection)
            return PrivateAIStatus(state: .ready)
        }
    }

    private func verify(_ selection: Selection) async throws {
        try await self.load(selection)
        do {
            let output = try await self.engine.generate(
                prompt: S1MiniPrompt.make(transcript: "hello world"), maxOutputTokens: 32, streamHandler: nil
            )
            try Task.checkCancellation()
            // Empty cleanup is valid for filler-only input, but this meaningful fixture must yield text.
            guard !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw S1MiniError.verification }
        } catch {
            let failure = Self.userFacingError(error)
            await self.retireAfterFailure(failure)
            throw failure
        }
    }

    func prewarmDictation() async {
        guard !Task.isCancelled else { return }
        _ = try? await self.loadModel(self.selectedModel)
    }

    func unloadCachedRuntime(reason _: String) async {
        // Cleanup joins the engine and lease even when its caller is already cancelled.
        await Task { try? await self.serialized { await self.retire() } }.value
    }

    func shutdownForTermination() async { await self.unloadCachedRuntime(reason: "termination") }

    nonisolated func enhanceDictation(
        _ inputText: String,
        runtime: PrivateAIIntegrationService.RuntimeConfiguration,
        context: PrivateAIIntegrationService.AppContext,
        maxOutputTokens: Int
    ) async throws -> PrivateAIIntegrationService.EnhancementResult {
        try await self.enhanceDictation(inputText, runtime: runtime, context: context, maxOutputTokens: maxOutputTokens, streamHandler: nil)
    }

    nonisolated func enhanceDictation(
        _ inputText: String,
        runtime: PrivateAIIntegrationService.RuntimeConfiguration,
        context _: PrivateAIIntegrationService.AppContext,
        maxOutputTokens: Int,
        streamHandler: PrivateAIStreamHandler?
    ) async throws -> PrivateAIIntegrationService.EnhancementResult {
        guard S1MiniProviderFeature.shared.isKnownModelID(runtime.model) else { throw S1MiniError.unknownModel }
        // Every value is immutable before admission. A settings change cannot switch this attempt's model.
        let selection = try await self.selection(model: self.selectedModel, path: runtime.localModelPath, context: runtime.contextTokenLimit)
        let prompt = S1MiniPrompt.make(transcript: inputText)
        return try await self.serialized {
            try await self.enhance(selection, prompt: prompt, maxOutputTokens: maxOutputTokens, streamHandler: streamHandler)
        }
    }

    private func enhance(
        _ selection: Selection, prompt: String, maxOutputTokens: Int, streamHandler: PrivateAIStreamHandler?
    ) async throws -> PrivateAIIntegrationService.EnhancementResult {
        let start = ContinuousClock.now
        try await self.load(selection)
        do {
            let output = try await self.engine.generate(prompt: prompt, maxOutputTokens: maxOutputTokens, streamHandler: streamHandler)
            try Task.checkCancellation()
            let elapsed = start.duration(to: .now).components
            let milliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
            return .init(outputText: output, backendKind: "llama.cpp", latencyMilliseconds: milliseconds)
        } catch {
            let failure = Self.userFacingError(error)
            await self.retireAfterFailure(failure)
            throw failure
        }
    }

    func summarizeMeeting(_: String, style _: String) async throws -> String { throw S1MiniError.unsupportedTask }
    func rewrite(
        _: String, systemPrompt _: String, runtime _: PrivateAIIntegrationService.RuntimeConfiguration,
        context _: PrivateAIIntegrationService.AppContext
    ) async throws -> PrivateAIIntegrationService.EnhancementResult { throw S1MiniError.unsupportedTask }

    private nonisolated func isKnown(_ model: PrivateAIRegisteredModel) -> Bool {
        // Never accept a caller-supplied URL/hash just because its identifier matches the catalog.
        model.artifact == self.store.model.artifact && model.id == S1MiniProviderFeature.shared.defaultModelID
    }

    private func selection(model: PrivateAIRegisteredModel, path: String?, context: Int) throws -> Selection {
        guard self.isKnown(model) else { throw S1MiniError.unknownModel }
        let url: URL
        if let path, !path.isEmpty { url = URL(fileURLWithPath: path).standardizedFileURL }
        else if self.store.isInstalled() { url = self.store.modelURL }
        else { throw S1MiniError.missingModel }
        guard S1MiniModelStore.hasExpectedFileSize(url, bytes: model.artifact.byteCount) else { throw S1MiniError.missingModel }
        return Selection(modelID: model.id, version: model.artifact.version ?? "", path: url.path, contextTokenLimit: context)
    }

    private func load(_ selection: Selection) async throws {
        try Task.checkCancellation()
        if self.loadedSelection == selection, await self.engine.isLoaded { return }
        await self.retire()
        self.state = .loading
        do {
            let url = URL(fileURLWithPath: selection.path)
            try self.store.validate(url)
            try await self.engine.load(modelURL: url, contextTokenLimit: selection.contextTokenLimit)
            try Task.checkCancellation()
            guard await self.engine.isLoaded else { throw S1MiniError.verification }
            self.loadedSelection = selection
            self.state = .ready
            self.failureMessage = nil
        } catch {
            let failure = Self.userFacingError(error)
            await self.retireAfterFailure(failure)
            throw failure
        }
    }

    private func retire() async {
        await self.engine.unload()
        self.loadedSelection = nil
        self.state = .configured
        self.failureMessage = nil
    }

    private func retireAfterFailure(_ error: Error) async {
        await self.retire()
        if !(error is CancellationError) {
            self.state = .failed
            self.failureMessage = error.localizedDescription
        }
    }

    private nonisolated static func userFacingError(_ error: Error) -> Error {
        guard let native = error as? NativeTextInferenceError else { return error }
        switch native {
        case .promptTooLarge, .contextLimitExceeded: return AIProcessingError.dictationExceedsAIContextWindow
        case .outputLimitExceeded: return S1MiniError.incompleteOutput
        case .invalidModelURL: return S1MiniError.integrity
        case .modelNotLoaded: return S1MiniError.missingModel
        default: return S1MiniError.verification
        }
    }

    private func serialized<T: Sendable>(_ operation: @Sendable () async throws -> T) async throws -> T {
        try await self.gate.acquire()
        do {
            try Task.checkCancellation()
            let result = try await operation()
            await self.gate.release()
            return result
        } catch {
            await self.gate.release()
            throw error
        }
    }
}
