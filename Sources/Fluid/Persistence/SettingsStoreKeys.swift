import Foundation

extension SettingsStore {
    enum Keys {
        static let fillerWordDefaultsMigrationV2 = "FillerWordDefaultsMigrationV2"
        static let fillerWordDefaultsMigrationV1 = "FillerWordDefaultsMigrationV1"
        static let holdSpaceToMute = "HoldSpaceToMute"
        static let meetingSaveAudio = "MeetingSaveAudio"
        static let meetingEncryptLocalRecordings = "MeetingEncryptLocalRecordings"
        static let meetingLocationEnabled = "MeetingLocationEnabled"
        static let meetingSpeakerLabelsEnabled = "MeetingSpeakerLabelsEnabled"
        static let meetingSpeakerProcessingMode = "MeetingSpeakerProcessingMode"
        static let meetingPIIRedactionEnabled = "MeetingPIIRedactionEnabled"
        static let enableAIProcessing = "EnableAIProcessing"
        static let showMainWindowAtLoginLaunch = "ShowMainWindowAtLoginLaunch"
        static let fileTranscriptionSpeakerLabelsEnabled = "FileTranscriptionSpeakerLabelsEnabled"
        static let fileTranscriptionExpectedSpeakerCount = "FileTranscriptionExpectedSpeakerCount"
        static let dictationPromptOff = "DictationPromptOff"
        static let enableDebugLogs = "EnableDebugLogs"
        static let availableAIModels = "AvailableAIModels"
        static let availableModelsByProvider = "AvailableModelsByProvider"
        static let selectedAIModel = "SelectedAIModel"
        static let selectedModelByProvider = "SelectedModelByProvider"
        static let selectedProviderID = "SelectedProviderID"
        static let privateAIPrefixKVCacheEnabled = "PrivateAIProviderPrefixKVCacheEnabled"
        static let privateAIBoostEnabled = "PrivateAIProviderBoostEnabled"
        static let privateAIIdleUnloadMinutes = "PrivateAIProviderIdleUnloadMinutes"
        static let privateAIIdleUnloadTestSeconds = "PrivateAIProviderIdleUnloadTestSeconds"
        static let privateAIBackendPreference = SettingsStore.privateAIBackendPreferenceDefaultsKey
        static let privateAIContextTokenLimit = "PrivateAIProviderContextTokenLimit"
        static let privateAIContextDefaultMigratedTo4K = "PrivateAIProviderContextDefaultMigratedTo4K"
        static let providerAPIKeys = "ProviderAPIKeys"
        static let providerAPIKeyIdentifiers = "ProviderAPIKeyIdentifiers"
        static let savedProviders = "SavedProviders"
        static let verifiedProviderFingerprints = "VerifiedProviderFingerprints"
        static let verifiedPrivateAIModelFingerprints = "VerifiedPrivateAIModelFingerprints"
        static let shareAnonymousAnalytics = "ShareAnonymousAnalytics"
        static let privateAIInterestCaptured = "PrivateAIProviderInterestCaptured"
        static let hotkeyShortcutKey = "HotkeyShortcutKey"
        static let primaryDictationShortcutsKey = "PrimaryDictationShortcuts"
        static let preferredInputDeviceUID = "PreferredInputDeviceUID"
        static let microphonePriority = "MicrophonePriority"
        static let suppressedMicrophoneUIDs = "SuppressedMicrophoneUIDs"
        static let preferredOutputDeviceUID = "PreferredOutputDeviceUID"
        static let meetingRecordingDefaults = "MeetingRecordingDefaults"
        static let meetingRecentApplication = "MeetingRecentApplication"
        static let meetingAudioRetentionPolicy = "MeetingAudioRetentionPolicy"
        static let meetingTranscriptionBackendID = "MeetingTranscriptionBackendID"
        static let fluidMeetEnabled = "FluidMeetEnabled"
        static let meetingAutoDetectEnabled = "MeetingAutoDetectEnabled"
        static let meetingAutoDetectBrowserEnabled = "MeetingAutoDetectBrowserEnabled"
        static let localAPIEnabled = "LocalAPIEnabled"
        static let microphoneSelectionMode = "MicrophoneSelectionMode"
        // Keep the original persisted key so existing installs migrate in place.
        static let microphoneSelectionMigrationVersion = "AppOnlyMicrophoneSelectionMigrationVersion"
        static let showMicrophoneChangeAlerts = "ShowMicrophoneChangeAlerts"
        static let showPasteCheckAlerts = "ShowPasteCheckAlerts"
        static let visualizerNoiseThreshold = "VisualizerNoiseThreshold"
        static let launchAtStartup = "LaunchAtStartup"
        static let showInDock = "ShowInDock"
        static let accentColorOption = "AccentColorOption"
        static let themePreference = "ThemePreference"
        static let enableTranscriptionSounds = "EnableTranscriptionSounds"
        static let transcriptionStartSound = "TranscriptionStartSound"
        static let transcriptionSoundVolume = "TranscriptionSoundVolume"
        static let pressAndHoldMode = "PressAndHoldMode"
        static let hotkeyMode = "HotkeyMode"
        static let enableStreamingPreview = "EnableStreamingPreview"
        static let experimentalParakeetUnifiedFinalEnabled = "ExperimentalParakeetUnifiedFinalEnabled"
        static let returnDictationToStartingField = "ReturnDictationToStartingField"
        static let showHistoryPerformanceMetrics = "ShowHistoryPerformanceMetrics"
        static let skipSilentRecordingsEnabled = "SkipSilentRecordingsEnabled"
        static let enableAIStreaming = "EnableAIStreaming"
        static let copyTranscriptionToClipboard = "CopyTranscriptionToClipboard"
        static let textInsertionMode = "TextInsertionMode"
        static let spokenSendEnabled = "SpokenSendEnabled"
        static let spokenSendImmediatelyEnabled = "SpokenSendImmediatelyEnabled"
        static let spokenSendPhrase = "SpokenSendPhrase"
        static let spokenSendKey = "SpokenSendKey"
        static let reliablePasteMigrationV1 = "TextInsertionModeMigratedToReliablePasteV1"
        static let autoUpdateCheckEnabled = UpdateKeys.autoUpdateCheckEnabled
        static let showUpdatePopups = UpdateKeys.showUpdatePopups
        static let betaReleasesEnabled = UpdateKeys.betaReleasesEnabled
        static let lastUpdateCheckDate = UpdateKeys.lastUpdateCheckDate
        static let updatePromptSnoozedUntil = UpdateKeys.updatePromptSnoozedUntil
        static let snoozedUpdateVersion = UpdateKeys.snoozedUpdateVersion
        static let playgroundUsed = "PlaygroundUsed"
        static let onboardingCompleted = "OnboardingCompleted"
        static let onboardingGeneration = "OnboardingGeneration"
        static let manualOnboardingResetRequested = "ManualOnboardingResetRequested"
        static let manualOnboardingResetRequestedAt = "ManualOnboardingResetRequestedAt"
        static let onboardingCurrentStep = "OnboardingCurrentStep"
        static let onboardingAISkipped = "OnboardingAISkipped"
        static let onboardingPlaygroundValidated = "OnboardingPlaygroundValidated"
        static let onboardingPlaygroundSkipped = "OnboardingPlaygroundSkipped"
        static let onboardingSelectedLanguageID = "OnboardingSelectedLanguageID"

        // Command Mode Keys
        static let commandModeSelectedModel = "CommandModeSelectedModel"
        static let commandModeSelectedProviderID = "CommandModeSelectedProviderID"
        static let commandModeHotkeyShortcut = "CommandModeHotkeyShortcut"
        static let commandModeConfirmBeforeExecute = "CommandModeConfirmBeforeExecute"
        static let meetingRecordingHotkeyShortcut = "MeetingRecordingHotkeyShortcut"
        static let cancelRecordingHotkeyShortcut = "CancelRecordingHotkeyShortcut"
        static let pasteLastTranscriptionHotkeyShortcut = "PasteLastTranscriptionHotkeyShortcut"
        static let pasteLastTranscriptionShortcutEnabled = "PasteLastTranscriptionShortcutEnabled"
        static let commandModeLinkedToGlobal = "CommandModeLinkedToGlobal"
        static let commandModeShortcutEnabled = "CommandModeShortcutEnabled"

        // Prompt Mode Keys (Transcribe with Prompt)
        static let promptModeHotkeyShortcut = "PromptModeHotkeyShortcut"
        static let promptModeShortcutEnabled = "PromptModeShortcutEnabled"
        static let promptModeSelectedPromptID = "PromptModeSelectedPromptID"
        static let secondaryDictationPromptOff = "SecondaryDictationPromptOff"
        static let secondaryPromptShortcutRemoved = "SecondaryPromptShortcutRemoved"
        static let legacySecondaryPromptShortcutRetired = "LegacySecondaryPromptShortcutRetired"
        static let dictationPromptConfigurations = "DictationPromptConfigurations"

        // Rewrite Mode Keys
        static let rewriteModeHotkeyShortcut = "RewriteModeHotkeyShortcut"
        static let rewriteModeSelectedModel = "RewriteModeSelectedModel"
        static let rewriteModeSelectedProviderID = "RewriteModeSelectedProviderID"
        static let rewriteModeLinkedToGlobal = "RewriteModeLinkedToGlobal"
        static let editModeReadsScreen = "EditModeReadsScreen"

        // Model Reasoning Config Keys
        static let modelReasoningConfigs = "ModelReasoningConfigs"
        static let rewriteModeShortcutEnabled = "RewriteModeShortcutEnabled"
        static let showThinkingTokens = "ShowThinkingTokens"

        // Stats Keys
        static let userTypingWPM = "UserTypingWPM"
        static let saveTranscriptionHistory = "SaveTranscriptionHistory"
        static let saveAudioWithTranscriptionHistory = "SaveAudioWithTranscriptionHistory"
        static let audioHistoryBudgetGB = "AudioHistoryBudgetGB"
        static let notifyAIProcessingFailures = "NotifyAIProcessingFailures"

        // Filler Words
        static let fillerWords = "FillerWords"
        static let removeFillerWordsEnabled = "RemoveFillerWordsEnabled"
        static let autoConvertPunctuationEnabled = "AutoConvertPunctuationEnabled"
        static let literalDictationFormattingEnabled = "LiteralDictationFormattingEnabled"
        static let punctuationDictionaryPrefix = "PunctuationDictionaryPrefix"
        static let punctuationDictionaryRules = "PunctuationDictionaryRules"
        static let spokenFormattingActionRules = "SpokenFormattingActionRules"

        /// GAAV Mode (removes capitalization and trailing punctuation)
        static let gaavModeEnabled = "GAAVModeEnabled"
        static let gaavLowercaseFirstLetterEnabled = "GAAVLowercaseFirstLetterEnabled"
        static let gaavRemoveTrailingPeriodEnabled = "GAAVRemoveTrailingPeriodEnabled"

        /// Continuous Dictation Mode (append trailing space + smart caps for chaining)
        static let continuousDictationModeEnabled = "ContinuousDictationModeEnabled"
        static let continuousDictationSpacingEnabled = "ContinuousDictationSpacingEnabled"
        static let contextAwareCapitalizationEnabled = "ContextAwareCapitalizationEnabled"
        static let dictationScreenContextEnabled = "DictationScreenContextEnabled"

        // Custom Dictionary
        static let customDictionaryEntries = "CustomDictionaryEntries"
        static let automaticDictionaryLearningEnabled = "AutomaticDictionaryLearningEnabled"
        static let automaticDictionarySuggestionFrequency = "AutomaticDictionarySuggestionFrequency"
        static let vocabularyBoostingEnabled = "VocabularyBoostingEnabled"
        static let pronunciationMatchingEnabled = "PronunciationMatchingEnabled"

        // Transcription Provider (ASR)
        static let selectedTranscriptionProvider = "SelectedTranscriptionProvider"
        static let whisperModelSize = "WhisperModelSize"

        /// Unified Speech Model (replaces above two)
        static let selectedSpeechModel = "SelectedSpeechModel"
        static let selectedWhisperLanguageCode = "SelectedWhisperLanguageCode"
        static let selectedCohereLanguage = "SelectedCohereLanguage"
        static let selectedNemotronLanguage = "SelectedNemotronLanguage"
        static let selectedAppleSpeechLocaleIdentifier = "SelectedAppleSpeechLocaleIdentifier"
        static let externalCoreMLArtifactsDirectories = "ExternalCoreMLArtifactsDirectories"

        // Overlay Position
        static let overlayPosition = "OverlayPosition"
        static let notchPresentationMode = "NotchPresentationMode"
        static let overlayBottomOffset = "OverlayBottomOffset"
        static let overlayBottomOffsetMigratedTo50 = "OverlayBottomOffsetMigratedTo50"
        static let overlaySize = "OverlaySize"
        static let overlayMaterial = "OverlayMaterial"
        static let overlayGlassOpacity = "OverlayGlassOpacity"
        static let meetingOverlayPreference = "MeetingOverlayPreference"
        static let transcriptionPreviewCharLimit = "TranscriptionPreviewCharLimit"

        /// Media Playback Control
        static let pauseMediaDuringTranscription = "PauseMediaDuringTranscription"

        /// Custom Dictation Prompt
        static let customDictationPrompt = "CustomDictationPrompt"

        // Dictation Prompt Profiles (multi-prompt system)
        static let dictationPromptProfiles = "DictationPromptProfiles"
        static let appPromptBindings = "AppPromptBindings"
        static let selectedDictationPromptID = "SelectedDictationPromptID"
        static let sendCustomPromptOnly = "SendCustomPromptOnly"
        static let editPromptOff = "EditPromptOff"
        static let selectedEditPromptID = "SelectedEditPromptID"
        static let selectedWritePromptID = "SelectedWritePromptID" // legacy fallback key
        static let selectedRewritePromptID = "SelectedRewritePromptID" // legacy fallback key

        // Default Dictation Prompt Override (optional)
        // nil   => use built-in default prompt
        // ""    => use empty system prompt
        // other => use custom default prompt text
        static let defaultDictationPromptOverride = "DefaultDictationPromptOverride"
        static let defaultEditPromptOverride = "DefaultEditPromptOverride"
        static let defaultWritePromptOverride = "DefaultWritePromptOverride" // legacy fallback key
        static let defaultRewritePromptOverride = "DefaultRewritePromptOverride" // legacy fallback key

        /// Streak Settings
        static let weekendsDontBreakStreak = "WeekendsDontBreakStreak"
    }
}
