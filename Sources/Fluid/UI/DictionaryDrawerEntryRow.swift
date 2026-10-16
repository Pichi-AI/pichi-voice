import SwiftUI

/// Presentation only. Persistence, training and deletion remain owned by the drawer.
struct DictionaryDrawerEntryRow: View {
    let entry: SettingsStore.CustomDictionaryEntry
    let isTestDisabled: Bool
    let onTest: () -> Void
    let onEdit: () -> Void
    let onDelete: () -> Void
    @Environment(\.theme) private var theme

    enum Part: CaseIterable, Hashable { case replacement, aliases, test, edit, delete }
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
                Text(verbatim: self.entry.triggers.joined(separator: ", "))
                    .font(self.theme.typography.caption)
                    .foregroundStyle(self.theme.palette.secondaryText)
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading),
                part: .aliases
            )
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
