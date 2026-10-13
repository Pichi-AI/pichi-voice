import AppKit
import SwiftUI

enum MeetingSettingsSection: String, CaseIterable, Identifiable {
    case recording = "Recording"
    case automation = "Automation & storage"
    case integrations = "Integrations"

    var id: String { self.rawValue }

    var symbol: String {
        switch self {
        case .recording: "waveform"
        case .automation: "slider.horizontal.3"
        case .integrations: "link"
        }
    }

    var guidance: String {
        switch self {
        case .recording: PichiLocalization.text("Choose your audio sources and transcript language.")
        case .automation: PichiLocalization.text("Choose when to see a recording prompt and how long to keep audio.")
        case .integrations: PichiLocalization.text("Connect your meeting notes to the AI assistants you already use.")
        }
    }
}

struct MeetingRecordingSettingsSheet: View {
    @Binding var draft: MeetingTranscriptionSetupDraft
    @Binding var retentionPolicy: MeetingAudioRetentionPolicy
    @ObservedObject private var dismissalAdvisor = MeetingAutoDetectDismissalAdvisor.shared
    @ObservedObject private var appServices = AppServices.shared

    let applications: [MeetingApplicationOption]
    let microphones: [MeetingMicrophoneOption]
    let readiness: MeetingSetupReadiness
    let isFirstSetup: Bool
    let onRefreshSources: () -> Void
    let onModelImported: @MainActor () -> Void
    let onOpenMicrophoneSettings: @MainActor @Sendable () -> Void
    let onOpenScreenRecordingSettings: @MainActor @Sendable () -> Void
    let onOpenVoiceEngine: () -> Void
    let onCancel: () -> Void
    let onSave: () -> Void

    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale

    @State private var selectedSection: MeetingSettingsSection

    // Keeps the existing sheet's bindings and callbacks together at its presentation boundary.
    init(
        draft: Binding<MeetingTranscriptionSetupDraft>,
        retentionPolicy: Binding<MeetingAudioRetentionPolicy>,
        applications: [MeetingApplicationOption],
        microphones: [MeetingMicrophoneOption],
        readiness: MeetingSetupReadiness,
        isFirstSetup: Bool,
        onRefreshSources: @escaping () -> Void,
        onOpenMicrophoneSettings: @escaping @MainActor @Sendable () -> Void,
        onOpenScreenRecordingSettings: @escaping @MainActor @Sendable () -> Void,
        onOpenVoiceEngine: @escaping () -> Void,
        onCancel: @escaping () -> Void,
        onSave: @escaping () -> Void,
        onModelImported: @escaping @MainActor () -> Void = {},
        initialSection: MeetingSettingsSection = .recording
    ) {
        self._draft = draft
        self._retentionPolicy = retentionPolicy
        self.applications = applications
        self.microphones = microphones
        self.readiness = readiness
        self.isFirstSetup = isFirstSetup
        self.onRefreshSources = onRefreshSources
        self.onModelImported = onModelImported
        self.onOpenMicrophoneSettings = onOpenMicrophoneSettings
        self.onOpenScreenRecordingSettings = onOpenScreenRecordingSettings
        self.onOpenVoiceEngine = onOpenVoiceEngine
        self.onCancel = onCancel
        self.onSave = onSave
        self._selectedSection = State(initialValue: initialSection)
    }

    private var canSave: Bool {
        guard VoiceEngineLanguageCatalog.parakeetV3LanguageIDs.contains(self.draft.languageCode) else { return false }
        guard self.microphones.contains(where: { $0.id == self.draft.selectedMicrophoneID }) else { return false }
        return self.draft.mode == .inRoom
            || self.draft.usesAutomaticApplication
            || self.applications.contains { $0.id == self.draft.selectedApplicationID }
    }

    private var saveHelp: String? {
        guard !self.canSave else { return nil }
        if !self.microphones.contains(where: { $0.id == self.draft.selectedMicrophoneID }) {
            return PichiLocalization.text("Choose an available microphone to save this setup.")
        }
        if self.draft.mode == .onlineCall, !self.draft.usesAutomaticApplication,
           !self.applications.contains(where: { $0.id == self.draft.selectedApplicationID })
        {
            return PichiLocalization.text("Choose an available meeting application to save this setup.")
        }
        return self.readiness.blockingMessage.map(PichiLocalization.text)
    }

    var body: some View {
        VStack(spacing: 0) {
            self.header
            Divider()

            HStack(spacing: 0) {
                self.sectionRail
                Divider()
                ScrollView {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
                        self.sectionHeading
                        switch self.selectedSection {
                        case .recording:
                            self.recordingSettings
                        case .automation:
                            self.automationSettings
                        case .integrations:
                            self.integrationSettings
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(self.theme.metrics.spacing.xl)
                }
            }

            Divider()
            self.footer
        }
        .frame(width: 820)
        .frame(minHeight: 540, idealHeight: 640)
        .background(self.theme.palette.windowBackground)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text(AppBrand.text("FluidMeet settings"))
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)
            Text("Audio and transcripts stay on this Mac.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, self.theme.metrics.spacing.xxl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
    }

    private var sectionRail: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            ForEach(MeetingSettingsSection.allCases) { section in
                Button {
                    self.selectedSection = section
                } label: {
                    HStack(spacing: self.theme.metrics.spacing.sm) {
                        Image(systemName: section.symbol)
                            .frame(width: self.theme.metrics.spacing.lg)
                            .foregroundStyle(self.theme.palette.secondaryText)
                        Text(PichiLocalization.text(section.rawValue))
                            .font(self.selectedSection == section ? self.theme.typography.bodySmallStrong : self.theme.typography.bodySmall)
                            .foregroundStyle(self.theme.palette.primaryText)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, self.theme.metrics.spacing.md)
                    .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
                    .padding(.vertical, self.theme.metrics.spacing.xs)
                    .background(
                        self.selectedSection == section ? self.theme.palette.cardBackground : Color.clear,
                        in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm)
                    )
                    .contentShape(RoundedRectangle(cornerRadius: self.theme.metrics.corners.sm))
                }
                .buttonStyle(.plain)
                .meetingHoverFeedback(cornerRadius: self.theme.metrics.corners.sm)
                .accessibilityAddTraits(self.selectedSection == section ? .isSelected : [])
            }
            Spacer(minLength: 0)
        }
        .padding(self.theme.metrics.spacing.sm)
        .padding(.top, self.theme.metrics.spacing.sm)
        .frame(width: 164)
        .frame(maxHeight: .infinity)
        .background(self.theme.palette.sidebarBackground)
    }

    private var sectionHeading: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text(PichiLocalization.text(self.selectedSection.rawValue))
                .font(self.theme.typography.sectionTitle)
                .foregroundStyle(self.theme.palette.primaryText)
            Text(self.selectedSection.guidance)
                .font(self.theme.typography.bodySmall)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var recordingSettings: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            FluidManagementGroup(title: PichiLocalization.text("Audio sources")) {
                VStack(spacing: 0) {
                    MeetingAdaptiveSetupRow(
                        title: PichiLocalization.text("Meeting type"),
                        detail: self.draft.mode == .onlineCall ? PichiLocalization.text("Meeting app and microphone.") : PichiLocalization.text("Microphone only.")
                    ) {
                        Menu {
                            Picker("Meeting type", selection: self.$draft.mode) {
                                Text("Online call").tag(MeetingCaptureMode.onlineCall)
                                Text("In-room").tag(MeetingCaptureMode.inRoom)
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(self.draft.mode == .onlineCall ? PichiLocalization.text("Online call") : PichiLocalization.text("In-room"))
                        }
                        .fluidDropdownStyle(fillsWidth: true)
                        .accessibilityLabel("Default meeting type")
                    }

                    if self.draft.mode == .onlineCall {
                        Divider()
                        MeetingAdaptiveSetupRow(
                            title: PichiLocalization.text("Meeting audio"),
                            detail: PichiLocalization.text("Automatic follows the detected call.")
                        ) {
                            Menu {
                                self.applicationMenuEntry(title: PichiLocalization.text("Automatic"), id: nil)
                                ForEach(self.meetingApplications) { option in
                                    self.applicationMenuEntry(title: self.applicationDisplayName(option), id: option.id)
                                }
                                if !self.otherApplications.isEmpty {
                                    Divider()
                                    Menu("Other audio sources") {
                                        ForEach(self.otherApplications) { option in
                                            self.applicationMenuEntry(title: self.applicationDisplayName(option), id: option.id)
                                        }
                                    }
                                }
                            } label: {
                                Text(self.selectedApplicationName)
                            }
                            .fluidDropdownStyle(fillsWidth: true)
                            .accessibilityLabel("Meeting audio source")
                        }
                    }

                    Divider()
                    MeetingAdaptiveSetupRow(
                        title: PichiLocalization.text("Microphone"),
                        detail: PichiLocalization.text("Capture your side of the conversation.")
                    ) {
                        Menu {
                            Picker("Microphone", selection: self.$draft.selectedMicrophoneID) {
                                Text("Choose microphone…").tag(String?.none)
                                ForEach(self.microphones) { option in
                                    Text(option.identity.displayName).tag(Optional(option.id))
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(self.microphones.first(where: { $0.id == self.draft.selectedMicrophoneID })?.identity.displayName ?? PichiLocalization.text("Choose microphone…"))
                        }
                        .fluidDropdownStyle(fillsWidth: true)
                        .accessibilityLabel("Default meeting microphone")
                    }
                }
            }
            .overlay(alignment: .topTrailing) {
                Button(self.readiness.isCheckingSources ? PichiLocalization.text("Refreshing…") : PichiLocalization.text("Refresh"), systemImage: "arrow.clockwise", action: self.onRefreshSources)
                    .buttonStyle(.plain)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.theme.palette.accent)
                    .disabled(self.readiness.isCheckingSources)
                    .help("Rescan meeting apps and microphones.")
                    .accessibilityLabel("Refresh audio sources")
            }

            FluidManagementGroup(title: PichiLocalization.text("Transcript language")) {
                MeetingAdaptiveSetupRow(
                    title: PichiLocalization.text("Language"),
                    detail: PichiLocalization.text("Live captions use English streaming or buffered transcription for supported languages. Russian captions support GigaAM and Parakeet v3.")
                ) {
                    Menu {
                        Picker("Meeting language", selection: self.$draft.languageCode) {
                            ForEach(VoiceEngineLanguageCatalog.allLanguages(availableModels: [.parakeetTDT])) { language in
                                Text(language.localizedDisplayName(locale: self.locale)).tag(language.id)
                            }
                        }
                        .pickerStyle(.inline)
                    } label: {
                        Text(VoiceEngineLanguageCatalog.language(id: self.draft.languageCode, availableModels: [.parakeetTDT])?.localizedDisplayName(locale: self.locale) ?? PichiLocalization.text("Choose language…"))
                    }
                    .fluidDropdownStyle(fillsWidth: true)
                    .accessibilityLabel("Meeting transcript language")
                }
            }

            MeetingModelSettingsSection(onModelImported: self.onModelImported)

            if self.readiness.showMicrophoneSettingsAction || self.readiness.showScreenRecordingSettingsAction {
                FluidManagementGroup(title: PichiLocalization.text("Permissions need attention")) {
                    Text("Allow the requested access in macOS Settings, then refresh your sources.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    FluidGlassControlGroup {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: self.theme.metrics.spacing.sm) { self.repairActions }
                            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) { self.repairActions }
                        }
                    }
                }
            }
        }
    }

    private var applicationSelection: Binding<String?> {
        Binding(
            get: { self.draft.usesAutomaticApplication ? nil : self.draft.selectedApplicationID },
            set: { id in
                self.draft.chooseApplication(self.applications.first { $0.id == id }?.identity)
            }
        )
    }

    private func applicationMenuEntry(title: String, id: String?) -> some View {
        Button {
            self.applicationSelection.wrappedValue = id
        } label: {
            if self.applicationSelection.wrappedValue == id {
                Label(title, systemImage: "checkmark")
            } else {
                Text(title)
            }
        }
    }

    private var meetingApplications: [MeetingApplicationOption] {
        self.applications.filter { MeetingAppRegistry.tier(forBundleIdentifier: $0.identity.bundleIdentifier) != nil }
    }

    private var otherApplications: [MeetingApplicationOption] {
        self.applications.filter { MeetingAppRegistry.tier(forBundleIdentifier: $0.identity.bundleIdentifier) == nil }
    }

    private var selectedApplicationName: String {
        guard !self.draft.usesAutomaticApplication else { return PichiLocalization.text("Automatic") }
        guard let selected = self.applications.first(where: { $0.id == self.draft.selectedApplicationID }) else {
            return PichiLocalization.text("Source unavailable")
        }
        return self.applicationDisplayName(selected)
    }

    private func applicationDisplayName(_ option: MeetingApplicationOption) -> String {
        let name = option.identity.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { return name }
        let bundleIdentifier = option.identity.bundleIdentifier.trimmingCharacters(in: .whitespacesAndNewlines)
        if !bundleIdentifier.isEmpty { return bundleIdentifier }
        if let processID = option.identity.processID { return PichiLocalization.format("Audio source (%d)", processID) }
        return PichiLocalization.text("Audio source")
    }

    private var automationSettings: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            FluidManagementGroup(title: PichiLocalization.text("Your preferences")) {
                VStack(spacing: 0) {
                    MeetingAdaptiveSetupRow(
                        title: PichiLocalization.text("Keep recordings"),
                        detail: PichiLocalization.text("Includes past meetings. Transcripts are always kept.")
                    ) {
                        Menu {
                            Picker("Keep audio", selection: self.$retentionPolicy) {
                                ForEach(MeetingAudioRetentionPolicy.allCases, id: \.self) { policy in
                                    Text(PichiLocalization.text(policy.displayName)).tag(policy)
                                }
                            }
                            .pickerStyle(.inline)
                        } label: {
                            Text(PichiLocalization.text(self.retentionPolicy.displayName))
                        }
                        .fluidDropdownStyle(fillsWidth: true)
                        .accessibilityLabel("Audio retention")
                    }

                    Divider()
                    MeetingAdaptiveSetupRow(
                        title: PichiLocalization.text("Detect meetings automatically"),
                        detail: PichiLocalization.text("Offer to record Zoom, Teams, and Webex meetings. Recording always starts with you."),
                        trailingSwitch: true
                    ) {
                        Toggle("Detect meetings automatically", isOn: self.$draft.autoDetectEnabled)
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .meetingHoverFeedback()
                            .accessibilityLabel("Detect meetings automatically")
                    }

                    if self.draft.autoDetectEnabled {
                        Divider()
                        MeetingAdaptiveSetupRow(
                            title: PichiLocalization.text("Include browser meetings"),
                            detail: PichiLocalization.text("Check the frontmost tab for supported meeting sites. Tab addresses are never stored or sent."),
                            trailingSwitch: true
                        ) {
                            Toggle("Include browser meetings", isOn: self.$draft.browserDetectionEnabled)
                                .labelsHidden()
                                .toggleStyle(.switch)
                                .meetingHoverFeedback()
                                .accessibilityLabel("Also check browser tabs")
                        }
                    }
                }
            }

            if self.draft.autoDetectEnabled,
               self.appServices.meetingAutoDetectHealth == .zoomWindowTitleUnreadable
            {
                MeetingAdaptiveSetupRow(
                    title: PichiLocalization.text("Zoom window access needs repair"),
                    detail: AppBrand.text("Screen Recording or Accessibility access is preventing FluidVoice from reading Zoom meeting windows. Recording has not started.")
                ) {
                    Button("Open Screen Recording Settings") {
                        self.onOpenScreenRecordingSettings()
                    }
                    .meetingGlassAction()
                }
            }

            if self.dismissalAdvisor.shouldSuggest {
                FluidManagementGroup(title: PichiLocalization.text("Fewer interruptions")) {
                    Text("You’ve dismissed several meeting prompts recently. You can turn off detection and still record manually.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                    FluidGlassControlGroup {
                        HStack(spacing: self.theme.metrics.spacing.sm) {
                            Button("Turn off detection") {
                                self.draft.autoDetectEnabled = false
                                self.draft.browserDetectionEnabled = false
                                self.dismissalAdvisor.shouldSuggest = false
                            }
                            .meetingGlassAction()
                            Button("Keep it on") {
                                self.dismissalAdvisor.shouldSuggest = false
                            }
                            .meetingGlassAction()
                        }
                    }
                }
            }

            Text(AppBrand.text("Expired audio is removed while FluidVoice is running."))
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
        }
    }

    private var integrationSettings: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            FluidManagementGroup(title: PichiLocalization.text("Claude & ChatGPT MCP links")) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    self.integrationRow(name: "Claude", provider: PichiLocalization.text("by Anthropic"), assetName: "Provider_Anthropic")
                    Divider()
                    self.integrationRow(name: "ChatGPT", provider: PichiLocalization.text("by OpenAI"), assetName: "Provider_OpenAI")
                }
            }

            Label("MCP connections are coming in a future update. No meeting notes are shared with Claude or ChatGPT.", systemImage: "lock.fill")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func integrationRow(name: String, provider: String, assetName: String) -> some View {
        HStack(spacing: self.theme.metrics.spacing.md) {
            Image(assetName)
                .resizable()
                .scaledToFit()
                .frame(width: 26, height: 26)
                .frame(width: 44, height: 44)
                .background(Color(nsColor: .white), in: RoundedRectangle(cornerRadius: self.theme.metrics.corners.md))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
                Text(name)
                    .font(self.theme.typography.bodyStrong)
                    .foregroundStyle(self.theme.palette.primaryText)
                Text(provider)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            Spacer(minLength: self.theme.metrics.spacing.md)
            Text("Coming soon")
                .font(self.theme.typography.badge)
                .foregroundStyle(self.theme.palette.secondaryText)
            Toggle("Enable \(name) MCP link — coming soon", isOn: .constant(false))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(true)
                .help("\(name) MCP links are coming soon.")
        }
        .padding(.vertical, self.theme.metrics.spacing.sm)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            if let saveHelp {
                Label(saveHelp, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
            }
            FluidGlassControlGroup {
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Spacer(minLength: self.theme.metrics.spacing.md)
                    Button(action: self.onCancel) {
                        Text(self.isFirstSetup ? PichiLocalization.text("Not now") : PichiLocalization.text("Cancel")).frame(minWidth: 72)
                    }
                    .meetingGlassAction()
                    .keyboardShortcut(.cancelAction)
                    Button(action: self.onSave) {
                        Text(self.isFirstSetup ? PichiLocalization.text("Save setup") : PichiLocalization.text("Save")).frame(minWidth: 72)
                    }
                    .meetingGlassAction(prominent: true)
                    .disabled(!self.canSave)
                    .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(.horizontal, self.theme.metrics.spacing.xxl)
        .padding(.vertical, self.theme.metrics.spacing.lg)
    }

    @ViewBuilder
    private var repairActions: some View {
        if self.readiness.showMicrophoneSettingsAction {
            Button("Microphone Settings", systemImage: "mic.fill", action: self.onOpenMicrophoneSettings)
                .meetingGlassAction()
        }
        if self.readiness.showScreenRecordingSettingsAction {
            Button(
                "Screen Recording Settings",
                systemImage: "rectangle.inset.filled.and.person.filled",
                action: self.onOpenScreenRecordingSettings
            )
            .meetingGlassAction()
        }
    }
}

private struct MeetingAdaptiveSetupRow<Content: View>: View {
    let title: String
    var detail: String?
    let trailingSwitch: Bool
    @ViewBuilder let content: Content

    @Environment(\.theme) private var theme

    init(
        title: String,
        detail: String? = nil,
        trailingSwitch: Bool = false,
        @ViewBuilder content: () -> Content
    ) {
        self.title = title
        self.detail = detail
        self.trailingSwitch = trailingSwitch
        self.content = content()
    }

    var body: some View {
        Group {
            if self.trailingSwitch {
                HStack(alignment: .center, spacing: self.theme.metrics.spacing.lg) {
                    self.label.frame(maxWidth: .infinity, alignment: .leading)
                    self.content.fixedSize()
                }
            } else {
                HStack(alignment: .center, spacing: self.theme.metrics.spacing.xl) {
                    self.label.frame(maxWidth: .infinity, alignment: .leading)
                    self.content
                        .frame(width: 240, alignment: .trailing)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.sm)
    }

    private var label: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text(self.title)
                .font(self.theme.typography.bodyStrong)
                .foregroundStyle(self.theme.palette.primaryText)
            if let detail {
                Text(detail)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
