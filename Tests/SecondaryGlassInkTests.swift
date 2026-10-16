import AppKit
import SwiftUI

/// Production secondary style and actual History/Export/Stats labels. Native
/// glass and Menu presentation are replaced only for reference rasterization.
/// Real material-to-label scheme propagation requires frozen-app verification.
enum SecondaryGlassInkTests {
    @MainActor final class State: ObservableObject {
        @Published var material: ColorScheme = .dark
        let theme: AppTheme
        init(theme: AppTheme) { self.theme = theme }
    }
    @MainActor private static func fill(_ state: State, kind: String) -> Color {
        kind == "menu-fallback" ? state.theme.palette.cardBackground
            : state.material == .dark ? Color(white: 0.25) : Color.white
    }
    private struct Fixture: View {
        @ObservedObject var state: State
        let kind: String
        let locale: Locale
        let active: Bool
        @ViewBuilder private var label: some View {
            switch self.kind {
            case "report": ProductionHistoryReportFixture(action: {})
            case "menu": ProductionExportReferenceFixture(fallback: false)
            case "menu-fallback": ProductionExportReferenceFixture(fallback: true)
            case "stats-share": ProductionStatsShareFixture().buttonStyle(.plain)
            default:
                Button(role: self.kind == "neutral" ? nil : .destructive, action: {}) {
                    Label("Remove file", systemImage: "xmark")
                }
                .buttonStyle(ProductionSecondaryReferenceStyle(tone: self.kind == "red" ? .red : nil))
            }
        }
        var body: some View {
            self.label
                .environment(\.colorScheme, self.state.material)
                .environment(\.appearsActive, self.active)
                .environment(\.locale, self.locale)
                .appTheme(self.state.theme)
                .frame(width: 300, height: 48)
                .background(SecondaryGlassInkTests.fill(self.state, kind: self.kind))
        }
    }

    @MainActor private static func check(_ image: CGImage, name: String, state: State,
                                        kind: String, directory: URL) throws {
        let bitmap = NSBitmapImageRep(cgImage: image)
        try bitmap.representation(using: .png, properties: [:])!.write(to: directory.appendingPathComponent(name + ".png"))
        var bytes = [UInt8](repeating: 0, count: image.width * image.height * 4)
        let context = CGContext(data: &bytes, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let background = UIContrastTests.components(self.fill(state, kind: kind))
        var environment = EnvironmentValues()
        environment.colorScheme = state.material
        let resolved = (kind == "red" ? state.theme.palette.readableText(.red) : state.theme.palette.primaryText).resolve(in: environment)
        let preserved = [Double(resolved.red), Double(resolved.green), Double(resolved.blue)]
        var visible = 0, preservedPixels = 0
        for offset in stride(from: 0, to: bytes.count, by: 4) {
            guard bytes[offset + 3] == 255 else { continue }
            let pixel = (0..<3).map { Double(bytes[offset + $0]) / 255 }
            if UIContrastTests.contrast(pixel, background) >= 4.5 { visible += 1 }
            if zip(pixel, preserved).allSatisfy({ abs($0 - $1) < 0.025 }) { preservedPixels += 1 }
        }
        if kind == "red" || kind == "menu-fallback" {
            precondition(preservedPixels >= 20, "\(name): explicit tone/fallback palette ink must be preserved")
        } else {
            precondition(visible >= 40, "\(name): label did not adapt to reference material appearance")
        }
    }

    @MainActor static func run(directory: URL) async throws {
        var checks = 0, existingChecks = 0
        for (brand, path) in [("pichi", "Sources/Fluid/Branding/brand-package.json"),
                              ("sber", "Configuration/BrandExamples/sber-demo.json"),
                              ("alfa", "Configuration/BrandExamples/alfa-demo.json")] {
            let package = try BrandPackage.decode(Data(contentsOf: URL(fileURLWithPath: path)))
            for appScheme: ColorScheme in [.light, .dark] {
                let theme = AppTheme.adaptive(accent: Color(hex: appScheme == .dark ? package.profile.accentDark : package.profile.accentLight)!,
                                              colorScheme: appScheme, package: package)
                existingChecks += try UIContrastTests.verifySecondaryLabels(theme: theme, scheme: appScheme, suffix: "focused-\(brand)-\(appScheme)", directory: directory)
                for language in ["en", "ru"] {
                    for kind in ["report", "neutral", "destructive", "red", "menu", "menu-fallback", "stats-share"] {
                        for active in [true, false] {
                            let state = State(theme: theme)
                            let renderer = ImageRenderer(content: Fixture(state: state, kind: kind, locale: Locale(identifier: language), active: active))
                            renderer.scale = 2
                            for (step, material) in [ColorScheme.dark, .light, .dark].enumerated() {
                                state.material = material
                                try? await Task.sleep(nanoseconds: 10_000_000)
                                let name = "secondary-ink-\(brand)-\(language)-app-\(appScheme)-\(kind)-active\(active)-\(step)-material-\(material)"
                                guard let image = renderer.cgImage else { preconditionFailure("Secondary label did not rasterize") }
                                try self.check(image, name: name, state: state, kind: kind, directory: directory)
                                checks += 1
                            }
                        }
                    }
                }
            }
        }
        UIContrastTests.verifyConstruction()
        print("Secondary ink: \(checks) production/reference-material checks and \(existingChecks) existing secondary label checks passed; explicit tones/fallback palette ink and shared Button construction preserved")
        print("SKIP: native glass/Menu rendering, native scheme propagation, keyboard/AX/physical input and frozen hot/cold replay")
    }
}
