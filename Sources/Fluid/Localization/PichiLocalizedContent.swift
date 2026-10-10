import SwiftUI

/// Keep independent NSHostingView surfaces in sync without recreating their state.
struct PichiLocalizedContent<Content: View>: View {
    @ObservedObject private var settings = SettingsStore.shared
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        self.content.environment(\.locale, PichiLocalization.locale)
            .environment(\.layoutDirection, PichiLocalization.language.usesRightToLeftLayout ? .rightToLeft : .leftToRight)
    }
}
