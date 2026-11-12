import Foundation

/// Concrete joined local-store operations shared by both composition roots. This contains no
/// account/token management and does not implement N5's consent or cloud-delivery lifecycle.
@MainActor enum PrivateProfileSources {
    static func conceal() async {
        #if os(macOS)
        await LocalAPIServer.shared.stop().value
        await DictionaryAudioLearningService.shared.prepareForPrivateProfileTransition()
        await DictionaryRejectionService.shared.prepareForPrivateProfileTransition()
        await StatsSnapshotStore.shared.prepareForPrivateProfileTransition()
        #endif
        await SettingsStore.prepareForPrivateProfileTransition()
        await PrivateProfileAuxiliaryServices.prepareForTransition()
    }

    static func prepare(coordinator: MeetingSessionCoordinator?, asr: ASRService?) async throws {
        var firstError: Error?
        var lease: ASRActivityLease?
        do { lease = try asr?.beginSettingsBackupRestore() }
        catch { firstError = error }
        defer { if let lease { asr?.releaseExclusiveActivity(lease) } }
        do { try await coordinator?.prepareForPrivateProfileTransition() }
        catch { if firstError == nil { firstError = error } }
        #if os(macOS)
        await AutomaticDictionaryCorrectionTracker.shared.prepareForPrivateProfileTransition()
        await DictionaryRejectionService.shared.prepareForPrivateProfileTransition()
        let audio = DictationAudioHistoryStore.shared
        await audio.prepareForProfileTransition()
        do { try await TranscriptionHistoryStore.shared.prepareForProfileTransition() }
        catch { audio.resumeAfterFailedProfileTransition(); if firstError == nil { firstError = error } }
        ChatHistoryStore.shared.prepareForProfileTransition()
        do { try await FileTranscriptionHistoryStore.shared.prepareForProfileTransition() }
        catch { if firstError == nil { firstError = error } }
        AutomaticDictionarySuggestionPolicy.shared.prepareForProfileTransition()
        #endif
        await MeetingOwnerVoiceProfileService.shared.prepareForProfileTransition()
        await PronunciationDictionaryStore.shared.prepareForProfileTransition()
        await DictionaryNegativeExampleStore.shared.prepareForProfileTransition()
        if let firstError { throw firstError }
    }

    static func activate(_ profile: PrivateProfileSnapshot, asr: ASRService?) async throws {
        await SettingsStore.privateProfileDidChange()
        try await asr?.reconcilePrivateProfileSelection()
        await PrivateProfileAuxiliaryServices.activate(profile)
    }
}
