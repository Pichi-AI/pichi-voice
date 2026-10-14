import AppKit
import SwiftUI

// The production label receives already-localized titles. Synthetic row data
// exercises both alphabets without app services or installed navigation state.
struct SidebarItem: Hashable, Identifiable {
    let id: Int
    let title: String
    let systemImage: String
}

enum NativeSidebarContrastTests {
    enum Family: String { case main, settings }
    @MainActor final class State: ObservableObject {
        @Published var selection: SidebarItem?
        @Published var theme: AppTheme
        let items: [SidebarItem]
        init(theme: AppTheme, russian: Bool, family: Family) {
            self.theme = theme
            self.items = [
                .init(id: 0, title: russian ? "Общие Ёё" : "General Ёё", systemImage: family == .main ? "house.fill" : "gearshape"),
                .init(id: 1, title: russian ? "Диктовка Ёё" : "Dictation Ёё", systemImage: family == .main ? "waveform" : "mic"),
            ]
            self.selection = self.items[0]
        }
    }

    private struct Host: View {
        @ObservedObject var state: State
        let family: Family
        var body: some View {
            NavigationSplitView {
                ProductionSidebarFixture(state: self.state, family: self.family)
                    .navigationSplitViewColumnWidth(300)
            } detail: { Text("Synthetic detail") }
            .appTheme(self.state.theme)
            .preferredColorScheme(self.state.theme.palette.nativeColorScheme(fallback: self.state.theme.variant!))
        }
    }

    private static func outlines(_ view: NSView) -> [NSOutlineView] {
        if let outline = view as? NSOutlineView { return [outline] }
        return view.subviews.flatMap(self.outlines)
    }

    @MainActor private static func settle(_ host: NSView, until predicate: () -> Bool) async {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Actual native sidebar rows did not materialize")
    }

    @MainActor private static func pixels(_ view: NSView, name: String, ink: Color, iconInk: Color, iconWidth: CGFloat, directory: URL) throws {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        let image = bitmap.cgImage!
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let expected = UIContrastTests.components(ink)
        let expectedIcon = UIContrastTests.components(iconInk)
        let scale = Double(image.width) / view.bounds.width
        let iconEnd = Int(ceil(Double(iconWidth) * scale))
        let textStart = Int(ceil(Double(iconWidth + 8) * scale))
        var matching = 0, iconMatching = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            guard bytes[offset + 3] == 255 else { continue }
            let x = (offset / 4) % image.width
            if x >= textStart && (0..<3).allSatisfy({ abs(Double(bytes[offset + $0]) / 255 - expected[$0]) < 0.04 }) { matching += 1 }
            if x < iconEnd && (0..<3).allSatisfy({ abs(Double(bytes[offset + $0]) / 255 - expectedIcon[$0]) < 0.04 }) { iconMatching += 1 }
        }
        precondition(matching >= 20, "\(name): actual native sidebar palette ink is absent")
        precondition(iconMatching >= 12, "\(name): actual native sidebar icon ink is absent")
    }

    @MainActor static func run(directory: URL) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let originalAppearance = NSApp.appearance
        defer { NSApp.appearance = originalAppearance }
        let fields = Set(["windowBackground", "contentBackground", "sidebarBackground",
                          "cardBackground", "elevatedCardBackground", "toolbarBackground"])
        var checks = 0
        for physical: ColorScheme in [.light, .dark] {
            let app: ColorScheme = physical == .light ? .dark : .light
            NSApp.appearance = NSAppearance(named: app == .dark ? .darkAqua : .aqua)
            let ink = physical == .dark ? "#FFFFFF" : "#000000"
            let surface = physical == .dark ? "#201A2C" : "#F4F0FA"
            var values = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, fields.contains($0) ? surface : ink) })
            values["accentForeground"] = physical == .dark ? "#000000" : "#FFFFFF"
            let palette = BrandPalette(colors: values)
            let accent = physical == .dark ? "#A98CFF" : "#6845AD"
            let profile = BrandProfile(appName: "Synthetic", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic",
                accentLight: accent, accentDark: accent, website: "https://example.invalid", support: "https://example.invalid")
            for design in BrandStyle.FontDesign.allCases {
                var style = BrandStyle()
                style.bodyFontDesign = design
                style.titleFontDesign = design
                let package = try BrandPackage.decode(BrandPackage(profile: profile, theme: BrandTheme(light: palette, dark: palette), style: style).encoded())
                let theme = AppTheme.adaptive(accent: Color(hex: profile.accentLight)!, colorScheme: app, package: package)
                for russian in [false, true] {
                    for family: Family in [.main, .settings] {
                        let state = State(theme: theme, russian: russian, family: family)
                        let controller = NSHostingController(rootView: Host(state: state, family: family))
                        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 350),
                                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
                        window.isReleasedWhenClosed = false
                        window.contentViewController = controller
                        defer { window.close() }
                        await self.settle(controller.view) { self.outlines(controller.view).first?.numberOfRows == 2 }
                        let outline = self.outlines(controller.view).first!
                        let originalOutline = outline
                        for selected in [0, 1] {
                            state.selection = state.items[selected]
                            await self.settle(controller.view) { outline.selectedRow == selected }
                            precondition(self.outlines(controller.view).first === originalOutline)
                            precondition(state.selection == state.items[selected])
                            for row in [0, 1] {
                                let view = outline.view(atColumn: 0, row: row, makeIfNecessary: true)!
                                let name = "native-sidebar-\(physical)-app-\(app)-\(design)-\(russian ? "ru" : "en")-\(family.rawValue)-selected\(selected)-row\(row)"
                                try self.pixels(view, name: name,
                                    ink: row == selected ? theme.palette.accentForeground : theme.palette.primaryText,
                                    iconInk: row == selected ? theme.palette.accentForeground : theme.palette.secondaryText,
                                    iconWidth: family == .main ? 16 : 18, directory: directory)
                                checks += 1
                            }
                            precondition(window.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (physical == .dark ? .darkAqua : .aqua))
                            precondition(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
                        }
                    }
                }
            }
        }
        print("Native sidebar: \(checks) actual main/settings selected/unselected row ink checks; opposite app/window appearances, RU/EN and shared font designs")
        let foregrounds = ["primaryText": "#767676", "secondaryText": "#949494", "tertiaryText": "#949494",
                           "warning": "#949494", "success": "#949494", "accentForeground": "#FFFFFF"]
        var marginalValues = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, "#FFFFFF") })
        for (key, value) in foregrounds { marginalValues[key] = value }
        let marginalPalette = BrandPalette(colors: marginalValues)
        let profile = BrandProfile(appName: "Synthetic marginal", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic",
            accentLight: "#767676", accentDark: "#767676", website: "https://example.invalid", support: "https://example.invalid")
        let marginal = try BrandPackage.decode(BrandPackage(profile: profile, theme: BrandTheme(light: marginalPalette, dark: marginalPalette)).encoded())
        let theme = AppTheme.adaptive(accent: Color(hex: "#767676")!, colorScheme: .light, package: marginal)
        let fills = UIContrastTests.components(theme.palette.elevatedCardBackground)
        for (name, view) in [("footer-hover", AnyView(ProductionSidebarChromeFixture(isHovered: true, isPressed: false))),
                             ("footer-pressed", AnyView(ProductionSidebarChromeFixture(isHovered: false, isPressed: true))),
                             ("navigation-hover", AnyView(ProductionSidebarHoveredFixture()))] {
            try UIContrastTests.verify(view, name: "sidebar-marginal-\(name)", theme: theme, scheme: .light,
                textBackground: fills, directory: directory, expectedForeground: theme.palette.primaryText,
                requiredContrast: 4.5, expectedSurface: theme.palette.elevatedCardBackground)
        }
        print("Sidebar marginal palette: 3 actual source-bound hover/pressed rendering checks with validated opaque surfaces")
        print("SKIP: native focus, pointer, AX interaction and visible sidebar material contrast require parent frozen-app screenshots")
    }
}
