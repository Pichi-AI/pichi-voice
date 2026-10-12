import SwiftUI

/// The same shortcut key used throughout onboarding.
struct OnboardingShortcutKeycap: View {
    let text: String
    let isPressed: Bool
    let isListening: Bool
    @Environment(\.theme) private var theme

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: 10, style: .continuous)

        return Text(self.text)
            .font(.fluidSystem(size: 20, weight: .semibold))
            .foregroundStyle(self.theme.palette.primaryText)
            .lineLimit(1)
            .minimumScaleFactor(0.62)
            .padding(.horizontal, 14)
            .frame(width: 112, height: 74)
            .background(
                shape
                    .fill(self.theme.palette.primaryText.opacity(self.isListening ? 0.115 : 0.075))
                    .overlay(
                        shape.stroke(
                            self.theme.palette.accent.opacity(self.isListening ? 0.86 : 0.48),
                            lineWidth: self.isListening ? 1.6 : 1.2
                        )
                    )
                    .shadow(
                        color: self.theme.palette.accent.opacity(self.isListening ? 0.34 : 0.20),
                        radius: self.isListening ? 18 : 12,
                        x: 0,
                        y: self.isPressed ? 2 : 0
                    )
            )
            .scaleEffect(self.isPressed ? 0.965 : 1)
            .offset(y: self.isPressed ? 4 : 0)
            .accessibilityLabel("Current shortcut \(self.text)")
    }
}
