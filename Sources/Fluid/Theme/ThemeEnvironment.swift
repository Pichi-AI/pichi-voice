import SwiftUI

private struct ThemeKey: EnvironmentKey {
    static var defaultValue: AppTheme = .dark
}

extension EnvironmentValues {
    var theme: AppTheme {
        get { self[ThemeKey.self] }
        set { self[ThemeKey.self] = newValue }
    }
}

extension View {
    /// Applies an app theme to the view hierarchy.
    func appTheme(_ theme: AppTheme) -> some View {
        self.font(theme.typography.inheritedFont)
        .environment(\.theme, theme)
        .buttonStyle(FluidOutlinedButtonStyle())
    }
}

struct AdaptiveAppTheme<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = SettingsStore.shared

    let accent: Color
    let content: Content

    init(accent: Color, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        let preferredScheme = self.settings.themePreference.preferredColorScheme
        let activeScheme = preferredScheme ?? self.colorScheme
        let activeAccent = self.settings.accentColorOption == .brand
            ? (Color(hex: activeScheme == .dark ? AppBrand.profile.accentDark : AppBrand.profile.accentLight) ?? self.accent)
            : self.accent

        self.content
            .appTheme(AppTheme.adaptive(accent: activeAccent, colorScheme: activeScheme))
            .environment(\.locale, PichiLocalization.locale)
            .environment(\.layoutDirection, PichiLocalization.language.usesRightToLeftLayout ? .rightToLeft : .leftToRight)
            .tint(activeAccent)
            .preferredColorScheme(preferredScheme)
    }
}

// MARK: - Color Hex Initializer

extension Color {
    /// Initialize a Color from a hex string (e.g., "#FF5733" or "FF5733")
    init?(hex: String) {
        var hexSanitized = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        hexSanitized = hexSanitized.replacingOccurrences(of: "#", with: "")

        guard hexSanitized.count == 6 else { return nil }

        var rgb: UInt64 = 0
        guard Scanner(string: hexSanitized).scanHexInt64(&rgb) else { return nil }

        let red = Double((rgb & 0xff0000) >> 16) / 255.0
        let green = Double((rgb & 0x00ff00) >> 8) / 255.0
        let blue = Double(rgb & 0x0000ff) / 255.0

        self.init(red: red, green: green, blue: blue)
    }

    static var fluidGreen: Color {
        SettingsStore.shared.accentColor
    }
}
