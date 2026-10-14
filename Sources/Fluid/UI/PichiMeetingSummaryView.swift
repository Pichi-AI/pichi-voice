import AppKit
import SwiftUI

struct PichiMeetingSummaryView: View {
    var session: MeetingSession?
    var asrService: ASRService?
    var isQuiescent: Bool
    @Environment(\.theme) private var theme
    @Environment(\.locale) private var interfaceLocale
    @StateObject private var preferences = PichiMeetingSummarySettings()
    @ObservedObject private var controller: PichiMeetingSummaryController
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showingConfiguration = false

    init(session: MeetingSession?, asrService: ASRService?, isQuiescent: Bool) {
        self.session = session
        self.asrService = asrService
        self.isQuiescent = isQuiescent
        self.controller = AppServices.shared.meetingSummaryController(for: session?.id)
    }

    private var requestConfiguration: PichiMeetingSummaryConfiguration? {
        self.controller.requestConfiguration(current: self.configuration)
    }

    private var interfaceLanguage: PichiInterfaceLanguage { PichiInterfaceLanguage(rawValue: self.interfaceLocale.identifier) ?? .russian }

    private var configuration: PichiMeetingSummaryConfiguration? {
        try? self.preferences.configuration(sessionLanguage: self.session?.languageCode ?? "ru", settings: self.settings)
    }

    private var refreshIdentity: String {
        (self.session?.id.uuidString ?? "") + "|" + (self.session.map(PichiMeetingSummaryInput.fingerprint) ?? "") + "|"
            + self.preferences.selectionIdentity + "|" + (self.configuration?.cacheIdentity ?? "")
    }

    private var canGenerate: Bool {
        self.isQuiescent && !self.controller.generating && !self.controller.checking && self.requestConfiguration != nil
            && self.session.map { !PichiMeetingSummaryInput.turns(for: $0).isEmpty } == true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xl) {
            HStack(alignment: .top, spacing: self.theme.metrics.spacing.lg) {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    Text("Meeting summary")
                        .font(self.theme.typography.sectionTitle)
                        .foregroundStyle(self.theme.palette.primaryText)
                        .accessibilityAddTraits(.isHeader)
                    Text("A factual recap, decisions and follow-ups with transcript sources.")
                        .font(self.theme.typography.bodySmall)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer(minLength: self.theme.metrics.spacing.md)
                if self.controller.generating {
                    Button("Cancel") { self.controller.cancel() }.meetingGlassAction()
                } else {
                    Button(PichiLocalization.text(self.controller.document == nil ? "Generate summary" : "Regenerate")) {
                        guard let session = self.session, let config = self.requestConfiguration else { return }
                        self.controller.summarize(session: session, configuration: config,
                                                  asr: self.asrService ?? AppServices.shared.asr)
                    }
                    .meetingGlassAction(prominent: true)
                    .disabled(!self.canGenerate)
                }
            }

            DisclosureGroup(isExpanded: self.$showingConfiguration) {
                self.configurationControls.padding(.top, self.theme.metrics.spacing.md)
            } label: {
                Text("Summary model and language").font(self.theme.typography.bodySmallStrong)
            }
            .disabled(self.controller.generating)

            if let config = self.requestConfiguration {
                Label(config.isOnDevice ? PichiLocalization.format("Transcript stays on this Mac · %@", config.modelID)
                      : PichiLocalization.format("Transcript will be sent to %@ · %@", config.baseURL, config.modelID),
                      systemImage: config.isOnDevice ? "lock" : "network")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Text(self.configurationIssue)
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if self.controller.generating || self.controller.checking {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    ProgressView().controlSize(.small)
                    Text(self.controller.generating ? (self.controller.progressState?.text(language: self.interfaceLanguage) ?? "") : PichiLocalization.text("Loading saved summary…", locale: self.interfaceLocale))
                        .font(self.theme.typography.bodySmall)
                }
            }
            if self.controller.generating {
                Text("Processing continues while you use other screens in this app. Dictation is temporarily unavailable. Return to this meeting to cancel. Keep the app open.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let error = self.controller.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let document = self.controller.document {
                if self.controller.documentIsHistorical {
                    Label("Saved summary. The local server is unavailable, so the current model version could not be checked.", systemImage: "clock.arrow.circlepath")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if !(self.session?.transcriptCoverageGaps ?? []).isEmpty {
                    Label("The transcript has gaps. Conclusions cover only the captured speech.", systemImage: "exclamationmark.circle")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }
                self.summarySection(PichiLocalization.text("Recap"), items: document.summary)
                self.summarySection(PichiLocalization.text("Decisions"), items: document.decisions)
                self.summarySection(PichiLocalization.text("Action items"), items: document.actions, actions: true)
                self.summarySection(PichiLocalization.text("Questions and answers"), items: document.openQuestions, questions: true)
                if let changes = document.changes, !changes.isEmpty {
                    self.summarySection(PichiLocalization.text("Corrections"), items: changes)
                }
                if let answers = document.answers, !answers.isEmpty {
                    self.summarySection(PichiLocalization.text("Answers"), items: answers)
                }
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Button("Copy summary", systemImage: "doc.on.doc") { self.copy(document) }
                        .meetingGlassAction()
                    Text("AI output should be checked against the linked sources.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
            } else if !self.controller.generating, !self.controller.checking {
                Text(PichiLocalization.text(self.session == nil ? "Record or open a meeting to generate its summary."
                     : "Finish the transcript, choose a model, then generate a summary. Russian is the default output language."))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, self.theme.metrics.spacing.md)
        .task(id: self.refreshIdentity) {
            await self.controller.refresh(session: self.session, configuration: self.configuration)
            if self.configuration == nil { self.showingConfiguration = true }
        }
    }

    private var configurationIssue: String {
        do { _ = try self.preferences.configuration(sessionLanguage: self.session?.languageCode ?? "ru", settings: self.settings) }
        catch { return error.localizedDescription }
        return ""
    }

    private var configurationControls: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.md) {
            Picker("Summary provider", selection: self.$preferences.mode) {
                ForEach(PichiMeetingSummarySettings.Mode.allCases) { mode in Text(mode.title).tag(mode) }
            }
            .pickerStyle(.menu)
            if self.preferences.mode == .local {
                TextField("Local API endpoint", text: self.$preferences.baseURL)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Local summary API endpoint")
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    TextField("Installed model ID", text: self.$preferences.modelID)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Local summary model")
                    if !self.preferences.models.isEmpty {
                        Menu("Installed models") {
                            ForEach(self.preferences.models, id: \.self) { id in
                                Button(id) { self.preferences.modelID = id }
                            }
                        }
                        .fluidDropdownStyle()
                    }
                    Button(PichiLocalization.text(self.preferences.discovering ? "Refreshing…" : "Refresh models")) {
                        Task { await self.preferences.discoverModels() }
                    }
                    .meetingGlassAction()
                    .disabled(self.preferences.discovering)
                }
                if let providerID = ModelRepository.shared.localTextModelProvider(for: self.preferences.baseURL) {
                    LocalTextModelLibraryMenu(providerID: providerID, installedModels: self.preferences.models,
                                              selectedModel: self.$preferences.modelID)
                }
                Text("Start an OpenAI-compatible local server in Ollama or LM Studio. Install models separately, refresh the list, and choose the model to use. Model availability does not confirm summary quality.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let issue = self.preferences.discoveryIssue {
                    Text(issue.text(language: self.interfaceLanguage)).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.warning)
                }
            } else {
                Text("Uses the provider and model selected in AI Enhancement settings. Choose an OpenAI-compatible API. Review the destination above before generating.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if self.preferences.mode == .local, let config = self.configuration,
               PichiMeetingSummaryTransport.usesNativeOllama(LLMClient.Config(messages: [], model: config.modelID,
                   baseURL: config.baseURL, apiKey: "", streaming: false)) {
                Picker("Local model thinking", selection: Binding(
                    get: { self.preferences.localReasoningSelection(settings: self.settings) },
                    set: { self.preferences.setLocalReasoningSelection($0, settings: self.settings) }
                )) {
                    Text("Application default").tag("default")
                    Text("Enabled").tag("enabled")
                    Text("Disabled").tag("disabled")
                    if self.preferences.localReasoningSelection(settings: self.settings) == "configured" {
                        Text("Configured model reasoning").tag("configured")
                    }
                }
                .pickerStyle(.menu)
                Text("Enable only if the installed model supports thinking. This updates the model's shared reasoning setting; unsupported models may reject the request.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Summary time budget", selection: self.$preferences.timeBudget) {
                ForEach(PichiMeetingSummarySettings.TimeBudget.allCases) { budget in Text(budget.title).tag(budget) }
            }
            .pickerStyle(.menu)
            Text("Extended processing allows more generation tokens and time. Reasoning follows this model's settings in AI Providers. Local Ollama context is limited to 16K; more time does not guarantee better quality. Speech recognition is paused until processing finishes or is cancelled.")
                .font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            Picker("Summary language", selection: self.$preferences.language) {
                Text("Русский").tag("ru")
                Text("English").tag("en")
                Text("Transcript language").tag("transcript")
            }
            .pickerStyle(.menu)
        }
    }

    private func summarySection(_ title: String, items: [PichiMeetingSummaryItem], questions: Bool = false, actions: Bool = false) -> some View {
        FluidManagementGroup(title: title) {
            if items.isEmpty {
                Text("None stated in the transcript.")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                            if actions, let title = item.title {
                                Text(title)
                                    .font(self.theme.typography.bodySmallStrong)
                                    .foregroundStyle(self.theme.palette.primaryText)
                                    .accessibilityAddTraits(.isHeader)
                            }
                            CommandMarkdownContent(text: item.text)
                                .strikethrough(item.superseded == true || item.status == .cancelled)
                            if item.superseded == true {
                                Text(PichiLocalization.text(item.status == .completed ? "Completed later" : "Updated later", locale: self.interfaceLocale))
                                    .font(self.theme.typography.captionStrong)
                                    .foregroundStyle(item.status == .completed ? self.theme.palette.success : self.theme.palette.warning)
                            }
                            if questions {
                                Text(PichiLocalization.text(item.resolved == true ? "Answered later" : "Open question"))
                                    .font(self.theme.typography.captionStrong)
                                    .foregroundStyle(item.resolved == true ? self.theme.palette.success : self.theme.palette.secondaryText)
                            }
                            if actions {
                                if item.superseded != true {
                                    Text(item.status.map { PichiLocalization.format("Status: %@", language: self.interfaceLanguage, bundle: .main,
                                        arguments: [$0.text(language: self.interfaceLanguage)]) }
                                        ?? PichiLocalization.text("Task status not specified", locale: self.interfaceLocale))
                                        .font(self.theme.typography.captionStrong)
                                        .foregroundStyle(item.status == .completed ? self.theme.palette.success : self.theme.palette.secondaryText)
                                }
                                Text(item.urgency.flatMap { urgency in urgency == .unspecified ? nil
                                    : PichiLocalization.format("Urgency: %@", language: self.interfaceLanguage, bundle: .main,
                                        arguments: [urgency.text(language: self.interfaceLanguage)]) }
                                    ?? PichiMeetingSummaryActionUrgency.unspecified.text(language: self.interfaceLanguage))
                                    .font(self.theme.typography.caption)
                                    .foregroundStyle(item.urgency == .urgent ? self.theme.palette.warning : self.theme.palette.secondaryText)
                            }
                            if let owner = item.owner {
                                Text(PichiLocalization.text("Owner: ") + owner)
                                    .font(self.theme.typography.captionStrong)
                            }
                            if let deadline = item.deadline {
                                Text(PichiLocalization.text("Due: ") + deadline)
                                    .font(self.theme.typography.caption)
                            }
                            DisclosureGroup("Sources") {
                                ForEach(Array(item.evidence.enumerated()), id: \.offset) { _, evidence in
                                    self.source(evidence)
                                }
                            }
                            .font(self.theme.typography.caption)
                            .foregroundStyle(self.theme.palette.secondaryText)
                        }
                    }
                }
            }
        }
    }

    private func source(_ evidence: PichiMeetingSummaryEvidence) -> some View {
        let turn = (self.controller.documentSourceSession ?? self.session).flatMap { PichiMeetingSummaryInput.turns(for: $0).first { $0.id == evidence.segmentID } }
        let seconds = Int(max(0, turn?.seconds ?? 0))
        return VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text("\(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(turn?.speaker ?? PichiLocalization.text("Speaker"))")
                .font(self.theme.typography.captionStrong)
            Text(evidence.quote).textSelection(.enabled)
        }
        .padding(.vertical, self.theme.metrics.spacing.xs)
    }

    private func copy(_ document: PichiMeetingSummaryDocument) {
        let language = self.controller.documentConfiguration.flatMap { PichiInterfaceLanguage(rawValue: $0.language) } ?? self.interfaceLanguage
        NSPasteboard.general.clearContents()
        let sources = (self.controller.documentSourceSession ?? self.session).map(PichiMeetingSummaryInput.turns(for:)) ?? []
        NSPasteboard.general.setString(document.copyMarkdown(language: language, sources: sources), forType: .string)
    }
}
