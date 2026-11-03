import AppKit
import Combine
import SwiftUI

/// A transcript can opt into a temporary word editor. The history owner checks
/// and persists the exact occurrence without changing the original model bytes.
struct DictionarySelectableTranscript: NSViewRepresentable {
    let text: NSAttributedString
    var inlineEditingEnabled = false
    var fragmentRanges: [NSRange] = []
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
        view.updateDisplayedText(self.text, fragments: self.fragmentRanges)
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
    private var sourceText = NSAttributedString(string: "")
    private var groupedRanges: [NSRange] = []
    private var dismissMouseMonitor: Any?
    private var resignKeyObserver: NSObjectProtocol?
    private var isUpdatingEditorLayout = false
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
        self.editorContainer?.layer?.backgroundColor = backgroundColor.cgColor
        if !enabled { self.hoveredRange = nil }
        self.needsDisplay = true
    }

    func updateDisplayedText(_ text: NSAttributedString, fragments: [NSRange] = []) {
        let groups = fragments.filter { DictionaryInlineTextEdit(sourceText: text.string, range: $0) != nil }
        guard !self.sourceText.isEqual(to: text) || groups != self.groupedRanges else { return }
        if self.sourceText.string != text.string || groups != self.groupedRanges { self.cancelInlineEdit(notify: false) }
        let selection = self.selectedRange()
        self.sourceText = NSAttributedString(attributedString: text)
        self.groupedRanges = groups
        self.wordRanges = DictionaryInlineTextEdit.editingRanges(in: text.string, fragments: groups)
        self.hoveredRange = nil
        if self.inlineEdit != nil {
            self.updateEditorLayout()
        } else {
            self.textStorage?.setAttributedString(text)
            if selection.location <= text.length, selection.length <= text.length - selection.location {
                self.setSelectedRange(selection)
            }
        }
        self.invalidateIntrinsicContentSize()
    }

    override func layout() {
        super.layout()
        self.positionEditor()
    }

    override func setFrameSize(_ newSize: NSSize) {
        let widthChanged = abs(newSize.width - self.bounds.width) > 0.5
        super.setFrameSize(newSize)
        if widthChanged, self.inlineEdit != nil { self.updateEditorLayout() }
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
            self.accentColor.withAlphaComponent(0.26).setFill()
            manager.enumerateEnclosingRects(forGlyphRange: glyphs, withinSelectedGlyphRange: NSRange(location: NSNotFound, length: 0),
                                           in: container) { box, _ in
                let highlight = box.offsetBy(dx: self.textContainerOrigin.x, dy: self.textContainerOrigin.y)
                    .insetBy(dx: -2, dy: -1)
                let path = NSBezierPath(roundedRect: highlight, xRadius: 3, yRadius: 3)
                path.fill()
                self.accentColor.withAlphaComponent(0.55).setStroke()
                path.lineWidth = 0.75
                path.stroke()
            }
        }
        super.draw(dirtyRect)
    }

    override func mouseDown(with event: NSEvent) {
        if self.inlineEdit != nil {
            self.cancelInlineEdit()
            return
        }
        let point = self.convert(event.locationInWindow, from: nil)
        let clicked = self.wordRange(at: point)
        let previousSelection = self.selectedRange()
        if self.inlineEditingEnabled, event.clickCount == 1, !event.modifierFlags.contains(.shift), previousSelection.length > 0 {
            self.setSelectedRange(NSRange(location: previousSelection.location, length: 0))
        }
        super.mouseDown(with: event) // Native selection tracking owns the multiword gesture.
        guard self.inlineEditingEnabled, event.clickCount == 1, !event.modifierFlags.contains(.shift),
              let clicked else { return }
        let selection = self.selectedRange()
        let range: NSRange
        if selection.length > 0 {
            guard let phrase = DictionaryInlineTextEdit.phraseRange(for: selection, in: self.wordRanges) else { return }
            range = phrase
        } else {
            range = previousSelection.length > 0 && NSIntersectionRange(previousSelection, clicked).length > 0
                ? previousSelection : clicked
        }
        // Finish NSTextView's native mouse tracking before handing focus to a
        // field editor. Otherwise the same click can take that focus back.
        let source = self.string
        let identity = self.interactionIdentity
        DispatchQueue.main.async { [weak self] in
            guard let self, self.string == source, self.interactionIdentity == identity else { return }
            self.beginInlineEdit(range: range)
        }
    }

    override func keyDown(with event: NSEvent) {
        if self.inlineEditingEnabled, event.keyCode == 36 || event.keyCode == 76,
           self.beginInlineEdit(range: DictionaryInlineTextEdit.phraseRange(for: self.selectedRange(), in: self.wordRanges) ?? self.selectedRange()) { return }
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
    func beginInlineEdit(range requestedRange: NSRange) -> Bool {
        let range = DictionaryInlineTextEdit.phraseRange(for: requestedRange, in: self.wordRanges) ?? requestedRange
        guard self.inlineEditingEnabled, self.onEdit != nil,
              let edit = DictionaryInlineTextEdit(sourceText: self.sourceText.string, range: range),
              self.bounds.width >= 90 else { return false }
        self.cancelInlineEdit()
        guard self.onBeginEdit?(range) != false else { return false }
        self.inlineEdit = edit
        self.hoveredRange = nil
        let field = NSTextField(string: edit.heardText)
        field.font = self.sourceText.attribute(.font, at: range.location, effectiveRange: nil) as? NSFont ?? self.font
        field.textColor = self.editorTextColor
        field.backgroundColor = self.editorBackgroundColor
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .exterior
        field.delegate = self
        field.setAccessibilityLabel(PichiLocalization.text("Edit selected word"))
        field.toolTip = PichiLocalization.text("Press Return to save or Escape to cancel.")
        field.identifier = NSUserInterfaceItemIdentifier("history.dictionary.inlineWord")
        field.cell?.isScrollable = true
        field.usesSingleLineMode = true
        let holder = NSView()
        holder.wantsLayer = true
        holder.layer?.backgroundColor = self.editorBackgroundColor.cgColor
        holder.layer?.cornerRadius = 5
        holder.addSubview(field)
        let save = self.inlineButton(symbol: "checkmark", label: "Save correction", action: #selector(self.commitInlineWord))
        let cancel = self.inlineButton(symbol: "xmark", label: "Cancel", action: #selector(self.cancelInlineWord))
        holder.addSubview(save)
        holder.addSubview(cancel)
        self.editorContainer = holder
        self.inlineEditor = field
        self.addSubview(holder)
        self.updateEditorLayout()
        self.installDismissMonitor()
        self.window?.makeFirstResponder(field)
        field.selectText(nil)
        // onBeginEdit can schedule a SwiftUI update in the same event cycle.
        // Restore focus only for this still-current editor after that update.
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self, let field, self.inlineEditor === field else { return }
            self.window?.makeFirstResponder(field)
        }
        self.needsDisplay = true
        return true
    }

    private func inlineButton(symbol: String, label: String, action: Selector) -> NSButton {
        let size = max(9, (self.font?.pointSize ?? NSFont.systemFontSize) * 0.72)
        let image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: .semibold)) ?? NSImage()
        let button = NSButton(image: image, target: self, action: action)
        button.bezelStyle = .inline
        button.isBordered = false
        button.contentTintColor = self.accentColor
        button.setAccessibilityLabel(PichiLocalization.text(label))
        button.toolTip = PichiLocalization.text(label)
        return button
    }

    /// Only the display replaces the selected term with an attachment. TextKit
    /// reserves the control's width and moves following text around it.
    private func updateEditorLayout() {
        guard !self.isUpdatingEditorLayout, let edit = self.inlineEdit, let field = self.inlineEditor,
              let holder = self.editorContainer, self.bounds.width >= 90 else { return }
        self.isUpdatingEditorLayout = true
        defer { self.isUpdatingEditorLayout = false }
        let font = field.font ?? NSFont.systemFont(ofSize: NSFont.systemFontSize)
        let textWidth = (edit.heardText as NSString).size(withAttributes: [.font: font]).width
        let width = min(max(150, textWidth + 64), min(400, self.bounds.width))
        let height = max(24, ceil(font.ascender - font.descender + 6))
        let bounds = NSRect(x: 0, y: (font.ascender + font.descender - height) / 2, width: width, height: height)
        let attachment = NSTextAttachment(data: nil, ofType: nil)
        attachment.allowsTextAttachmentView = false
        attachment.bounds = bounds
        attachment.attachmentCell = InlineEditorAttachmentCell(bounds: bounds)
        let display = NSMutableAttributedString(attributedString: self.sourceText)
        let placeholder = NSMutableAttributedString(attachment: attachment)
        if self.sourceText.length > edit.range.location {
            placeholder.addAttributes(self.sourceText.attributes(at: edit.range.location, effectiveRange: nil), range: NSRange(location: 0, length: 1))
        }
        display.replaceCharacters(in: edit.range, with: placeholder)
        self.textStorage?.setAttributedString(display)
        holder.setFrameSize(NSSize(width: width, height: height))
        field.frame = NSRect(x: 0, y: 0, width: width - 48, height: height)
        if holder.subviews.count >= 3 {
            holder.subviews[1].frame = NSRect(x: width - 46, y: 0, width: 22, height: height)
            holder.subviews[2].frame = NSRect(x: width - 22, y: 0, width: 22, height: height)
        }
        self.invalidateIntrinsicContentSize()
        self.positionEditor()
        self.needsLayout = true
    }

    private func positionEditor() {
        guard let edit = self.inlineEdit, let holder = self.editorContainer,
              let manager = self.layoutManager, let container = self.textContainer,
              edit.range.location < (self.textStorage?.length ?? 0) else { return }
        manager.ensureLayout(for: container)
        let glyphs = manager.glyphRange(forCharacterRange: NSRange(location: edit.range.location, length: 1), actualCharacterRange: nil)
        let box = manager.boundingRect(forGlyphRange: glyphs, in: container)
        holder.setFrameOrigin(NSPoint(x: box.minX + self.textContainerOrigin.x, y: box.minY + self.textContainerOrigin.y))
    }

    private func installDismissMonitor() {
        self.dismissMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self, self.inlineEdit != nil, event.window === self.window, let holder = self.editorContainer else { return event }
            let point = holder.convert(event.locationInWindow, from: nil)
            guard !holder.bounds.contains(point) else { return event }
            let inParagraph = self.bounds.contains(self.convert(event.locationInWindow, from: nil))
            self.cancelInlineEdit()
            return inParagraph ? nil : event // A paragraph click cancels, without opening another word.
        }
        if let window = self.window {
            self.resignKeyObserver = NotificationCenter.default.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.cancelInlineEdit() }
            }
        }
    }

    @objc private func commitInlineWord() { _ = self.commitInlineEdit() }
    @objc private func cancelInlineWord() { self.cancelInlineEdit() }

    @discardableResult
    func commitInlineEdit() -> Bool {
        guard let edit = self.inlineEdit, let field = self.inlineEditor,
              self.sourceText.string == edit.sourceText,
              edit.replacing(with: field.stringValue) != nil else { self.cancelInlineEdit(); return false }
        let replacement = field.stringValue
        if replacement == edit.heardText,
           DictionaryInlineTextEdit.wordRanges(in: replacement).count < 2 || self.groupedRanges.contains(edit.range) {
            self.cancelInlineEdit(); return true
        }
        guard self.onEdit?(edit.range, replacement) == true else {
            self.cancelInlineEdit()
            return false
        }
        self.cancelInlineEdit()
        return true
    }

    func cancelInlineEdit(notify: Bool = true) {
        let wasEditing = self.inlineEdit != nil
        if let monitor = self.dismissMouseMonitor { NSEvent.removeMonitor(monitor) }
        self.dismissMouseMonitor = nil
        if let observer = self.resignKeyObserver { NotificationCenter.default.removeObserver(observer) }
        self.resignKeyObserver = nil
        self.inlineEditor?.delegate = nil
        if self.window?.firstResponder === self.inlineEditor?.currentEditor() {
            self.window?.makeFirstResponder(self)
        }
        self.inlineEditor = nil
        self.inlineEdit = nil
        self.editorContainer?.removeFromSuperview()
        self.editorContainer = nil
        if wasEditing { self.textStorage?.setAttributedString(self.sourceText); self.invalidateIntrinsicContentSize() }
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
            if let responder = self.window?.firstResponder,
               responder === field || responder === field.currentEditor() { return }
            if let responder = self.window?.firstResponder as? NSView, let holder = self.editorContainer,
               responder.isDescendant(of: holder) { return }
            self.cancelInlineEdit()
        }
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let range = DictionaryInlineTextEdit.phraseRange(for: self.selectedRange(), in: self.wordRanges) ?? self.selectedRange()
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
        let range = DictionaryInlineTextEdit.phraseRange(for: self.selectedRange(), in: self.wordRanges) ?? self.selectedRange()
        guard range.location != NSNotFound, range.length > 0,
              NSMaxRange(range) <= (self.string as NSString).length,
              DictionaryCorrectionEditPolicy.isTerm((self.string as NSString).substring(with: range)) else { return }
        self.onCorrect?(range)
    }

    isolated deinit {
        if let monitor = self.dismissMouseMonitor { NSEvent.removeMonitor(monitor) }
        if let observer = self.resignKeyObserver { NotificationCenter.default.removeObserver(observer) }
    }
}

/// TextKit 1 asks the attachment cell for geometry, including during independent
/// SwiftUI measurement. Immutable metrics also support background measurement.
private final class InlineEditorAttachmentCell: NSTextAttachmentCell {
    nonisolated let reservedBounds: NSRect
    init(bounds: NSRect) { self.reservedBounds = bounds; super.init(textCell: "") }
    required init(coder: NSCoder) { self.reservedBounds = .zero; super.init(coder: coder) }
    nonisolated override func cellSize() -> NSSize { self.reservedBounds.size }
    nonisolated override func cellBaselineOffset() -> NSPoint { self.reservedBounds.origin }
    override func draw(withFrame frame: NSRect, in controlView: NSView?) {}
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
