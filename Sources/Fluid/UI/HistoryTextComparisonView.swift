import AppKit
import SwiftUI

struct HistoryTextComparisonView: View {
    @Environment(\.theme) private var theme
    let entry: TranscriptionHistoryEntry
    let copy: (String) -> Void
    @State private var showChanges = true
    @State private var comparison: HistoryTextDiff?
    @State private var comparisonMessage: String?
    @State private var hasCompared = false
    @State private var correctionSelection: DictionaryHistoryWordSelection?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            if self.entry.wasAIProcessed {
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
            if self.entry.wasAIProcessed {
                self.section(title: "Original transcription", content: self.entry.rawText, isOriginal: true)
            }
        }
        .task(id: self.showChanges) {
            // Keep the result while toggling; only this selected entry is compared, once.
            guard self.entry.wasAIProcessed, self.showChanges, !self.hasCompared else { return }
            let original = self.entry.rawText
            let final = self.entry.clipboardText ?? ""
            let result = await Task.detached(priority: .utility) {
                HistoryTextDiff.compare(original: original, final: final)
            }.value
            guard !Task.isCancelled else { return }
            self.comparison = result
            self.hasCompared = true
            self.comparisonMessage = result == nil
                ? "This entry is too long for inline comparison. Both texts remain available below."
                : nil
        }
        .sheet(item: self.$correctionSelection) { selection in
            HistoryDictionaryCorrectionSheet(selection: selection) { corrected in
                guard PrivateProfileStorage.isReadable(selection.profile), PrivateProfileStorage.acceptsNewWork,
                      let current = TranscriptionHistoryStore.shared.entries.first(where: { $0.id == selection.entryID }),
                      selection.matches(current),
                      let request = DictionaryWordTrainingRequest(
                          candidate: .init(heardText: selection.heardText, correctedText: corrected),
                          profile: selection.profile
                      ) else { return false }
                self.correctionSelection = nil
                NotificationCenter.default.post(name: .openDictionaryWordTraining, object: request)
                return true
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: PrivateProfileService.willConceal)) { _ in
            self.correctionSelection = nil
        }
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
            DictionarySelectableTranscript(text: self.attributedText(content, isOriginal: isOriginal)) { range in
                self.correctionSelection = DictionaryHistoryWordSelection(
                    entryID: self.entry.id, sourceText: content, range: range, isOriginal: isOriginal
                )
            }
            .frame(maxWidth: .infinity, alignment: .leading)
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
        if !isOriginal, self.entry.wasAIProcessed {
            Text("AI enhanced").font(self.theme.typography.caption)
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
        guard self.showChanges, let comparison else { return NSAttributedString(string: content, attributes: attributes) }
        let result = NSMutableAttributedString(string: "")
        for run in isOriginal ? comparison.original : comparison.final {
            var runAttributes = attributes
            if run.changed {
                runAttributes[.foregroundColor] = NSColor(self.theme.palette.readableText(isOriginal ? .red : .green))
                runAttributes[.backgroundColor] = NSColor(self.theme.palette.cardBackground)
                runAttributes[isOriginal ? .strikethroughStyle : .underlineStyle] = NSUnderlineStyle.single.rawValue
            }
            result.append(NSAttributedString(string: run.text, attributes: runAttributes))
        }
        return result
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
