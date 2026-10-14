import AppKit
import SwiftUI

// Inert settings are process-local. The production appearance observer and
// AdaptiveAppTheme use these values without preferences, models or app services.
@MainActor final class SettingsStore: ObservableObject {
    static let shared = SettingsStore()
    enum AccentColorOption { case brand }
    struct ThemePreference { var preferredColorScheme: ColorScheme? }
    @Published var themePreference = ThemePreference(preferredColorScheme: nil)
    let accentColorOption = AccentColorOption.brand
    var accentColor: Color { Color(hex: AppBrand.profile.accentLight)! }
}
@MainActor enum PichiBrandMark {
    static var appIcon: NSImage { NSImage(size: NSSize(width: 16, height: 16)) }
}

@main struct NativeWindowAppearanceTests {
    nonisolated(unsafe) static var package = BrandPackage(profile: .neutral)
    @MainActor static var logoVariants: [ColorScheme] = []
    @MainActor static var seenThemes: [AppTheme] = []
    @MainActor static var seenSchemes: [ColorScheme] = []

    private static func samePalette(_ first: AppTheme.Palette, _ second: AppTheme.Palette) -> Bool {
        func colors(_ palette: AppTheme.Palette) -> [Color] {
            [palette.windowBackground, palette.contentBackground, palette.sidebarBackground,
             palette.cardBackground, palette.elevatedCardBackground, palette.toolbarBackground,
             palette.cardBorder, palette.separator, palette.primaryText, palette.secondaryText,
             palette.tertiaryText, palette.accent, palette.warning, palette.success, palette.accentForeground]
        }
        return colors(first) == colors(second) && first.accentForegroundOverride == second.accentForegroundOverride
    }

    private struct Probe: View {
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            NativeWindowAppearanceTests.seenThemes.append(self.theme)
            NativeWindowAppearanceTests.seenSchemes.append(self.scheme)
            return VStack {
                Text("Native window Ёё")
                LogoVariantProbe()
            }
            .padding(20)
            .frame(width: 360, height: 150)
            .background(self.theme.palette.cardBackground)
        }
    }

    @MainActor private static func settle(_ host: NSView, context: (() -> String)? = nil, until predicate: () -> Bool) async {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Actual owned window appearance did not converge: \(context?() ?? "unspecified")")
    }

    @MainActor static func main() async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let observer = BrandAppearanceController.ApplicationAppearance.shared
        let fields = Set(["windowBackground", "contentBackground", "sidebarBackground",
                          "cardBackground", "elevatedCardBackground", "toolbarBackground"])
        func palette(surface: String, ink: String, accentForeground: String) -> BrandPalette {
            var values = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map {
                ($0, fields.contains($0) ? surface : ink)
            })
            values["accentForeground"] = accentForeground
            return BrandPalette(colors: values)
        }
        let white = palette(surface: "#FFFFFF", ink: "#000000", accentForeground: "#000000")
        let dark = palette(surface: "#606060", ink: "#FFFFFF", accentForeground: "#FFFFFF")
        let grayProfile = BrandProfile(appName: "Synthetic", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic",
            accentLight: "#949494", accentDark: "#949494", website: "https://example.invalid", support: "https://example.invalid")
        let inverseProfile = BrandProfile(appName: "Synthetic inverse", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic",
            accentLight: "#000000", accentDark: "#949494", website: "https://example.invalid", support: "https://example.invalid")
        let stock = try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: "Sources/Fluid/Branding/brand-package.json")))
        let gray = try BrandPackage.decode(BrandPackage(profile: grayProfile, theme: BrandTheme(light: white, dark: white)).encoded())
        let inverse = try BrandPackage.decode(BrandPackage(profile: inverseProfile, theme: BrandTheme(light: dark, dark: white)).encoded())
        var checks = 0
        for (name, fixture) in [("stock", stock), ("gray", gray), ("inverse", inverse)] {
            self.package = fixture
            self.seenThemes.removeAll(); self.seenSchemes.removeAll(); self.logoVariants.removeAll()
            let controller = NSHostingController(rootView: AdaptiveAppTheme(accent: .purple) { Probe() })
            // Same native host/window boundary used to recreate a closed main window.
            let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                                  styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.title = "Native fixture Ёё"
            window.toolbarStyle = .unified
            window.contentViewController = controller
            defer { window.close() }
            for preferred: ColorScheme? in [nil, .light, .dark] {
                SettingsStore.shared.themePreference = .init(preferredColorScheme: preferred)
                for application: ColorScheme in [.light, .dark, .light, .dark] {
                    NSApp.appearance = NSAppearance(named: application == .dark ? .darkAqua : .aqua)
                    let logical = preferred ?? application
                    let accent = Color(hex: logical == .dark ? fixture.profile.accentDark : fixture.profile.accentLight)!
                    let expected = AppTheme.adaptive(accent: accent, colorScheme: logical, package: fixture)
                    let physical = expected.palette.nativeColorScheme(fallback: logical)
                    let nativeName: NSAppearance.Name = physical == .dark ? .darkAqua : .aqua
                    await self.settle(controller.view, context: {
                        "\(name) pref \(String(describing: preferred)) application \(application) logical \(logical) physical \(physical); observer \(observer.colorScheme), actualApp \(NSApp.effectiveAppearance.name), actualWindow \(window.effectiveAppearance.name), variant \(String(describing: self.seenThemes.last?.variant)), subtree \(String(describing: self.seenSchemes.last)), logo \(String(describing: self.logoVariants.last))"
                    }) {
                        observer.colorScheme == application && self.seenThemes.last?.variant == logical
                            && self.seenSchemes.last == physical && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == nativeName
                            && self.logoVariants.last == logical
                    }
                    if physical != application {
                        precondition(window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == nativeName)
                    }
                    precondition(NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (application == .dark ? .darkAqua : .aqua), "Window appearance must not change the logical application source")
                    precondition(self.seenThemes.last.map { self.samePalette($0.palette, expected.palette) } == true)
                    precondition(window.contentView?.superview?.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == nativeName,
                        "The native window frame must use the physical presentation appearance")
                    for button: NSWindow.ButtonType in [.closeButton, .miniaturizeButton, .zoomButton] {
                        let chrome = window.standardWindowButton(button)
                        // Native traffic lights use their own vibrant appearance,
                        // independently of Aqua/DarkAqua. Retain their owned native
                        // controls; visible glyph contrast is a parent screenshot check.
                        precondition(chrome?.window === window && chrome?.isHidden == false)
                    }
                    // Physical appearance must settle rather than selecting the opposite
                    // brand variant on the next update, particularly in System mode.
                    for _ in 0..<6 {
                        try? await Task.sleep(nanoseconds: 10_000_000)
                        controller.view.layoutSubtreeIfNeeded()
                        precondition(observer.colorScheme == application && self.seenThemes.last?.variant == logical)
                        precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == nativeName)
                    }
                    precondition(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
                    checks += 1
                }
            }
            let originalHost = controller.view
            SettingsStore.shared.themePreference = .init(preferredColorScheme: nil)
            NSApp.appearance = NSAppearance(named: .darkAqua)
            // A live import changes the existing owned window and then restores
            // it. The logical Dark variant remains stable on both transitions.
            for updated in [name == "stock" ? gray : stock, fixture] {
                self.package = updated
                SettingsStore.shared.objectWillChange.send()
                let expected = AppTheme.adaptive(accent: Color(hex: updated.profile.accentDark)!, colorScheme: .dark, package: updated)
                let physical = expected.palette.nativeColorScheme(fallback: .dark)
                let nativeName: NSAppearance.Name = physical == .dark ? .darkAqua : .aqua
                await self.settle(controller.view) {
                    self.seenThemes.last?.variant == .dark && self.seenThemes.last.map { self.samePalette($0.palette, expected.palette) } == true
                        && window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == nativeName && self.logoVariants.last == .dark
                }
                precondition(controller.view === originalHost && controller.view.window === window)
                precondition(observer.colorScheme == .dark && NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua)
                checks += 1
            }
            print("Actual native window \(name): System/Light/Dark follow application changes without palette feedback")
        }
        NSApp.appearance = nil
        await self.settle(NSView()) {
            observer.colorScheme == (NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? .dark : .light)
        }
        precondition(NSApp.appearance == nil, "System restores the OS appearance source")
        print("Native owned windows: \(checks) real NSHostingController/window/chrome checks passed; application scope, logical variants and System nil preserved")
        print("SKIP: actual OS appearance toggle, native glass pixels and visible title/glyph screenshots require the parent's frozen-app GUI verification")
    }
}
