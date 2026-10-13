import SwiftUI
import UniformTypeIdentifiers

/// The mobile subset keeps the desktop destinations and their existing preference owner.
struct MobileSettingsRoot: View {
    @ObservedObject var asr: ASRService
    let privacy: PichiTranscriptPrivacyService
    let microphones: [MeetingMicrophoneIdentity]
    let reportError: (Error) -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            Section {
                NavigationLink { MobileGeneralSettings() } label: { Label(PichiLocalization.text("General"), systemImage: "gearshape") }
                    .accessibilityIdentifier("settings.general")
                NavigationLink { MobileRecordingSettings(microphones: microphones) } label: {
                    Label(PichiLocalization.text("Recording"), systemImage: "waveform")
                }.accessibilityIdentifier("settings.recording")
                NavigationLink { MobileVoiceEngineSettings(asr: asr, reportError: reportError) } label: {
                    Label(PichiLocalization.text("Voice Engine"), systemImage: "waveform")
                }.accessibilityIdentifier("settings.models")
                NavigationLink { MobilePrivacySettings(privacy: privacy, reportError: reportError) } label: {
                    Label(PichiLocalization.text("Privacy"), systemImage: "lock.shield")
                }.accessibilityIdentifier("settings.privacy")
            }
            Section {
                Text(PichiLocalization.text("Audio recordings and transcripts are stored on this device."))
                    .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
        }.listStyle(.insetGrouped).accessibilityIdentifier("settings.root")
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
        }.navigationTitle(PichiLocalization.text("General"))
    }
}

struct MobileRecordingSettings: View {
    let microphones: [MeetingMicrophoneIdentity]
    @ObservedObject private var settings = SettingsStore.shared
    @ObservedObject private var diarization = MeetingDiarizationModelStore.shared
    @Environment(\.dismiss) private var dismiss
    @State private var isPreparing = false
    @State private var error: String?

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
            Section(PichiLocalization.text("Speaker labels")) {
                Toggle(PichiLocalization.text("Identify each speaker"), isOn: $settings.meetingSpeakerLabelsEnabled)
                    .accessibilityIdentifier("recording.diarization")
                if settings.meetingSpeakerLabelsEnabled {
                    diarizationState
                    if isPreparing { ProgressView() }
                    Button(PichiLocalization.text("Download")) {
                        isPreparing = true
                        Task { @MainActor in
                            defer { isPreparing = false }
                            do { _ = try await diarization.ensureInstalled(includingVoiceEncoder: true) } catch { self.error = error.localizedDescription }
                        }
                    }.disabled(isPreparing).accessibilityIdentifier("recording.downloadSpeakerModel")
                    Text(PichiLocalization.text("Speaker labels are added after recording."))
                }
            }
            if let error { Section { Text(error).foregroundStyle(.red) } }
        }.navigationTitle(PichiLocalization.text("Recording"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(PichiLocalization.text("Done")) { dismiss() } } }
            .accessibilityIdentifier("settings.recording.detail")
    }

    @ViewBuilder private var diarizationState: some View {
        switch diarization.state {
        case .idle: Text(PichiLocalization.text("Available after recording"))
        case .checking: ProgressView(PichiLocalization.text("Checking…"))
        case .downloading(let progress): ProgressView(value: progress)
        case .ready:
            if diarization.allSpeakerResourcesReady {
                Label(PichiLocalization.text("Ready · runs after recording"), systemImage: "checkmark.circle.fill")
            } else { Text(PichiLocalization.text("Available after recording")) }
        case .failed(let message): Text(message).foregroundStyle(.red)
        }
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
                        Text(PichiLocalization.text(model.languageSupport)).font(theme.typography.bodySmall).foregroundStyle(.secondary)
                        Text(model.downloadSize).font(theme.typography.caption).foregroundStyle(.secondary)
                        if asr.downloadingModelId == model.id {
                            if let progress = asr.downloadProgress { ProgressView(value: progress) } else { ProgressView() }
                            Button(PichiLocalization.text("Cancel")) { asr.cancelModelDownload() }
                        } else {
                            if installed.contains(model.id) {
                                Button(PichiLocalization.text("Use Model")) {
                                    Task { do { try await asr.activateModel(model); await refresh() } catch { reportError(error) } }
                                }.disabled(asr.activeExclusiveActivity != nil).accessibilityIdentifier("model.activate.\(model.id)")
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
    let privacy: PichiTranscriptPrivacyService
    let reportError: (Error) -> Void
    @ObservedObject private var settings = SettingsStore.shared
    @Environment(\.theme) private var theme
    @State private var isPreparing = false
    @State private var progress: Double?
    @State private var preparationTask: Task<Void, Never>?

    var body: some View {
        Form {
            Section(PichiLocalization.text("Audio storage")) {
                Toggle(PichiLocalization.text("Save audio recordings"), isOn: $settings.meetingSaveAudio)
                    .accessibilityIdentifier("privacy.saveAudio")
                Text(PichiLocalization.text("When disabled, audio is never written to files, including temporary files. Only the transcript is saved."))
                    .font(theme.typography.caption).foregroundStyle(.secondary)
                if settings.meetingSaveAudio {
                    Picker(PichiLocalization.text("Keep recordings"), selection: $settings.meetingAudioRetentionPolicy) {
                        ForEach(MeetingAudioRetentionPolicy.allCases, id: \.rawValue) { policy in
                            Text(PichiLocalization.text(policy.displayName)).tag(policy)
                        }
                    }.accessibilityIdentifier("privacy.retention")
                    Text(PichiLocalization.text("Applies to past meetings too. Transcripts are always kept."))
                        .font(theme.typography.caption).foregroundStyle(.secondary)
                }
            }
            Section(PichiLocalization.text("Sensitive data")) {
                Toggle(PichiLocalization.text("Redact sensitive data"), isOn: Binding(
                    get: { settings.meetingPIIRedactionEnabled }, set: { enable in
                        if !enable { settings.meetingPIIRedactionEnabled = false; return }
                        isPreparing = true; progress = nil
                        preparationTask = Task { @MainActor in
                            defer { isPreparing = false; progress = nil; preparationTask = nil }
                            do {
                                try await privacy.prepare(progress: { value in Task { @MainActor in progress = value } })
                                try Task.checkCancellation()
                                settings.meetingPIIRedactionEnabled = true
                            } catch is CancellationError { }
                            catch { reportError(error) }
                        }
                    }))
                    .disabled(isPreparing).accessibilityIdentifier("privacy.pii")
                if isPreparing {
                    if let progress { ProgressView(value: progress) } else { ProgressView() }
                    Button(PichiLocalization.text("Cancel")) { preparationTask?.cancel() }
                }
                Text(PichiLocalization.text("Russian names and structured identifiers are redacted locally before saving text. Recognition may miss sensitive data. Review the result before sharing."))
                    .font(theme.typography.caption).foregroundStyle(.secondary)
                if settings.meetingSaveAudio {
                    Text(PichiLocalization.text("Audio recordings retain the original voices and sensitive information. Text redaction does not change audio."))
                        .font(theme.typography.caption).foregroundStyle(.secondary)
                }
            }
            Section {
                Text(PichiLocalization.text("Changes apply to new meetings. Audio retention also applies to existing recordings."))
                    .font(theme.typography.caption).foregroundStyle(.secondary)
            }
        }.navigationTitle(PichiLocalization.text("Privacy")).accessibilityIdentifier("settings.privacy.detail")
    }
}
