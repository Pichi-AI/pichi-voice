import SwiftUI

/// The desktop step card: a faint ink fill and hairline, with an accent edge and glow when selected.
private struct OnboardingStepCardModifier: ViewModifier {
    @Environment(\.theme) private var theme
    let isSelected: Bool

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: 16, style: .continuous)
        content
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(shape.fill(self.theme.palette.primaryText.opacity(self.isSelected ? 0.075 : 0.04)))
            .overlay(shape.stroke(self.isSelected ? self.theme.palette.accent.opacity(0.92) : self.theme.palette.primaryText.opacity(0.10),
                                  lineWidth: self.isSelected ? 1.4 : 1))
            .shadow(color: self.theme.palette.accent.opacity(self.isSelected ? 0.18 : 0), radius: 18)
    }
}

extension View {
    func fluidOnboardingStepCard(isSelected: Bool = false) -> some View {
        self.modifier(OnboardingStepCardModifier(isSelected: isSelected))
    }
}
