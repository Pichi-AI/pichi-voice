import AppKit

class MenuBarIconGenerator {
    static func createMenuBarIcon() -> NSImage? {
        guard let image = PichiBrandMark.menuBarIcon else { return nil }
        image.size = NSSize(width: 18, height: 18)
        image.isTemplate = true
        return image
    }
}
