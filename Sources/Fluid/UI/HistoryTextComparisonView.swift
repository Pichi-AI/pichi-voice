import AppKit
import SwiftUI

struct HistoryTextComparisonView: View {
    @Environment(\.theme) private var theme
    let entry: TranscriptionHistoryEntry
    let copy: (String) -> Void
    @State private var showChanges = true
    @State private var comparison: HistoryTextDiff?
    @State private var comparisonMessage: String?
    @State private var comparedInput: ComparisonInput?
    @State private var correctionSelection: DictionaryHistoryWordSelection?
    @State private var activeInlineCorrection: InlineCorrection?
    @State private var savedInlineCorrection: SavedInlineCorrection?
    @State private var inlineError: String?
    @State private var interactionEpoch = UUID()
    @State private var isPreparingPronunciation = false
    @State private var pronunciationTask: Task<Void, Never>?

    private struct ComparisonInput: Equatable {
        let entryID: UUID
        let rawText: String
        let finalText: String
        let showChanges: Bool
        let manuallyEdited: Bool
    }

    private struct InlineCorrection {
        let entryID: UUID
        let edit: DictionaryInlineTextEdit
        let profile: PrivateProfileSnapshot
        let canonicalTerms: [String]
    }

    private struct SavedInlineCorrection {
        let entryID: UUID
        let expectedText: String
        let sourceText: String
        let profile: PrivateProfileSnapshot
        let candidate: AutomaticDictionaryCorrectionCandidate
    }

    private var comparisonInput: ComparisonInput {
        ComparisonInput(entryID: self.entry.id, rawText: self.entry.rawText,
                        finalText: self.entry.clipboardText ?? "", showChanges: self.showChanges,
                        manuallyEdited: self.entry.originalProcessedText != nil)
    }

    private var hasComparisonSource: Bool {
        self.entry.wasAIProcessed || self.entry.originalProcessedText != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if self.hasComparisonSource {
                HStack {
                    if self.showChanges, let message = self.comparisonMessage {
                        Text(PichiLocalization.text(message)).foregroundStyle(self.theme.palette.secondaryText)
                            .lineLimit(1).help(PichiLocalization.text(message))
                    }
                    Spacer()
                    Toggle("Show changes", isOn: self.$showChanges).toggleStyle(.switch).controlSize(.small)
                        .fixedSize()
                }
                .font(self.theme.typography.caption)
                .frame(minHeight: 24)
            }
            self.section(title: "Final text", content: self.entry.clipboardText ?? "", isOriginal: false)
            if self.hasComparisonSource {
                self.section(title: "Original transcription", content: self.entry.rawText, isOriginal: true)
            }
        }
        .task(id: self.comparisonInput) {
            let input = self.comparisonInput
            guard self.hasComparisonSource, self.showChanges else {
                self.comparison = nil
                self.comparisonMessage = nil
                return
            }
            guard self.comparedInput != input else { return }
            let result = await Task.detached(priority: .utility) {
                HistoryTextDiff.compare(original: input.rawText, final: input.finalText)
            }.value
            guard !Task.isCancelled, self.comparisonInput == input else { return }
            self.comparison = result
            self.comparedInput = input
            self.comparisonMessage = result == nil
                ? "This entry is too long for inline comparison. Both texts remain available below."
                : nil
        }
        .sheet(item: self.$correctionSelection) { selection in
            HistoryDictionaryCorrectionSheet(selection: selection) { corrected in
                guard PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
                      let current = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == selection.entryID }),
                      selection.matches(current) else { return false }
                self.correctionSelection = nil
                self.preparePronunciation(
                    candidate: .init(heardText: selection.heardText, correctedText: corrected),
                    selection: selection, expectedText: current.clipboardText ?? ""
                )
                return true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)) { _ in
            self.correctionSelection = nil
            self.clearInlineInteraction()
        }
        .onChange(of: self.entry.id) { _ in
            self.clearInlineInteraction()
        }
        .onDisappear { self.clearInlineInteraction() }
    }

    private func section(title: String, content: String, isOriginal: Bool) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    self.sectionTitle(title)
                    self.enhancementBadge(isOriginal: isOriginal)
                    Spacer(minLength: 8)
                    self.copyButton(content, isOriginal: isOriginal)
                }
                .fixedSize(horizontal: true, vertical: false)
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 8) {
                        self.sectionTitle(title)
                        Spacer(minLength: 8)
                        self.copyButton(content, isOriginal: isOriginal)
                    }
                    self.enhancementBadge(isOriginal: isOriginal)
                }
            }
            DictionarySelectableTranscript(
                text: self.attributedText(content, isOriginal: isOriginal),
                inlineEditingEnabled: !isOriginal,
                interactionIdentity: "\(self.entry.id):\(self.interactionEpoch)",
                accentColor: NSColor(self.theme.palette.accent),
                editorBackgroundColor: NSColor(self.theme.palette.cardBackground),
                editorTextColor: NSColor(self.theme.palette.primaryText),
                onBeginEdit: isOriginal ? nil : { range in self.beginInlineCorrection(range: range, source: content) },
                onEndEdit: { self.activeInlineCorrection = nil },
                onEdit: isOriginal ? nil : self.commitInlineCorrection,
                onCorrect: { range in
                    self.correctionSelection = DictionaryHistoryWordSelection(
                        entryID: self.entry.id, sourceText: content, range: range, isOriginal: isOriginal
                    )
                }
            )
            .frame(maxWidth: .infinity, alignment: .leading)
            if !isOriginal {
                if let error = self.inlineError {
                    Text(PichiLocalization.text(error)).font(self.theme.typography.caption)
                        .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                } else if self.savedInlineCorrection?.entryID == self.entry.id {
                    HStack(spacing: 8) {
                        Label(PichiLocalization.text(self.isPreparingPronunciation ? "Preparing pronunciation sample…" : "Correction saved"), systemImage: "checkmark.circle")
                            .foregroundStyle(self.theme.palette.secondaryText)
                        Spacer(minLength: 8)
                        Button("Record pronunciation", action: self.openSavedInlinePronunciation)
                            .buttonStyle(.borderless)
                            .disabled(self.isPreparingPronunciation)
                    }
                    .font(self.theme.typography.caption)
                }
            }
        }
        .padding(20)
        .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 16))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(self.theme.palette.cardBorder.opacity(0.5)))
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(PichiLocalization.text(title)).font(self.theme.typography.bodyStrong)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func enhancementBadge(isOriginal: Bool) -> some View {
        if !isOriginal, self.entry.wasAIProcessed || self.entry.originalProcessedText != nil {
            Text(PichiLocalization.text(self.entry.originalProcessedText != nil ? "Edited by you" : "AI enhanced")).font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.accentText)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(self.theme.palette.elevatedCardBackground, in: Capsule())
                .overlay(Capsule().stroke(self.theme.palette.accent.opacity(0.1), lineWidth: 1))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func copyButton(_ content: String, isOriginal: Bool) -> some View {
        Button { self.copy(content) } label: { Image(systemName: "doc.on.doc") }
            .buttonStyle(.plain).foregroundStyle(self.theme.palette.secondaryText)
            .help(PichiLocalization.text(isOriginal ? "Copy raw text" : "Copy final text"))
            .accessibilityLabel(PichiLocalization.text(isOriginal ? "Copy raw text" : "Copy final text"))
            .fixedSize()
    }

    private func attributedText(_ content: String, isOriginal: Bool) -> NSAttributedString {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        let attributes: [NSAttributedString.Key: Any] = [
            .font: self.theme.typography.nativeBodyFont,
            .foregroundColor: NSColor(isOriginal ? self.theme.palette.secondaryText : self.theme.palette.primaryText),
            .paragraphStyle: paragraph,
        ]
        guard self.showChanges, let comparison,
              (isOriginal ? comparison.original : comparison.final).map(\.text).joined() == content
        else { return NSAttributedString(string: content, attributes: attributes) }
        let result = NSMutableAttributedString(string: "")
        for run in isOriginal ? comparison.original : comparison.final {
            var runAttributes = attributes
            if run.changed {
                runAttributes[.foregroundColor] = NSColor(self.theme.palette.readableText(isOriginal ? .red : .green))
                runAttributes[isOriginal ? .strikethroughStyle : .underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: runAttributes))
        }
        return result
    }

    private func clearInlineInteraction() {
        self.pronunciationTask?.cancel()
        self.pronunciationTask = nil
        self.isPreparingPronunciation = false
        self.interactionEpoch = UUID()
        self.activeInlineCorrection = nil
        self.savedInlineCorrection = nil
        self.inlineError = nil
    }

    private func beginInlineCorrection(range: NSRange, source: String) -> Bool {
        let profile = PrivateProfileStorage.current
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              let current = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == self.entry.id }),
              current.clipboardText == source,
              let edit = DictionaryInlineTextEdit(sourceText: source, range: range) else { return false }
        self.activeInlineCorrection = InlineCorrection(
            entryID: self.entry.id, edit: edit, profile: profile,
            canonicalTerms: SettingsStore.shared.customDictionaryEntries.map(\.replacement)
        )
        self.inlineError = nil
        return true
    }

    private func commitInlineCorrection(range: NSRange, replacement: String) -> Bool {
        guard let context = self.activeInlineCorrection,
              context.entryID == self.entry.id, context.edit.range == range,
              let updatedText = context.edit.replacing(with: replacement),
              TranscriptionHistoryStore.shared.applyWordCorrection(
                  entryID: context.entryID, expectedText: context.edit.sourceText,
                  range: range, replacement: replacement, profile: context.profile
              ) else {
            self.inlineError = "This transcription changed. Select the word again."
            return false
        }
        self.activeInlineCorrection = nil
        self.inlineError = nil
        // Explicitly edited text can be a new term. Existing compounds retain all
        // unchanged components through the same detector used by fresh dictation.
        let candidate = AutomaticDictionaryCorrectionDetector.candidate(
            before: context.edit.sourceText, after: updatedText,
            insertedRange: NSRange(location: 0, length: (context.edit.sourceText as NSString).length),
            knownCanonicalTerms: context.canonicalTerms
        ) ?? self.explicitInlineCandidate(context: context, replacement: replacement)
        self.savedInlineCorrection = candidate.map {
            SavedInlineCorrection(entryID: context.entryID, expectedText: updatedText, sourceText: context.edit.sourceText,
                                  profile: context.profile, candidate: $0)
        }
        return true
    }

    private func explicitInlineCandidate(context: InlineCorrection, replacement: String) -> AutomaticDictionaryCorrectionCandidate? {
        guard DictionaryCorrectionEditPolicy.isTerm(context.edit.heardText),
              DictionaryCorrectionEditPolicy.isTerm(replacement), replacement != context.edit.heardText else { return nil }
        return AutomaticDictionaryCorrectionCandidate(
            heardText: context.edit.heardText, correctedText: replacement,
            sourceUTF16Range: context.edit.range
        )
    }

    private func openSavedInlinePronunciation() {
        guard let correction = self.savedInlineCorrection,
              correction.entryID == self.entry.id,
              let current = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == correction.entryID }),
              current.clipboardText == correction.expectedText,
              PrivateProfileStorage.isReadable(correction.profile),
              let range = correction.candidate.sourceUTF16Range,
              let selection = DictionaryHistoryWordSelection(entryID: correction.entryID, sourceText: correction.sourceText, range: range, isOriginal: false)
        else {
            self.savedInlineCorrection = nil
            return
        }
        self.preparePronunciation(candidate: correction.candidate, selection: selection, expectedText: correction.expectedText)
    }

    private func preparePronunciation(candidate: AutomaticDictionaryCorrectionCandidate, selection: DictionaryHistoryWordSelection, expectedText: String) {
        self.pronunciationTask?.cancel()
        let epoch = self.interactionEpoch
        self.isPreparingPronunciation = true
        self.pronunciationTask = Task { @MainActor in
            defer {
                if self.interactionEpoch == epoch {
                    self.isPreparingPronunciation = false
                    self.pronunciationTask = nil
                }
            }
            let enriched = await HistoryDictionaryAudioLearningService.shared.enrich(candidate: candidate, selection: selection)
            guard !Task.isCancelled, self.interactionEpoch == epoch, self.entry.id == selection.entryID,
                  let current = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == selection.entryID }),
                  current.clipboardText == expectedText,
                  let request = DictionaryWordTrainingRequest(candidate: enriched, profile: selection.profile) else { return }
            self.savedInlineCorrection = nil
            NotificationCenter.default.post(name: .openDictionaryWordTraining, object: request)
        }
    }
}

private struct HistoryDictionaryCorrectionSheet: View {
    let selection: DictionaryHistoryWordSelection
    let onContinue: (String) -> Bool
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    @State private var corrected = ""
    @State private var error: String?
    @FocusState private var spellingFocused: Bool

    private var spelling: String { self.corrected.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.lg) {
            Text("Correct word in dictionary").font(self.theme.typography.sectionTitle)
            Text(self.selection.heardText).font(self.theme.typography.body)
                .foregroundStyle(self.theme.palette.secondaryText)
            TextField("Correct spelling", text: self.$corrected)
                .textFieldStyle(.roundedBorder).font(self.theme.typography.body)
                .focused(self.$spellingFocused)
                .onSubmit(self.continueToDictionary)
            Text("Record pronunciation examples in the dictionary. The history text stays unchanged.")
                .font(self.theme.typography.caption).foregroundStyle(self.theme.palette.secondaryText)
                .fixedSize(horizontal: false, vertical: true)
            if let error = self.error {
                Text(PichiLocalization.text(error)).font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
            }
            HStack {
                Spacer()
                Button("Cancel") { self.dismiss() }.keyboardShortcut(.cancelAction)
                Button("Continue in dictionary", action: self.continueToDictionary)
                    .keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(!DictionaryCorrectionEditPolicy.isTerm(self.spelling) || self.spelling == self.selection.heardText)
            }
        }
        .padding(self.theme.metrics.spacing.xl).frame(width: 440)
        .background(self.theme.palette.windowBackground)
        .onAppear { self.corrected = self.selection.heardText; self.spellingFocused = true }
    }

    private func continueToDictionary() {
        guard DictionaryCorrectionEditPolicy.isTerm(self.spelling), self.spelling != self.selection.heardText else { return }
        if self.onContinue(self.spelling) { self.dismiss() }
        else { self.error = "This transcription changed. Select the word again." }
    }
}
