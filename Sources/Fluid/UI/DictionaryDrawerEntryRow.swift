import SwiftUI

struct DictionarySavedAudioSummary {
    let count: Int
    let latestCapture: Date?
    var heardVariants: [String] = []

    /// Counts links in committed metadata. A legacy feature-only reference is
    /// not an audio sample; the links do not verify that their files are readable.
    static func from(_ captures: [PronunciationEnrollmentCapture]) -> Self {
        let linked = captures.filter { $0.inspectionID != nil || $0.originalAudioID != nil }
        var seen = Set<String>()
        let variants = captures.compactMap(\.observedText).filter { !$0.isEmpty && seen.insert($0).inserted }
        return Self(count: linked.count, latestCapture: linked.compactMap(\.capturedAt).max(), heardVariants: variants)
    }
}

struct DictionarySavedAudioSummaryView: View {
    let summary: DictionarySavedAudioSummary
    var onManage: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    var body: some View {
        if self.summary.count > 0 {
            Button(action: self.onManage ?? {}) {
                Label(PichiLocalization.format("Recordings (%lld)", self.summary.count), systemImage: "waveform")
            }
            .fluidGlassAction()
            .font(self.theme.typography.caption)
            .disabled(self.onManage == nil)
        }
    }
}

/// Presentation only. Persistence, training and deletion remain owned by the drawer.
struct DictionaryDrawerEntryRow: View {
    let entry: SettingsStore.CustomDictionaryEntry
    var audioSummary: DictionarySavedAudioSummary? = nil
    let isTestDisabled: Bool
    let onTest: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    var onRecordings: (() -> Void)? = nil
    @Environment(\.theme) private var theme

    enum Part: CaseIterable, Hashable { case replacement, aliases, samples, test, edit, delete }
    #if DEBUG
    /// Measures the actual production row without creating the dictionary service UI.
    var onLayout: ((Part, CGRect) -> Void)? = nil
    #endif

    var body: some View {
        VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
            self.measured(
                Text(verbatim: self.entry.replacement)
                    .font(self.theme.typography.bodyStrong)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading),
                part: .replacement
            )
            self.measured(
                self.spellings,
                part: .aliases
            )
            if let summary = self.audioSummary {
                self.measured(DictionarySavedAudioSummaryView(summary: summary, onManage: self.onRecordings), part: .samples)
            }
            ViewThatFits(in: .horizontal) {
                HStack(spacing: self.theme.metrics.spacing.sm) {
                    self.testButton
                    Spacer(minLength: 0)
                    self.editAndDeleteButtons
                }
                VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                    self.testButton
                    self.editAndDeleteButtons
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .coordinateSpace(name: self.entry.id)
    }

    private var spellings: some View {
        DictionarySavedSpellingsView(entry: self.entry, heardVariants: self.audioSummary?.heardVariants ?? [])
    }

    private var testButton: some View {
        self.measured(
            Button("Test word", action: self.onTest)
                .fluidGlassAction()
                .disabled(self.isTestDisabled)
                .accessibilityLabel("Test \(self.entry.replacement)"),
            part: .test
        )
    }

    private var editAndDeleteButtons: some View {
        HStack(spacing: self.theme.metrics.spacing.sm) {
            self.measured(
                Button(action: self.onEdit) {
                    FluidPencilShape()
                        .stroke(style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round))
                        .frame(width: 20, height: 20)
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .fluidGlassAction(circular: true)
                .help("Edit word")
                .accessibilityLabel("Edit \(self.entry.replacement)"),
                part: .edit
            )
            self.measured(
                Button(role: .destructive, action: self.onDelete) {
                    Image(systemName: "trash")
                        .font(.fluidSystem(size: 15, weight: .regular))
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                }
                .fluidGlassAction(circular: true)
                .help("Delete word")
                .accessibilityLabel("Delete \(self.entry.replacement)"),
                part: .delete
            )
        }
    }

    @ViewBuilder
    private func measured<Content: View>(_ content: Content, part: Part) -> some View {
        #if DEBUG
        content.onGeometryChange(for: CGRect.self) { geometry in
            geometry.frame(in: .named(self.entry.id))
        } action: { frame in
            self.onLayout?(part, frame)
        }
        #else
        content
        #endif
    }
}

/// Literal rules and acoustic observations have distinct labels in both word lists.
struct DictionarySavedSpellingsView: View {
    let entry: SettingsStore.CustomDictionaryEntry
    var heardVariants: [String] = []
    @Environment(\.theme) private var theme

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            if !self.entry.triggers.isEmpty {
                Text(PichiLocalization.format("Auto-replace: %@", self.entry.triggers.joined(separator: ", ")))
                    .lineLimit(2)
            }
            let heard = self.heardVariants.filter { value in
                value.caseInsensitiveCompare(self.entry.replacement) != .orderedSame &&
                    !self.entry.triggers.contains { $0.caseInsensitiveCompare(value) == .orderedSame }
            }
            if !heard.isEmpty {
                Text(PichiLocalization.format("Recognized as: %@", heard.joined(separator: ", ")))
                    .lineLimit(2)
            }
        }
        .font(self.theme.typography.caption)
        .foregroundStyle(self.theme.palette.secondaryText)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
