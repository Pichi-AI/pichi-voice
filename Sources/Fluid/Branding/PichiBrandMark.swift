#if canImport(AppKit)
import AppKit
#else
import UIKit
#endif
import SwiftUI

struct PichiBrandMark: View {
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.theme) private var theme
    let size: CGFloat
    let color: Color

    #if canImport(AppKit)
    private static var imageCache: [String: NSImage] = [:]
    private static var unavailableImages: Set<String> = []
    private static var imageRevision = -1
    static var customImage: NSImage? { self.image(BrandPackageStore.shared.snapshot(), role: .primary) }

    static var packagedIcon: NSImage {
        AppBrand.distribution.appIconAsset.flatMap { NSImage(named: $0) }
            ?? self.image(BrandPackageStore.shared.snapshot(), role: .primary, packaged: true)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
            ?? NSImage(size: NSSize(width: 32, height: 32))
    }

    static func image(_ snapshot: BrandPackageStore.Snapshot, role: BrandLogos.Role, fallbackToPrimary: Bool = true, packaged: Bool = false) -> NSImage? {
        let revision = snapshot.revision
        let key = "\(packaged):\(role.rawValue):\(fallbackToPrimary)"
        if self.imageRevision != revision {
            self.imageCache.removeAll()
            self.unavailableImages.removeAll()
            self.imageRevision = revision
        }
        if let image = self.imageCache[key] { return image }
        guard !self.unavailableImages.contains(key) else { return nil }
        let logos = packaged ? AppBrand.packagedPackage.logos : snapshot.package.logos
        guard let data = logos?.visibleData(for: role, fallbackToPrimary: fallbackToPrimary), let image = NSImage(data: data) else {
            self.unavailableImages.insert(key)
            return nil
        }
        self.imageCache[key] = image
        return image
    }

    static var appIcon: NSImage {
        let snapshot = BrandPackageStore.shared.snapshot()
        return self.image(snapshot, role: .primary) ?? (snapshot.hasOverride
            ? (NSImage(systemSymbolName: "waveform", accessibilityDescription: nil) ?? NSImage(size: NSSize(width: 32, height: 32)))
            : self.packagedIcon)
    }

    static var menuBarIcon: NSImage? {
        // A packaged distribution asset retains precedence over primary art.
        // Imported packages have no distribution fallback and use their primary.
        let snapshot = BrandPackageStore.shared.snapshot()
        let explicitMenuLogo = self.image(snapshot, role: .menuBar, fallbackToPrimary: false)
        let source = explicitMenuLogo
            ?? (snapshot.hasOverride ? self.image(snapshot, role: .primary) : AppBrand.distribution.menuBarAsset.flatMap { NSImage(named: $0) })
            ?? self.image(snapshot, role: .primary)
            ?? NSImage(systemSymbolName: "waveform", accessibilityDescription: nil)
        guard let image = source?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    #else
    private static var imageCache: [String: UIImage] = [:]
    private static var unavailableImages: Set<String> = []
    private static var imageRevision = -1
    static func image(_ snapshot: BrandPackageStore.Snapshot, role: BrandLogos.Role) -> UIImage? {
        let revision = snapshot.revision
        let key = role.rawValue
        if self.imageRevision != revision {
            self.imageCache.removeAll()
            self.unavailableImages.removeAll()
            self.imageRevision = revision
        }
        if let image = self.imageCache[key] { return image }
        guard !self.unavailableImages.contains(key) else { return nil }
        guard let data = snapshot.package.logos?.visibleData(for: role), let image = UIImage(data: data) else {
            self.unavailableImages.insert(key)
            return nil
        }
        self.imageCache[key] = image
        return image
    }
    static var customImage: UIImage? { self.image(BrandPackageStore.shared.snapshot(), role: .primary) }
    #endif

    var body: some View {
        let variant = self.theme.variant ?? self.colorScheme
        let snapshot = BrandPackageStore.shared.snapshot()
        Group {
            if let image = Self.image(snapshot, role: variant == .dark ? .dark : .light) {
                #if canImport(AppKit)
                Image(nsImage: image).resizable()
                #else
                Image(uiImage: image).resizable()
                #endif
            } else if !snapshot.hasOverride, let asset = AppBrand.distribution.markAsset {
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
