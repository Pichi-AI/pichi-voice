import AppKit
import SwiftUI

struct PichiBrandMark: View {
    let size: CGFloat
    let color: Color

    static var customImage: NSImage? = {
        guard let data = UserDefaults.standard.data(forKey: "PichiBrandLogo") else { return nil }
        return NSImage(data: data)
    }()

    static let packagedIcon: NSImage = NSImage(named: "PichiAppIcon")
        ?? NSApplication.shared.applicationIconImage
        ?? NSImage(size: NSSize(width: 32, height: 32))

    static var appIcon: NSImage { self.customImage ?? self.packagedIcon }

    static var menuBarIcon: NSImage? {
        guard let image = (self.customImage ?? NSImage(named: "PichiMenuBarIcon"))?.copy() as? NSImage else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }

    var body: some View {
        Group {
            if let image = Self.customImage {
                Image(nsImage: image).resizable()
            } else {
                Image("PichiBrandMark").resizable().renderingMode(.template).foregroundStyle(self.color)
            }
        }
        .aspectRatio(contentMode: .fit)
        .frame(width: self.size, height: self.size)
        .accessibilityHidden(true)
    }
}
