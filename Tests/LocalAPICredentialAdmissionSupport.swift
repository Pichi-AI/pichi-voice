import Foundation

// Standalone metadata/adapter doubles only. Actual API controller, route,
// process, fingerprint gate and HTTP client are compiled by the existing runner.
extension UserDefaults {
    func bool(forKey key: String) -> Bool { self.values[key] as? Bool ?? false }
    func integer(forKey key: String) -> Int { self.values[key] as? Int ?? 0 }
}
extension SettingsStore {
    enum Mode { case dictate }
    enum DictationShortcutSlot { case primary, secondary }
    enum DictationPromptSelection: Equatable { case off, `default`, privateAI, profile(String) }
    enum PromptRoutingScope { case selectedAppsOnly, allApps }
    struct DictationPromptConfiguration { let providerID: String; let modelName: String }
    var privateAIPrefixKVCacheEnabled: Bool { false }
    var privateAIBoostEnabled: Bool { false }
    var privateAIContextTokenLimit: Int { 512 }
    var privateCapabilityReady: Bool {
        get { UserDefaults.standard.bool(forKey: "synthetic-private-capability") }
        set { UserDefaults.standard.values["synthetic-private-capability"] = newValue }
    }
    var selectsPrivateCapability: Bool {
        get { UserDefaults.standard.bool(forKey: "synthetic-private-selection") }
        set { UserDefaults.standard.values["synthetic-private-selection"] = newValue }
    }
    func dictationPromptSelection(for _: DictationShortcutSlot) -> DictationPromptSelection {
        self.selectsPrivateCapability ? .privateAI : .default
    }
    func resolvedDictationPromptSelection(for slot: DictationShortcutSlot, appBundleID: String?, privateAIAvailable: Bool? = nil) -> DictationPromptSelection {
        if let choice = DictationAppSession.shared.choice(for: slot, appID: appBundleID) { return choice }
        if let profile = self.resolvedDictationPromptProfile(for: slot, appBundleID: appBundleID) { return .profile(profile.id) }
        return UserDefaults.standard.values["synthetic-prompt-off"] as? Bool == true ? .off : self.dictationPromptSelection(for: slot)
    }
    func dictationPromptConfiguration(for selection: DictationPromptSelection) -> DictationPromptConfiguration {
        if case .profile(let id) = selection, let profile = self.syntheticProfiles.values.first(where: { $0.id == id }) {
            return .init(providerID: profile.providerID, modelName: profile.model)
        }
        return .init(providerID: self.selectedProviderID, modelName: self.selectedModel ?? "")
    }
    func promptRoutingScope(for _: Mode) -> PromptRoutingScope { .selectedAppsOnly }
    func appPromptBinding(for _: Mode, appBundleID _: String?) -> String? { nil }
    func effectiveDictationSystemPrompt(for _: DictationShortcutSlot, appBundleID _: String?) -> String { "Correct the synthetic text." }
    func recordFluidIntelligenceUse(output _: String) {}
    struct SpeechModel { let displayName: String }
    var selectedSpeechModel: SpeechModel { fatalError("Postprocess tests must never access an ASR model") }
}
enum PrivateAIProviderPromptFormat {
    // Metadata-only warmup input. Any attempted model verification is outside this
    // intercepted credential-admission probe and must fail rather than touch weights.
    struct VerificationInput {
        init(settings _: SettingsStore) {}
    }
    static func verifiedModelID(settings: SettingsStore) -> String? {
        settings.privateCapabilityReady ? PrivateAIProviderFeature.shared.modelIDs().first : nil
    }
}
extension PrivateAIIntegrationService {
    struct RuntimeConfiguration {
        let selectedProviderID: String
        let providerKey: String
        let baseURL: String
        let model: String
        let apiKey: String
        let localModelPath: String?
        let usesStablePromptPrefixKVCache: Bool
        let usesFluid1Boost: Bool
        let contextTokenLimit: Int
    }
    struct AppContext { let appName: String; let bundleID: String; let windowTitle: String; let appVersion: String? }
    struct Response { let outputText: String; let tokensPerSecond: Double? = nil }
    @MainActor final class InertAdapter {
        private(set) var calls = 0
        func enhanceDictation(_: String, runtime: RuntimeConfiguration, context _: AppContext, streamHandler _: PrivateAIStreamHandler? = nil) async throws -> Response {
            precondition(runtime.model == PrivateAIProviderFeature.shared.modelIDs().first && runtime.apiKey.isEmpty)
            self.calls += 1
            return Response(outputText: "Synthetic private result")
        }
    }
    @MainActor static let shared = InertAdapter()
    static let configuredLocalModelPath: String? = nil
}
@MainActor final class MeetingSummaryActivityCoordinator {
    static let shared = MeetingSummaryActivityCoordinator()
    private var active = Set<UUID>()
    var activeCount: Int { self.active.count }
    func beginProcessing() -> UUID? {
        guard self.active.isEmpty else { return nil }
        let token = UUID()
        self.active.insert(token)
        return token
    }
    func endProcessing(_ token: UUID) { precondition(self.active.remove(token) != nil) }
    func beginOptionalProcessing(cancelAndJoin _: @escaping @MainActor () async -> Void) -> UUID? { self.beginProcessing() }
}
enum MeetingModelResidencyError: Error { case busy }
final class ASRService {
    static func applyGAAVFormatting(_ text: String) -> String { text }
    func transcribeFileForAPI(_: URL) async throws -> (result: (text: String, confidence: Float), sampleCount: Int) {
        fatalError("Postprocess tests must never use ASR or audio")
    }
}
final class AppServices {
    static var shared: AppServices { fatalError("Postprocess tests must never start application services") }
    let asr = ASRService()
}
enum LocalAPIAudioDecoder {
    static func temporaryFile(fromAudioData _: Data, suggestedExtension _: String) async throws -> URL {
        fatalError("Postprocess tests must never create audio files")
    }
    static func removeTemporaryFile(at _: URL) async { fatalError("Postprocess tests must never access audio files") }
}
