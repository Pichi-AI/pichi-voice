import AppKit
import SwiftUI

struct PichiMeetingSummaryView: View {
    var session: MeetingSession?
    var asrService: ASRService?
    var isQuiescent: Bool
    @Environment(\.theme) private var theme
    @StateObject private var preferences = PichiMeetingSummarySettings()
    @StateObject private var controller = PichiMeetingSummaryController()
    @ObservedObject private var settings = SettingsStore.shared
    @State private var showingConfiguration = false

    private var configuration: PichiMeetingSummaryConfiguration? {
        try? self.preferences.configuration(sessionLanguage: self.session?.languageCode ?? "ru", settings: self.settings)
    }

    private var refreshIdentity: String {
        (self.session.map(PichiMeetingSummaryInput.fingerprint) ?? "") + "|"
            + self.preferences.selectionIdentity + "|" + (self.configuration?.cacheIdentity ?? "")
    }

    private var canGenerate: Bool {
        self.isQuiescent && !self.controller.generating && !self.controller.checking && self.configuration != nil
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
                    Button(self.controller.document == nil ? "Generate summary" : "Regenerate") {
                        guard let session = self.session, let config = self.configuration else { return }
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

            if let config = self.configuration {
                Label(config.isOnDevice ? "Transcript stays on this Mac · \(config.modelID)"
                      : "Transcript will be sent to \(config.baseURL) · \(config.modelID)",
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
                    Text(self.controller.generating ? self.controller.progress : "Loading saved summary…")
                        .font(self.theme.typography.bodySmall)
                }
            }
            if let error = self.controller.error {
                Label(error, systemImage: "exclamationmark.circle")
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let document = self.controller.document {
                if !(self.session?.transcriptCoverageGaps ?? []).isEmpty {
                    Label("The transcript has gaps. Conclusions cover only the captured speech.", systemImage: "exclamationmark.circle")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.warning)
                }
                self.summarySection(self.title(ru: "Резюме", en: "Recap"), items: document.summary)
                self.summarySection(self.title(ru: "Решения", en: "Decisions"), items: document.decisions)
                self.summarySection(self.title(ru: "Задачи", en: "Action items"), items: document.actions)
                self.summarySection(self.title(ru: "Вопросы и ответы", en: "Questions and answers"), items: document.openQuestions, questions: true)
                HStack(spacing: self.theme.metrics.spacing.md) {
                    Button("Copy summary", systemImage: "doc.on.doc") { self.copy(document) }
                        .meetingGlassAction()
                    Text("AI output should be checked against the linked sources.")
                        .font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.secondaryText)
                }
            } else if !self.controller.generating, !self.controller.checking {
                Text(self.session == nil ? "Record or open a meeting to generate its summary."
                     : "Finish the transcript, choose a model, then generate a summary. Russian is the default output language.")
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
        .onDisappear { self.controller.cancel() }
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
                    Button(self.preferences.discovering ? "Refreshing…" : "Refresh models") {
                        Task { await self.preferences.discoverModels() }
                    }
                    .meetingGlassAction()
                    .disabled(self.preferences.discovering)
                }
                Text("Start an OpenAI-compatible local server in Ollama or LM Studio. Recommended compact model: qwen3.5:4b; qwen3.5:2b uses less memory. Models must be installed separately.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                if let error = self.preferences.discoveryError {
                    Text(error).font(self.theme.typography.caption).foregroundStyle(self.theme.palette.warning)
                }
            } else {
                Text("Uses the provider and model selected in AI Enhancement settings. Choose an OpenAI-compatible API. Review the destination above before generating.")
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Picker("Summary language", selection: self.$preferences.language) {
                Text("Русский").tag("ru")
                Text("English").tag("en")
                Text("Transcript language").tag("transcript")
            }
            .pickerStyle(.menu)
        }
    }

    private func title(ru: String, en: String) -> String {
        self.configuration?.language == "ru" ? ru : en
    }

    private func summarySection(_ title: String, items: [PichiMeetingSummaryItem], questions: Bool = false) -> some View {
        FluidManagementGroup(title: title) {
            if items.isEmpty {
                Text(self.title(ru: "Не указаны в расшифровке.", en: "None stated in the transcript."))
                    .font(self.theme.typography.bodySmall)
                    .foregroundStyle(self.theme.palette.secondaryText)
            } else {
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
                    ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                            Text(item.text)
                                .font(self.theme.typography.body)
                                .strikethrough(item.superseded == true)
                                .textSelection(.enabled)
                            if item.superseded == true {
                                Text(self.title(ru: "Отменено или заменено позднее", en: "Cancelled or replaced later"))
                                    .font(self.theme.typography.captionStrong)
                                    .foregroundStyle(self.theme.palette.warning)
                            }
                            if questions {
                                Text(item.resolved == true
                                     ? self.title(ru: "Ответ получен позднее", en: "Answered later")
                                     : self.title(ru: "Открытый вопрос", en: "Open question"))
                                    .font(self.theme.typography.captionStrong)
                                    .foregroundStyle(item.resolved == true ? self.theme.palette.success : self.theme.palette.secondaryText)
                            }
                            if let owner = item.owner {
                                Text(self.title(ru: "Ответственный: ", en: "Owner: ") + owner)
                                    .font(self.theme.typography.captionStrong)
                            }
                            if let deadline = item.deadline {
                                Text(self.title(ru: "Срок: ", en: "Due: ") + deadline)
                                    .font(self.theme.typography.caption)
                            }
                            DisclosureGroup(self.title(ru: "Источники", en: "Sources")) {
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
        let turn = self.session.flatMap { PichiMeetingSummaryInput.turns(for: $0).first { $0.id == evidence.segmentID } }
        let seconds = Int(max(0, turn?.seconds ?? 0))
        return VStack(alignment: .leading, spacing: self.theme.metrics.spacing.xs) {
            Text("\(seconds / 60):\(String(format: "%02d", seconds % 60)) · \(turn?.speaker ?? "Speaker")")
                .font(self.theme.typography.captionStrong)
            Text(evidence.quote).textSelection(.enabled)
        }
        .padding(.vertical, self.theme.metrics.spacing.xs)
    }

    private func copy(_ document: PichiMeetingSummaryDocument) {
        let sections: [(String, [PichiMeetingSummaryItem])] = [
            (self.title(ru: "Резюме", en: "Recap"), document.summary),
            (self.title(ru: "Решения", en: "Decisions"), document.decisions),
            (self.title(ru: "Задачи", en: "Action items"), document.actions),
            (self.title(ru: "Вопросы и ответы", en: "Questions and answers"), document.openQuestions),
        ]
        let text = sections.map { title, items in
            title + "\n" + items.map { item in
                "- " + (item.superseded == true ? self.title(ru: "[Отменено/заменено] ", en: "[Superseded] ") : "")
                    + (item.resolved == true ? self.title(ru: "[Ответ получен] ", en: "[Answered] ") : "")
                    + item.text + (item.owner.map { " (\($0))" } ?? "") + (item.deadline.map { " [\($0)]" } ?? "")
                    + "\n" + item.evidence.map { "  > \($0.quote)" }.joined(separator: "\n")
            }.joined(separator: "\n")
        }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
