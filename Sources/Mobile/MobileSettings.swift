import SwiftUI
import UniformTypeIdentifiers

/// Settings routes belong to the Settings stack, rather than to the selected app section.
enum MobileSettingsDestination: Hashable {
    case recording, participants, models, privacy, account, kiosk
}

/// The mobile subset keeps the desktop destinations and their existing preference owner.
/// Each destination has its own symbol and a one-line summary of what it contains; the two
/// app-wide pickers stay on the root instead of behind a separate General page.
struct MobileSettingsRoot: View {
    @ObservedObject var accountSession: AccountSessionService = AppServices.shared.accountSession
    var accountInteraction: MobileAccountInteraction? = nil
    var cloudPublication: PichiCloudPublicationService? = nil
    var cloudInteraction: MobileCloudInteraction? = nil
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
    @ObservedObject private var privateProfile = PrivateProfileService.shared
    @Environment(\.theme) private var theme

    var body: some View {
        List {
            if accountSession.isConfigured {
                Section {
                    NavigationLink(value: MobileSettingsDestination.account) {
                        MobileSettingsRowLabel(PichiLocalization.text("account.title", defaultValue: "Account"),
                                               systemImage: "person.crop.circle.fill")
                    }.accessibilityIdentifier("settings.account")
                }
            }
            if privateProfile.isPrivateDataVisible {
                Section {
                    NavigationLink(value: MobileSettingsDestination.recording) {
                        MobileSettingsRowLabel(PichiLocalization.text("Recording"),
                            summary: PichiLocalization.text("Microphone, language and meeting location"), systemImage: "mic.fill")
                    }.accessibilityIdentifier("settings.recording")
                    NavigationLink(value: MobileSettingsDestination.participants) {
                        MobileSettingsRowLabel(PichiLocalization.text("Participants"),
                            summary: PichiLocalization.text("Speaker labels and your voice"), systemImage: "person.wave.2.fill")
                    }.accessibilityIdentifier("settings.participants")
                    NavigationLink(value: MobileSettingsDestination.models) {
                        MobileSettingsRowLabel(PichiLocalization.text("Voice Engine"),
                            summary: settings.selectedSpeechModel.displayName, systemImage: "waveform")
                    }.accessibilityIdentifier("settings.models")
                    NavigationLink(value: MobileSettingsDestination.privacy) {
                        LabeledContent {
                            privacyAttention
                        } label: {
                            MobileSettingsRowLabel(PichiLocalization.text("Privacy"),
                                summary: PichiLocalization.text("Audio storage, cleanup and encryption"), systemImage: "hand.raised.fill")
                        }
                    }.accessibilityIdentifier("settings.privacy")
                }
                Section {
                    Picker(selection: $settings.interfaceLanguage) {
                        ForEach(PichiInterfaceLanguage.allCases) { Text($0.displayName).tag($0) }
                    } label: {
                        MobileSettingsRowLabel(PichiLocalization.text("Interface language"), systemImage: "globe")
                    }.accessibilityIdentifier("settings.interfaceLanguage")
                    Picker(selection: $settings.themePreference) {
                        ForEach(SettingsStore.ThemePreference.allCases) { item in
                            Text(PichiLocalization.text(item.displayName)).tag(item)
                        }
                    } label: {
                        MobileSettingsRowLabel(PichiLocalization.text("Appearance"), systemImage: "circle.lefthalf.filled")
                    }.accessibilityIdentifier("settings.appearance")
                }
                Section {
                    NavigationLink(value: MobileSettingsDestination.kiosk) {
                        MobileSettingsRowLabel(PichiLocalization.text("Restricted mode"),
                            summary: PichiLocalization.text("Recording only, full access with a password"), systemImage: "lock.fill")
                    }.accessibilityIdentifier("settings.kiosk")
                }
                Section {
                    Button {
                        guard canReplaySetup, privateProfile.isPrivateDataVisible,
                              !privateProfile.isTransitioning else { return }
                        settings.resetMobileSetupProgress()
                    } label: {
                        MobileSettingsRowLabel(PichiLocalization.text("Replay onboarding"), systemImage: "arrow.counterclockwise")
                    }
                    // A native row like the ones above: full-row touch and highlight, no box inside it.
                    .buttonStyle(.automatic)
                    .disabled(!canReplaySetup || privateProfile.isTransitioning)
                    .accessibilityIdentifier("settings.replaySetup")
                } footer: {
                    MobileSettingsFooter(PichiLocalization.text("Your meetings, models and voice profile are kept."))
                }
            }
        }.listStyle(.insetGrouped).mobileSettingsPage().accessibilityIdentifier("settings.root")
            .navigationDestination(for: MobileSettingsDestination.self) { destination in
                if destination == .account {
                    MobileAccountSettings(session: accountSession, interaction: accountInteraction,
                        cloudPublication: cloudPublication, cloudInteraction: cloudInteraction)
                } else if !privateProfile.isPrivateDataVisible {
                    Text(PichiLocalization.text("account.profile.unavailable"))
                } else {
                    switch destination {
                    case .account: EmptyView()
                    case .recording: MobileRecordingSettings(microphones: microphones)
                    case .participants:
                        MobileParticipantSettings(required: required,
                            microphone: microphones.first { $0.coreAudioUID == settings.meetingRecordingDefaults.microphoneCoreAudioUID })
                    case .models: MobileVoiceEngineSettings(asr: asr, reportError: reportError)
                    case .privacy:
                        MobilePrivacySettings(activation: privacyActivation, accountSession: accountSession,
                            cloudPublication: cloudPublication, cloudInteraction: cloudInteraction)
                    case .kiosk:
                        MobileKioskSettings(access: .shared,
                            canEnable: canReplaySetup && !privateProfile.isTransitioning
                                && !required.isPreparing && !privacyActivation.isPreparing)
                    }
                }
            }
    }

    /// Only states that need attention appear beside Privacy; its page shows the full status.
    @ViewBuilder private var privacyAttention: some View {
        switch privacyActivation.state {
        case .enabling: ProgressView().controlSize(.small)
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(theme.palette.warning)
                .accessibilityLabel(PichiLocalization.text("Data cleanup is not active"))
        case .active, .off: EmptyView()
        }
    }
}

/// One label for every Settings row: a distinct symbol on the accent tile, the title and an
/// optional one-line summary of the destination. Separators start at the title, as in iOS Settings.
struct MobileSettingsRowLabel: View {
    let title: String
    var summary: String?
    let systemImage: String
    @Environment(\.theme) private var theme
    @Environment(\.isEnabled) private var isEnabled
    @ScaledMetric(relativeTo: .body) private var tileSize: CGFloat = 30

    init(_ title: String, summary: String? = nil, systemImage: String) {
        self.title = title; self.summary = summary; self.systemImage = systemImage
    }

    var body: some View {
        HStack(spacing: theme.metrics.spacing.md) {
            Image(systemName: systemImage)
                .font(theme.typography.bodySmallStrong)
                .foregroundStyle(theme.palette.accentForeground)
                .frame(width: tileSize, height: tileSize)
                .background(theme.palette.accent, in: RoundedRectangle(cornerRadius: theme.metrics.corners.sm, style: .continuous))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(theme.typography.body).foregroundStyle(theme.palette.primaryText)
                if let summary {
                    Text(summary).font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
                }
            }
            .alignmentGuide(.listRowSeparatorLeading) { $0[.leading] }
        }
        .padding(.vertical, theme.metrics.spacing.xs)
        .opacity(isEnabled ? 1 : 0.5)
    }
}

/// Explanations live below their group, in the native footer position, instead of inside rows.
struct MobileSettingsFooter: View {
    let paragraphs: [String]
    @Environment(\.theme) private var theme

    init(_ paragraphs: String...) { self.paragraphs = paragraphs }
    init(_ paragraphs: [String]) { self.paragraphs = paragraphs }

    var body: some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
            ForEach(paragraphs, id: \.self) { Text($0) }
        }
        .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
    }
}

extension View {
    /// Settings pages keep a readable width in a wide iPad detail column, and their buttons are
    /// action rows: the app-wide outlined style would draw a box inside each grouped row.
    func mobileSettingsPage() -> some View { modifier(MobileSettingsColumn()).buttonStyle(MobileSettingsActionRowStyle()) }
}

/// A grouped-row action reads as one: accent text, the outlined style's readable red for a
/// destructive role, and the secondary color while unavailable. The native automatic style keeps
/// the whole row as its touch target and highlight. Replay onboarding keeps its own native row.
private struct MobileSettingsActionRowStyle: PrimitiveButtonStyle {
    func makeBody(configuration: Configuration) -> some View { Row(configuration: configuration) }

    private struct Row: View {
        let configuration: PrimitiveButtonStyleConfiguration
        @Environment(\.theme) private var theme
        @Environment(\.isEnabled) private var isEnabled

        var body: some View {
            Button(configuration)
                .buttonStyle(.automatic)
                .foregroundStyle(!isEnabled ? theme.palette.secondaryText
                    : configuration.role == .destructive ? theme.palette.readableText(.red) : theme.palette.accentText)
        }
    }
}

private struct MobileSettingsColumn: ViewModifier {
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass
    @State private var frameWidth: CGFloat = 0
    /// Includes the grouped list's own row inset on each side.
    private let readableWidth: CGFloat = 760

    func body(content: Content) -> some View {
        // Extra safe area keeps the native insets, scrolling across the full width and a floating
        // sidebar's own inset. The list keeps its identity, so its modifiers stay where they are.
        content
            .safeAreaPadding(.horizontal, horizontalSizeClass == .regular ? max(0, (frameWidth - readableWidth) / 2) : 0)
            .background {
                // The visible width inside the column's own safe area. The background is outside
                // the padded content, so the added padding cannot feed back into it.
                GeometryReader { proxy in
                    Color.clear
                        .onAppear { frameWidth = proxy.size.width }
                        .onChange(of: proxy.size.width) { _, width in frameWidth = width }
                }
            }
    }
}

/// What the next recording uses. The start screen opens the same page as a sheet.
struct MobileRecordingSettings: View {
    let microphones: [MeetingMicrophoneIdentity]
    var isPresentedAsSheet = false
    @ObservedObject private var settings = SettingsStore.shared
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

    /// Language names start with a capital letter, like the interface language on the root.
    private func languageName(_ code: String) -> String {
        let name = PichiLocalization.locale.localizedString(forLanguageCode: code) ?? code
        return name.prefix(1).uppercased(with: PichiLocalization.locale) + name.dropFirst()
    }

    var body: some View {
        Form {
            Section {
                Picker(PichiLocalization.text("Microphone"), selection: selectedMicrophone) {
                    Text(PichiLocalization.text("System Default")).tag("")
                    ForEach(microphones, id: \.captureDeviceID) { microphone in
                        Text(microphone.displayName).tag(microphone.coreAudioUID ?? microphone.captureDeviceID)
                    }
                }.accessibilityIdentifier("recording.microphone")
                Picker(PichiLocalization.text("Transcript language"), selection: selectedLanguage) {
                    ForEach(supportedLanguages, id: \.self) { code in
                        Text(code == "auto" ? PichiLocalization.text("Automatic") : languageName(code)).tag(code)
                    }
                }.accessibilityIdentifier("recording.language")
            }
            Section {
                MeetingLocationSettingsContent(asFormRows: true)
            } header: {
                Text(PichiLocalization.text("Meeting location"))
            } footer: {
                MobileSettingsFooter(MeetingLocationExplanation.paragraphs)
            }
        }.mobileSettingsPage().navigationTitle(PichiLocalization.text("Recording"))
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

/// Automatic speaker labels and the owner's voice profile, which labels matching speech as You.
private struct MobileParticipantSettings: View {
    @ObservedObject var required: MobileRequiredResources
    let microphone: MeetingMicrophoneIdentity?

    var body: some View {
        Form {
            Section {
                MobileRequiredResourcesStatus(resources: required)
            } header: {
                Text(PichiLocalization.text("Speaker labels"))
            } footer: {
                MobileSettingsFooter(PichiLocalization.text("Speaker labels appear automatically while you record. Short or overlapping speech can be uncertain. You can correct participant names later."),
                    PichiLocalization.text("Text and participant labels update in fragments. A delay is normal while enough speech is collected."))
            }
            Section(PichiLocalization.text("My voice")) {
                MeetingOwnerVoiceSettingsContent(audioArbiter: AppServices.shared.meetingAudioActivityArbiter,
                    microphone: microphone)
            }
        }.mobileSettingsPage().navigationTitle(PichiLocalization.text("Participants"))
            .accessibilityIdentifier("settings.participants.detail")
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
    @State private var pendingDeletion: SettingsStore.SpeechModel?

    var body: some View {
        List {
            ForEach(asr.availableMeetingModels, id: \.rawValue) { model in
                // Each action is its own row: a native full-width target that cannot trigger its neighbours.
                Section {
                    summary(of: model)
                    MobileModelDetails(modelID: model.id)
                    actions(for: model)
                }
            }
        }.mobileSettingsPage().navigationTitle(PichiLocalization.text("Voice Engine"))
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

    private func summary(of model: SettingsStore.SpeechModel) -> some View {
        VStack(alignment: .leading, spacing: theme.metrics.spacing.xs) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.displayName).font(theme.typography.sectionTitle)
                Spacer()
                if settings.selectedSpeechModel == model {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(theme.palette.accentText)
                        .accessibilityLabel(PichiLocalization.text("Selected"))
                }
            }
            Text(PichiLocalization.text(model.cardDescription)).font(theme.typography.bodySmall)
            if let creditLine = model.creditLine {
                Text(PichiLocalization.text(creditLine)).font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            }
            Text(verbatim: PichiLocalization.text(model.languageSupport) + " · " + model.downloadSize)
                .font(theme.typography.caption).foregroundStyle(theme.palette.secondaryText)
            if let processor = model.libraryMetadata?.processor {
                Text(PichiLocalization.text(processor))
                    .font(theme.typography.captionStrong).foregroundStyle(theme.palette.accentText)
                    .accessibilityIdentifier("model.computePreference.\(model.id)")
            }
            if let execution = asr.executionStatus(for: model) {
                Label(PichiLocalization.format("Configured execution: %@", PichiLocalization.text(execution.backend.label)), systemImage: "cpu")
                    .font(theme.typography.captionStrong).foregroundStyle(theme.palette.secondaryText)
                    .accessibilityHint(PichiLocalization.text("The configured execution device is not a live utilization measurement."))
                    .accessibilityIdentifier("model.executionStatus.\(model.id)")
                if let reason = execution.fallbackReason {
                    Text(PichiLocalization.text(reason)).font(theme.typography.caption)
                        .foregroundStyle(theme.palette.readableText(theme.palette.warning))
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("model.executionFallback.\(model.id)")
                }
            }
        }.padding(.vertical, theme.metrics.spacing.xs)
    }

    @ViewBuilder private func actions(for model: SettingsStore.SpeechModel) -> some View {
        if asr.downloadingModelId == model.id {
            Group {
                if let progress = asr.downloadProgress { ProgressView(value: progress) } else { ProgressView() }
            }.padding(.vertical, theme.metrics.spacing.xs)
            Button(PichiLocalization.text("Cancel")) { asr.cancelModelDownload() }
        } else {
            if installed.contains(model.id) {
                if settings.selectedSpeechModel == model {
                    Label(PichiLocalization.text("Selected for new meetings. Text and speaker labels update during recording."),
                          systemImage: "checkmark.circle.fill")
                        .font(theme.typography.bodySmall).foregroundStyle(theme.palette.secondaryText)
                        .accessibilityIdentifier("model.selected.\(model.id)")
                } else {
                    Button {
                        activatingModelID = model.id
                        Task { @MainActor in
                            defer { activatingModelID = nil }
                            do { try await asr.activateModel(model); await refresh() }
                            catch { reportError(error) }
                        }
                    } label: {
                        if activatingModelID == model.id { ProgressView() }
                        else { Text(PichiLocalization.text("Use Model")) }
                    }.disabled(asr.activeExclusiveActivity != nil || activatingModelID != nil)
                        .accessibilityIdentifier("model.activate.\(model.id)")
                }
                Button(PichiLocalization.text("Delete"), role: .destructive) { pendingDeletion = model }
                    .disabled(asr.activeExclusiveActivity != nil).accessibilityIdentifier("model.delete.\(model.id)")
                    // Attached to its own row, so an iPad popover points at the Delete row.
                    .confirmationDialog(model.displayName, isPresented: Binding(
                        get: { pendingDeletion == model }, set: { if !$0 { pendingDeletion = nil } }
                    ), titleVisibility: .visible) {
                        Button(PichiLocalization.text("Delete model"), role: .destructive) {
                            pendingDeletion = nil
                            Task { do { try await asr.clearModelCache(for: model); await refresh() } catch { reportError(error) } }
                        }.accessibilityIdentifier("model.delete.confirm")
                    } message: {
                        Text(PichiLocalization.text("The model will be removed from this device. Meetings and transcripts stay."))
                    }
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
    }

    private func refresh() async {
        var values: Set<String> = []
        for model in asr.availableMeetingModels {
            if (try? await asr.modelIsInstalled(model)) == true { values.insert(model.id) }
        }
        installed = values
    }
}

/// Audio storage, transcript data cleanup with its private dictionary, and recording protection.
/// Each explanation is its section footer; the audio footer follows the Save audio recordings choice.
private struct MobilePrivacySettings: View {
    @ObservedObject var activation: MobilePrivacyActivation
    @ObservedObject var accountSession: AccountSessionService
    var cloudPublication: PichiCloudPublicationService?
    var cloudInteraction: MobileCloudInteraction?
    @ObservedObject private var settings = SettingsStore.shared
    @State private var dictionaryEdit: MobileSensitiveDictionaryEdit?

    var body: some View {
        Form {
            Section {
                MobileAudioPrivacyControls(asFormRows: true)
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
                    MobileSettingsFooter(PichiLocalization.text("Applies to past meetings too. Transcripts are always kept."),
                        MobileAudioPrivacyControls.retainedAudioExplanation)
                } else {
                    MobileSettingsFooter(MobileAudioPrivacyControls.memoryOnlyExplanation)
                }
            }
            Section {
                MobilePrivacyActivationControls(activation: activation, asFormRows: true)
            } header: {
                Text(PichiLocalization.text("Data cleanup"))
            } footer: {
                MobileSettingsFooter(MobilePrivacyActivationControls.explanation)
            }
            // The dictionary refines data cleanup, so it follows that section directly.
            MobileSensitiveDictionarySettings { entry in dictionaryEdit = .init(entry: entry) }
            Section {
                MobileRecordingDataControls(session: accountSession, service: cloudPublication,
                    interaction: cloudInteraction)
            } header: {
                Text(PichiLocalization.text("recording.protection.section"))
            } footer: {
                MobileSettingsFooter(PichiLocalization.text("recording.settings.scope"))
            }
        }.mobileSettingsPage().navigationTitle(PichiLocalization.text("Privacy")).accessibilityIdentifier("settings.privacy.detail")
            .sheet(item: $dictionaryEdit) { request in
                MobileSensitiveDictionaryEditor(entry: request.entry)
            }
    }
}
