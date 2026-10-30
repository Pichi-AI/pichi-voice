import Foundation

// Metadata and effect doubles only. The runner compiles the production stop
// snapshot, post-ASR AI/fallback block, processor, warm admission and transports.
typealias PrivateAIStreamHandler = (String) -> Void

extension SettingsStore {
    struct SyntheticPromptProfile {
        let id: String
        let name: String
        let prompt: String
        let providerID: String
        let model: String
    }
    var syntheticProfiles: [String: SyntheticPromptProfile] {
        get { UserDefaults.standard.values["synthetic-profiles"] as? [String: SyntheticPromptProfile] ?? [:] }
        set { UserDefaults.standard.values["synthetic-profiles"] = newValue }
    }
    var onboardingCurrentStep: Int { 0 }
    func resolvedDictationPromptProfile(for _: DictationShortcutSlot, appBundleID: String?) -> SyntheticPromptProfile? {
        appBundleID.flatMap { self.syntheticProfiles[$0] }
    }
    func shortcutOverrideSystemPrompt(for profile: SyntheticPromptProfile) -> String? { profile.prompt }
    func effectiveDictationPromptBody(for slot: DictationShortcutSlot, appBundleID: String?) -> String {
        self.effectiveDictationSystemPrompt(for: slot, appBundleID: appBundleID)
    }
    static func defaultSystemPromptText(for _: Mode) -> String { "Synthetic default prompt" }
}

final class DictationAppSession {
    static let shared = DictationAppSession()
    var appID: String?
    var selected: SettingsStore.DictationPromptSelection?
    var selectedSlot = SettingsStore.DictationShortcutSlot.primary
    func choice(for slot: SettingsStore.DictationShortcutSlot, appID: String?) -> SettingsStore.DictationPromptSelection? {
        self.appID == appID && self.selectedSlot == slot ? self.selected : nil
    }
}

enum TypingService {
    struct RecordingTargetContext {
        let id: UUID
        let pid: Int32
        let bundleIdentifier: String
        let window: String?
        let element: String?
    }
    struct CapturedFocusTarget { let pid: Int32; let window: String?; let element: String }
    struct Preparation { let isReady: Bool }
    @MainActor static func prepareTargetForDelivery(_: RecordingTargetContext, isOutputValid _: @escaping @MainActor () -> Bool) async -> Preparation {
        fatalError("Credential admission must never operate Accessibility")
    }
}
@MainActor final class PasteDeliveryCoordinator {
    static let shared = PasteDeliveryCoordinator()
    func prepareForDelivery(_: String, preserveTranscriptOnClipboard _: Bool, isOutputValid _: @escaping @MainActor () -> Bool,
                            targetIsReady _: @escaping @MainActor () async -> Bool) async -> Bool {
        fatalError("Credential admission must never access the clipboard or type")
    }
}
@MainActor final class MeetingModelResidencyCoordinator {
    static let shared = MeetingModelResidencyCoordinator()
    private(set) var activeCount = 0
    func withBackgroundOperation<T>(owner _: String, modelID _: String, operation: @escaping @MainActor () async throws -> T) async rethrows -> T {
        self.activeCount += 1
        defer { self.activeCount -= 1 }
        return try await operation()
    }
}

nonisolated enum NormalDictationHTTPConfiguration {
    // Installed explicitly before any actual readiness transport may execute.
    static var make: () -> URLSessionConfiguration = { fatalError("No uninjected HTTP session is allowed") }
}

@MainActor final class NormalDictationAdmissionOwner {
    let privateOutputOperations = PrivateProfileOperationOwner()
    enum ActiveRecordingMode { case dictate }
    enum DictationOutputRoute { case normal, onboardingSandbox }
    struct AITextProcessingResult {
        let text: String
        let tokensPerSecond: Double?
        let fluidIntelligenceLatencyMilliseconds: Int?
    }
    final class Preview {
        var text = ""
        func append(_ chunk: String) { self.text += chunk }
        func flush() {}
    }
    let llmClient: LLMClient
    init(client: LLMClient) { self.llmClient = client }
    var settings: SettingsStore { SettingsStore.shared }
    var recordingAppInfo: (name: String, bundleId: String, windowTitle: String)?
    let activeRecordingMode = ActiveRecordingMode.dictate
    let shouldTracePromptProcessing = false
    var isCallingAI = false
    var aiInputText = "Synthetic raw transcript Ёё."
    var aiOutputText = ""
    func appBench(_: @autoclosure () -> String) {}
    func getCurrentAppInfo() -> (name: String, bundleId: String, windowTitle: String) { ("Synthetic editor", "synthetic.editor", "Synthetic window") }
    func buildSystemPrompt(appInfo: (name: String, bundleId: String, windowTitle: String), dictationSlot: SettingsStore.DictationShortcutSlot?) -> String {
        self.settings.effectiveDictationSystemPrompt(for: dictationSlot ?? .primary, appBundleID: appInfo.bundleId)
    }
    func logDictationPromptTrace(_: String, value _: String) {}
    func isLocalEndpoint(_ endpoint: String) -> Bool { ModelRepository.shared.isLocalEndpoint(endpoint) }
    func providerKey(for id: String) -> String { ModelRepository.shared.providerKey(for: id) }
    func currentDictationShortcutSlot(for _: ActiveRecordingMode) -> SettingsStore.DictationShortcutSlot? { .primary }
    func currentTranscriptionModelInfo() -> (provider: String, model: String) { ("synthetic-asr", "synthetic-asr-model") }
    func currentDictationAIModelInfo(dictationSlot: SettingsStore.DictationShortcutSlot?, appBundleID: String) -> (provider: String?, model: String?) {
        let route = DictationProviderRoute.resolve(settings: self.settings, dictationSlot: dictationSlot, appBundleID: appBundleID)
        return (route.providerKey, route.model)
    }
    func recordDictationUsage(shouldUseAI _: Bool, dictationSlot: SettingsStore.DictationShortcutSlot?, appBundleID: String,
                             snapshot: DictationStopSnapshot?) -> (provider: String?, model: String?) {
        let route = snapshot?.route ?? DictationProviderRoute.resolve(settings: self.settings, dictationSlot: dictationSlot, appBundleID: appBundleID)
        return (route.providerKey, route.model)
    }
    func makeAIProcessingFeedback(lifecycleID _: UInt64) -> (statusTask: Task<Void, Never>, streamPreview: Preview) {
        (Task {}, Preview())
    }
    func logAIProcessCall(_: String, _: (provider: String?, model: String?), _: Int) {}
}

@MainActor final class NormalDictationWarmAdmissionOwner {
    var localAIResidencySlot: SettingsStore.DictationShortcutSlot = .primary
}
