import SwiftUI

/// Only the theme members consumed by the unchanged meeting caption renderer.
/// This bridge keeps the design host isolated while the real AppKit theme is split for iOS.
struct PrototypeCaptionTheme {
    struct Palette {
        let accent: Color
        let primaryText: Color
        let secondaryText: Color
        let contentBackground: Color
    }
    struct Typography { let body: Font; let captionStrong: Font }
    struct Metrics {
        struct Spacing { let sm: CGFloat }
        let spacing: Spacing
    }
    let palette: Palette
    let typography: Typography
    let metrics: Metrics

    init(_ theme: PrototypeTheme) {
        palette = Palette(accent: theme.accent, primaryText: theme.color("primaryText"),
                          secondaryText: theme.color("secondaryText"), contentBackground: theme.color("contentBackground"))
        typography = Typography(body: theme.font(.body), captionStrong: theme.font(.caption, weight: .medium))
        metrics = Metrics(spacing: .init(sm: 8 * PrototypeBrand.shared.style.spacingScale))
    }
}

private struct PrototypeCaptionThemeKey: EnvironmentKey {
    static let defaultValue = PrototypeCaptionTheme(PrototypeTheme(dark: false))
}

extension EnvironmentValues {
    var theme: PrototypeCaptionTheme {
        get { self[PrototypeCaptionThemeKey.self] }
        set { self[PrototypeCaptionThemeKey.self] = newValue }
    }
}

extension Font {
    static func fluidSystem(size: CGFloat, weight: Font.Weight = .regular, design: Font.Design = .default) -> Font {
        let configured = PrototypeBrand.shared.style.bodyFontDesign
        let resolved: Font.Design = design == .monospaced || design == .rounded ? design
            : configured == "serif" ? .serif : configured == "rounded" ? .rounded : .default
        return .system(size: size, weight: weight, design: resolved)
    }
}

/// In-room replay has one microphone source. The unused application-audio branch still needs
/// the source renderer's palette symbol; it resolves through this host's portable brand.
enum MeetingSpeakerPalette {
    static func tint(forSpeakerIndex: Int) -> Color { PrototypeTheme(dark: false).accent }
}
