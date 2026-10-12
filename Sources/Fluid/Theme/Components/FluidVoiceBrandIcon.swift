import AppKit
import SwiftUI

/// Reuse AppKit's cached app icon; no asset lookup or filesystem query in the view.
struct FluidVoiceBrandIcon: View {
    let size: CGFloat

    var body: some View {
        Image(nsImage: PichiBrandMark.appIcon)
            .resizable()
            .interpolation(.high)
            .aspectRatio(contentMode: .fit)
            .frame(width: self.size, height: self.size)
            .accessibilityHidden(true)
    }
}
