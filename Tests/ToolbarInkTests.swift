import AppKit
import SwiftUI

/// Actual label expressions rendered against a reference material appearance.
/// No window, native host, application activation, preferences or glass renderer.
/// Native toolbar-to-SwiftUI appearance propagation remains an application gate.
enum ToolbarInkTests {
    @MainActor final class State: ObservableObject {
        @Published var material: ColorScheme = .light
        let theme: AppTheme
        var seenScheme: ColorScheme?
        init(theme: AppTheme) { self.theme = theme }
    }
    private struct SchemeProbe: View {
        @ObservedObject var state: State
        @Environment(\.colorScheme) private var scheme
        var body: some View {
            self.state.seenScheme = self.scheme
            return Color.clear.frame(width: 1, height: 1)
        }
    }
    private struct Fixture: View {
        @ObservedObject var state: State
        let kind: String
        let locale: Locale
        @ViewBuilder private var label: some View {
            switch self.kind {
            case "sidebar": ProductionToolbarSidebarFixture()
            case "theme": ProductionToolbarThemeFixture()
            case "issue": ProductionToolbarIssueFixture()
            case "update": ProductionToolbarUpdateFixture()
            case "page": ProductionToolbarPageFixture()
            case "page-stale-host": ProductionToolbarPageFixture(staleHostScheme: self.state.material == .light ? .dark : .light)
            case "today-empty": ProductionToolbarTodayFixture(hasActivity: false, action: {})
            default: ProductionToolbarTodayFixture(hasActivity: true, action: {})
            }
        }
        var body: some View {
            self.label
                .buttonStyle(.plain)
                .overlay { SchemeProbe(state: self.state) }
                // A native toolbar supplies its material appearance at this
                // boundary. Explicitly supply it here to test label ownership.
                .environment(\.colorScheme, self.state.material)
                .environment(\.locale, self.locale)
                .appTheme(self.state.theme)
                .frame(width: 240, height: 48)
                .background(self.state.material == .light ? Color.white : Color.black)
        }
    }

    @MainActor private static func check(_ image: CGImage, name: String, state: State,
                                        updater: Bool, directory: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let background = Array(repeating: state.material == .light ? 1.0 : 0.0, count: 3)
        let accent = UIContrastTests.components(state.theme.palette.accent)
        var visible = 0, accentPixels = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            guard bytes[offset + 3] == 255 else { continue }
            let pixel = (0..<3).map { Double(bytes[offset + $0]) / 255 }
            if UIContrastTests.contrast(pixel, background) >= 4.5 { visible += 1 }
            if zip(pixel, accent).allSatisfy({ abs($0 - $1) < 0.04 }) { accentPixels += 1 }
        }
        if updater {
            precondition(accentPixels >= 20, "\(name): intentional updater accent must remain explicit")
        } else {
            precondition(visible >= 40, "\(name): actual toolbar label did not adapt to material appearance")
        }
    }

    @MainActor static func run(directory: URL) async throws {
        var checks = 0
        var packages = try [("pichi", "Sources/Fluid/Branding/brand-package.json"),
                            ("sber", "Configuration/BrandExamples/sber-demo.json"),
                            ("alfa", "Configuration/BrandExamples/alfa-demo.json")].map {
            ($0.0, try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: $0.1))))
        }
        var inverted = packages[0].1
        let profile = inverted.profile
        inverted.profile = BrandProfile(appName: profile.appName, meetingName: profile.meetingName,
            assistantName: profile.assistantName, tagline: profile.tagline,
            accentLight: profile.accentDark, accentDark: profile.accentLight,
            website: profile.website, support: profile.support)
        inverted.theme = BrandTheme(light: inverted.theme!.dark, dark: inverted.theme!.light)
        packages.append(("inverted", try BrandPackage.decode(inverted.encoded())))
        for (brand, package) in packages {
            for appScheme: ColorScheme in [.dark, .light] {
                let theme = AppTheme.adaptive(accent: Color(hex: appScheme == .dark ? package.profile.accentDark : package.profile.accentLight)!,
                                              colorScheme: appScheme, package: package)
                if brand == "inverted" {
                    precondition(theme.palette.nativeColorScheme(fallback: appScheme) != appScheme)
                }
                let kinds = brand == "inverted" ? ["page", "page-stale-host"]
                    : ["sidebar", "theme", "issue", "update", "page", "page-stale-host", "today-empty", "today-active"]
                for language in ["en", "ru"] {
                    for kind in kinds {
                        let state = State(theme: theme)
                        let renderer = ImageRenderer(content: Fixture(state: state, kind: kind, locale: Locale(identifier: language)))
                        renderer.scale = 2
                        for (step, material) in [ColorScheme.light, .dark, .light].enumerated() {
                            state.material = material
                            // Preserve the same renderer, observable state and view
                            // identity while its material environment changes.
                            try? await Task.sleep(nanoseconds: 10_000_000)
                            let name = "toolbar-ink-\(brand)-\(language)-app-\(appScheme)-\(kind)-\(step)-material-\(material)"
                            guard let image = renderer.cgImage else { preconditionFailure("Toolbar label did not rasterize") }
                            precondition(state.seenScheme == material, "Inner material appearance must override the app palette scheme in this projection")
                            try self.check(image, name: name, state: state, updater: kind == "update", directory: directory)
                            checks += 1
                        }
                    }
                }
            }
        }
        print("Toolbar ink: \(checks) production label/reference-material checks, 3 brands plus validated inverted palette, RU/EN, opposite and matching app/material appearances; stale page-host forwarding and intentional updater accent preserved")
        print("SKIP: actual native toolbar material-to-label scheme propagation, disabled chrome, pointer/AX actions and hot/cold application replay")
    }
}
