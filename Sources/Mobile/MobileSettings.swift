import SwiftUI
import UniformTypeIdentifiers

/// Settings routes belong to the Settings stack, rather than to the selected app section.
enum MobileSettingsDestination: Hashable {
    case general, recording, models, privacy
}

/// The mobile subset keeps the desktop destinations and their existing preference owner.
struct MobileSettingsRoot: View {
    @ObservedObject var asr: ASRService
    let privacy: PichiTranscriptPrivacyService
    let microphones: [MeetingMicrophoneIdentity]
    @ObservedObject var required: MobileRequiredResources
    @ObservedObject var privacyActivation: MobilePrivacyActivation
    /// Setup replaces the meeting interface, so it is offered only while no meeting, export or
    /// model operation is running.
    let canReplaySetup: Bool
    let reportError: (Error) -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                NavigationLink(value: MobileSettingsDestination.general) { Label(PichiLocalization.text("General"), systemImage: "gearshape") }
                    .accessibilityIdentifier("settings.general")
                NavigationLink(value: MobileSettingsDestination.recording) {
                    Label(PichiLocalization.text("Recording"), systemImage: "waveform")
                }.accessibilityIdentifier("settings.recording")
                NavigationLink(value: MobileSettingsDestination.models) {
                    Label(PichiLocalization.text("Voice Engine"), systemImage: "waveform")
                }.accessibilityIdentifier("settings.models")
                NavigationLink(value: MobileSettingsDestination.privacy) {
                    Label(PichiLocalization.text("Data cleanup"), systemImage: "lock.shield")
                }.accessibilityIdentifier("settings.privacy")
            } footer: {
                Text(PichiLocalization.text("Audio recordings and transcripts are stored on this device."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
            Section {
                Button {
                    guard canReplaySetup else { return }
                    settings.resetMobileSetupProgress()
                } label: {
                    Label(PichiLocalization.text("Replay onboarding"), systemImage: "arrow.counterclockwise")
                }
                .disabled(!canReplaySetup)
                .accessibilityIdentifier("settings.replaySetup")
            } footer: {
                Text(PichiLocalization.text("Your meetings, models and voice profile are kept."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
        }.listStyle(.insetGrouped).accessibilityIdentifier("settings.root")
            .navigationDestination(for: MobileSettingsDestination.self) { destination in
                switch destination {
                case .general: MobileGeneralSettings()
                case .recording: MobileRecordingSettings(microphones: microphones, required: required)
                case .models: MobileVoiceEngineSettings(asr: asr, reportError: reportError)
                case .privacy:
                    MobilePrivacySettings(activation: privacyActivation)
                }
            }
    }
}

private struct MobileGeneralSettings: View {
    @ObservedObject private var settings = SettingsStore.shared
    var body: some View {
        Form {
            Picker(PichiLocalization.text("Interface language"), selection: $settings.interfaceLanguage) {
                ForEach(PichiInterfaceLanguage.allCases) { Text($0.displayName).tag($0) }
            }.accessibilityIdentifier("settings.interfaceLanguage")
            Picker(PichiLocalization.text("Appearance"), selection: $settings.themePreference) {
                ForEach(SettingsStore.ThemePreference.allCases) { item in
                    Text(PichiLocalization.text(item.displayName)).tag(item)
                }
            }.accessibilityIdentifier("settings.appearance")
        }.navigationTitle(PichiLocalization.text("General")).accessibilityIdentifier("settings.general.detail")
    }
}

struct MobileRecordingSettings: View {
    let microphones: [MeetingMicrophoneIdentity]
    var isPresentedAsSheet = false
    @ObservedObject var required: MobileRequiredResources
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @Environment(\.dismiss) private var dismiss

    private var selectedMicrophone: Binding<String> {
        Binding(get: { settings.meetingRecordingDefaults.microphoneCoreAudioUID ?? "" }, set: { selected in
            var value = settings.meetingRecordingDefaults
            value.isConfigured = true; value.mode = .inRoom
            let mic = microphones.first { $0.coreAudioUID == selected }
            value.microphoneCoreAudioUID = mic?.coreAudioUID
            value.microphoneCaptureDeviceID = mic?.captureDeviceID
            value.microphoneRole = .shared
            settings.meetingRecordingDefaults = value
        })
    }
    private var supportedLanguages: [String] {
        (PichiMeetingProviderFactory.registeredLanguageCodes(for: settings.selectedSpeechModel.rawValue) ?? []).sorted()
    }
    private var selectedLanguage: Binding<String> {
        Binding(get: {
            let stored = settings.meetingRecordingDefaults.languageCode
            return stored.flatMap { supportedLanguages.contains($0) ? $0 : nil }
                ?? PichiMeetingProviderFactory.defaultLanguageCode(for: settings.selectedSpeechModel.rawValue) ?? "auto"
        }, set: { code in
            var value = settings.meetingRecordingDefaults
            value.isConfigured = true; value.mode = .inRoom; value.languageCode = code
            settings.meetingRecordingDefaults = value
        })
    }

    var body: some View {
        Form {
            Section(PichiLocalization.text("Audio sources")) {
                LabeledContent(PichiLocalization.text("Meeting type"), value: PichiLocalization.text("In-room"))
                Picker(PichiLocalization.text("Microphone"), selection: selectedMicrophone) {
                    Text(PichiLocalization.text("System Default")).tag("")
                    ForEach(microphones, id: \.captureDeviceID) { microphone in
                        Text(microphone.displayName).tag(microphone.coreAudioUID ?? microphone.captureDeviceID)
                    }
                }.accessibilityIdentifier("recording.microphone")
            }
            Section(PichiLocalization.text("Transcript language")) {
                Picker(PichiLocalization.text("Language"), selection: selectedLanguage) {
                    ForEach(supportedLanguages, id: \.self) { code in
                        Text(code == "auto" ? PichiLocalization.text("Automatic")
                            : (PichiLocalization.locale.localizedString(forLanguageCode: code) ?? code)).tag(code)
                    }
                }.accessibilityIdentifier("recording.language")
            }
            Section(PichiLocalization.text("Meeting location")) {
                MeetingLocationSettingsContent()
            }
            Section(PichiLocalization.text("Speaker labels")) {
                Text(PichiLocalization.text("Speaker labels appear automatically while you record. Short or overlapping speech can be uncertain. You can correct participant names later."))
                Text(PichiLocalization.text("Text and participant labels update in fragments. A delay is normal while enough speech is collected."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                MobileRequiredResourcesStatus(resources: required)
            }
            Section(PichiLocalization.text("My voice")) {
                MeetingOwnerVoiceSettingsContent(audioArbiter: AppServices.shared.meetingAudioActivityArbiter,
                    microphone: microphones.first { $0.coreAudioUID == settings.meetingRecordingDefaults.microphoneCoreAudioUID })
            }
        }.navigationTitle(PichiLocalization.text("Recording"))
            .toolbar {
                if isPresentedAsSheet {
                    ToolbarItem(placement: .confirmationAction) {
                        Button(PichiLocalization.text("Done")) { dismiss() }
                            .accessibilityIdentifier("settings.recording.done")
                    }
                }
            }
            .accessibilityIdentifier("settings.recording.detail")
    }

}

private struct MobileVoiceEngineSettings: View {
    @ObservedObject var asr: ASRService
    let reportError: (Error) -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var installed: Set<String> = []
    @State private var importing: SettingsStore.SpeechModel?
    @State private var fileImporter = false
    @State private var activatingModelID: String?

    var body: some View {
        List {
            ForEach(asr.availableMeetingModels, id: \.rawValue) { model in
                Section {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text(model.displayName).font(theme.typography.sectionTitle)
                            Spacer()
                            if settings.selectedSpeechModel == model { Image(systemName: "checkmark.circle.fill").foregroundStyle(.tint) }
                        }
                        Text(PichiLocalization.text(model.cardDescription)).font(theme.typography.bodySmall)
                        if let creditLine = model.creditLine {
                            Text(PichiLocalization.text(creditLine)).font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                        }
                        Text(PichiLocalization.text(model.languageSupport)).font(theme.typography.bodySmall).foregroundStyle(theme.palette.secondaryText)
                        Text(model.downloadSize).font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                        MobileModelDetails(modelID: model.id)
                        if asr.downloadingModelId == model.id {
                            if let progress = asr.downloadProgress { ProgressView(value: progress) } else { ProgressView() }
                            Button(PichiLocalization.text("Cancel")) { asr.cancelModelDownload() }
                        } else {
                            if installed.contains(model.id) {
                                Button {
                                    activatingModelID = model.id
                                    Task { @MainActor in
                                        defer { activatingModelID = nil }
                                        do { try await asr.activateModel(model); await refresh() }
                                        catch { reportError(error) }
                                    }
                                } label: {
                                    if activatingModelID == model.id {
                                        ProgressView()
                                    } else {
                                        Label(PichiLocalization.text(settings.selectedSpeechModel == model ? "Selected" : "Use Model"),
                                            systemImage: settings.selectedSpeechModel == model ? "checkmark.circle.fill" : "checkmark.circle")
                                    }
                                }.disabled(asr.activeExclusiveActivity != nil || activatingModelID != nil
                                    || settings.selectedSpeechModel == model)
                                    .accessibilityIdentifier("model.activate.\(model.id)")
                                if settings.selectedSpeechModel == model {
                                    Text(PichiLocalization.text("Selected for new meetings. Text and speaker labels update during recording."))
                                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                                        .accessibilityIdentifier("model.selected.\(model.id)")
                                }
                                Button(PichiLocalization.text("Delete"), role: .destructive) {
                                    Task { do { try await asr.clearModelCache(for: model); await refresh() } catch { reportError(error) } }
                                }.disabled(asr.activeExclusiveActivity != nil).accessibilityIdentifier("model.delete.\(model.id)")
                            } else if model.supportsAutomaticDownload {
                                Button(PichiLocalization.text("Download")) {
                                    Task {
                                        do { try await asr.downloadModel(model, progressHandler: nil); await refresh() }
                                        catch { reportError(error) }
                                    }
                                }.disabled(asr.activeExclusiveActivity != nil || (asr.downloadingModelId != nil))
                                    .accessibilityIdentifier("model.download.\(model.id)")
                            }
                            if model.supportsFolderImport {
                                Button(PichiLocalization.text("Import")) { importing = model; fileImporter = true }
                                    .disabled(asr.activeExclusiveActivity != nil)
                            }
                        }
                    }.padding(.vertical, 6)
                }
            }
        }.navigationTitle(PichiLocalization.text("Voice Engine"))
            .fileImporter(isPresented: $fileImporter, allowedContentTypes: [.folder]) { result in
                guard let model = importing else { return }
                switch result {
                case .failure(let error): reportError(error)
                case .success(let url):
                    Task {
                        let access = url.startAccessingSecurityScopedResource()
                        defer { if access { url.stopAccessingSecurityScopedResource() } }
                        do { try await asr.importModel(model, from: url); await refresh() } catch { reportError(error) }
                    }
                }
            }
            .task { await refresh() }.accessibilityIdentifier("settings.models.detail")
    }
    private func refresh() async {
        var values: Set<String> = []
        for model in asr.availableMeetingModels {
            if (try? await asr.modelIsInstalled(model)) == true { values.insert(model.id) }
        }
        installed = values
    }
}

private struct MobilePrivacySettings: View {
    @ObservedObject var activation: MobilePrivacyActivation
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var dictionaryEdit: MobileSensitiveDictionaryEdit?

    var body: some View {
        Form {
            Section {
                MobileAudioPrivacyControls()
                if settings.meetingSaveAudio {
                    Picker(PichiLocalization.text("Keep recordings"), selection: $settings.meetingAudioRetentionPolicy) {
                        ForEach(MeetingAudioRetentionPolicy.allCases, id: \.rawValue) { policy in
                            Text(PichiLocalization.text(policy.displayName)).tag(policy)
                        }
                    }.accessibilityIdentifier("privacy.retention")
                }
            } header: {
                Text(PichiLocalization.text("Audio storage"))
            } footer: {
                if settings.meetingSaveAudio {
                    Text(PichiLocalization.text("Applies to past meetings too. Transcripts are always kept."))
                        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                }
            }
            Section(PichiLocalization.text("Data cleanup")) {
                MobilePrivacyActivationControls(activation: activation)
            }
            MobileSensitiveDictionarySettings { entry in dictionaryEdit = .init(entry: entry) }
            Section {
                Text(PichiLocalization.text("Changes apply to new meetings. Audio retention also applies to existing recordings."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
        }.navigationTitle(PichiLocalization.text("Data cleanup")).accessibilityIdentifier("settings.privacy.detail")
            .sheet(item: $dictionaryEdit) { request in
                MobileSensitiveDictionaryEditor(entry: request.entry)
            }
    }
}
