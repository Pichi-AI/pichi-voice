import AppKit
import SwiftUI

@MainActor enum PichiLocalization { static func text(_ value: String) -> String { value } }
@MainActor enum DictionaryCorrectionEditPolicy { static func isTerm(_ value: String) -> Bool { !value.isEmpty } }

@MainActor final class InlineFocusState: ObservableObject {
    @Published var begins = 0
    var commits: [String] = []
}

private struct InlineFocusHost: View {
    @ObservedObject var state: InlineFocusState
    var body: some View {
        var view = DictionarySelectableTranscript(text: NSAttributedString(
            string: "Ёжик 🦔 Pech и Pech.", attributes: [.font: NSFont.systemFont(ofSize: 16)])) { _ in }
        view.inlineEditingEnabled = true
        view.interactionIdentity = "stable-source"
        view.onBeginEdit = { _ in state.begins += 1; return true }
        view.onEdit = { _, value in state.commits.append(value); return true }
        return view.frame(width: 500, height: 60).id("source")
    }
}

@main struct DictionaryInlineFocusTests {
    @MainActor static func main() {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        let state = InlineFocusState()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 80),
                              styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: InlineFocusHost(state: state))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func pump() { RunLoop.main.run(until: Date().addingTimeInterval(0.1)); host.layoutSubtreeIfNeeded() }
        func find(_ root: NSView) -> DictionarySelectableTextView? {
            if let view = root as? DictionarySelectableTextView { return view }
            return root.subviews.lazy.compactMap { find($0) }.first
        }
        pump()
        guard let view = find(host) else { preconditionFailure("Native transcript must be mounted") }
        let source = view.string
        let last = (source as NSString).range(of: "Pech", options: .backwards)
        precondition(view.beginInlineEdit(range: last))
        pump() // Includes the real SwiftUI update caused by onBeginEdit.
        guard let field = view.inlineEditor else { preconditionFailure("Editor survives SwiftUI state update") }
        precondition(window.firstResponder === field || window.firstResponder === field.currentEditor(),
                     "Inline field owns focus after the update")
        // A late native end-edit notification must not close a currently focused editor.
        view.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        pump()
        precondition(view.inlineEditor === field, "Late focus notification must not dismiss the active editor")
        field.stringValue = "Pichi"
        precondition(view.commitInlineEdit() && state.commits == ["Pichi"])
        precondition(view.inlineEditor == nil)
        precondition(view.beginInlineEdit(range: last)); pump()
        view.cancelInlineEdit(); pump()
        precondition(view.inlineEditor == nil && state.commits.count == 1, "Cancel must not save")
        precondition(view.beginInlineEdit(range: last)); pump()
        guard let losingField = view.inlineEditor else { preconditionFailure() }
        window.makeFirstResponder(view)
        view.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: losingField))
        pump()
        precondition(view.inlineEditor == nil, "Genuine focus loss dismisses the editor")
        precondition(view.beginInlineEdit(range: last)); pump()
        view.configureInlineEditing(enabled: true, identity: "another-entry", accentColor: .systemPurple,
                                    backgroundColor: .white, textColor: .black)
        pump()
        precondition(view.inlineEditor == nil && !view.commitInlineEdit(), "Stale entry cancels without saving")
        window.close()
        print("PASS: native inline focus survives SwiftUI updates and late notifications; save, cancel, focus loss and stale identity")
    }
}
