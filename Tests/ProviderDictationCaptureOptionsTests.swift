import Foundation

// Only the neighboring settings/engine contracts are synthetic. The runner extracts
// the actual admission declarations, getters and language application methods.
struct ExternalCoreMLASRModelSpec {
    let defaultCacheDirectory: URL?
}
enum AppBrand {
    static let cachesDirectory = URL(fileURLWithPath: "/synthetic/caches")
}
final class SettingsStore {
    enum SpeechModel { case whisperTiny, whisperSmall, cohere, alternateCohere
        var externalCoreMLSpec: ExternalCoreMLASRModelSpec? {
            switch self {
            case .cohere: return .init(defaultCacheDirectory: URL(fileURLWithPath: "/synthetic/public/cohere"))
            case .alternateCohere: return .init(defaultCacheDirectory: URL(fileURLWithPath: "/synthetic/public/alternate"))
            default: return nil
            }
        }
    }
    enum CohereLanguage { case russian, english, german }
    struct NemotronLanguage { let rawValue: String }
    static let shared = SettingsStore()
    var hidden = false
    var model = SpeechModel.whisperTiny
    var whisperLanguage: String? = "ru"
    var appleLocale = Locale(identifier: "ru-RU")
    var nemotronLanguage = "ru"
    var cohereLanguage = CohereLanguage.russian
    var artifactDirectory: URL? = URL(fileURLWithPath: "/synthetic/import/A")
    var selectedSpeechModel: SpeechModel { hidden ? .whisperSmall : model }
    var selectedWhisperLanguageCode: String? { hidden ? nil : whisperLanguage }
    var selectedAppleSpeechLocale: Locale { hidden ? Locale(identifier: "en-US") : appleLocale }
    var selectedNemotronLanguage: NemotronLanguage { .init(rawValue: hidden ? "en" : nemotronLanguage) }
    var selectedCohereLanguage: CohereLanguage { hidden ? .english : cohereLanguage }
    func externalCoreMLArtifactsDirectory(for model: SpeechModel) -> URL? { hidden ? nil : artifactDirectory }
}
// The configuration-only projection has no active recognition workers. Full worker
// ownership is exercised separately by AppleSpeechLifecycleTests from actual sources.
final class AppleSpeechRecognitionOperation {
    func cancel() {}
    func waitUntilFinished() async {}
}
final class SFSpeechRecognizer {
    let locale: Locale
    init?(locale: Locale) { self.locale = locale }
}
final class NemotronStreamingAsrManager {
    var targetLanguage: String
    var changes: [String] = []
    init(targetLanguage: String) { self.targetLanguage = targetLanguage }
    func setTargetLanguage(_ language: String) async throws {
        self.targetLanguage = language
        self.changes.append(language)
    }
}

@main struct ProviderDictationCaptureOptionsTests {
    private static var assertions = 0
    private static func check(_ value: Bool, _ message: String) {
        assertions += 1
        precondition(value, message)
    }
    private static func rejects(_ operation: () throws -> Void) {
        do { try operation(); preconditionFailure("Overlapping admission must reject") }
        catch { assertions += 1 }
    }
    private static func reset() {
        let settings = SettingsStore.shared
        settings.hidden = false; settings.model = .whisperTiny; settings.whisperLanguage = "ru"
        settings.appleLocale = Locale(identifier: "ru-RU"); settings.nemotronLanguage = "ru"
        settings.cohereLanguage = .russian; settings.artifactDirectory = URL(fileURLWithPath: "/synthetic/import/A")
    }
    static func main() async throws {
        let settings = SettingsStore.shared
        do {
            reset()
            let provider = WhisperProvider(), lease = UUID(), other = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            settings.hidden = true
            check(provider.observedModel == .whisperTiny && provider.resolvedLanguageCode() == "ru", "Whisper retains admitted model/language after concealment")
            check(provider.observedDirectory.path == "/synthetic/caches/WhisperModels", "Whisper retains artifact directory")
            rejects { try provider.beginAdmittedTranscription(leaseID: other) }
            try provider.beginAdmittedTranscription(leaseID: lease)
            provider.endAdmittedTranscription(leaseID: other)
            check(provider.resolvedLanguageCode() == "ru", "Stale Whisper end and repeat admission cannot replace the snapshot")
            provider.endAdmittedTranscription(leaseID: lease)
            check(provider.observedModel == .whisperSmall && provider.resolvedLanguageCode() == nil, "Matching Whisper end restores current settings")
            settings.hidden = false; settings.whisperLanguage = nil
            try provider.beginAdmittedTranscription(leaseID: other)
            settings.whisperLanguage = "de"
            check(provider.resolvedLanguageCode() == nil, "Admitted automatic Whisper language is a value, not a missing override")
            provider.endAdmittedTranscription(leaseID: other)
            check(provider.resolvedLanguageCode() == "de", "Automatic Whisper admission clears on matching end")
        }
        for automatic in [false, true] {
            reset()
            let directory = URL(fileURLWithPath: "/synthetic/meeting/whisper")
            let provider = WhisperProvider(model: .whisperTiny, language: "fr", automatic: automatic, directory: directory)
            let lease = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            settings.hidden = true
            check(provider.observedModel == .whisperTiny && provider.observedDirectory == directory, "Explicit Whisper meeting artifact/model retain precedence")
            check(provider.resolvedLanguageCode() == (automatic ? nil : "fr"), "Explicit meeting language/automatic detection retain precedence")
            check(provider.resolvedLanguageCode(explicit: "de") == "de" && provider.resolvedLanguageCode(explicit: "auto") == nil, "Explicit per-call language retains existing precedence")
            provider.endAdmittedTranscription(leaseID: lease)
            check(provider.resolvedLanguageCode() == (automatic ? nil : "fr"), "Ending dictation cannot clear fixed meeting options")
        }
        do {
            reset()
            let provider = AppleSpeechProvider(), lease = UUID(), other = UUID()
            let original = provider.observedRecognizer()
            try provider.beginAdmittedTranscription(leaseID: lease)
            settings.hidden = true
            check(provider.observedRecognizer() === original, "Concealment cannot replace admitted Apple recognizer/locale")
            rejects { try provider.beginAdmittedTranscription(leaseID: other) }
            try provider.beginAdmittedTranscription(leaseID: lease)
            await provider.endAdmittedTranscription(leaseID: other)
            check(provider.observedRecognizer()?.locale.identifier == "ru-RU", "Stale Apple end retains locale")
            await provider.endAdmittedTranscription(leaseID: lease)
            check(provider.observedRecognizer()?.locale.identifier == "en-US", "Matching Apple end restores current locale")
        }
        do {
            reset()
            let provider = NemotronProvider(activeLanguage: "ru"), manager = NemotronStreamingAsrManager(targetLanguage: "ru")
            let lease = UUID(), other = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            settings.hidden = true
            try await provider.apply(to: manager)
            check(manager.targetLanguage == "ru" && manager.changes.isEmpty, "Concealment preserves existing Nemotron manager target")
            rejects { try provider.beginAdmittedTranscription(leaseID: other) }
            try provider.beginAdmittedTranscription(leaseID: lease)
            provider.endAdmittedTranscription(leaseID: other)
            try await provider.apply(to: manager)
            check(manager.targetLanguage == "ru", "Stale Nemotron end retains target")
            provider.endAdmittedTranscription(leaseID: lease)
            try await provider.apply(to: manager)
            check(manager.targetLanguage == "en" && manager.changes == ["en"], "Matching Nemotron end allows current target application")
            settings.hidden = false; settings.nemotronLanguage = "de"
            try provider.beginAdmittedTranscription(leaseID: other)
            settings.hidden = true
            try await provider.apply(to: manager)
            check(manager.targetLanguage == "de", "Nemotron also applies an admitted target not previously loaded")
            provider.endAdmittedTranscription(leaseID: other)
        }
        do {
            reset(); settings.model = .cohere
            let provider = ExternalCoreMLTranscriptionProvider(), lease = UUID(), other = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            settings.hidden = true
            check(provider.observedModel == .cohere && provider.observedPrompt == [100, 201, 999], "Cohere retains admitted model and language prompt")
            check(provider.observedDirectory?.path == "/synthetic/import/A", "Cohere retains imported artifact directory after concealment")
            rejects { try provider.beginAdmittedTranscription(leaseID: other) }
            try provider.beginAdmittedTranscription(leaseID: lease)
            provider.endAdmittedTranscription(leaseID: other)
            check(provider.observedPrompt == [100, 201, 999] && provider.observedDirectory?.path == "/synthetic/import/A", "Stale Cohere end retains snapshot")
            provider.endAdmittedTranscription(leaseID: lease)
            settings.hidden = false; settings.model = .alternateCohere; settings.cohereLanguage = .german
            settings.artifactDirectory = URL(fileURLWithPath: "/synthetic/import/B")
            check(provider.observedModel == .alternateCohere && provider.observedPrompt == [100, 203, 999], "Matching Cohere end restores current model/language")
            check(provider.observedDirectory?.path == "/synthetic/import/B", "Matching Cohere end restores current artifact destination")
        }
        do {
            reset(); settings.model = .alternateCohere; settings.artifactDirectory = nil
            let provider = ExternalCoreMLTranscriptionProvider(model: .cohere), lease = UUID()
            try provider.beginAdmittedTranscription(leaseID: lease)
            settings.artifactDirectory = URL(fileURLWithPath: "/synthetic/import/B")
            check(provider.observedModel == .cohere && provider.observedDirectory?.path == "/synthetic/public/cohere", "Explicit Cohere model and admitted public fallback retain precedence")
            provider.endAdmittedTranscription(leaseID: lease)
            check(provider.observedModel == .cohere && provider.observedDirectory?.path == "/synthetic/import/B", "Ending admission preserves explicit Cohere model")
        }
        print("Provider dictation capture options: \(assertions) assertions passed.")
    }
}
