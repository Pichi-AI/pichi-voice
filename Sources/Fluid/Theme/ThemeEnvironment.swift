import AppKit
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
    @ViewBuilder func appTheme(_ theme: AppTheme) -> some View {
        let themed = self.font(theme.typography.inheritedFont)
        .foregroundStyle(theme.palette.primaryText)
        .environment(\.theme, theme)
        .buttonStyle(FluidOutlinedButtonStyle())
        if let variant = theme.variant {
            themed.environment(\.colorScheme, theme.palette.nativeColorScheme(fallback: variant))
        } else {
            themed
        }
    }
}

struct AdaptiveAppTheme<Content: View>: View {
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var settings = SettingsStore.shared
    #if os(macOS)
    @ObservedObject private var applicationAppearance = BrandAppearanceController.ApplicationAppearance.shared
    #endif

    let accent: Color
    let content: Content

    init(accent: Color, @ViewBuilder content: () -> Content) {
        self.accent = accent
        self.content = content()
    }

    var body: some View {
        let preferredScheme = self.settings.themePreference.preferredColorScheme
        #if os(macOS)
        let activeScheme = preferredScheme ?? self.applicationAppearance.colorScheme
        #else
        let activeScheme = preferredScheme ?? self.colorScheme
        #endif
        let activeAccent = self.settings.accentColorOption == .brand
            ? (Color(hex: activeScheme == .dark ? AppBrand.profile.accentDark : AppBrand.profile.accentLight) ?? self.accent)
            : self.accent
        let theme = AppTheme.adaptive(accent: activeAccent, colorScheme: activeScheme)

        self.content
            .appTheme(theme)
            .environment(\.locale, PichiLocalization.locale)
            .environment(\.layoutDirection, PichiLocalization.language.usesRightToLeftLayout ? .rightToLeft : .leftToRight)
            .tint(activeAccent)
            #if os(macOS)
            // Inherit the application's live appearance when it already matches
            // the palette. Pinning the same scheme here creates a second owner
            // during hot changes: application first, then the old window override.
            // Imported inverted palettes still need an owned window override.
            .preferredColorScheme(theme.palette.nativeColorScheme(fallback: activeScheme) == self.applicationAppearance.colorScheme
                ? nil : theme.palette.nativeColorScheme(fallback: activeScheme))
            // Keep the branded bar surface, but let native toolbar glass supply
            // its own appearance to its labels. A separate bar color-scheme
            // preference can pin ink while the glass still uses another scheme.
            .toolbarBackground(theme.palette.toolbarBackground, for: .windowToolbar)
            .toolbarBackgroundVisibility(.visible, for: .windowToolbar)
            #else
            .preferredColorScheme(preferredScheme)
            .toolbarColorScheme(theme.palette.nativeColorScheme(fallback: activeScheme), for: .navigationBar)
            #endif
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

    /// "#RRGGBB" in sRGB, the inverse of `init?(hex:)`.
    var hexString: String? {
        guard let rgb = NSColor(self).usingColorSpace(.sRGB) else { return nil }
        let channel = { (value: CGFloat) in Int((min(max(value, 0), 1) * 255).rounded()) }
        return String(format: "#%02X%02X%02X", channel(rgb.redComponent), channel(rgb.greenComponent), channel(rgb.blueComponent))
    }

    static var fluidGreen: Color {
        SettingsStore.shared.accentColor
    }
}
