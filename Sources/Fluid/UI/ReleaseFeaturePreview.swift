import SwiftUI

/// Static product illustrations: no live user data, model loading, or recording work.
struct ReleaseFeaturePreview: View {
    let kind: ReleaseHighlightsContent.Preview
    @Environment(\.theme) private var theme

    var body: some View {
        Group {
            switch self.kind {
            case .meeting: self.meeting
            case .sources:
                self.options([
                    ("mic", "Microphone only"),
                    ("macwindow", "One application"),
                    ("speaker.wave.2", "All computer audio"),
                ])
            case .analytics:
                self.options([
                    ("calendar", "Daily activity"),
                    ("chart.bar", "Optional detailed metrics"),
                    ("waveform.slash", "No audio or transcripts"),
                ])
            case .dictation:
                Label { Text(verbatim: "GigaAM") } icon: { Image(systemName: "waveform") }
                    .font(self.theme.typography.title)
                    .foregroundStyle(self.theme.palette.accentText)
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(self.theme.palette.elevatedCardBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(self.theme.palette.cardBorder, lineWidth: 1)
        }
        .foregroundStyle(self.theme.palette.primaryText)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var meeting: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 7) {
                Image(systemName: "waveform").foregroundStyle(self.theme.palette.accentText)
                Text("Product catch-up").font(.fluidSystem(size: 11, weight: .semibold))
                Spacer(minLength: 0)
                Text("12:48").font(.fluidSystem(size: 9, design: .monospaced))
                    .foregroundStyle(self.theme.palette.secondaryText)
            }
            HStack(alignment: .top, spacing: 8) {
                Circle().fill(self.theme.palette.cardBackground)
                    .overlay(Circle().stroke(self.theme.palette.accent.opacity(0.18), lineWidth: 1))
                    .frame(width: 19, height: 19)
                    .overlay(Text("A").font(.fluidSystem(size: 9, weight: .medium)).foregroundStyle(self.theme.palette.accentText))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Let’s get the next release ready.")
                        .font(.fluidSystem(size: 10))
                    Text("We’ll start with the new features.")
                        .font(.fluidSystem(size: 9)).foregroundStyle(self.theme.palette.secondaryText)
                }
            }
            VStack(alignment: .leading, spacing: 5) {
                Label("Summary", systemImage: "sparkles")
                    .font(.fluidSystem(size: 9, weight: .semibold))
                    .foregroundStyle(self.theme.palette.accentText)
                Text("Review features. Prepare the release.")
                    .font(.fluidSystem(size: 9)).foregroundStyle(self.theme.palette.secondaryText)
            }
            .padding(9)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(self.theme.palette.cardBackground, in: RoundedRectangle(cornerRadius: 7))
        }
    }

    private func options(_ rows: [(symbol: String, title: String)]) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            ForEach(rows, id: \.symbol) { row in
                HStack(spacing: 10) {
                    Image(systemName: row.symbol)
                        .foregroundStyle(self.theme.palette.accentText)
                        .frame(width: 20)
                    Text(PichiLocalization.text(row.title))
                        .font(self.theme.typography.bodySmall)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}
