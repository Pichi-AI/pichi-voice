import Foundation

// Shared inert neighbors for standalone probes that compile MeetingProcessingConfiguration.swift.
// That file reaches the model selection, provider registry and language catalog. Those pull in
// SettingsStore and the inference adapters, so this file supplies only the surface it names.
// Compile it together with Sources/Fluid/Services/ParakeetSpeechModelCatalog.swift (real).
// When MeetingProcessingConfiguration.swift names a new neighbor, extend THIS file only.

enum SettingsStore {
    enum SpeechModel: String, CaseIterable, Identifiable, Codable {
        case parakeetTDT = "parakeet-tdt"
        case parakeetTDTv2 = "parakeet-tdt-v2"
        case fluidParakeetPro = "fluid-parakeet-pro"
        case gigaam = "gigaam-v3-eou"

        var id: String { self.rawValue }
        static var availableModels: [SpeechModel] { self.allCases }
        var parakeetDescriptor: ParakeetSpeechModelCatalog.Descriptor? {
            ParakeetSpeechModelCatalog.descriptor(forModelID: self.rawValue)
        }
    }
}

/// Mirrors the model choice in Services/FluidAudioProvider.swift (MeetingProviderOptions).
nonisolated struct MeetingProviderOptions: Equatable, Sendable {
    static let supportedModels: Set<SettingsStore.SpeechModel> = [.parakeetTDTv2, .parakeetTDT, .fluidParakeetPro]

    static func preferredModel(for languageCode: String, selected: SettingsStore.SpeechModel?) -> SettingsStore.SpeechModel {
        if let selected, self.supportedModels.contains(selected),
           ParakeetSpeechModelCatalog.descriptor(forModelID: selected.rawValue)?.supportedLanguageCodes.contains(languageCode) == true
        { return selected }
        return languageCode == "en" ? .parakeetTDTv2 : .parakeetTDT
    }
}

enum PichiMeetingProviderFactory {
    nonisolated static var retranscriptionModels: [SettingsStore.SpeechModel] { [] }
    nonisolated static func registeredLanguageCodes(for modelID: String) -> Set<String>? { nil }
}

struct VoiceEngineLanguage: Identifiable, Equatable {
    let id: String
    let displayName: String
}

enum VoiceEngineLanguageCatalog {
    static func allLanguages(supportedLanguageCodes: Set<String>) -> [VoiceEngineLanguage] {
        supportedLanguageCodes.sorted().map { VoiceEngineLanguage(id: $0, displayName: $0) }
    }
}

/// Required by the real ParakeetSpeechModelCatalog. These probes never inspect installed models.
nonisolated enum HuggingFaceModelDownloader {
    static func artifactIsComplete(at url: URL, isDirectory: Bool) -> Bool { false }
}
