import AppKit

/// Rasterizes views at a fixed backing scale, whatever display the process runs on.
///
/// A window takes its scale from its screen: 2x on a Retina Mac and 1x on a runner without a Retina display. The
/// visual probes measure thin symbol strokes and text against thresholds calibrated at 2x, so a 1x raster would make
/// them pass or fail by display and not by product. The probes therefore host their fixtures in a
/// `FixedScaleWindow` and snapshot into a bitmap with the same pixel density, and keep their thresholds.
enum FixedScaleSnapshot {
    static let scale = 2

    /// A window that reports the fixed scale, so SwiftUI and AppKit rasterize text and symbols at that scale.
    final class Window: NSWindow {
        override var backingScaleFactor: CGFloat { CGFloat(FixedScaleSnapshot.scale) }
    }

    /// The same native snapshot the probes always took. Inside a `Window` it has the fixed pixel density.
    @MainActor static func bitmap(of view: NSView) -> NSBitmapImageRep? {
        guard view.window is Window else { preconditionFailure("Snapshot views must be hosted in FixedScaleSnapshot.Window") }
        view.layoutSubtreeIfNeeded()
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds),
              Int(bitmap.pixelsWide) >= Int((view.bounds.width * CGFloat(self.scale)).rounded(.down)),
              Int(bitmap.pixelsHigh) >= Int((view.bounds.height * CGFloat(self.scale)).rounded(.down))
        else { return nil }
        view.cacheDisplay(in: view.bounds, to: bitmap)
        return bitmap
    }
}
