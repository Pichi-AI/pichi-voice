import AppKit
import SwiftUI

// Inert dependencies for the real theme environment. No application singleton,
// Keychain, persistent settings, microphone or visible window is initialized.
final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    enum AccentColorOption { case brand }
    struct ThemePreference { let preferredColorScheme: ColorScheme? = nil }
    let themePreference = ThemePreference()
    let accentColorOption = AccentColorOption.brand
    let accentColor = Color.purple
}

// The appearance observer is real; this icon dependency never touches an app
// bundle, installed brand state or application icon in nonactivating tests.
@MainActor enum PichiBrandMark {
    static var appIcon: NSImage { NSImage(size: NSSize(width: 16, height: 16)) }
}

@main
struct UIContrastTests {
    // A renderer's inherited ink is applied around its configuration label, as
    // native prominent glass does. This probe isolates label-scope precedence;
    // it does not substitute for or claim native glass rasterization.
    private struct InheritedWhiteInkRenderer: ButtonStyle {
        func makeBody(configuration: Configuration) -> some View {
            configuration.label.foregroundStyle(.white)
        }
    }
    @MainActor
    private final class ConstructionObservations {
        var roles = [ButtonRole?]()
        var enabled = [Bool]()
        var trigger: (() -> Void)?
        var activations = 0
    }
    private struct ConstructionInspectionStyle: PrimitiveButtonStyle {
        let observations: ConstructionObservations
        @Environment(\.isEnabled) private var isEnabled
        func makeBody(configuration: Configuration) -> some View {
            self.observations.roles.append(configuration.role)
            self.observations.enabled.append(self.isEnabled)
            self.observations.trigger = configuration.trigger
            // Materialize the style body. A transparent configuration.label
            // identity is elided by the nonactivating image renderer.
            return configuration.label.padding(4).background(.yellow)
        }
    }

    @MainActor
    static func verifyConstruction() {
        if #available(macOS 26, *) {
            for role: ButtonRole? in [nil, .cancel, .destructive] {
                for enabled in [false, true] {
                    let observations = ConstructionObservations()
                    let button = FluidGlassProminentActionStyle.pairedLabelButton(role: role, foreground: .black, action: { observations.activations += 1 }) {
                        Label("Native construction", systemImage: "xmark")
                    }
                    .buttonStyle(ConstructionInspectionStyle(observations: observations))
                    .disabled(!enabled)
                    let renderer = ImageRenderer(content: button.padding(12).background(.white).appTheme(.light))
                    precondition(renderer.cgImage != nil, "Construction renderer must produce an image")
                    precondition(!observations.roles.isEmpty && observations.roles.allSatisfy { $0 == role }, "Production Button preserves native role")
                    precondition(!observations.enabled.isEmpty && observations.enabled.allSatisfy { $0 == enabled }, "Production Button preserves enabled environment")
                    precondition(observations.activations == 0, "Constructing/rendering a native Button never invokes its action")
                    if enabled {
                        // Configuration.trigger forwards the actual Button action.
                        // It intentionally bypasses input handling, so disabled
                        // physical/AX presses remain the parent's native E2E check.
                        precondition(observations.trigger != nil)
                        observations.trigger?()
                        precondition(observations.activations == 1, "Native trigger forwards the supplied action exactly once")
                    }
                }
            }
            print("Actual native Button construction: 6 role/enabled checks and 3 enabled trigger-forwarding checks passed")
        }
    }
    // Render the source-bound production foreground decision and real Button
    // label constructor on reference fills. Native glass itself remains skipped.
    @MainActor
    static func verifyProminentAppearance(theme: AppTheme, scheme: ColorScheme, suffix: String,
                                         directory: URL) throws -> Int {
        guard #available(macOS 26, *) else { return 0 }
        let nativeScheme = theme.palette.nativeColorScheme(fallback: scheme)
        let appearance = NSAppearance(named: nativeScheme == .dark ? .darkAqua : .aqua)!
        var failure: Error?
        var checks = 0
        appearance.performAsCurrentDrawingAppearance {
            do {
                for active in [true, false] {
                    for (toneName, tone): (String, Color?) in [("accent", nil), ("red", .red)] {
                        let fill = active ? (tone ?? theme.palette.accent) : (nativeScheme == .dark ? Color.black : Color.white)
                        // System label ink is translucent. Compare its actual composite
                        // on the neutral reference fill, not opaque brand text tokens.
                        let nativeInk = NSColor.labelColor.usingColorSpace(.sRGB)!
                        let neutral = self.components(fill)
                        let alpha = Double(nativeInk.alphaComponent)
                        let nativeComposite = Color(.sRGB,
                            red: Double(nativeInk.redComponent) * alpha + neutral[0] * (1 - alpha),
                            green: Double(nativeInk.greenComponent) * alpha + neutral[1] * (1 - alpha),
                            blue: Double(nativeInk.blueComponent) * alpha + neutral[2] * (1 - alpha))
                        let ink = active ? theme.palette.foreground(on: tone ?? theme.palette.accent) : nativeComposite
                        let button = ProminentGlassLabelFixture(tone: tone)
                            .environment(\.appearsActive, active)
                            .buttonStyle(InheritedWhiteInkRenderer())
                            .padding(14)
                            .background(fill)
                        try self.verify(button, name: "prominent-appearance-\(active ? "active" : "inactive")-\(toneName)-\(suffix)",
                            theme: theme, scheme: scheme, textBackground: self.components(fill), directory: directory,
                            expectedForeground: ink, labelOnly: true)
                        checks += 1
                    }
                }
            } catch { failure = error }
        }
        if let failure { throw failure }
        return checks
    }

    static func components(_ color: Color) -> [Double] {
        let rgb = NSColor(color).usingColorSpace(.sRGB)!
        return [Double(rgb.redComponent), Double(rgb.greenComponent), Double(rgb.blueComponent)]
    }

    static func luminance(_ components: [Double]) -> Double {
        let channels = components.map { $0 <= 0.04045 ? $0 / 12.92 : pow(($0 + 0.055) / 1.055, 2.4) }
        return channels[0] * 0.2126 + channels[1] * 0.7152 + channels[2] * 0.0722
    }

    static func contrast(_ first: [Double], _ second: [Double]) -> Double {
        let values = [self.luminance(first), self.luminance(second)]
        return (values.max()! + 0.05) / (values.min()! + 0.05)
    }

    @MainActor
    static func verify(_ view: some View, name: String, theme: AppTheme, scheme: ColorScheme,
                       textBackground: [Double], directory: URL, expectedForeground: Color? = nil,
                       labelOnly: Bool = false, requiredContrast: Double? = 4.5, expectedSurface: Color? = nil) throws {
        let expected = self.components(expectedForeground ?? theme.palette.primaryText)
        if let requiredContrast {
            precondition(self.contrast(expected, textBackground) >= requiredContrast, "\(name): label contrast must meet \(requiredContrast):1")
        }
        let renderer = ImageRenderer(content: view
            .padding(12)
            .background(theme.palette.cardBackground)
            .appTheme(theme)
            .tint(theme.palette.accent)
            .environment(\.colorScheme, scheme))
        renderer.scale = 2
        let image = renderer.cgImage!
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent("\(name).png"))
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        if let expectedSurface {
            let surface = self.components(expectedSurface)
            // This fixture has a 160x44-point row and 12 points of outer padding.
            // Sample its interior left corner, away from centered glyph and border.
            let index = (32 * image.width + 32) * 4
            precondition(pixels[index + 3] == 255)
            for channel in 0..<3 {
                precondition(abs(Double(pixels[index + channel]) / 255 - surface[channel]) < 0.025,
                             "\(name): production row must pair its glyph with the expected opaque surface")
            }
        }
        var matching = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
            if labelOnly {
                let x = (index / 4) % image.width
                let y = (index / 4) / image.width
                // Text only: exclude the symbol, surrounding card and surface outline.
                guard x >= Int(Double(image.width) * 0.4), x < image.width - 24,
                      y >= Int(Double(image.height) * 0.3), y < Int(Double(image.height) * 0.7) else { continue }
            }
            var matches = pixels[index + 3] == 255
            for channel in 0..<3 {
                matches = matches && abs(Double(pixels[index + channel]) / 255 - expected[channel]) < 0.025
            }
            if matches { matching += 1 }
        }
        // This assertion observes actual production label pixels. Reverting either
        // label to its decorative accent/red fails even when the palette stays valid.
        precondition(matching >= 12, "\(name): production label must render the accessible theme foreground")
        print("\(name): \(String(format: "%.2f", self.contrast(expected, textBackground))):1, \(matching) foreground pixels")
    }

    @MainActor
    static func main() async throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        if CommandLine.arguments.contains("--segmented-only") {
            try await FluidSegmentedPickerTests.run(directory: directory)
            return
        }
        if CommandLine.arguments.contains("--native-appearance-only") {
            try await NativePaletteAppearanceTests.run(directory: directory)
            return
        }
        if CommandLine.arguments.contains("--native-sidebar-only") {
            try await NativeSidebarContrastTests.run(directory: directory)
            return
        }
        if CommandLine.arguments.contains("--dashboard-shortcuts-only") {
            try await DashboardShortcutSurfaceTests.run(directory: directory)
            return
        }
        let packages = [
            ("pichi", "Sources/Fluid/Branding/brand-package.json"),
            ("sber", "Configuration/BrandExamples/sber-demo.json"),
            ("alfa", "Configuration/BrandExamples/alfa-demo.json"),
        ]
        // The actual saved accent observed in the frozen native app. This is a
        // regression fixture, never a product default or a settings mutation.
        let savedPaleAccent = "#A98CFF"
        var checks = 0
        var actionChecks = 0
        var reviewChecks = 0
        var prominentAppearanceChecks = 0
        for (name, path) in packages {
            let package = try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            for scheme: ColorScheme in [.light, .dark] {
                let appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)!
                var failure: Error?
                appearance.performAsCurrentDrawingAppearance {
                    do {
                        let brandAccent = scheme == .dark ? package.profile.accentDark : package.profile.accentLight
                        // The captured defect used a saved darker accent in dark mode.
                        let variants = name == "pichi" && scheme == .dark
                            ? [("brand", brandAccent), ("saved", package.profile.accentLight)]
                            : [("brand", brandAccent)]
                        for (variant, accentHex) in variants {
                            let accent = Color(hex: accentHex)!
                            let theme = AppTheme.adaptive(accent: accent, colorScheme: scheme, package: package)
                            let suffix = "\(name)-\(scheme == .dark ? "dark" : "light")-\(variant)"
                            let background = self.components(theme.palette.cardBackground)
                            let accentRGB = self.components(theme.palette.accent)
                            let badgeBackground = zip(accentRGB, background).map { $0 * 0.25 + $1 * 0.75 }
                            try self.verify(DeleteRoleFixture(), name: "delete-\(suffix)", theme: theme, scheme: scheme,
                                textBackground: self.components(theme.palette.elevatedCardBackground), directory: directory)
                            try self.verify(ActiveBadgeFixture(), name: "active-\(suffix)", theme: theme, scheme: scheme,
                                textBackground: badgeBackground, directory: directory)
                            try self.verify(LiquidBar(fillPercent: 0.9, color: accent, secondaryColor: .cyan, icon: "target", label: "Accuracy"),
                                name: "accuracy-\(suffix)", theme: theme, scheme: scheme, textBackground: background, directory: directory)
                            checks += 3
                        }
                        for (variant, accentHex) in [("brand", brandAccent), ("saved-pale", savedPaleAccent)] {
                            let theme = AppTheme.adaptive(accent: Color(hex: accentHex)!, colorScheme: scheme, package: package)
                            let suffix = "\(name)-\(scheme == .dark ? "dark" : "light")-\(variant)"
                            let foreground = theme.palette.accentForeground
                            prominentAppearanceChecks += try self.verifyProminentAppearance(theme: theme, scheme: scheme, suffix: suffix, directory: directory)
                            let accentRGB = self.components(theme.palette.accent)
                            // Actual accessibility fallback controls use the same paired
                            // foreground as active native glass. Label pixels are rendered from
                            // fail-closed source excerpts, not copied surrogate labels.
                            try self.verify(ChooseFileActionFixture(),
                                name: "fallback-choose-\(suffix)", theme: theme, scheme: scheme, textBackground: accentRGB,
                                directory: directory, expectedForeground: foreground, labelOnly: true)
                            try self.verify(CopyTranscriptActionFixture(),
                                name: "fallback-copy-\(suffix)", theme: theme, scheme: scheme, textBackground: accentRGB,
                                directory: directory, expectedForeground: foreground, labelOnly: true)
                            try self.verify(ExploreReleaseActionFixture(),
                                name: "fallback-explore-\(suffix)", theme: theme, scheme: scheme, textBackground: accentRGB,
                                directory: directory, expectedForeground: foreground, labelOnly: true)
                            try self.verify(CopyToastFixture(), name: "toast-\(suffix)", theme: theme, scheme: scheme,
                                textBackground: accentRGB, directory: directory, expectedForeground: foreground, labelOnly: true)
                            for (roleName, control) in [
                                ("microphone", AnyView(MicrophonePermissionFixture())),
                                ("accessibility", AnyView(AccessibilityPermissionFixture())),
                                ("backup", AnyView(BackupPrimaryActionFixture())),
                                ("updates", AnyView(UpdatePrimaryActionFixture())),
                            ] {
                                let disabled = roleName == "updates" && !AppBrand.updatesEnabled
                                try self.verify(control, name: "settings-\(roleName)-\(suffix)", theme: theme, scheme: scheme,
                                    textBackground: disabled ? self.components(theme.palette.elevatedCardBackground) : accentRGB,
                                    directory: directory, expectedForeground: disabled ? theme.palette.secondaryText : foreground,
                                    labelOnly: true, requiredContrast: disabled ? 3 : 4.5)
                            }
                            actionChecks += 4
                            if #available(macOS 26, *) {
                                // Exercise the real production Button constructor, not
                                // the fallback style. An inherited white foreground
                                // models the native renderer default that caused the
                                // bug. Explicit ink INSIDE the label must win.
                                let button = FluidGlassProminentActionStyle.pairedLabelButton(role: nil, foreground: foreground, action: {}) {
                                    Label("Production label", systemImage: "plus")
                                }
                                .buttonStyle(InheritedWhiteInkRenderer())
                                .padding(14)
                                .background(theme.palette.accent)
                                try self.verify(button, name: "native-label-boundary-\(suffix)", theme: theme, scheme: scheme,
                                    textBackground: accentRGB, directory: directory, expectedForeground: foreground, labelOnly: true)
                                actionChecks += 1
                                let secondary = SecondaryGlassLabelFixture(role: nil, tone: nil)
                                    .buttonStyle(InheritedWhiteInkRenderer())
                                    .padding(14)
                                    .background(theme.palette.elevatedCardBackground)
                                try self.verify(secondary, name: "secondary-label-boundary-\(suffix)", theme: theme, scheme: scheme,
                                    textBackground: self.components(theme.palette.elevatedCardBackground), directory: directory,
                                    expectedForeground: theme.palette.primaryText, labelOnly: true)
                                let destructive = SecondaryGlassLabelFixture(role: .destructive, tone: nil)
                                    .buttonStyle(InheritedWhiteInkRenderer()).padding(14)
                                    .background(theme.palette.elevatedCardBackground)
                                try self.verify(destructive, name: "secondary-destructive-label-\(suffix)", theme: theme, scheme: scheme,
                                    textBackground: self.components(theme.palette.elevatedCardBackground), directory: directory,
                                    expectedForeground: theme.palette.primaryText, labelOnly: true)
                                let tone = SecondaryGlassLabelFixture(role: .destructive, tone: .red)
                                    .buttonStyle(InheritedWhiteInkRenderer()).padding(14)
                                    .background(theme.palette.elevatedCardBackground)
                                try self.verify(tone, name: "secondary-tone-\(suffix)", theme: theme, scheme: scheme,
                                    textBackground: self.components(theme.palette.elevatedCardBackground), directory: directory,
                                    expectedForeground: theme.palette.readableText(.red), labelOnly: true, requiredContrast: 3)
                                actionChecks += 3
                            }
                            // Explicit tones must pair ink with their actual fill, including
                            // pale saved accents passed explicitly by the dictionary wizard.
                            for (toneName, tone) in [("explicit-accent", theme.palette.accent), ("white", Color.white),
                                                     ("black", Color.black), ("yellow", Color.yellow), ("red", Color.red)] {
                                let ink = theme.palette.foreground(on: tone)
                                try self.verify(Button("Tone action") {}.buttonStyle(AccentButtonStyle(tone: tone)),
                                    name: "tone-\(toneName)-\(suffix)", theme: theme, scheme: scheme,
                                    textBackground: self.components(tone), directory: directory,
                                    expectedForeground: ink, labelOnly: true)
                                actionChecks += 1
                            }
                            let disabledBackground = self.components(theme.palette.elevatedCardBackground)
                            try self.verify(ProductionCommandGlyphFixture(), name: "disabled-command-glyph-\(suffix)",
                                theme: theme, scheme: scheme, textBackground: disabledBackground, directory: directory,
                                expectedForeground: theme.palette.secondaryText, requiredContrast: 3)
                            reviewChecks += 1
                            try self.verify(Button {} label: {
                                Image(systemName: "pencil").font(.system(size: 20, weight: .bold))
                            }.buttonStyle(FluidHoverIconButtonStyle()).disabled(true),
                                name: "disabled-edit-icon-\(suffix)", theme: theme, scheme: scheme,
                                textBackground: disabledBackground, directory: directory,
                                expectedForeground: theme.palette.secondaryText, requiredContrast: 3)
                            reviewChecks += 1
                            try self.verify(ProductionQuietPressedFixture(), name: "pressed-quiet-\(suffix)",
                                theme: theme, scheme: scheme, textBackground: self.components(theme.palette.cardBackground),
                                directory: directory, expectedForeground: theme.palette.secondaryText, requiredContrast: 3)
                            reviewChecks += 1
                            for (controlName, control) in [
                                ("glass", AnyView(Button("Continue") {}.fluidGlassAction(prominent: true, tone: theme.palette.accent).disabled(true))),
                                ("fallback", AnyView(Button("Continue") {}.buttonStyle(AccentButtonStyle(tone: theme.palette.accent)).disabled(true))),
                                ("outlined", AnyView(Button("Continue") {}.buttonStyle(FluidOutlinedButtonStyle()).disabled(true))),
                            ] {
                                try self.verify(control, name: "disabled-\(controlName)-\(suffix)", theme: theme, scheme: scheme,
                                    textBackground: disabledBackground, directory: directory,
                                    expectedForeground: theme.palette.secondaryText, labelOnly: true, requiredContrast: 3)
                                actionChecks += 1
                            }
                            precondition(theme.palette.readableText(theme.palette.primaryText.opacity(0.05)) == theme.palette.primaryText,
                                         "Transparent label ink must fall back before it disappears on the surface")
                            let paleTheme = AppTheme.adaptive(accent: .white, colorScheme: scheme, package: package)
                            for surface in [paleTheme.palette.windowBackground, paleTheme.palette.contentBackground,
                                            paleTheme.palette.sidebarBackground, paleTheme.palette.cardBackground,
                                            paleTheme.palette.elevatedCardBackground, paleTheme.palette.toolbarBackground] {
                                precondition(self.contrast(self.components(paleTheme.palette.accentText), self.components(surface)) >= 3,
                                             "Legacy/saved pale accent text must be legible on every surface")
                            }
                            try self.verify(Button("Tone role") {}.buttonStyle(AccentButtonStyle(tone: .red)), name: "tone-role-\(suffix)",
                                theme: theme, scheme: scheme, textBackground: self.components(.red), directory: directory,
                                expectedForeground: theme.palette.foreground(on: .red), labelOnly: true)
                            try self.verify(Button("Record role") {}.buttonStyle(FluidRecordInvitationStyle(inviting: false, recording: true)),
                                name: "record-role-\(suffix)", theme: theme, scheme: scheme,
                                textBackground: self.components(.red), directory: directory,
                                expectedForeground: theme.palette.foreground(on: .red), labelOnly: true)
                            actionChecks += 6
                        }
                    } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
        print("Actual delete, active badge and metric foreground: \(checks) native rendering checks passed")
        print("Actual fallback actions, toast and preserved semantic ink: \(actionChecks) rendering checks passed")
        for (name, background, ink, accent) in [("gray-accent", "#FFFFFF", "#000000", "#949494"),
                                                ("opposite-inks", "#606060", "#FFFFFF", "#000000"),
                                                ("gray-secondary", "#FFFFFF", "#000000", "#000000")] {
            let backgrounds: Set<String> = ["windowBackground", "contentBackground", "sidebarBackground",
                                           "cardBackground", "elevatedCardBackground", "toolbarBackground"]
            var colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, backgrounds.contains($0) ? background : ink) })
            if name == "gray-accent" { colors["warning"] = accent }
            if name == "gray-secondary" {
                colors["secondaryText"] = "#949494"
                colors["tertiaryText"] = "#949494"
                colors["accentForeground"] = "#FFFFFF"
            }
            let profile = BrandProfile(appName: "Contrast", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic fixture",
                                       accentLight: accent, accentDark: accent, website: "https://example.invalid", support: "https://example.invalid")
            let palette = BrandPalette(colors: colors)
            let package = try BrandPackage.decode(BrandPackage(profile: profile, theme: BrandTheme(light: palette, dark: palette)).encoded())
            for scheme: ColorScheme in [.light, .dark] {
                let theme = AppTheme.adaptive(accent: Color(hex: accent)!, colorScheme: scheme, package: package)
                let suffix = "\(name)-\(scheme == .dark ? "dark" : "light")"
                prominentAppearanceChecks += try self.verifyProminentAppearance(theme: theme, scheme: scheme, suffix: suffix, directory: directory)
                for (controlName, control) in [("help", AnyView(ProductionHelpActionFixture())),
                                               ("number", AnyView(ProductionHelpNumberFixture())),
                                               ("words", AnyView(ProductionWordMetricFixture()))] {
                    try self.verify(control, name: "review-\(controlName)-\(suffix)", theme: theme, scheme: scheme,
                        textBackground: self.components(theme.palette.cardBackground), directory: directory,
                        expectedForeground: theme.palette.primaryText)
                    reviewChecks += 1
                }
                try self.verify(ProductionAPIKeyWarningFixture(), name: "review-warning-\(suffix)", theme: theme, scheme: scheme,
                    textBackground: self.components(theme.palette.cardBackground), directory: directory,
                    expectedForeground: theme.palette.readableText(theme.palette.warning), requiredContrast: 3)
                try self.verify(FluidIconTile(icon: "gearshape.fill", tint: theme.palette.accent), name: "review-icon-tile-\(suffix)",
                    theme: theme, scheme: scheme, textBackground: self.components(theme.palette.elevatedCardBackground), directory: directory,
                    expectedForeground: theme.palette.readableText(theme.palette.accent), requiredContrast: 3)
                reviewChecks += 2
                try self.verify(Button {} label: {
                    Image(systemName: "pencil").font(.system(size: 20, weight: .bold))
                }.buttonStyle(FluidHoverIconButtonStyle()).disabled(true),
                    name: "review-disabled-edit-icon-\(suffix)", theme: theme, scheme: scheme,
                    textBackground: self.components(theme.palette.elevatedCardBackground), directory: directory,
                    expectedForeground: theme.palette.secondaryText, requiredContrast: 3)
                reviewChecks += 1
                try self.verify(Image(systemName: "checkmark").font(.system(size: 20, weight: .bold))
                    .foregroundStyle(theme.palette.accentText).frame(width: 160, height: 44)
                    .searchablePickerSelectedRowBackground(isSelected: true),
                    name: "review-selected-picker-row-\(suffix)", theme: theme, scheme: scheme,
                    textBackground: self.components(theme.palette.elevatedCardBackground), directory: directory,
                    expectedForeground: theme.palette.accentText, labelOnly: true, requiredContrast: 3,
                    expectedSurface: theme.palette.elevatedCardBackground)
                reviewChecks += 1
                try self.verify(ProductionQuietPressedFixture(), name: "review-pressed-quiet-\(suffix)",
                    theme: theme, scheme: scheme, textBackground: self.components(theme.palette.cardBackground),
                    directory: directory, expectedForeground: theme.palette.secondaryText, requiredContrast: 3)
                reviewChecks += 1
            }
        }
        print("Production disabled command glyph, Help and word metric: \(reviewChecks) review regression rendering checks passed")
        print("Production prominent active/inactive foreground: \(prominentAppearanceChecks) reference-fill rendering checks passed")
        self.verifyConstruction()
        try await FluidSegmentedPickerTests.run(directory: directory)
        try await NativePaletteAppearanceTests.run(directory: directory)
        try await NativeSidebarContrastTests.run(directory: directory)
        try await DashboardShortcutSurfaceTests.run(directory: directory)
        print("SKIP: native glass rasterization is unavailable in this nonactivating standalone renderer; parent frozen-app screenshots provide native glass evidence.")
    }
}
