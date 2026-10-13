import SwiftUI

struct DictationMutedIndicator: View {
    @Environment(\.theme) private var theme
    var compact = false

    var body: some View {
        // Recording surfaces use dark glass in either application theme.
        let overlayTheme = AppTheme.adaptive(accent: self.theme.palette.accent, colorScheme: .dark)
        // Keep the icon legible over clear glass and a bright desktop.
        let mutedIcon = Image(systemName: "mic.slash.fill")
            .padding(self.theme.metrics.spacing.xs)
            .background(overlayTheme.palette.cardBackground, in: Circle())
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                mutedIcon
                if !self.compact {
                    Text("Muted")
                }
            }
            .fixedSize()
            mutedIcon.fixedSize()
        }
        .font(self.theme.typography.captionStrong)
        .foregroundStyle(overlayTheme.palette.warning)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PichiLocalization.text("Dictation muted. Release Space to resume."))
        .help(PichiLocalization.text("Release Space to resume dictation"))
    }
}
