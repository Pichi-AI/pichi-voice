#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

struct PichiBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme
    let size: CGFloat
    let color: Color

    #if canImport(AppKit)
    private static var imageCache: [String: NSImage] = [:]
    private static var imageRevision = -1
    static var customImage: NSImage? { self.image(AppBrand.package.logos?.primary, key: "primary") }

    static var packagedIcon: NSImage {
        AppBrand.distribution.appIconAsset.flatMap { NSImage(named: $0) }
            ?? self.image(AppBrand.packagedPackage.logos?.primary, key: "packaged")
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }

    private static func image(_ logo: BrandLogo?, key: String) -> NSImage? {
        let revision = BrandPackageStore.shared.revision
        if self.imageRevision != revision {
            self.imageCache.removeAll()
            self.imageRevision = revision
        }
        if let image = self.imageCache[key] { return image }
        guard let logo, let data = Data(base64Encoded: logo.base64), let image = NSImage(data: data) else { return nil }
        self.imageCache[key] = image
        return image
    }

    static var appIcon: NSImage {
        self.customImage ?? (BrandPackageStore.shared.hasOverride
            ? (NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32)))
            : self.packagedIcon)
    }

    static var menuBarIcon: NSImage? {
        let explicitMenuLogo = self.image(AppBrand.package.logos?.menuBar, key: "menuBar")
        let source = explicitMenuLogo
            ?? (BrandPackageStore.shared.hasOverride ? self.customImage : AppBrand.distribution.menuBarAsset.flatMap { NSImage(named: $0) })
            ?? self.customImage
        guard let image = source?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = explicitMenuLogo != nil || !BrandPackageStore.shared.hasOverride
        return image
    }

    #else
    private static func image(_ logo: BrandLogo?, key: String) -> UIImage? {
        guard let logo, let data = Data(base64Encoded: logo.base64) else { return nil }
        return UIImage(data: data)
    }
    static var customImage: UIImage? { self.image(AppBrand.package.logos?.primary, key: "primary") }
    #endif

    var body: some View {
        Group {
            if let image = Self.image(self.colorScheme == .dark ? AppBrand.package.logos?.dark : AppBrand.package.logos?.light, key: self.colorScheme == .dark ? "dark" : "light") ?? Self.customImage {
                #if canImport(AppKit)
                Image(nsImage: image).resizable()
                #else
                Image(uiImage: image).resizable()
                #endif
            } else if !BrandPackageStore.shared.hasOverride, let asset = AppBrand.distribution.markAsset {
                Image(asset).resizable().renderingMode(.template).foregroundStyle(self.color)
            } else {
                Image(systemName: "waveform").resizable().foregroundStyle(self.color)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}
