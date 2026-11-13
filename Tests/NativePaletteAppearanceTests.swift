import AppKit
import SwiftUI

/// Production appTheme rehosting in unshown windows, with real native controls.
/// This checks native appearance and pixels, never glass or visible toolbar UI.
enum NativePaletteAppearanceTests {
    @MainActor private final class State: ObservableObject {
        @Published var theme: AppTheme
        @Published var selection = 0
        @Published var enabled = false
        var seenVariants: [ColorScheme?] = []
        var seenNativeSchemes: [ColorScheme] = []
        var seenAmbientSchemes: [ColorScheme] = []
        init(theme: AppTheme) { self.theme = theme }
    }

    private struct VariantProbe: View {
        @ObservedObject var state: State
        @Environment(\.theme) private var theme
        @Environment(\.colorScheme) private var nativeScheme
        var body: some View {
            self.state.seenVariants.append(self.theme.variant)
            self.state.seenNativeSchemes.append(self.nativeScheme)
            return Color.clear.frame(width: 1, height: 1)
        }
    }

    private struct Host: View {
        @ObservedObject var state: State
        @Environment(\.colorScheme) private var ambientScheme
        var body: some View {
            self.state.seenAmbientSchemes.append(self.ambientScheme)
            return VStack {
                Picker("Interface language", selection: self.$state.selection) {
                    Text("Russian Ёё").tag(0)
                    Text("English").tag(1)
                }.pickerStyle(.menu)
                Toggle("Native switch", isOn: self.$state.enabled).toggleStyle(.switch)
                VariantProbe(state: self.state)
            }
            .padding(20)
            .frame(width: 360, height: 150)
            .background(self.state.theme.palette.cardBackground)
            .appTheme(self.state.theme)
        }
    }

    private static func nativeControls(in view: NSView) -> [NSView] {
        if view is NSPopUpButton || view is NSSwitch { return [view] }
        return view.subviews.flatMap(self.nativeControls)
    }

    /// An AppKit switch backs the SwiftUI switch on every supported system. macOS 27 draws the menu picker in
    /// SwiftUI itself, without an AppKit pop-up button, so the pop-up is required only before macOS 27. A SwiftUI-drawn
    /// picker takes the SwiftUI color scheme, which `VariantProbe` checks; its pixels are not checked here.
    private static func hasExpectedNativeControls(_ controls: [NSView]) -> Bool {
        let switches = controls.filter { $0 is NSSwitch }.count
        let popUps = controls.filter { $0 is NSPopUpButton }.count
        guard switches == 1, controls.count == switches + popUps else { return false }
        if #available(macOS 27, *) { return popUps <= 1 }
        return popUps == 1
    }

    @MainActor private static func wait(in host: NSView, expecting: NSAppearance.Name? = nil, until predicate: () -> Bool) async {
        // Three seconds: a slow or newer system can take longer to settle the appearance change.
        for _ in 0..<300 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        let found = self.nativeControls(in: host).map { "\(type(of: $0)):\($0.effectiveAppearance.name.rawValue)" }
        preconditionFailure("Native picker and switch did not refresh to \(expecting?.rawValue ?? "the expected appearance"); "
                            + "found \(found) among \(self.viewClasses(in: host))")
    }

    private static func viewClasses(in view: NSView) -> [String] {
        Array(Set(([view] + view.subviews.flatMap { [$0] + $0.subviews }).map { String(describing: type(of: $0)) })).sorted()
    }

    @MainActor private static func checkPixels(_ view: NSView, name: String, scheme: ColorScheme,
                                               directory: URL) throws {
        let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        let image = bitmap.cgImage!
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        var inkPixels = 0, shapePixels = 0
        for offset in stride(from: 0, to: pixels.count, by: 4) {
            guard pixels[offset + 3] >= 200 else { continue }
            shapePixels += 1
            let channels = (0..<3).map { Int(pixels[offset + $0]) }
            if scheme == .light ? channels.max()! <= 80 : channels.min()! >= 175 { inkPixels += 1 }
        }
        if view is NSPopUpButton {
            precondition(inkPixels >= 20, "\(name): native label ink is absent")
        } else {
            precondition(shapePixels >= 20, "\(name): native switch shape is absent")
        }
    }

    @MainActor static func run(directory: URL) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let files = [("pichi", "Sources/Fluid/Branding/brand-package.json"),
                     ("sber", "Configuration/BrandExamples/sber-demo.json"),
                     ("alfa", "Configuration/BrandExamples/alfa-demo.json")]
        var packages = try files.map { (name, path) in
            (name, try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: path))))
        }
        let backgrounds = Set(["windowBackground", "contentBackground", "sidebarBackground",
                               "cardBackground", "elevatedCardBackground", "toolbarBackground"])
        for (name, surface, ink, accent) in [("white", "#FFFFFF", "#000000", "#949494"),
                                             ("opposite", "#606060", "#FFFFFF", "#000000")] {
            var colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, backgrounds.contains($0) ? surface : ink) })
            colors["accentForeground"] = "#FFFFFF" == surface ? "#000000" : "#FFFFFF"
            let profile = BrandProfile(appName: "Synthetic", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic",
                accentLight: accent, accentDark: accent, website: "https://example.invalid", support: "https://example.invalid")
            let palette = BrandPalette(colors: colors)
            packages.append((name, try BrandPackage.decode(BrandPackage(profile: profile, theme: BrandTheme(light: palette, dark: palette)).encoded())))
        }
        let white = packages.first { $0.0 == "white" }!.1
        let dark = packages.first { $0.0 == "opposite" }!.1
        let invertedProfile = BrandProfile(appName: "Synthetic inverted", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic",
            accentLight: "#000000", accentDark: "#949494", website: "https://example.invalid", support: "https://example.invalid")
        packages.append(("inverted", try BrandPackage.decode(BrandPackage(profile: invertedProfile,
            theme: BrandTheme(light: dark.theme!.light, dark: white.theme!.dark)).encoded())))
        var checks = 0
        for (name, package) in packages {
            for logical: ColorScheme in [.light, .dark] {
                let accent = Color(hex: logical == .dark ? package.profile.accentDark : package.profile.accentLight)!
                let theme = AppTheme.adaptive(accent: accent, colorScheme: logical, package: package)
                let native = theme.palette.nativeColorScheme(fallback: logical)
                precondition(theme.variant == logical, "Native appearance must not change the selected brand variant")
                if name == "white" { precondition(native == .light && theme.palette.accentText == theme.palette.primaryText) }
                if name == "opposite" { precondition(native == .dark) }
                let state = State(theme: theme)
                let host = NSHostingView(rootView: Host(state: state))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                var originalControls: [NSView]?
                for parent: ColorScheme in [.light, .dark] {
                    // An unchanged parent need not invalidate Host. Retain its
                    // actual last observation and wait for both sides of the
                    // appearance boundary, not only already-settled controls.
                    window.appearance = NSAppearance(named: parent == .dark ? .darkAqua : .aqua)
                    let expected: NSAppearance.Name = native == .dark ? .darkAqua : .aqua
                    await self.wait(in: host, expecting: expected) {
                        let controls = self.nativeControls(in: host)
                        return state.seenAmbientSchemes.last == parent
                            && self.hasExpectedNativeControls(controls) && controls.allSatisfy {
                            $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == expected
                        }
                    }
                    let controls = self.nativeControls(in: host)
                    if let originalControls {
                        precondition(zip(originalControls, controls).allSatisfy { $0 === $1 }, "Appearance changes must preserve native control identity")
                    } else { originalControls = controls }
                    precondition(state.seenVariants.allSatisfy { $0 == logical })
                    precondition(!state.seenNativeSchemes.isEmpty && state.seenNativeSchemes.allSatisfy { $0 == native })
                    precondition(state.seenAmbientSchemes.last == parent, "Physical descendant scheme must not feed back into the ambient logical scheme")
                    precondition(state.selection == 0 && !state.enabled, "Appearance must not invoke controls or change their bindings")
                    precondition(!window.isVisible && !window.isKeyWindow && !window.isMainWindow)
                    for (index, control) in controls.enumerated() {
                        let imageName = "native-appearance-\(name)-\(logical)-parent-\(parent)-\(index)"
                        try self.checkPixels(control, name: imageName, scheme: native, directory: directory)
                        checks += 1
                    }
                }
                let changedPackage = name == "white" ? dark : white
                let changedAccent = Color(hex: logical == .dark ? changedPackage.profile.accentDark : changedPackage.profile.accentLight)!
                let changed = AppTheme.adaptive(accent: changedAccent, colorScheme: logical, package: changedPackage)
                // A normal brand import updates the existing tree. Verify both
                // directions without replacing controls or changing their values.
                for (transition, updated) in [("import", changed), ("restore", theme)] {
                    state.seenNativeSchemes.removeAll()
                    state.theme = updated
                    let updatedNative = updated.palette.nativeColorScheme(fallback: logical)
                    await self.wait(in: host) {
                        self.nativeControls(in: host).allSatisfy {
                            $0.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == (updatedNative == .dark ? .darkAqua : .aqua)
                        } && state.seenNativeSchemes.last == updatedNative
                    }
                    let controls = self.nativeControls(in: host)
                    precondition(self.hasExpectedNativeControls(controls) && controls.count == originalControls!.count
                                 && zip(originalControls!, controls).allSatisfy { $0 === $1 })
                    precondition(state.seenVariants.allSatisfy { $0 == logical })
                    precondition(state.selection == 0 && !state.enabled)
                    for (index, control) in controls.enumerated() {
                        try self.checkPixels(control, name: "native-appearance-\(name)-\(logical)-\(transition)-\(index)",
                                             scheme: updatedNative, directory: directory)
                        checks += 1
                    }
                }
            }
        }
        print("Native palette appearance: \(checks) actual hidden picker/switch appearance and pixel checks passed; logical variant and bindings preserved")
    }
}
