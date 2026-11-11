import AppKit
import SwiftUI

struct HistoryTextComparisonView: View {
    @Environment(\.theme) private var theme
    let entry: TranscriptionHistoryEntry
    let copy: (String) -> Void
    var historyStore: TranscriptionHistoryStore? = nil
    var rejectionService: DictionaryRejectionService? = nil
    @State private var showChanges = true
    @State private var comparison: HistoryTextDiff?
    @State private var sourceCorrections: HistoryTextDiff?
    @State private var comparisonMessage: String?
    @State private var comparedInput: ComparisonInput?
    @State private var correctionSelection: DictionaryHistoryWordSelection?
    @State private var activeInlineCorrection: InlineCorrection?
    @State private var savedInlineCorrection: SavedInlineCorrection?
    @State private var inlineError: String?
    @State private var interactionEpoch = UUID()
    @State private var isPreparingPronunciation = false
    @State private var pronunciationTask: Task<Void, Never>?
    @State private var savedAudioStatus: String?
    @State private var rejectionStatus: String?
    @State private var rejectionTask: Task<Void, Never>?

    private struct ComparisonInput: Equatable {
        let entryID: UUID
        let rawText: String
        let originalRawText: String
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
        let plan: DictionaryCorrectionReplacementPlan
    }

    private var comparisonInput: ComparisonInput {
        ComparisonInput(entryID: self.entry.id, rawText: self.entry.sourceTranscriptText,
                        originalRawText: self.entry.rawText,
                        finalText: self.entry.clipboardText ?? "", showChanges: self.showChanges,
                        manuallyEdited: self.entry.originalProcessedText != nil)
    }

    private var hasComparisonSource: Bool {
        self.entry.wasAIProcessed || self.entry.originalProcessedText != nil || self.entry.correctedRawText != nil
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
            self.section(title: "Original transcription", content: self.entry.sourceTranscriptText, isOriginal: true)
        }
        .task(id: self.comparisonInput) {
            let input = self.comparisonInput
            guard self.hasComparisonSource, self.showChanges else {
                self.comparison = nil
                self.sourceCorrections = nil
                self.comparedInput = nil
                self.comparisonMessage = nil
                return
            }
            guard self.comparedInput != input else { return }
            let (result, sourceEdits) = await Task.detached(priority: .utility) {
                (HistoryTextDiff.compare(original: input.rawText, final: input.finalText),
                 HistoryTextDiff.compare(original: input.originalRawText, final: input.rawText))
            }.value
            guard !Task.isCancelled, self.comparisonInput == input else { return }
            self.comparison = result
            self.sourceCorrections = sourceEdits
            self.comparedInput = input
            self.comparisonMessage = result == nil
                ? "This entry is too long for inline comparison. Both texts remain available below."
                : nil
        }
        .sheet(item: self.$correctionSelection) { selection in
            HistoryDictionaryCorrectionSheet(selection: selection) { corrected in
                guard PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
                      let current = (self.historyStore ?? TranscriptionHistoryStore.shared).entries.first(where: { $0.id == selection.entryID }),
                      selection.matches(current) else { return false }
                self.correctionSelection = nil
                self.preparePronunciation(
                    candidate: .init(heardText: selection.heardText, correctedText: corrected),
                    selection: selection, expectedText: selection.isOriginal ? current.sourceTranscriptText : (current.clipboardText ?? "")
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
            self.sectionHeader(title: title, content: content, isOriginal: isOriginal)
            self.transcript(content: content, isOriginal: isOriginal)
                .frame(maxWidth: .infinity, alignment: .leading)
            if isOriginal {
                self.dictionaryReplacementActions
                self.inlineStatus
                self.savedAudioActions
            }
        }
        .padding(20)
        .background { RoundedRectangle(cornerRadius: 16).fill(self.theme.palette.cardBackground) }
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(self.theme.palette.cardBorder.opacity(0.5)) }
    }

    @ViewBuilder private var dictionaryReplacementActions: some View {
        let hits = self.entry.currentDictionaryReplacements
        if !hits.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Label(PichiLocalization.text("From dictionary"), systemImage: "text.book.closed")
                    .foregroundStyle(self.theme.palette.readableText(self.theme.palette.warning))
                ForEach(hits) { hit in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(verbatim: hit.label).font(self.theme.typography.bodyStrong)
                            Text(PichiLocalization.format("Model heard: %@", hit.heard))
                                .foregroundStyle(self.theme.palette.secondaryText)
                        }
                        Spacer(minLength: 8)
                        Button("Use model version") { self.restoreDictionaryReplacement(hit) }
                            .buttonStyle(.borderless)
                            .accessibilityIdentifier("history.dictionary.restore.\(hit.id.uuidString)")
                    }
                }
            }.font(self.theme.typography.caption)
        }
        if let status = self.rejectionStatus {
            Text(PichiLocalization.text(status)).font(self.theme.typography.caption)
                .foregroundStyle(self.theme.palette.secondaryText)
                .accessibilityIdentifier("history.dictionary.rejectionStatus")
        }
    }

    private func restoreDictionaryReplacement(_ hit: DictionaryHistoryReplacement) {
        self.rejectionTask?.cancel()
        let entryID = self.entry.id, source = self.entry.sourceTranscriptText
        let profile = PrivateProfileStorage.current
        let history = self.historyStore ?? TranscriptionHistoryStore.shared
        self.rejectionTask = Task { @MainActor in
            let result = await (self.rejectionService ?? .shared).restore(entryID: entryID, replacementID: hit.id,
                expectedSource: source, history: history, profile: profile)
            guard !Task.isCancelled, self.entry.id == entryID, PrivateProfileStorage.isReadable(profile) else { return }
            self.rejectionStatus = result.restored
                ? (result.negativeSaved ? "Model version restored. Negative example saved." : "Model version restored. Negative example unavailable.")
                : "This text changed. Select the replacement again."
            self.rejectionTask = nil
        }
    }

    private func sectionHeader(title: String, content: String, isOriginal: Bool) -> some View {
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
    }

    private func transcript(content: String, isOriginal: Bool) -> DictionarySelectableTranscript {
        var view = DictionarySelectableTranscript(text: self.attributedText(content, isOriginal: isOriginal)) { range in
            self.correctionSelection = DictionaryHistoryWordSelection(
                entryID: self.entry.id, sourceText: content, range: range, isOriginal: isOriginal)
        }
        view.inlineEditingEnabled = isOriginal
        view.fragmentRanges = isOriginal ? self.entry.sourceFragments.map(\.range) : []
        view.interactionIdentity = "\(self.entry.id):\(self.interactionEpoch)"
        view.accentColor = NSColor(self.theme.palette.accent)
        view.editorBackgroundColor = NSColor(self.theme.palette.cardBackground)
        view.editorTextColor = NSColor(self.theme.palette.primaryText)
        view.onEndEdit = { self.activeInlineCorrection = nil }
        if isOriginal {
            view.onBeginEdit = { range in self.beginInlineCorrection(range: range, source: content) }
            view.onEdit = { range, replacement in self.commitInlineCorrection(range: range, replacement: replacement) }
            view.onConfirmFragment = { range in self.confirmInlinePronunciation(range: range) }
        }
        return view
    }

    @ViewBuilder private var inlineStatus: some View {
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

    @ViewBuilder private var savedAudioActions: some View {
        let indices = self.entry.sourceFragments.indices.filter { index in
            let fragment = self.entry.sourceFragments[index]
            return fragment.isValid(in: self.entry.sourceTranscriptText) &&
                DictionaryCorrectionEditPolicy.isTerm(fragment.text)
        }
        if DictionaryMatcherExperiment.sharedFeaturesEnabled, self.savedInlineCorrection == nil,
           self.entry.correctedRawText != nil, self.entry.audio != nil, !indices.isEmpty {
            HStack(spacing: 8) {
                if let status = self.savedAudioStatus {
                    Text(PichiLocalization.text(status)).foregroundStyle(self.theme.palette.secondaryText)
                }
                Spacer(minLength: 8)
                if indices.count == 1, let index = indices.first {
                    Button("Use original audio") { self.learnSavedAudio(fragmentIndex: index) }
                        .buttonStyle(.borderless)
                } else {
                    Menu("Use original audio") {
                        ForEach(indices, id: \.self) { index in
                            Button(String(index + 1) + ". " + self.entry.sourceFragments[index].text) { self.learnSavedAudio(fragmentIndex: index) }
                        }
                    }.menuStyle(.borderlessButton).fixedSize()
                }
            }.font(self.theme.typography.caption)
        }
    }

    private func learnSavedAudio(fragmentIndex: Int) {
        let queued = HistoryDictionaryAudioLearningService.shared.enqueueSavedCorrection(entryID: self.entry.id,
            fragmentIndex: fragmentIndex, expectedSourceText: self.entry.sourceTranscriptText)
        self.savedAudioStatus = queued > 0 ? "Pronunciation sample queued" : "Pronunciation sample unavailable"
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(PichiLocalization.text(title)).font(self.theme.typography.bodyStrong)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder
    private func enhancementBadge(isOriginal: Bool) -> some View {
        if isOriginal ? self.entry.correctedRawText != nil : (self.entry.wasAIProcessed || self.entry.originalProcessedText != nil) {
            Text(PichiLocalization.text((isOriginal || self.entry.originalProcessedText != nil) ? "Edited by you" : "AI enhanced")).font(self.theme.typography.caption)
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
        if isOriginal {
            let result = NSMutableAttributedString(string: content, attributes: attributes)
            // A corrected source contains current words, not deleted words. Give
            // explicit user corrections positive emphasis instead of AI deletion markup.
            if self.showChanges, let edits = self.sourceCorrections,
               edits.final.map(\.text).joined() == content {
                var offset = 0
                for run in edits.final {
                    let range = NSRange(location: offset, length: run.text.utf16.count)
                    if run.changed {
                        result.addAttributes([
                            .foregroundColor: NSColor(self.theme.palette.accentText),
                            .backgroundColor: NSColor(self.theme.palette.accent.opacity(0.16)),
                        ], range: range)
                    }
                    offset += range.length
                }
            }
            if self.showChanges {
                for fragment in self.entry.sourceFragments where fragment.isValid(in: content) {
                    result.addAttributes([
                        .foregroundColor: NSColor(self.theme.palette.accentText),
                        .backgroundColor: NSColor(self.theme.palette.accent.opacity(0.16)),
                    ], range: fragment.range)
                }
            }
            self.markDictionaryReplacements(in: result, content: content)
            return result
        }
        guard self.showChanges, let comparison,
              (isOriginal ? comparison.original : comparison.final).map(\.text).joined() == content
        else {
            let result = NSMutableAttributedString(string: content, attributes: attributes)
            self.markDictionaryReplacements(in: result, content: content)
            return result
        }
        let result = NSMutableAttributedString(string: "")
        for run in isOriginal ? comparison.original : comparison.final {
            var runAttributes = attributes
            if run.changed {
                runAttributes[.foregroundColor] = NSColor(self.theme.palette.readableText(.green))
                runAttributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: runAttributes))
        }
        self.markDictionaryReplacements(in: result, content: content)
        return result
    }

    private func markDictionaryReplacements(in result: NSMutableAttributedString, content: String) {
        for hit in self.entry.currentDictionaryReplacements {
            guard let range = DictionaryLearningAlignmentResolver.textRange(in: content,
                delivered: self.entry.sourceTranscriptText, selected: hit.range),
                  DictionaryCorrectionReplacementPlan.isValid(range, in: content),
                  (content as NSString).substring(with: range).caseInsensitiveCompare(hit.label) == .orderedSame else { continue }
            result.addAttributes([
                .foregroundColor: NSColor(self.theme.palette.readableText(self.theme.palette.warning)),
                .backgroundColor: NSColor(self.theme.palette.warning.opacity(0.12)),
                .underlineStyle: NSUnderlineStyle.single.rawValue,
                .toolTip: PichiLocalization.format("Dictionary: %@. Model heard: %@", hit.label, hit.heard),
            ], range: range)
        }
    }

    private func clearInlineInteraction() {
        self.rejectionTask?.cancel()
        self.rejectionTask = nil
        self.rejectionStatus = nil
        self.pronunciationTask?.cancel()
        self.pronunciationTask = nil
        self.isPreparingPronunciation = false
        self.interactionEpoch = UUID()
        self.activeInlineCorrection = nil
        self.savedInlineCorrection = nil
        self.inlineError = nil
        self.savedAudioStatus = nil
    }

    private func beginInlineCorrection(range: NSRange, source: String) -> Bool {
        let profile = PrivateProfileStorage.current
        guard PrivateProfileStorage.isReadable(profile), PrivateProfileStorage.acceptsNewWork,
              let current = (self.historyStore ?? TranscriptionHistoryStore.shared).entries.first(where: { $0.id == self.entry.id }),
              current.sourceTranscriptText == source,
              let edit = DictionaryInlineTextEdit(sourceText: source, range: range) else { return false }
        self.activeInlineCorrection = InlineCorrection(
            entryID: self.entry.id, edit: edit, profile: profile,
            canonicalTerms: SettingsStore.shared.customDictionaryEntries.map(\.replacement)
        )
        self.inlineError = nil
        return true
    }

    private func commitInlineCorrection(range: NSRange, replacement: String) -> Bool {
        let history = self.historyStore ?? TranscriptionHistoryStore.shared
        let protected = history.entries.first(where: { $0.id == self.entry.id })?.currentDictionaryReplacements.map(\.range) ?? []
        guard let context = self.activeInlineCorrection,
              context.entryID == self.entry.id, context.edit.range == range,
              let singleEditText = context.edit.replacing(with: replacement),
              let plan = DictionaryCorrectionReplacementPlan(sourceText: context.edit.sourceText, range: range, replacement: replacement, protectedRanges: protected)
        else { return false }
        // Detect only the explicit edit. Propagated repetitions are not separate
        // user edits and must not turn one correction into an ambiguous diff.
        let detected = AutomaticDictionaryCorrectionDetector.candidate(
            before: context.edit.sourceText, after: singleEditText,
            insertedRange: NSRange(location: 0, length: (context.edit.sourceText as NSString).length),
            knownCanonicalTerms: context.canonicalTerms
        )
        let explicit = self.explicitInlineCandidate(context: context, replacement: replacement)
        let selectedPhrase = DictionaryInlineTextEdit.wordRanges(in: context.edit.heardText).count > 1 ||
            DictionaryInlineTextEdit.wordRanges(in: replacement).count > 1
        let proposed = selectedPhrase ? explicit : (detected ?? explicit)
        let candidate = AutomaticDictionaryCorrectionDetector.confirmedCandidate(proposed, in: plan) ??
            AutomaticDictionaryCorrectionDetector.confirmedCandidate(explicit, in: plan)
        let rejected = history.entries.first(where: { $0.id == context.entryID })?.currentDictionaryReplacements.first {
            $0.range == range && DictionaryNegativeEvidenceResolver.normalized($0.label) != DictionaryNegativeEvidenceResolver.normalized(replacement)
        }
        guard history.applyWordCorrection(
            entryID: context.entryID, expectedText: context.edit.sourceText,
            range: range, replacement: replacement, profile: context.profile, isOriginal: true,
            confirmationRange: candidate?.sourceUTF16Range, replacesAllOccurrences: rejected == nil
        ) else {
            self.inlineError = "This transcription changed. Select the word again."
            return false
        }
        self.activeInlineCorrection = nil
        self.inlineError = nil
        if let rejected {
            self.savedInlineCorrection = nil
            self.rejectionTask?.cancel()
            self.rejectionTask = Task { @MainActor in
                let saved = await (self.rejectionService ?? .shared).remember(rejected, corrected: replacement, profile: context.profile, isValid: {
                    history.entries.first(where: { $0.id == context.entryID })?.rejectionRemainsValid(rejected.id) == true
                })
                guard !Task.isCancelled, self.entry.id == context.entryID else { return }
                self.rejectionStatus = saved ? "Correction saved. Negative example saved." : "Correction saved. Negative example unavailable."
                self.rejectionTask = nil
            }
            return true
        }
        if let candidate, let candidateRange = candidate.sourceUTF16Range,
           let selection = DictionaryHistoryWordSelection(entryID: context.entryID, sourceText: context.edit.sourceText,
               range: candidateRange, isOriginal: true) {
            HistoryDictionaryAudioLearningService.shared.enqueueInline(candidate: candidate, selection: selection,
                expectedText: plan.text, correctionPlan: plan)
        }
        self.savedInlineCorrection = candidate.map {
            SavedInlineCorrection(entryID: context.entryID, expectedText: plan.text, sourceText: context.edit.sourceText,
                                  profile: context.profile, candidate: $0, plan: plan)
        }
        return true
    }

    private func explicitInlineCandidate(context: InlineCorrection, replacement: String) -> AutomaticDictionaryCorrectionCandidate? {
        guard let heard = DictionaryCorrectionEditPolicy.acousticSpelling(context.edit.heardText),
              DictionaryCorrectionEditPolicy.isTerm(replacement),
              replacement != context.edit.heardText || DictionaryInlineTextEdit.wordRanges(in: replacement).count > 1 else { return nil }
        return AutomaticDictionaryCorrectionCandidate(
            heardText: heard, correctedText: replacement,
            sourceUTF16Range: context.edit.range
        )
    }

    /// Confirming a previously corrected group can teach its retained audio
    /// without rewriting the history entry or inventing another text edit.
    private func confirmInlinePronunciation(range: NSRange) {
        guard let context = self.activeInlineCorrection, context.entryID == self.entry.id,
              context.edit.range == range, PrivateProfileStorage.isReadable(context.profile),
              let current = (self.historyStore ?? TranscriptionHistoryStore.shared).entries.first(where: { $0.id == context.entryID }),
              current.sourceTranscriptText == context.edit.sourceText,
              current.sourceFragments.contains(where: { $0.range == range }),
              let selection = DictionaryHistoryWordSelection(entryID: context.entryID, sourceText: context.edit.sourceText, range: range, isOriginal: true),
              let candidate = self.explicitInlineCandidate(context: context, replacement: context.edit.heardText) else { return }
        HistoryDictionaryAudioLearningService.shared.enqueueInline(candidate: candidate, selection: selection, expectedText: current.sourceTranscriptText)
    }

    private func openSavedInlinePronunciation() {
        guard let correction = self.savedInlineCorrection,
              correction.entryID == self.entry.id,
              let current = (self.historyStore ?? TranscriptionHistoryStore.shared).entries.first(where: { $0.id == correction.entryID }),
              current.sourceTranscriptText == correction.expectedText,
              PrivateProfileStorage.isReadable(correction.profile),
              let range = correction.candidate.sourceUTF16Range,
              let selection = DictionaryHistoryWordSelection(entryID: correction.entryID, sourceText: correction.sourceText, range: range, isOriginal: true)
        else {
            self.savedInlineCorrection = nil
            return
        }
        self.preparePronunciation(candidate: correction.candidate, selection: selection, expectedText: correction.expectedText, correctionPlan: correction.plan)
    }

    private func preparePronunciation(candidate: AutomaticDictionaryCorrectionCandidate, selection: DictionaryHistoryWordSelection, expectedText: String,
                                      correctionPlan: DictionaryCorrectionReplacementPlan? = nil) {
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
            let enriched = await HistoryDictionaryAudioLearningService.shared.enrich(candidate: candidate, selection: selection, correctionPlan: correctionPlan)
            guard !Task.isCancelled, self.interactionEpoch == epoch, self.entry.id == selection.entryID,
                  let current = (self.historyStore ?? TranscriptionHistoryStore.shared).entries.first(where: { $0.id == selection.entryID }),
                  (selection.isOriginal ? current.sourceTranscriptText : (current.clipboardText ?? "")) == expectedText,
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
