import SwiftUI

struct DictationMutedIndicator: View {
    @Environment(\.theme) private var theme
    var compact = false

    var body: some View {
        // The recording surfaces use dark glass in either application theme.
        let overlayTheme = AppTheme.adaptive(accent: self.theme.palette.accent, colorScheme: .dark)
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 5) {
                Image(systemName: "mic.slash.fill")
                if !self.compact {
                    Text("Muted")
                }
            }
            .fixedSize()
            Image(systemName: "mic.slash.fill")
                .fixedSize()
        }
        .font(self.theme.typography.bodySmallStrong)
        .foregroundStyle(overlayTheme.palette.warning)
        .environment(\.colorScheme, .dark)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(PichiLocalization.text("Dictation muted. Release Space to resume."))
        .help(PichiLocalization.text("Release Space to resume dictation"))
    }
}
