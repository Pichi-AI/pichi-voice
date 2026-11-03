import AppKit
import Combine
import SwiftUI

/// The original transcript stays read-only. Final text can opt into a temporary
/// word editor; the history owner checks and persists the exact occurrence.
struct DictionarySelectableTranscript: NSViewRepresentable {
    let text: NSAttributedString
    var inlineEditingEnabled = false
    var interactionIdentity = ""
    var accentColor: NSColor = .controlAccentColor
    var editorBackgroundColor: NSColor = .textBackgroundColor
    var editorTextColor: NSColor = .textColor
    var onBeginEdit: ((NSRange) -> Bool)?
    var onEndEdit: (() -> Void)?
    var onEdit: ((NSRange, String) -> Bool)?
    let onCorrect: (NSRange) -> Void

    func makeNSView(context: Context) -> DictionarySelectableTextView {
        let view = DictionarySelectableTextView(frame: .zero)
        view.isEditable = false
        view.isSelectable = true
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = true
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = true
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        view.setAccessibilityIdentifier("history.dictionary.selectableText")
        return view
    }

    func updateNSView(_ view: DictionarySelectableTextView, context: Context) {
        view.onCorrect = self.onCorrect
        view.onBeginEdit = self.onBeginEdit
        view.onEndEdit = self.onEndEdit
        view.onEdit = self.onEdit
        view.configureInlineEditing(
            enabled: self.inlineEditingEnabled,
            identity: self.interactionIdentity,
            accentColor: self.accentColor,
            backgroundColor: self.editorBackgroundColor,
            textColor: self.editorTextColor
        )
        view.updateDisplayedText(self.text)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: DictionarySelectableTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        // SwiftUI can measure several proposals after assigning the final frame.
        // Measuring the live container would leave it wrapped at the last probe's
        // width even though the displayed text view has a different width.
        let storage = NSTextStorage(attributedString: view.attributedString())
        let manager = NSLayoutManager()
        let container = NSTextContainer(size: NSSize(width: width, height: .greatestFiniteMagnitude))
        container.lineFragmentPadding = 0
        manager.addTextContainer(container)
        storage.addLayoutManager(manager)
        manager.ensureLayout(for: container)
        return CGSize(width: width, height: max(22, ceil(manager.usedRect(for: container).height)))
    }

    static func dismantleNSView(_ view: DictionarySelectableTextView, coordinator: ()) {
        view.cancelInlineEdit(notify: false)
        view.onCorrect = nil
        view.onEdit = nil
        view.onBeginEdit = nil
        view.onEndEdit = nil
    }
}

final class DictionarySelectableTextView: NSTextView, NSTextFieldDelegate {
    var onCorrect: ((NSRange) -> Void)?
    var onBeginEdit: ((NSRange) -> Bool)?
    var onEndEdit: (() -> Void)?
    var onEdit: ((NSRange, String) -> Bool)?
    private(set) var inlineEdit: DictionaryInlineTextEdit?
    private(set) var inlineEditor: NSTextField?
    private var editorContainer: NSView?
    private var tracking: NSTrackingArea?
    private var wordRanges: [NSRange] = []
    private var hoveredRange: NSRange?
    private var inlineEditingEnabled = false
    private var interactionIdentity = ""
    private var accentColor = NSColor.controlAccentColor
    private var editorBackgroundColor = NSColor.textBackgroundColor
    private var editorTextColor = NSColor.textColor

    func configureInlineEditing(
        enabled: Bool, identity: String, accentColor: NSColor,
        backgroundColor: NSColor, textColor: NSColor
    ) {
        if !enabled || identity != self.interactionIdentity { self.cancelInlineEdit(notify: false) }
        self.inlineEditingEnabled = enabled
        self.interactionIdentity = identity
        self.accentColor = accentColor
        self.editorBackgroundColor = backgroundColor
        self.editorTextColor = textColor
        self.inlineEditor?.backgroundColor = backgroundColor
        self.inlineEditor?.textColor = textColor
        if !enabled { self.hoveredRange = nil }
        self.needsDisplay = true
    }

    func updateDisplayedText(_ text: NSAttributedString) {
        guard self.textStorage?.isEqual(to: text) != true else { return }
        if self.string != text.string { self.cancelInlineEdit(notify: false) }
        let selection = self.selectedRange()
        self.textStorage?.setAttributedString(text)
        self.wordRanges = DictionaryInlineTextEdit.wordRanges(in: text.string)
        self.hoveredRange = nil
        if selection.location <= text.length, selection.length <= text.length - selection.location {
            self.setSelectedRange(selection)
        }
        self.invalidateIntrinsicContentSize()
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { self.removeTrackingArea(tracking) }
        let tracking = NSTrackingArea(
            rect: .zero, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
            owner: self, userInfo: nil
        )
        self.addTrackingArea(tracking)
        self.tracking = tracking
    }

    override func mouseMoved(with event: NSEvent) {
        guard self.inlineEditingEnabled, self.inlineEdit == nil else { return }
        let range = self.wordRange(at: self.convert(event.locationInWindow, from: nil))
        guard range != self.hoveredRange else { return }
        self.hoveredRange = range
        self.needsDisplay = true
    }

    override func mouseExited(with event: NSEvent) {
        self.hoveredRange = nil
        self.needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        // NSTextView skips drawBackground when drawsBackground is false.
        // Paint the decoration before native glyphs, without changing source attributes.
        if self.inlineEdit == nil, let range = self.hoveredRange,
           let manager = self.layoutManager, let container = self.textContainer {
            let glyphs = manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil)
            self.accentColor.withAlphaComponent(0.11).setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { box, _ in
                let highlight = box.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                    .insetBy(dx: -2, dy: -1)
                NSBezierPath(roundedRect: highlight, xRadius: 3, yRadius: 3).fill()
            }
        }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        let point = self.convert(event.locationInWindow, from: nil)
        let clicked = self.wordRange(at: point)
        let previousSelection = self.selectedRange()
        super.mouseDown(with: event) // Native text dragging and multiword selection stay intact.
        guard self.inlineEditingEnabled, event.clickCount == 1, !event.modifierFlags.contains(.shift),
              self.selectedRange().length == 0,
              let clicked,
              let mouse = self.window?.mouseLocationOutsideOfEventStream else { return }
        let released = self.convert(mouse, from: nil)
        guard hypot(released.x - point.x, released.y - point.y) < 4 else { return }
        let range = previousSelection.length > 0 && NSIntersectionRange(previousSelection, clicked).length > 0
            ? previousSelection : clicked
        self.beginInlineEdit(range: range)
    }

    override func keyDown(with event: NSEvent) {
        if self.inlineEditingEnabled, event.keyCode == 36 || event.keyCode == 76,
           self.beginInlineEdit(range: self.selectedRange()) { return }
        super.keyDown(with: event)
    }

    private func wordRange(at point: NSPoint) -> NSRange? {
        guard self.inlineEditingEnabled, let manager = self.layoutManager,
              let container = self.textContainer, manager.numberOfGlyphs > 0 else { return nil }
        let position = NSPoint(x: point.x - self.textContainerOrigin.x, y: point.y - self.textContainerOrigin.y)
        let glyph = manager.glyphIndex(for: position, in: container)
        guard glyph < manager.numberOfGlyphs,
              let range = DictionaryInlineTextEdit.wordRange(at: manager.characterIndexForGlyph(at: glyph), in: self.wordRanges),
              manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
                .contains(position) else { return nil }
        return range
    }

    @discardableResult
    func beginInlineEdit(range: NSRange) -> Bool {
        guard self.inlineEditingEnabled, self.onEdit != nil,
              let edit = DictionaryInlineTextEdit(sourceText: self.string, range: range),
              let manager = self.layoutManager, let container = self.textContainer,
              self.bounds.width >= 90 else { return false }
        self.cancelInlineEdit()
        guard self.onBeginEdit?(range) != false else { return false }
        self.inlineEdit = edit
        self.hoveredRange = nil
        let field = NSTextField(string: edit.heardText)
        field.font = self.textStorage?.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? self.font
        field.textColor = self.editorTextColor
        field.backgroundColor = self.editorBackgroundColor
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = self
        field.setAccessibilityLabel(PichiLocalization.text("Edit selected word"))
        field.toolTip = PichiLocalization.text("Press Return to save or Escape to cancel.")
        field.identifier = NSUserInterfaceItemIdentifier("history.dictionary.inlineWord")
        let holder = NSView()
        holder.addSubview(field)
        let save = self.inlineButton(symbol: "checkmark", label: "Save correction", action: #selector(self.commitInlineWord))
        let cancel = self.inlineButton(symbol: "xmark", label: "Cancel", action: #selector(self.cancelInlineWord))
        holder.addSubview(save)
        holder.addSubview(cancel)
        let box = manager.boundingRect(forGlyphRange: manager.glyphRange(forCharacterRange: range, actualCharacterRange: nil), in: container)
        let height = min(max(22, box.height + 4), self.bounds.height)
        let width = min(max(150, box.width + 76), self.bounds.width)
        let x = min(max(0, box.minX + self.textContainerOrigin.x - 4), max(0, self.bounds.width - width))
        holder.frame = NSRect(x: x, y: min(max(0, box.minY + self.textContainerOrigin.y - 2), max(0, self.bounds.height - height)), width: width, height: height)
        field.frame = NSRect(x: 0, y: 0, width: width - 52, height: height)
        save.frame = NSRect(x: width - 50, y: 0, width: 24, height: height)
        cancel.frame = NSRect(x: width - 24, y: 0, width: 24, height: height)
        self.editorContainer = holder
        self.inlineEditor = field
        self.addSubview(holder)
        self.window?.makeFirstResponder(field)
        field.selectText(nil)
        self.needsDisplay = true
        return true
    }

    private func inlineButton(symbol: String, label: String, action: Selector) -> NSButton {
        let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage(), target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = self.accentColor
        button.setAccessibilityLabel(PichiLocalization.text(label))
        button.toolTip = PichiLocalization.text(label)
        return button
    }

    @objc private func commitInlineWord() { _ = self.commitInlineEdit() }
    @objc private func cancelInlineWord() { self.cancelInlineEdit() }

    @discardableResult
    func commitInlineEdit() -> Bool {
        guard let edit = self.inlineEdit, let field = self.inlineEditor,
              self.string == edit.sourceText,
              edit.replacing(with: field.stringValue) != nil else { self.cancelInlineEdit(); return false }
        let replacement = field.stringValue
        if replacement == edit.heardText { self.cancelInlineEdit(); return true }
        guard self.onEdit?(edit.range, replacement) == true else {
            self.cancelInlineEdit()
            return false
        }
        self.cancelInlineEdit()
        return true
    }

    func cancelInlineEdit(notify: Bool = true) {
        let wasEditing = self.inlineEdit != nil
        self.inlineEditor?.delegate = nil
        if self.window?.firstResponder === self.inlineEditor?.currentEditor() {
            self.window?.makeFirstResponder(self)
        }
        self.inlineEditor = nil
        self.inlineEdit = nil
        self.editorContainer?.removeFromSuperview()
        self.editorContainer = nil
        self.needsDisplay = true
        if wasEditing, notify { self.onEndEdit?() }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            _ = self.commitInlineEdit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            self.cancelInlineEdit()
            return true
        }
        return false
    }

    func controlTextDidEndEditing(_ notification: Notification) {
        guard let field = notification.object as? NSTextField else { return }
        // A Save button action may follow the field's end-editing notification.
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.inlineEditor === field else { return }
            self.cancelInlineEdit()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let range = self.selectedRange()
        if self.inlineEditingEnabled, DictionaryInlineTextEdit(sourceText: self.string, range: range) != nil {
            menu.addItem(.separator())
            let item = NSMenuItem(title: PichiLocalization.text("Edit selected word"), action: #selector(self.editSelectedWord), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        if range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= (self.string as NSString).length,
           DictionaryCorrectionEditPolicy.isTerm((self.string as NSString).substring(with: range)) {
            menu.addItem(.separator())
            let item = NSMenuItem(title: PichiLocalization.text("Correct word in dictionary…"), action: #selector(self.correctSelectedWord), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

    @objc private func editSelectedWord() { self.beginInlineEdit(range: self.selectedRange()) }

    @objc private func correctSelectedWord() {
        let range = self.selectedRange()
        guard range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= (self.string as NSString).length,
              DictionaryCorrectionEditPolicy.isTerm((self.string as NSString).substring(with: range)) else { return }
        self.onCorrect?(range)
    }
}

/// A minimized stale window must not consume a handoff opened in a new window.
final class DictionaryTrainingWindowReference: ObservableObject {
    weak var window: NSWindow?

    func update(_ window: NSWindow?) {
        guard self.window !== window else { return }
        self.window = window
        self.objectWillChange.send()
    }
}

struct DictionaryTrainingWindowReader: NSViewRepresentable {
    let reference: DictionaryTrainingWindowReference

    func makeNSView(context: Context) -> WindowView {
        let view = WindowView()
        view.reference = self.reference
        return view
    }

    func updateNSView(_ view: WindowView, context: Context) {
        view.reference = self.reference
    }

    final class WindowView: NSView {
        weak var reference: DictionaryTrainingWindowReference?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.reference?.update(self.window)
            }
        }
    }
}
