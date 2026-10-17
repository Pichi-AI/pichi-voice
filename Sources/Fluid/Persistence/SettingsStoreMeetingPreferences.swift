import Foundation
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

// The same defaults keys and Codable records are used by desktop and mobile targets.
extension SettingsStore {
    enum UpdateKeys {
        static let autoUpdateCheckEnabled = "AutoUpdateCheckEnabled"
        static let showUpdatePopups = "ShowUpdatePopups"
        static let popupPreferenceRevision = "UpdatePopupPreferenceRevision"
        static let betaReleasesEnabled = "BetaReleasesEnabled"
        static let channelPreferenceRevision = "UpdateChannelPreferenceRevision"
        static let lastUpdateCheckDate = "LastUpdateCheckDate"
        static let updatePromptSnoozedUntil = "UpdatePromptSnoozedUntil"
        static let snoozedUpdateVersion = "SnoozedUpdateVersion"
    }

    var onboardingSelectedLanguageID: String {
        get { Self.onboardingLanguagePreference(in: self.defaults, defaultLanguageID: VoiceEngineLanguageCatalog.defaultOnboardingLanguageID) }
        set {
            objectWillChange.send()
            let normalized = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if normalized.isEmpty { self.defaults.removeObject(forKey: Keys.onboardingSelectedLanguageID) }
            else { self.defaults.set(normalized, forKey: Keys.onboardingSelectedLanguageID) }
        }
    }

    /// Read an explicit choice before applying the distribution's first-run default.
    static func onboardingLanguagePreference(in defaults: UserDefaults, defaultLanguageID: String) -> String {
        let stored = defaults.string(forKey: Keys.onboardingSelectedLanguageID)?.trimmingCharacters(in: .whitespacesAndNewlines)
        return stored.flatMap { $0.isEmpty ? nil : $0 } ?? defaultLanguageID
    }


    var vocabularyBoostingEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.vocabularyBoostingEnabled)
            return value as? Bool ?? false
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.vocabularyBoostingEnabled)
            NotificationCenter.default.post(name: .parakeetVocabularyDidChange, object: nil)
        }
    }

    enum AutomaticDictionarySuggestionFrequency: Int, Codable, CaseIterable, Identifiable {
        case first = 1
        case second = 2
        case third = 3

        var id: Int { self.rawValue }

        var displayName: String {
            switch self {
            case .first: "1 correction"
            case .second: "2 corrections"
            case .third: "3 corrections"
            }
        }
    }

    var automaticDictionaryLearningEnabled: Bool {
        get { self.defaults.object(forKey: Keys.automaticDictionaryLearningEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.automaticDictionaryLearningEnabled)
        }
    }

    var automaticDictionarySuggestionFrequency: AutomaticDictionarySuggestionFrequency {
        get {
            let stored = self.defaults.integer(forKey: Keys.automaticDictionarySuggestionFrequency)
            return AutomaticDictionarySuggestionFrequency(rawValue: stored) ?? .first
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.automaticDictionarySuggestionFrequency)
        }
    }

    var pronunciationMatchingEnabled: Bool {
        get { self.defaults.object(forKey: Keys.pronunciationMatchingEnabled) as? Bool ?? false }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.pronunciationMatchingEnabled)
        }
    }

    /// Custom dictionary entries for word replacement
    var experimentalParakeetUnifiedFinalEnabled: Bool {
        get { self.defaults.object(forKey: Keys.experimentalParakeetUnifiedFinalEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.experimentalParakeetUnifiedFinalEnabled)
        }
    }

    /// Opt in to restoring the field captured at recording start.

    enum AccentColorOption: String, CaseIterable, Identifiable, Codable {
        case brand = "Brand"
        case cyan = "Cyan"
        case green = "Green"
        case blue = "Blue"
        case purple = "Purple"
        case orange = "Orange"

        var id: String {
            self.rawValue
        }

        var hex: String {
            switch self {
            case .brand: return AppBrand.profile.accentLight
            case .cyan: return "#3AC8C6"
            case .green: return "#22C55E"
            case .blue: return "#3B82F6"
            case .purple: return "#A855F7"
            case .orange: return "#F59E0B"
            }
        }
    }

    var accentColorOption: AccentColorOption {
        get {
            guard let raw = self.defaults.string(forKey: Keys.accentColorOption),
                  let option = AccentColorOption(rawValue: raw)
            else {
                return .brand
            }
            return option
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.accentColorOption)
        }
    }

    var accentColor: Color {
        Color(hex: self.accentColorOption.hex) ?? Color(red: 0.404, green: 0.286, blue: 0.757)
    }


    var meetingRecordingDefaults: MeetingRecordingDefaults {
        get {
            guard let data = self.defaults.data(forKey: Keys.meetingRecordingDefaults),
                  let saved = try? JSONDecoder().decode(MeetingRecordingDefaults.self, from: data)
            else {
                return .unconfigured
            }
            return saved
        }
        set {
            guard let data = try? JSONEncoder().encode(newValue) else {
                return
            }
            self.defaults.set(data, forKey: Keys.meetingRecordingDefaults)
        }
    }

    var meetingAudioRetentionPolicy: MeetingAudioRetentionPolicy {
        get {
            guard let raw = self.defaults.string(forKey: Keys.meetingAudioRetentionPolicy),
                  let policy = MeetingAudioRetentionPolicy(rawValue: raw)
            else { return .days7 }
            return policy
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.meetingAudioRetentionPolicy)
        }
    }

    /// Which meeting transcription backend final processing should use.
    ///
    /// An absent preference resolves to the current production default. A stored value is handed
    /// through verbatim, including an ID this build does not know: the pipeline rejects an unknown
    /// selection loudly rather than quietly transcribing with a different backend than the one
    /// that was chosen. An explicit legacy selection therefore remains a reliable rollback switch.
    var meetingTranscriptionBackendID: MeetingBackendID {
        get {
            guard let raw = self.defaults.string(forKey: Keys.meetingTranscriptionBackendID)
            else { return .productionDefault }
            return MeetingBackendID(rawValue: raw)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.meetingTranscriptionBackendID)
        }
    }

    /// Tier 1 native (Zoom/Teams/Webex) meeting auto-detection (default: ON).
    var meetingAutoDetectEnabled: Bool {
        get {
            let value = self.defaults.object(forKey: Keys.meetingAutoDetectEnabled)
            if value == nil { return true }
            return self.defaults.bool(forKey: Keys.meetingAutoDetectEnabled)
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.meetingAutoDetectEnabled)
        }
    }

    /// Opt-in browser-tab detection does not inspect URLs until enabled.
    var meetingAutoDetectBrowserEnabled: Bool {
        get { self.defaults.bool(forKey: Keys.meetingAutoDetectBrowserEnabled) }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.meetingAutoDetectBrowserEnabled)
        }
    }

    enum ThemePreference: String, CaseIterable, Identifiable, Codable {
        case system
        case light
        case dark

        var id: String {
            self.rawValue
        }

        var displayName: String {
            switch self {
            case .system: return "System"
            case .light: return "Light"
            case .dark: return "Dark"
            }
        }

        var systemImageName: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light: return "sun.max"
            case .dark: return "moon"
            }
        }

        var preferredColorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light: return .light
            case .dark: return .dark
            }
        }
    }

    var interfaceLanguage: PichiInterfaceLanguage {
        get { .stored(in: self.defaults) }
        set {
            guard newValue != self.interfaceLanguage else { return }
            objectWillChange.send()
            newValue.persist(in: self.defaults)
            PichiLocalization.configureApplicationLanguage()
            NotificationCenter.default.post(name: PichiLocalization.languageChanged, object: nil)
        }
    }

    var themePreference: ThemePreference {
        get {
            guard let raw = self.defaults.string(forKey: Keys.themePreference),
                  let preference = ThemePreference(rawValue: raw)
            else {
                return .system
            }
            return preference
        }
        set {
            objectWillChange.send()
            self.defaults.set(newValue.rawValue, forKey: Keys.themePreference)
            #if os(macOS)
            NSApplication.shared.appearance = BrandAppearanceController.nativeAppearance(for: newValue.preferredColorScheme)
            #endif
        }
    }

    var selectedAppleSpeechLocaleIdentifier: String {
        get {
            let stored = self.defaults.string(forKey: Keys.selectedAppleSpeechLocaleIdentifier)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let stored, !stored.isEmpty {
                return stored
            }
            return Locale.current.identifier.replacingOccurrences(of: "_", with: "-")
        }
        set {
            objectWillChange.send()
            let normalized = newValue
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "_", with: "-")
            self.defaults.set(normalized.isEmpty ? "en-US" : normalized, forKey: Keys.selectedAppleSpeechLocaleIdentifier)
        }
    }

    nonisolated struct CustomDictionaryEntry: Codable, Identifiable, Hashable, Sendable {
        let id: UUID
        /// Words/phrases to look for (case-insensitive matching)
        var triggers: [String]
        /// The correct replacement text
        var replacement: String

        init(triggers: [String], replacement: String) {
            self.id = UUID()
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }

        init(id: UUID, triggers: [String], replacement: String) {
            self.id = id
            self.triggers = triggers.map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            self.replacement = replacement
        }

        /// Trims padding around visible replacement text while preserving an intentional
        /// all-whitespace payload such as a newline, space, or tab.
        static func sanitizedReplacement(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? text : trimmed
        }
    }

    var customDictionaryEntries: [CustomDictionaryEntry] {
        get {
            guard let data = defaults.data(forKey: Keys.customDictionaryEntries),
                  let decoded = try? JSONDecoder().decode([CustomDictionaryEntry].self, from: data)
            else {
                return []
            }
            return decoded
        }
        set {
            objectWillChange.send()
            if let encoded = try? JSONEncoder().encode(newValue) {
                self.defaults.set(encoded, forKey: Keys.customDictionaryEntries)
            }
        }
    }

    var meetingSaveAudio: Bool {
        get { self.defaults.object(forKey: Keys.meetingSaveAudio) as? Bool ?? true }
        set { objectWillChange.send(); self.defaults.set(newValue, forKey: Keys.meetingSaveAudio) }
    }

    var meetingSpeakerLabelsEnabled: Bool {
        get { self.defaults.object(forKey: Keys.meetingSpeakerLabelsEnabled) as? Bool ?? true }
        set { objectWillChange.send(); self.defaults.set(newValue, forKey: Keys.meetingSpeakerLabelsEnabled) }
    }

    /// Explicit opt-in. Missing or future values keep the established processing schedule.
    var meetingSpeakerProcessingMode: MeetingSpeakerProcessingMode {
        get {
            self.defaults.string(forKey: Keys.meetingSpeakerProcessingMode)
                .flatMap(MeetingSpeakerProcessingMode.init(rawValue:)) ?? .afterRecording
        }
        set { objectWillChange.send(); self.defaults.set(newValue.rawValue, forKey: Keys.meetingSpeakerProcessingMode) }
    }

    var meetingPIIRedactionEnabled: Bool {
        get { self.defaults.bool(forKey: Keys.meetingPIIRedactionEnabled) }
        set { objectWillChange.send(); self.defaults.set(newValue, forKey: Keys.meetingPIIRedactionEnabled) }
    }
}
