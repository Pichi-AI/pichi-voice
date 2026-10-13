import SwiftUI

/// A bounded onboarding surface whose painted background matches its validated ink.
struct OnboardingGlassSurface: ViewModifier {
    @Environment(\.theme) private var theme
    let selected: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: AppTheme.Metrics.Showcase.cardRadius, style: .continuous)
    }

    func body(content: Content) -> some View {
        content
            .background(self.theme.palette.cardBackground, in: self.shape)
            .overlay {
                self.shape.strokeBorder(
                    self.selected ? self.theme.palette.accentText : self.theme.palette.cardBorder,
                    lineWidth: self.contrast == .increased || self.selected ? 2 : 1
                )
                .allowsHitTesting(false)
            }
            .shadow(color: .black.opacity(self.selected ? 0.22 : 0.1), radius: self.selected ? 12 : 4, y: self.selected ? 8 : 2)
    }

}
