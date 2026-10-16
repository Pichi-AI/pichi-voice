import AppKit
import SwiftUI
import ImageIO
import UniformTypeIdentifiers

// A synthetic theme satisfies the actual mark's environment contract. This
// executable never creates NSApplication, windows or installed package state.
struct AppTheme {
    var variant: ColorScheme? = nil
    struct Palette { var accent: Color = .purple }
    var palette = Palette()
}
private struct LogoThemeKey: EnvironmentKey {
    static let defaultValue = AppTheme()
}
extension EnvironmentValues {
    var theme: AppTheme {
        get { self[LogoThemeKey.self] }
        set { self[LogoThemeKey.self] = newValue }
    }
}

@main struct BrandLogoRenderingTests {
    @MainActor static func main() throws {
        let suite = "brand-logo-snapshot-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = BrandPackageStore(defaults: defaults, packaged: BrandPackage(profile: .neutral))
        let missingA = store.snapshot()
        precondition(missingA.package.logos == nil && !missingA.hasOverride)
        let white = try self.logo(white: true)
        let black = try self.logo(white: false)
        // Deterministically place the import between capturing old artwork and
        // asking the real renderer to cache it. No scheduler timing is needed.
        try store.importData(BrandPackage(profile: .neutral, logos: BrandLogos(primary: white)).encoded())
        let visibleB = store.snapshot()
        precondition(visibleB.revision == missingA.revision + 1 && visibleB.hasOverride)
        precondition(visibleB.package.logos?.primary == white)
        precondition(PichiBrandMark.image(missingA, role: .primary) == nil)
        let imageB = PichiBrandMark.image(visibleB, role: .primary)!
        precondition(PichiBrandMark.image(visibleB, role: .primary) === imageB)
        precondition(PichiBrandMark.image(missingA, role: .primary) == nil)
        let freshB = PichiBrandMark.image(visibleB, role: .primary)!
        precondition(freshB.tiffRepresentation == imageB.tiffRepresentation)
        // Successful cache entries obey the same snapshot boundary as misses.
        try store.importData(BrandPackage(profile: .neutral, logos: BrandLogos(primary: black)).encoded())
        let visibleC = store.snapshot()
        precondition(visibleC.revision == visibleB.revision + 1)
        let imageC = PichiBrandMark.image(visibleC, role: .primary)!
        let staleB = PichiBrandMark.image(visibleB, role: .primary)!
        let freshC = PichiBrandMark.image(visibleC, role: .primary)!
        precondition(staleB.tiffRepresentation == imageB.tiffRepresentation)
        precondition(freshC.tiffRepresentation == imageC.tiffRepresentation)
        precondition(freshC.tiffRepresentation != staleB.tiffRepresentation)
        try store.reset()
        let reset = store.snapshot()
        precondition(reset.revision == visibleC.revision + 1 && !reset.hasOverride && reset.package.logos == nil)
        precondition(PichiBrandMark.image(reset, role: .primary) == nil)
        precondition(PichiBrandMark.image(visibleC, role: .primary) != nil)
        precondition(PichiBrandMark.image(reset, role: .primary) == nil)
        print("Actual brand renderer: immutable store snapshots, stale negative/positive entries, reordered generations and reset passed without windows")
    }

    static func logo(white: Bool) throws -> BrandLogo {
        let pixels = Array(repeating: [UInt8](repeating: white ? 255 : 0, count: 3) + [255], count: 4).flatMap { $0 }
        let image = CGImage(width: 2, height: 2, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: 8,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
            provider: CGDataProvider(data: Data(pixels) as CFData)!, decode: nil, shouldInterpolate: false, intent: .defaultIntent)!
        let data = NSMutableData()
        let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, image, nil)
        precondition(CGImageDestinationFinalize(destination))
        return try BrandLogo(data: data as Data)
    }
}
