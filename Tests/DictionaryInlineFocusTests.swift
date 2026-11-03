import AppKit
import SwiftUI

@MainActor enum PichiLocalization { static func text(_ value: String) -> String { value } }
@MainActor enum DictionaryCorrectionEditPolicy { static func isTerm(_ value: String) -> Bool { !value.isEmpty } }

@MainActor final class InlineFocusState: ObservableObject {
    @Published var begins = 0
    @Published var fragments: [NSRange] = []
    var commits: [String] = []
}

private struct InlineFocusHost: View {
    @ObservedObject var state: InlineFocusState
    var body: some View {
        var view = DictionarySelectableTranscript(text: NSAttributedString(
            string: "Ёжик 🦔 Pech AI и Pech AI.", attributes: [.font: NSFont.systemFont(ofSize: 16)])) { _ in }
        view.inlineEditingEnabled = true
        view.fragmentRanges = state.fragments
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
        let glyphs = view.layoutManager!.glyphRange(forCharacterRange: last, actualCharacterRange: nil)
        let box = view.layoutManager!.boundingRect(forGlyphRange: glyphs, in: view.textContainer!)
        let point = view.convert(NSPoint(x: box.midX, y: box.midY), to: nil)
        let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 1,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)!
        let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 1.01,
            windowNumber: window.windowNumber, context: nil, eventNumber: 2, clickCount: 1, pressure: 0)!
        NSApp.postEvent(up, atStart: true)
        view.mouseDown(with: down)
        pump() // Includes the real SwiftUI update caused by onBeginEdit.
        guard let field = view.inlineEditor else { preconditionFailure("Editor survives SwiftUI state update") }
        precondition(window.firstResponder === field || window.firstResponder === field.currentEditor(),
                     "Inline field owns focus after the update")
        precondition(view.string.contains("\u{fffc}") && view.inlineEdit?.sourceText == source,
            "Only the display contains an attachment; the immutable source stays exact")
        view.layoutManager!.ensureLayout(for: view.textContainer!)
        let following = (view.string as NSString).range(of: "AI", options: .backwards)
        let followingBox = view.layoutManager!.boundingRect(forGlyphRange: view.layoutManager!.glyphRange(
            forCharacterRange: following, actualCharacterRange: nil), in: view.textContainer!)
            .offsetBy(dx: view.textContainerOrigin.x, dy: view.textContainerOrigin.y)
        let editorBox = field.superview!.frame
        precondition(followingBox.minY >= editorBox.maxY - 1 || followingBox.minX >= editorBox.maxX - 0.5,
            "TextKit reserves space for the field and both buttons instead of painting them over following text")
        // A late native end-edit notification must not close a currently focused editor.
        view.controlTextDidEndEditing(Notification(name: NSControl.textDidEndEditingNotification, object: field))
        pump()
        precondition(view.inlineEditor === field, "Late focus notification must not dismiss the active editor")
        field.stringValue = "Pichi"
        precondition(view.commitInlineEdit() && state.commits == ["Pichi"])
        precondition(view.inlineEditor == nil)
        let phrase = (source as NSString).range(of: "Pech AI", options: .backwards)
        let firstGlyphs = view.layoutManager!.glyphRange(forCharacterRange: NSRange(location: phrase.location, length: 1), actualCharacterRange: nil)
        let lastGlyphs = view.layoutManager!.glyphRange(forCharacterRange: NSRange(location: NSMaxRange(phrase) - 1, length: 1), actualCharacterRange: nil)
        let startBox = view.layoutManager!.boundingRect(forGlyphRange: firstGlyphs, in: view.textContainer!)
        let endBox = view.layoutManager!.boundingRect(forGlyphRange: lastGlyphs, in: view.textContainer!)
        let dragStart = view.convert(NSPoint(x: startBox.minX + 0.1, y: startBox.midY), to: nil)
        let dragEnd = view.convert(NSPoint(x: endBox.maxX - 0.1, y: endBox.midY), to: nil)
        func mouse(_ type: NSEvent.EventType, _ point: NSPoint, _ number: Int) -> NSEvent {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: 2 + Double(number) / 100,
                windowNumber: window.windowNumber, context: nil, eventNumber: number, clickCount: 1,
                pressure: type == .leftMouseUp ? 0 : 1)!
        }
        view.setSelectedRange(NSRange(location: 0, length: 0))
        NSApp.postEvent(mouse(.leftMouseUp, dragEnd, 12), atStart: true)
        NSApp.postEvent(mouse(.leftMouseDragged, dragEnd, 11), atStart: true)
        view.mouseDown(with: mouse(.leftMouseDown, dragStart, 10))
        pump()
        precondition(view.inlineEdit?.range == phrase && view.inlineEditor?.stringValue == "Pech AI",
            "Dragging across two fragments opens one whole-phrase editor after mouse release")
        view.inlineEditor!.stringValue = "Pichi AI"
        precondition(view.commitInlineEdit() && state.commits == ["Pichi", "Pichi AI"])
        precondition(view.beginInlineEdit(range: phrase)); pump()
        precondition(view.commitInlineEdit() && state.commits.last == "Pech AI" && state.commits.count == 3,
            "Saving unchanged words still confirms a newly merged phrase")
        precondition(view.beginInlineEdit(range: last)); pump()
        view.cancelInlineEdit(); pump()
        precondition(view.inlineEditor == nil && state.commits.count == 3, "Cancel must not save")
        precondition(view.beginInlineEdit(range: last)); pump()
        view.inlineEditor!.stringValue = "Must not save"
        let outside = mouse(.leftMouseDown, view.convert(NSPoint(x: 1, y: 1), to: nil), 20)
        view.mouseDown(with: outside)
        pump()
        precondition(view.inlineEditor == nil && state.commits.count == 3 && view.string == source,
            "A paragraph click cancels the edit, restores text flow, and does not open another word")
        state.fragments = [phrase]; pump()
        let groupEnd = (source as NSString).range(of: "AI", options: .backwards)
        let groupBox = view.layoutManager!.boundingRect(forGlyphRange: view.layoutManager!.glyphRange(
            forCharacterRange: groupEnd, actualCharacterRange: nil), in: view.textContainer!)
        let groupPoint = view.convert(NSPoint(x: groupBox.midX, y: groupBox.midY), to: nil)
        view.setSelectedRange(NSRange(location: 0, length: 0))
        NSApp.postEvent(mouse(.leftMouseUp, groupPoint, 22), atStart: true)
        view.mouseDown(with: mouse(.leftMouseDown, groupPoint, 21)); pump()
        precondition(view.inlineEdit?.range == phrase && view.inlineEditor?.stringValue == "Pech AI",
            "Clicking the second word of a saved fragment edits its complete range, including the space")
        view.cancelInlineEdit(); pump()
        precondition(view.beginInlineEdit(range: last)); pump()
        precondition(view.commitInlineEdit() && state.commits.count == 3,
            "An already grouped unchanged phrase does not write a duplicate group")
        precondition(view.beginInlineEdit(range: last)); pump()
        view.inlineEditor!.stringValue = "Blank click must cancel"
        NSApp.sendEvent(mouse(.leftMouseDown, NSPoint(x: 490, y: 79), 30))
        NSApp.sendEvent(mouse(.leftMouseUp, NSPoint(x: 490, y: 79), 31))
        pump()
        precondition(view.inlineEditor == nil && state.commits.count == 3,
            "A click in blank window space cancels through the scoped local monitor")
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
        let firstPhrase = (source as NSString).range(of: "Pech AI")
        state.fragments = [firstPhrase]; pump()
        view.setSelectedRange(firstPhrase)
        let conjunctionContext = (source as NSString).range(of: " и ")
        let conjunction = NSRange(location: conjunctionContext.location + 1, length: 1)
        let firstBox = view.layoutManager!.boundingRect(forGlyphRange: view.layoutManager!.glyphRange(
            forCharacterRange: NSRange(location: firstPhrase.location, length: 1), actualCharacterRange: nil), in: view.textContainer!)
        let conjunctionBox = view.layoutManager!.boundingRect(forGlyphRange: view.layoutManager!.glyphRange(
            forCharacterRange: conjunction, actualCharacterRange: nil), in: view.textContainer!)
        let extendStart = view.convert(NSPoint(x: firstBox.minX + 0.1, y: firstBox.midY), to: nil)
        let extendEnd = view.convert(NSPoint(x: conjunctionBox.maxX - 0.1, y: conjunctionBox.midY), to: nil)
        NSApp.postEvent(mouse(.leftMouseUp, extendEnd, 42), atStart: true)
        NSApp.postEvent(mouse(.leftMouseDragged, extendEnd, 41), atStart: true)
        view.mouseDown(with: mouse(.leftMouseDown, extendStart, 40)); pump()
        precondition(view.inlineEditor?.stringValue == "Pech AI и", "A drag can extend an already selected saved fragment")
        view.cancelInlineEdit()
        window.close()
        print("PASS: reserved editor flow, outside cancellation, saved compound hit-testing, multiword drag and focus survive SwiftUI updates and late notifications; save, cancel, focus loss and stale identity")
    }
}
