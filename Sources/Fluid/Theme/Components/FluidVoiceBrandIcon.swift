import SwiftUI

/// Decorative artwork follows the shared theme and existing package variants.
/// Distribution and Dock icons continue to use PichiBrandMark.appIcon.
struct FluidVoiceBrandIcon: View {
    @Environment(\.theme) private var theme
    let size: CGFloat

    var body: some View {
        PichiBrandMark(size: self.size, color: self.theme.palette.accent)
    }
}
