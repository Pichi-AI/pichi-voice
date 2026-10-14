import SwiftUI

struct CommandShimmerText: View {
    let text: String
    @Environment(\.theme) private var theme

    var body: some View {
        // Independently readable inks can lose contrast when interpolated.
        Text(self.text)
            .font(.fluidSystem(size: 13, weight: .semibold))
            .foregroundStyle(self.theme.palette.primaryText)
            .accessibilityLabel(Text(self.text))
    }
}
