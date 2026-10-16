import AppKit
import SwiftUI

/// Uses the production native control in an unshown window. No app services,
/// permission prompts, persistent preferences or native input are initialized.
enum FluidSegmentedPickerTests {
    private enum Choice: CaseIterable, Hashable { case system, light, dark }

    @MainActor private final class State: ObservableObject {
        @Published var selection = Choice.dark
        @Published var titles = ["System", "Light", "Dark"]
        @Published var enabled = true
        @Published var theme: AppTheme
        init(theme: AppTheme) { self.theme = theme }
    }

    private struct Host: View {
        @ObservedObject var state: State
        var body: some View {
            FluidSegmentedPicker(title: "Theme", options: Choice.allCases.enumerated().map {
                (value: $0.element, title: self.state.titles[$0.offset])
            }, selection: self.$state.selection)
            .disabled(!self.state.enabled)
            .appTheme(self.state.theme)
            .environment(\.locale, Locale(identifier: "en"))
            .frame(width: 240)
        }
    }

    private static func controls(in view: NSView) -> [NSSegmentedControl] {
        (view as? NSSegmentedControl).map { [$0] } ?? view.subviews.flatMap { self.controls(in: $0) }
    }

    @MainActor private static func wait(in host: NSView, until predicate: () -> Bool) async throws {
        for _ in 0..<100 {
            host.layoutSubtreeIfNeeded()
            if predicate() { return }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        preconditionFailure("Native segmented control did not refresh")
    }

    @MainActor private static func render(_ control: NSSegmentedControl, name: String,
                                          fill: Color, ink: Color, required: Double, directory: URL) throws {
        let bitmap = control.bitmapImageRepForCachingDisplay(in: control.bounds)!
        control.cacheDisplay(in: control.bounds, to: bitmap)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        let image = bitmap.cgImage!
        var pixels = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &pixels, width: image.width, height: image.height, bitsPerComponent: 8,
                                bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let expected = UIContrastTests.components(ink)
        let background = UIContrastTests.components(fill)
        precondition(UIContrastTests.contrast(expected, background) >= required)
        // Only inspect the selected segment's centre, excluding its native bezel.
        let left = bitmap.pixelsWide * control.selectedSegment / control.segmentCount
        let right = bitmap.pixelsWide * (control.selectedSegment + 1) / control.segmentCount
        var inkPixels = 0, fillPixels = 0
        for y in 2..<(bitmap.pixelsHigh - 2) {
            for x in (left + 4)..<(right - 4) {
                let offset = (y * image.width + x) * 4
                guard pixels[offset + 3] == 255 else { continue }
                let rgb = (0..<3).map { Double(pixels[offset + $0]) / 255 }
                if zip(rgb, expected).allSatisfy({ abs($0 - $1) < 0.025 }) { inkPixels += 1 }
                if zip(rgb, background).allSatisfy({ abs($0 - $1) < 0.025 }) { fillPixels += 1 }
            }
        }
        precondition(inkPixels >= 12, "\(name): actual selected label ink is absent")
        precondition(fillPixels >= 24, "\(name): opaque surface directly under selected label is absent")
        print("\(name): \(UIContrastTests.contrast(expected, background)):1, \(inkPixels) ink / \(fillPixels) fill pixels")
    }

    @MainActor static func run(directory: URL) async throws {
        NSApplication.shared.setActivationPolicy(.prohibited)
        let paths = [("pichi", "Sources/Fluid/Branding/brand-package.json"),
                     ("sber", "Configuration/BrandExamples/sber-demo.json"),
                     ("alfa", "Configuration/BrandExamples/alfa-demo.json")]
        var packages = try paths.map { (name, path) in
            (name, try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: path))))
        }
        let backgrounds = Set(["windowBackground", "contentBackground", "sidebarBackground",
                               "cardBackground", "elevatedCardBackground", "toolbarBackground"])
        for (name, surface, ink, accent) in [("inverse-white", "#FFFFFF", "#000000", "#949494"),
                                              ("opposite-inks", "#606060", "#FFFFFF", "#000000")] {
            let colors = Dictionary(uniqueKeysWithValues: BrandPalette.tokens.map { ($0, backgrounds.contains($0) ? surface : ink) })
            let profile = BrandProfile(appName: "Contrast", meetingName: "Meet", assistantName: "AI", tagline: "Synthetic fixture",
                                       accentLight: accent, accentDark: accent, website: "https://example.invalid", support: "https://example.invalid")
            let palette = BrandPalette(colors: colors)
            let package = try BrandPackage.decode(BrandPackage(profile: profile, theme: BrandTheme(light: palette, dark: palette)).encoded())
            packages.append((name, package))
        }
        var checked = 0
        for (name, package) in packages {
            for scheme: ColorScheme in [.light, .dark] {
                let accent = Color(hex: scheme == .light ? package.profile.accentLight : package.profile.accentDark)!
                let initial = AppTheme.adaptive(accent: accent, colorScheme: scheme, package: package)
                let state = State(theme: initial)
                let host = NSHostingView(rootView: Host(state: state))
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 260, height: 50), styleMask: [.titled], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.contentView = host
                defer { window.close() }
                try await self.wait(in: host) { !self.controls(in: host).isEmpty }
                let control = self.controls(in: host)[0]
                let originalCell = control.cell
                precondition(control.trackingMode == .selectOne && control.selectedSegment == 2)
                precondition(control.label(forSegment: 2) == "Dark")
                precondition(control.accessibilityLabel() == PichiLocalization.text("Theme", locale: Locale(identifier: "en")))
                let appearance = NSAppearance(named: scheme == .light ? .aqua : .darkAqua)!
                control.appearance = appearance
                for (variant, chosenAccent) in [("brand", accent), ("saved-pale", Color(hex: "#A98CFF")!)] {
                    state.theme = AppTheme.adaptive(accent: chosenAccent, colorScheme: scheme, package: package)
                    state.titles = ["Системная", "Светлая", "Тёмная"]
                    try await self.wait(in: host) { control.label(forSegment: 2) == "Тёмная" && control.selectedSegmentBezelColor == NSColor(chosenAccent) }
                    precondition(self.controls(in: host)[0] === control && control.cell === originalCell)
                    let theme = state.theme
                    var failure: Error?
                    appearance.performAsCurrentDrawingAppearance {
                        do { try self.render(control, name: "segmented-\(name)-\(scheme == .light ? "light" : "dark")-\(variant)",
                                             fill: theme.palette.accent, ink: theme.palette.foreground(on: theme.palette.accent), required: 4.5, directory: directory) }
                        catch { failure = error }
                    }
                    if let failure { throw failure }
                    checked += 1
                }
                // Native target/action still writes the exact existing binding.
                control.selectedSegment = 0
                control.sendAction(control.action!, to: control.target)
                precondition(state.selection == .system)
                state.enabled = false
                try await self.wait(in: host) { !control.isEnabled }
                control.selectedSegment = 1
                control.sendAction(control.action!, to: control.target)
                precondition(state.selection == .system, "Disabled native action cannot change the selection")
                state.selection = .dark
                try await self.wait(in: host) { control.selectedSegment == 2 }
                var failure: Error?
                appearance.performAsCurrentDrawingAppearance {
                    do { try self.render(control, name: "segmented-\(name)-\(scheme == .light ? "light" : "dark")-disabled",
                                         fill: state.theme.palette.elevatedCardBackground, ink: state.theme.palette.secondaryText, required: 3, directory: directory) }
                    catch { failure = error }
                }
                if let failure { throw failure }
                checked += 1
            }
        }
        print("Native segmented label surfaces: \(checked) rendering checks; binding, disabled action and view/cell refresh preserved")
        print("SKIP: native pointer, keyboard focus and accessibility interaction require the parent's frozen-app GUI retest.")
    }
}
