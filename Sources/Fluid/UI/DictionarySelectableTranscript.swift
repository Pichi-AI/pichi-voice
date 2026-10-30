import AppKit
import Combine
import SwiftUI

/// Native selection exposes an exact range to the correction action while keeping
/// history read-only. The existing dictionary remains the sole recording editor.
struct DictionarySelectableTranscript: NSViewRepresentable {
    let text: NSAttributedString
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
        guard view.textStorage?.isEqual(to: self.text) != true else { return }
        let selection = view.selectedRange()
        view.textStorage?.setAttributedString(self.text)
        if selection.location <= self.text.length, selection.length <= self.text.length - selection.location {
            view.setSelectedRange(selection)
        }
        view.invalidateIntrinsicContentSize()
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
        view.onCorrect = nil
    }
}

final class DictionarySelectableTextView: NSTextView {
    var onCorrect: ((NSRange) -> Void)?

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = super.menu(for: event) ?? NSMenu()
        let range = self.selectedRange()
        if range.location != NSNotFound, range.length > 0, NSMaxRange(range) <= (self.string as NSString).length,
           DictionaryCorrectionEditPolicy.isTerm((self.string as NSString).substring(with: range)) {
            menu.addItem(.separator())
            let item = NSMenuItem(title: PichiLocalization.text("Correct word in dictionary…"), action: #selector(self.correctSelectedWord), keyEquivalent: "")
            item.target = self
            menu.addItem(item)
        }
        return menu
    }

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
