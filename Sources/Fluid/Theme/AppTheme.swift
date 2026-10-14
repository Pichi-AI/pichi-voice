import SwiftUI
#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif

/// Shared product accents. Onboarding and feature surfaces use the same source of truth.
enum FluidBrandColors {
    static var blue: Color { Color(hex: AppBrand.profile.accentLight) ?? .purple }
}

/// Central theme definition for the Fluid app. All colors, spacings and materials
/// should be defined here to keep styling consistent and easy to evolve.
struct AppTheme {
    struct Palette {
        let windowBackground: Color
        let contentBackground: Color
        let sidebarBackground: Color
        let cardBackground: Color
        let elevatedCardBackground: Color
        let toolbarBackground: Color
        let cardBorder: Color
        let separator: Color
        let primaryText: Color
        let secondaryText: Color
        let tertiaryText: Color
        let accent: Color
        let warning: Color
        let success: Color
        var accentForegroundOverride: Color? = nil
        var accentForeground: Color {
            if let accentForegroundOverride { return accentForegroundOverride }
            return Self.contrastingInk(on: self.accent)
        }

        /// A fill and text drawn on a neutral surface have different contrast needs.
        /// Saved accents and legacy profiles may predate package contrast validation.
        var accentText: Color {
            self.readableText(self.accent, minimumContrast: 4.5)
        }

        private var backgrounds: [Color] {
            [windowBackground, contentBackground, sidebarBackground,
             cardBackground, elevatedCardBackground, toolbarBackground]
        }

        func readableText(_ proposed: Color, minimumContrast: Double = 3) -> Color {
            return self.backgrounds.allSatisfy { Self.contrast(proposed, $0) >= minimumContrast }
                ? proposed : self.primaryText
        }

        /// Native controls paint their own ink and material. A portable palette
        /// can use light surfaces in its dark variant, or the reverse; select
        /// native ink against those surfaces without changing the brand variant.
        func nativeColorScheme(fallback: ColorScheme) -> ColorScheme {
            var result = fallback
            let resolve = {
                let lightContrast = self.backgrounds.map { Self.contrast(.black, $0) }.min() ?? 0
                let darkContrast = self.backgrounds.map { Self.contrast(.white, $0) }.min() ?? 0
                if lightContrast != darkContrast { result = lightContrast > darkContrast ? .light : .dark }
            }
            #if canImport(AppKit)
            NSAppearance(named: fallback == .dark ? .darkAqua : .aqua)?.performAsCurrentDrawingAppearance(resolve)
            #else
            UITraitCollection(userInterfaceStyle: fallback == .dark ? .dark : .light).performAsCurrent(resolve)
            #endif
            return result
        }

        func foreground(on fill: Color) -> Color {
            fill == self.accent ? self.accentForeground : Self.contrastingInk(on: fill)
        }

        static func contrastingInk(on fill: Color) -> Color {
            Self.luminance(fill) > 0.179 ? .black : .white
        }

        private static func luminance(_ color: Color, over background: Color? = nil) -> Double {
            guard let rgb = NSColor(color).usingColorSpace(.sRGB) else { return 0 }
            let surface = background.flatMap { NSColor($0).usingColorSpace(.sRGB) }
            let alpha = surface == nil ? 1 : rgb.alphaComponent
            func channel(_ value: CGFloat) -> Double {
                value <= 0.04045 ? Double(value / 12.92) : pow(Double((value + 0.055) / 1.055), 2.4)
            }
            return channel(rgb.redComponent * alpha + (surface?.redComponent ?? 0) * (1 - alpha)) * 0.2126
                + channel(rgb.greenComponent * alpha + (surface?.greenComponent ?? 0) * (1 - alpha)) * 0.7152
                + channel(rgb.blueComponent * alpha + (surface?.blueComponent ?? 0) * (1 - alpha)) * 0.0722
        }

        private static func contrast(_ first: Color, _ second: Color) -> Double {
            let a = Self.luminance(first, over: second), b = Self.luminance(second)
            return (max(a, b) + 0.05) / (min(a, b) + 0.05)
        }
    }

    struct Typography {
        let displayTitle: Font
        let statement: Font
        let title: Font
        let titleIcon: Font
        let sectionTitle: Font
        let body: Font
        let bodyStrong: Font
        let bodySmall: Font
        let bodySmallStrong: Font
        let caption: Font
        let captionStrong: Font
        let captionSmall: Font
        let tiny: Font
        let tinyStrong: Font
        let badge: Font
        let metricTiny: Font
        let codeCaption: Font
        let sidebarItem: Font
        let sidebarSection: Font
        let chromeCaption: Font
        var inheritedFont: Font? = nil
        var brandStyle: BrandStyle? = nil
        var nativeBodyFont: NSFont { .fluidSystemFont(ofSize: 14, style: self.brandStyle) }
        var nativeBodySmallFont: NSFont { .fluidSystemFont(ofSize: 13, style: self.brandStyle) }

        static var standard: Typography { self.standard(style: AppBrand.package.style) }

        static func standard(style: BrandStyle?) -> Typography {
            Typography(
                displayTitle: .fluidSystem(size: 42, weight: .semibold, role: .title, style: style),
                statement: .fluidSystem(size: 17, weight: .regular, style: style),
                title: .fluidSystem(size: 22, weight: .bold, role: .title, style: style),
                titleIcon: .fluidSystem(size: 22, weight: .regular, style: style),
                sectionTitle: .fluidSystem(size: 15, weight: .semibold, role: .title, style: style),
                body: .fluidSystem(size: 14, weight: .regular, style: style),
                bodyStrong: .fluidSystem(size: 14, weight: .medium, style: style),
                bodySmall: .fluidSystem(size: 13, weight: .regular, style: style),
                bodySmallStrong: .fluidSystem(size: 13, weight: .medium, style: style),
                caption: .fluidSystem(size: 12, weight: .regular, style: style),
                captionStrong: .fluidSystem(size: 12, weight: .medium, style: style),
                captionSmall: .fluidSystem(size: 11, weight: .regular, style: style),
                tiny: .fluidSystem(size: 11, weight: .regular, style: style),
                tinyStrong: .fluidSystem(size: 11, weight: .bold, style: style),
                badge: .fluidSystem(size: 11, weight: .semibold, style: style),
                metricTiny: .fluidSystem(size: 11, weight: .bold, design: .rounded, style: style),
                codeCaption: .fluidSystem(size: 12, weight: .medium, design: .monospaced, style: style),
                sidebarItem: .fluidSystem(size: 14, weight: .regular, style: style),
                sidebarSection: .fluidSystem(size: 12, weight: .medium, style: style),
                chromeCaption: .fluidSystem(size: 12, weight: .regular, style: style),
                inheritedFont: FluidTypography.overridesStandard(style: style) ? .fluidSystem(.body, style: style) : nil,
                brandStyle: style
            )
        }
    }

    struct Metrics {
        struct Spacing {
            let xs: CGFloat
            let sm: CGFloat
            let md: CGFloat
            let lg: CGFloat
            let xl: CGFloat
            let xxl: CGFloat

            static let standard = Spacing(
                xs: 4,
                sm: 8,
                md: 12,
                lg: 16,
                xl: 20,
                xxl: 28
            )
        }

        struct CornerRadius {
            let sm: CGFloat
            let md: CGFloat
            let lg: CGFloat
            let pill: CGFloat

            static let standard = CornerRadius(
                sm: 6,
                md: 10,
                lg: 16,
                pill: 999
            )
        }

        struct Shadow {
            let color: Color
            let radius: CGFloat
            let x: CGFloat
            let y: CGFloat
            let opacity: Double

            static func subtle(color: Color, opacity: Double = 0.45) -> Shadow {
                // Wide and low: reads as ambient depth rather than a hard drop.
                Shadow(color: color, radius: 18, x: 0, y: 4, opacity: opacity)
            }
        }

        struct FormRow {
            let horizontalPadding: CGFloat
            let verticalPadding: CGFloat
            let cornerRadius: CGFloat
            let materialOpacity: Double
            let borderOpacity: Double

            static let standard = FormRow(
                horizontalPadding: 12,
                verticalPadding: 10,
                cornerRadius: 8,
                materialOpacity: 0.5,
                borderOpacity: 0.8
            )
        }

        struct PickerControl {
            let horizontalPadding: CGFloat
            let verticalPadding: CGFloat
            let cornerRadius: CGFloat
            let borderOpacity: Double
            let searchBorderOpacity: Double
            let disclosureSize: CGFloat
            let disclosureBorderOpacity: Double
            let selectedRowOpacity: Double

            static let standard = PickerControl(
                horizontalPadding: 8,
                verticalPadding: 5,
                cornerRadius: 6,
                borderOpacity: 0.35,
                searchBorderOpacity: 0.3,
                disclosureSize: 20,
                disclosureBorderOpacity: 0.4,
                selectedRowOpacity: 0.15
            )
        }

        struct CardSurface {
            struct Variant {
                let borderOpacity: Double
                let hoverBorderOpacity: Double
                let borderWidth: CGFloat
                let hoverShadowBoost: Double
            }

            let defaultPadding: CGFloat
            let standard: Variant
            let prominent: Variant
            let subtle: Variant

            static let defaults = CardSurface(
                defaultPadding: 14,
                standard: Variant(
                    borderOpacity: 0.28,
                    hoverBorderOpacity: 0.5,
                    borderWidth: 1,
                    hoverShadowBoost: 0.12
                ),
                prominent: Variant(
                    borderOpacity: 0.25,
                    hoverBorderOpacity: 0.55,
                    borderWidth: 1.2,
                    hoverShadowBoost: 0.15
                ),
                subtle: Variant(
                    borderOpacity: 0.18,
                    hoverBorderOpacity: 0.32,
                    borderWidth: 0.8,
                    hoverShadowBoost: 0.08
                )
            )
        }

        struct OnboardingSurface {
            struct Landing {
                let contentWidth: CGFloat
                let heroPadding: CGFloat
                let heroIconSize: CGFloat
                let heroIconFrame: CGFloat
                let tileSpacing: CGFloat
                let sectionSpacing: CGFloat
                let heroCornerRadius: CGFloat
            }

            let normalFillOpacity: Double
            let selectedFillOpacity: Double
            let normalBorderOpacity: Double
            let selectedBorderOpacity: Double
            let editorBorderOpacity: Double
            let editorPadding: CGFloat
            let optionPadding: CGFloat
            let compactOptionPadding: CGFloat
            let optionCornerRadius: CGFloat
            let compactOptionCornerRadius: CGFloat
            let editorCornerRadius: CGFloat
            let landing: Landing

            static let standard = OnboardingSurface(
                normalFillOpacity: 0.55,
                selectedFillOpacity: 0.82,
                normalBorderOpacity: 0.32,
                selectedBorderOpacity: 0.45,
                editorBorderOpacity: 0.6,
                editorPadding: 10,
                optionPadding: 12,
                compactOptionPadding: 10,
                optionCornerRadius: 12,
                compactOptionCornerRadius: 10,
                editorCornerRadius: 8,
                landing: Landing(
                    contentWidth: 820,
                    heroPadding: 28,
                    heroIconSize: 48,
                    heroIconFrame: 68,
                    tileSpacing: 12,
                    sectionSpacing: 16,
                    heroCornerRadius: 18
                )
            )
        }

        struct Window {
            let mainMinWidth: CGFloat
            let mainMinHeight: CGFloat
            let onboardingMinWidth: CGFloat
            let onboardingMinHeight: CGFloat

            static let standard = Window(
                mainMinWidth: 800,
                mainMinHeight: 500,
                onboardingMinWidth: 940,
                onboardingMinHeight: 700
            )
        }

        let spacing: Spacing
        let corners: CornerRadius
        let formRow: FormRow
        let pickerControl: PickerControl
        let cardSurface: CardSurface
        let onboardingSurface: OnboardingSurface
        let window: Window
        let cardShadow: Shadow
        let elevatedCardShadow: Shadow
    }

    struct Materials {
        let window: Material
        let sidebar: Material
        let card: Material
        let elevatedCard: Material
        let formRow: Material
        let toolbar: Material
    }

    let palette: Palette
    let typography: Typography
    let metrics: Metrics
    let materials: Materials
    /// Retained across AppKit rehosting and export rendering so native control
    /// appearance cannot switch the selected portable palette or logo variant.
    var variant: ColorScheme? = nil

    static func adaptive(accent: Color, colorScheme: ColorScheme, package: BrandPackage = AppBrand.package) -> AppTheme {
        let base = colorScheme == .light ? Self.light(accent: accent) : Self.dark(accent: accent)
        let palette = colorScheme == .light ? package.theme?.light : package.theme?.dark
        var theme = base.applying(palette: palette, style: package.style, brandAccent: colorScheme == .light ? package.profile.accentLight : package.profile.accentDark)
        theme.variant = colorScheme
        return theme
    }

    private func applying(palette branded: BrandPalette?, style: BrandStyle?, brandAccent: String) -> AppTheme {
        func color(_ key: String, _ fallback: Color) -> Color {
            branded?.colors[key].flatMap(Color.init(hex:)) ?? fallback
        }
        let palette = Palette(
            windowBackground: color("windowBackground", self.palette.windowBackground),
            contentBackground: color("contentBackground", self.palette.contentBackground),
            sidebarBackground: color("sidebarBackground", self.palette.sidebarBackground),
            cardBackground: color("cardBackground", self.palette.cardBackground),
            elevatedCardBackground: color("elevatedCardBackground", self.palette.elevatedCardBackground),
            toolbarBackground: color("toolbarBackground", self.palette.toolbarBackground),
            cardBorder: color("cardBorder", self.palette.cardBorder),
            separator: color("separator", self.palette.separator),
            primaryText: color("primaryText", self.palette.primaryText),
            secondaryText: color("secondaryText", self.palette.secondaryText),
            tertiaryText: color("tertiaryText", self.palette.secondaryText),
            accent: self.palette.accent,
            warning: color("warning", self.palette.warning),
            success: color("success", self.palette.success),
            accentForegroundOverride: self.palette.accent == Color(hex: brandAccent)
                ? branded?.colors["accentForeground"].flatMap(Color.init(hex:)) : nil
        )
        let scale = CGFloat(style?.spacingScale ?? 1)
        let radius = CGFloat(style?.cornerRadiusScale ?? 1)
        let metrics = Metrics(
            spacing: Metrics.Spacing(xs: self.metrics.spacing.xs * scale, sm: self.metrics.spacing.sm * scale,
                md: self.metrics.spacing.md * scale, lg: self.metrics.spacing.lg * scale,
                xl: self.metrics.spacing.xl * scale, xxl: self.metrics.spacing.xxl * scale),
            corners: Metrics.CornerRadius(sm: self.metrics.corners.sm * radius, md: self.metrics.corners.md * radius,
                lg: self.metrics.corners.lg * radius, pill: self.metrics.corners.pill),
            formRow: self.metrics.formRow, pickerControl: self.metrics.pickerControl,
            cardSurface: self.metrics.cardSurface, onboardingSurface: self.metrics.onboardingSurface,
            window: self.metrics.window, cardShadow: self.metrics.cardShadow, elevatedCardShadow: self.metrics.elevatedCardShadow
        )
        return AppTheme(palette: palette, typography: .standard(style: style), metrics: metrics, materials: self.materials)
    }

    /// Light theme using system colors so macOS accessibility contrast settings stay in control.
    static func light(accent: Color) -> AppTheme {
        AppTheme(
            palette: Palette(
                windowBackground: Color(nsColor: .windowBackgroundColor),
                contentBackground: Color(nsColor: .controlBackgroundColor),
                sidebarBackground: Color(nsColor: .windowBackgroundColor),
                cardBackground: Color(nsColor: .controlBackgroundColor),
                elevatedCardBackground: Color(nsColor: .windowBackgroundColor),
                toolbarBackground: Color(nsColor: .windowBackgroundColor),

                cardBorder: Color.black.opacity(0.12),
                separator: Color(nsColor: .separatorColor),
                primaryText: Color(nsColor: .labelColor),
                secondaryText: Color(nsColor: .secondaryLabelColor),
                tertiaryText: Color(nsColor: .tertiaryLabelColor),
                accent: accent,
                warning: Color(nsColor: .systemOrange),
                success: Color(nsColor: .systemGreen)
            ),
            typography: .standard,
            metrics: Metrics(
                spacing: .standard,
                corners: .standard,
                formRow: .standard,
                pickerControl: .standard,
                cardSurface: .defaults,
                onboardingSurface: .standard,
                window: .standard,
                cardShadow: .subtle(color: .black, opacity: 0.12),
                elevatedCardShadow: .subtle(color: .black, opacity: 0.16)
            ),
            materials: Materials(
                window: .thinMaterial,
                sidebar: .ultraThinMaterial,
                card: .thinMaterial,
                elevatedCard: .regularMaterial,
                formRow: .ultraThinMaterial,
                toolbar: .ultraThinMaterial
            )
        )
    }

    /// Default dark-forward theme tuned for macOS Sonoma / Sequoia aesthetics.
    static func dark(accent: Color) -> AppTheme {
        AppTheme(
            palette: Palette(
                windowBackground: Color(red: 0.055, green: 0.047, blue: 0.039),
                contentBackground: Color(red: 0.102, green: 0.090, blue: 0.082),
                sidebarBackground: Color(red: 0.055, green: 0.047, blue: 0.039),
                cardBackground: Color(red: 0.118, green: 0.102, blue: 0.090),
                elevatedCardBackground: Color(red: 0.180, green: 0.157, blue: 0.141),
                toolbarBackground: Color(red: 0.055, green: 0.047, blue: 0.039),

                cardBorder: Color.white.opacity(0.10),
                separator: Color.white.opacity(0.16),
                primaryText: Color(nsColor: .labelColor),
                secondaryText: Color(nsColor: .secondaryLabelColor),
                tertiaryText: Color(nsColor: .tertiaryLabelColor),
                accent: accent,
                warning: Color(nsColor: .systemOrange),
                success: Color(nsColor: .systemGreen)
            ),
            typography: .standard,
            metrics: Metrics(
                spacing: .standard,
                corners: .standard,
                formRow: .standard,
                pickerControl: .standard,
                cardSurface: .defaults,
                onboardingSurface: .standard,
                window: .standard,
                cardShadow: .subtle(color: .black, opacity: 0.45),
                elevatedCardShadow: .subtle(color: .black, opacity: 0.55)
            ),
            materials: Materials(
                window: .thinMaterial,
                sidebar: .ultraThinMaterial,
                card: .thinMaterial,
                elevatedCard: .regularMaterial,
                formRow: .ultraThinMaterial,
                toolbar: .ultraThinMaterial
            )
        )
    }

    static let light = AppTheme.light(accent: .fluidGreen)
    static let dark = AppTheme.dark(accent: .fluidGreen)
}

// MARK: - Helpers
