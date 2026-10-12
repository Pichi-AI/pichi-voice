import AppKit
import SwiftUI

/// Keep long transcripts out of SwiftUI's unconstrained Text measurement path.
/// AppKit lays out the viewport and retains its text storage across parent updates.
struct FileTranscriptTextView: NSViewRepresentable {
    @Environment(\.locale) private var interfaceLocale
    let entryID: UUID
    let text: String
    @Environment(\.theme) private var theme

    func makeNSView(context: Context) -> FileTranscriptScrollView {
        FileTranscriptScrollView(frame: .zero)
    }

    func updateNSView(_ view: FileTranscriptScrollView, context: Context) {
        // Only the UI label changes with locale; display() retains document selection and scroll.
        view.documentView?.setAccessibilityLabel(PichiLocalization.text("Transcript", locale: self.interfaceLocale))
        view.display(
            entryID: self.entryID,
            text: self.text,
            font: .fluidSystemFont(ofSize: 14),
            color: NSColor(self.theme.palette.primaryText),
            inset: self.theme.metrics.spacing.lg
        )
    }
}
