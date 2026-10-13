import SwiftUI

struct DictationMutedIndicator: View {
    @Environment(\.theme) private var theme
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "mic.slash.fill")
            if !self.compact {
                Text("Muted")
            }
        }
        .font(self.theme.typography.captionStrong)
        .foregroundStyle(self.theme.palette.warning)
        .fixedSize()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Dictation muted. Release Space to resume.")
        .help("Release Space to resume dictation")
    }
}
