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

@main
struct UIContrastTests {
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
                       textBackground: [Double], directory: URL) throws {
        let expected = self.components(theme.palette.primaryText)
        precondition(self.contrast(expected, textBackground) >= 4.5, "\(name): label contrast must meet 4.5:1")
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
        var matching = 0
        for index in stride(from: 0, to: pixels.count, by: 4) {
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
    static func main() throws {
        let directory = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        let packages = [
            ("pichi", "Sources/Fluid/Branding/brand-package.json"),
            ("sber", "Configuration/BrandExamples/sber-demo.json"),
            ("alfa", "Configuration/BrandExamples/alfa-demo.json"),
        ]
        var checks = 0
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
                    } catch { failure = error }
                }
                if let failure { throw failure }
            }
        }
        print("Actual delete, active badge and metric foreground: \(checks) native rendering checks passed")
    }
}
