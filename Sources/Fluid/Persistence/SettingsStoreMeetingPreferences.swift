import Foundation
import Combine
import SwiftUI
#if os(macOS)
import AppKit
#endif

// The same defaults keys and Codable records are used by desktop and mobile targets.
extension SettingsStore {
    enum UpdateKeys {
        static let automaticUpdateDownloads = "AutomaticUpdateDownloads"
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

    /// Reuses finalized Parakeet windows so long recordings only process their remaining tail at stop.
    /// Experimental and enabled by default; users can fall back to full-buffer finalization.
    var experimentalParakeetUnifiedFinalEnabled: Bool {
        get { self.defaults.object(forKey: Keys.experimentalParakeetUnifiedFinalEnabled) as? Bool ?? true }
        set {
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.experimentalParakeetUnifiedFinalEnabled)
        }
    }

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

    /// Picker recency is separate from the admitted recording scope.
    var meetingRecentApplication: MeetingApplicationIdentity? {
        get {
            guard let data = self.defaults.data(forKey: Keys.meetingRecentApplication) else { return nil }
            return try? JSONDecoder().decode(MeetingApplicationIdentity.self, from: data)
        }
        set {
            guard var application = newValue else {
                self.defaults.removeObject(forKey: Keys.meetingRecentApplication)
                return
            }
            application.windowID = nil
            application.displayID = nil
            guard let data = try? JSONEncoder().encode(application) else { return }
            self.defaults.set(data, forKey: Keys.meetingRecentApplication)
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

    /// Feature availability is separate from the user's meeting detection preferences.
    @MainActor var fluidMeetEnabled: Bool {
        get { self.defaults.object(forKey: Keys.fluidMeetEnabled) as? Bool ?? true }
        set {
            guard newValue != self.fluidMeetEnabled else { return }
            objectWillChange.send()
            self.defaults.set(newValue, forKey: Keys.fluidMeetEnabled)
            NotificationCenter.default.post(name: .fluidMeetEnabledChanged, object: nil)
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

    /// Profile-scoped future-capture policy. Existing manifests retain their own immutable requirement.
    var meetingEncryptLocalRecordings: Bool {
        get { self.defaults.bool(forKey: Keys.meetingEncryptLocalRecordings) }
        set { objectWillChange.send(); self.defaults.set(newValue, forKey: Keys.meetingEncryptLocalRecordings) }
    }

    var meetingSaveAudio: Bool {
        get { self.defaults.object(forKey: Keys.meetingSaveAudio) as? Bool ?? true }
        set { objectWillChange.send(); self.defaults.set(newValue, forKey: Keys.meetingSaveAudio) }
    }

    /// Optional metadata requires an explicit choice, independent of the OS permission.
    var meetingLocationEnabled: Bool {
        get { self.defaults.bool(forKey: Keys.meetingLocationEnabled) }
        set { objectWillChange.send(); self.defaults.set(newValue, forKey: Keys.meetingLocationEnabled) }
    }

    var meetingSpeakerLabelsEnabled: Bool {
        get { self.defaults.object(forKey: Keys.meetingSpeakerLabelsEnabled) as? Bool ?? true }
        set { objectWillChange.send(); self.defaults.set(newValue, forKey: Keys.meetingSpeakerLabelsEnabled) }
    }

    /// New recordings share one live processing policy. The setter retains the legacy
    /// preference storage contract for imports and older clients; it cannot select an offline
    /// path for a new capture. Encoded sessions retain their own immutable processing mode.
    var meetingSpeakerProcessingMode: MeetingSpeakerProcessingMode {
        get { self.meetingSpeakerProcessingMode(for: .inRoom) }
        set { objectWillChange.send(); self.defaults.set(newValue.rawValue, forKey: Keys.meetingSpeakerProcessingMode) }
    }

    /// Processing behavior belongs to the meeting, independently of its selected speech model.
    /// Capability/language validation must reject unsupported requests before capture, rather
    /// than silently record for a full post-Stop pass. Old manifests and retry pins are untouched.
    func meetingSpeakerProcessingMode(for mode: MeetingCaptureMode) -> MeetingSpeakerProcessingMode {
        .streaming
    }

    /// Freeze the current recording policy when a platform has resolved its sources.
    /// Capture admission owns encryption requirements; applying preferences must preserve
    /// that explicit requirement as well as the selected sources and backend override.
    func applyingMeetingRecordingPreferences(to configuration: MeetingCaptureConfiguration) -> MeetingCaptureConfiguration {
        var configured = configuration
        let speakerLabelsEnabled = self.meetingSpeakerLabelsEnabled
        configured.audioStorageMode = self.meetingSaveAudio ? .retainedFiles : .memoryOnly
        configured.speakerLabelsEnabled = speakerLabelsEnabled
        configured.speakerProcessingMode = speakerLabelsEnabled
            && self.meetingSpeakerProcessingMode(for: configuration.mode) == .streaming ? .streaming : nil
        configured.piiRedactionEnabled = self.meetingPIIRedactionEnabled
        return configured
    }

    var meetingPIIRedactionEnabled: Bool {
        get { self.defaults.bool(forKey: Keys.meetingPIIRedactionEnabled) }
        set { objectWillChange.send(); self.defaults.set(newValue, forKey: Keys.meetingPIIRedactionEnabled) }
    }
}
