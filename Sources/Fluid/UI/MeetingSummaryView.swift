import AppKit
import SwiftUI

struct MeetingSummaryView: View {
    var session: MeetingSession? = nil
    var asrService: ASRService? = nil
    var isQuiescent = true
    var body: some View {
        PichiMeetingSummaryView(session: self.session, asrService: self.asrService, isQuiescent: self.isQuiescent)
    }
}

/// Marks a text editor in the app's own window as somewhere dictation may write. Dictated text
/// otherwise goes to other apps, and inside the app only to the sidebar search field.
struct DictationTextTarget: NSViewRepresentable {
    final class Marker: NSView {
        override func hitTest(_: NSPoint) -> NSView? { nil }
    }

    func makeNSView(context _: Context) -> Marker { Marker() }
    func updateNSView(_: Marker, context _: Context) {}

    /// True when `editor` lies on a marker. SwiftUI hosts a background view and the editor it
    /// backs under a shared ancestor a few levels up, with the same frame.
    static func accepts(_ editor: NSTextView) -> Bool {
        guard editor.isEditable, !editor.isFieldEditor else { return false }
        let editorView: NSView = editor.enclosingScrollView ?? editor
        var ancestor = editorView.superview
        for _ in 0..<6 {
            guard let current = ancestor else { return false }
            let editorFrame = editorView.convert(editorView.bounds, to: current)
            var pending = current.subviews
            while let view = pending.popLast() {
                if view is Marker, view.convert(view.bounds, to: current).insetBy(dx: -2, dy: -2).contains(editorFrame) {
                    return true
                }
                pending.append(contentsOf: view.subviews)
            }
            ancestor = current.superview
        }
        return false
    }
}
