import SwiftUI

/// Relative time belongs to the visible caption, rather than the library's static metadata cache.
struct FileTranscriptRelativeDateLabel: View {
    let entry: FileTranscriptionEntry
    let locale: Locale
    var refreshInterval: TimeInterval = 30
    @State private var isVisible = false
    @Environment(\.fluidPageToolbarVisible) private var isPageVisible

    var body: some View {
        Group {
            if self.isVisible && self.isPageVisible {
                TimelineView(.periodic(from: .now, by: self.refreshInterval)) { context in
                    self.label(relativeTo: context.date)
                }
            } else {
                self.label(relativeTo: .now)
            }
        }
        // LazyVStack may create rows before they enter the viewport.
        .onScrollVisibilityChange(threshold: 0.01) { self.isVisible = $0 }
        .onDisappear { self.isVisible = false }
    }

    private func label(relativeTo reference: Date) -> Text {
        Text(self.entry.relativeTimeString(locale: self.locale, relativeTo: reference))
    }
}
