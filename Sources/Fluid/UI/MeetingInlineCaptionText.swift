import SwiftUI
#if os(iOS)
import UIKit
private typealias InlineCaptionFont = UIFont
private typealias InlineCaptionColor = UIColor
private typealias InlineCaptionImage = UIImage
private typealias InlineCaptionNativeView = UIView
#else
import AppKit
private typealias InlineCaptionFont = NSFont
private typealias InlineCaptionColor = NSColor
private typealias InlineCaptionImage = NSImage
private typealias InlineCaptionNativeView = NSView
#endif

/// Only the active paragraph needs native attachments: TextKit wraps each existing waveform
/// like a word immediately after its text. Attachment characters stay inside this view.
struct MeetingInlineCaptionText: View {
    let rows: [MeetingLiveBubbleComposer.Row]
    let pending: MeetingPendingSpeechSnapshot
    var documentStyle = true

    @Environment(\.theme) private var theme
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.layoutDirection) private var layoutDirection
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .body) private var wordHeight: CGFloat = 18
    @ScaledMetric(relativeTo: .body) private var wordWidth: CGFloat = 56

    var body: some View {
        InlineCaptionNativeText(configuration: InlineCaptionConfiguration(
            rows: self.rows, pending: self.pending, documentStyle: self.documentStyle,
            theme: self.theme, dynamicTypeSize: self.dynamicTypeSize,
            scenePhase: self.scenePhase, layoutDirection: self.layoutDirection,
            reduceMotion: self.reduceMotion, wordSize: CGSize(width: self.wordWidth, height: self.wordHeight)))
            .accessibilityHidden(true)
    }
}

private struct InlineCaptionConfiguration {
    let rows: [MeetingLiveBubbleComposer.Row]
    let pending: MeetingPendingSpeechSnapshot
    let documentStyle: Bool
    let theme: AppTheme
    let dynamicTypeSize: DynamicTypeSize
    let scenePhase: ScenePhase
    let layoutDirection: LayoutDirection
    let reduceMotion: Bool
    let wordSize: CGSize

    var font: InlineCaptionFont {
        #if os(iOS)
        // UIKit counterpart of the shared body role. Match the current SwiftUI Dynamic Type
        // environment, including previews and per-window overrides, rather than global traits.
        let size = documentStyle
            ? UIFont.preferredFont(forTextStyle: .body,
                compatibleWith: UITraitCollection(preferredContentSizeCategory: dynamicTypeSize.contentSizeCategory)).pointSize
            : 15
        let design: Font.Design = documentStyle ? .default : .monospaced
        if let name = FluidTypography.name(for: design), let named = UIFont(name: name, size: size) { return named }
        let resolved = FluidTypography.systemDesign(for: design, style: theme.typography.brandStyle)
        let nativeDesign: UIFontDescriptor.SystemDesign = switch resolved {
        case .serif: .serif
        case .rounded: .rounded
        case .monospaced: .monospaced
        default: .default
        }
        let base = UIFont.systemFont(ofSize: size)
        return base.fontDescriptor.withDesign(nativeDesign).map { UIFont(descriptor: $0, size: size) } ?? base
        #else
        return documentStyle ? theme.typography.nativeBodyFont
            : .fluidFont(ofSize: 15, weight: .regular, design: .monospaced, style: theme.typography.brandStyle)
        #endif
    }

    func waveform(_ token: MeetingPendingSpeechToken, animatedIDs: Set<UInt64>) -> AnyView {
        AnyView(MeetingPendingSpeechTokenView(token: token,
            isAnimating: !reduceMotion && scenePhase != .background && animatedIDs.contains(token.id))
            .environment(\.theme, theme)
            .environment(\.dynamicTypeSize, dynamicTypeSize)
            .environment(\.scenePhase, scenePhase)
            .environment(\.layoutDirection, layoutDirection)
            .accessibilityHidden(true))
    }
}

#if os(iOS)
private extension DynamicTypeSize {
    var contentSizeCategory: UIContentSizeCategory {
        switch self {
        case .xSmall: .extraSmall
        case .small: .small
        case .medium: .medium
        case .large: .large
        case .xLarge: .extraLarge
        case .xxLarge: .extraExtraLarge
        case .xxxLarge: .extraExtraExtraLarge
        case .accessibility1: .accessibilityMedium
        case .accessibility2: .accessibilityLarge
        case .accessibility3: .accessibilityExtraLarge
        case .accessibility4: .accessibilityExtraExtraLarge
        case .accessibility5: .accessibilityExtraExtraExtraLarge
        @unknown default: .large
        }
    }
}
#endif

/// Immutable, bounded correlation between the accepted attributed text and its native layout.
/// Only lengths and visual token IDs cross the logger queue, never caption contents.
private nonisolated struct InlineCaptionRenderReceipt: Equatable, Sendable {
    let rendererID: UUID
    let sequence: UInt64
    let pendingRevision: UInt64
    let rowCount: Int
    let visibleUTF16: Int
    let pendingCount: Int
    let pendingIDs: [UInt64]

    var fields: String {
        "renderer=\(rendererID.uuidString) renderSequence=\(sequence) pendingRevision=\(pendingRevision) " +
            "rows=\(rowCount) visibleUTF16=\(visibleUTF16) pendingCount=\(pendingCount) pendingIDs=\(pendingIDs)"
    }
}

/// Stable attachment/hosting identities preserve waveform state while only text or pending
/// tokens change. Their fixed bounds mean waveform animation never requests text layout.
@MainActor
private final class InlineCaptionContent {
    private var attachments: [UInt64: InlineCaptionAttachment] = [:]
    private var previousText: NSAttributedString?
    private let rendererID = UUID()
    private var renderSequence: UInt64 = 0
    private(set) var renderReceipt: InlineCaptionRenderReceipt?

    func attributedText(_ configuration: InlineCaptionConfiguration) -> NSAttributedString? {
        let font = configuration.font
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 5
        paragraph.lineBreakMode = .byWordWrapping
        paragraph.baseWritingDirection = configuration.layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        paragraph.alignment = .natural
        let attributes: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
        let result = NSMutableAttributedString(string: "")
        for (index, row) in configuration.rows.enumerated() {
            let separator = MeetingLiveCaptionParagraphs.Paragraph.separator(
                after: index > 0 ? configuration.rows[index - 1].text : nil, before: row.text)
            var runAttributes = attributes
            runAttributes[.foregroundColor] = InlineCaptionColor(row.isPartial
                ? configuration.theme.palette.secondaryText : configuration.theme.palette.primaryText)
            result.append(NSAttributedString(string: separator + row.text, attributes: runAttributes))
        }
        let retained = Set(configuration.pending.tokens.map(\.id))
        attachments = attachments.filter { retained.contains($0.key) }
        let animated = Set(configuration.pending.tokens.suffix(3).map(\.id))
        var boundsChanged = false
        for token in configuration.pending.tokens {
            let attachment = attachments[token.id] ?? InlineCaptionAttachment(tokenID: token.id)
            attachments[token.id] = attachment
            let size = CGSize(width: configuration.wordSize.width * CGFloat(token.widthHint), height: configuration.wordSize.height)
            // Attachment origins are measured from the baseline. Center the waveform on the
            // font's x-height, keeping it in the same line box as the words it will replace.
            let bounds = CGRect(x: 0, y: (font.xHeight - size.height) / 2, width: size.width, height: size.height)
            boundsChanged = boundsChanged || attachment.bounds != bounds
            attachment.bounds = bounds
            attachment.update(configuration.waveform(token, animatedIDs: animated))
            if let last = result.string.last, !last.isWhitespace {
                result.append(NSAttributedString(string: " ", attributes: attributes))
            }
            let run = NSMutableAttributedString(attachment: attachment)
            run.addAttributes(attributes, range: NSRange(location: 0, length: run.length))
            result.append(run)
        }
        let changed = boundsChanged || previousText?.isEqual(to: result) != true
        if changed { renderSequence &+= 1 }
        if DebugLogger.diagnosticsEnabled {
            renderReceipt = InlineCaptionRenderReceipt(rendererID: rendererID, sequence: renderSequence,
                pendingRevision: configuration.pending.revision, rowCount: configuration.rows.count,
                visibleUTF16: configuration.rows.reduce(0) { $0 + $1.text.utf16.count },
                pendingCount: configuration.pending.tokens.count,
                pendingIDs: Array(configuration.pending.tokens.prefix(MeetingPendingSpeechProjection.maximumTokens).map(\.id)))
        }
        guard changed else { return nil }
        previousText = result.copy() as? NSAttributedString
        return result
    }

    func logAcceptedText() {
        guard let receipt = renderReceipt else { return }
        let eventTime = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.logLazy(level: .debug, source: "MeetingPendingSpeech") {
            "inline_text.accepted t=\(eventTime) \(receipt.fields)"
        }
    }

    func logDismantled() {
        guard let receipt = renderReceipt else { return }
        let eventTime = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.logLazy(level: .debug, source: "MeetingPendingSpeech") {
            "inline_view.dismantled t=\(eventTime) \(receipt.fields)"
        }
    }
}

/// TextKit owns word placement. The noninteractive caption view mounts the existing
/// waveform hosts at its attachment rectangles; no animation rasterizes the paragraph.
@MainActor
private final class InlineCaptionAttachment: NSTextAttachment {
    let tokenID: UInt64
    #if os(iOS)
    private var host: UIHostingController<AnyView>?
    #else
    private var host: NSHostingView<AnyView>?
    #endif
    private var root = AnyView(EmptyView())

    init(tokenID: UInt64) {
        self.tokenID = tokenID
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = false
    }

    required init?(coder: NSCoder) { nil }

    func update(_ root: AnyView) {
        self.root = root
        host?.rootView = root
    }

    var waveformView: InlineCaptionNativeView {
        #if os(iOS)
        if let host { return host.view }
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.isAccessibilityElement = false
        host.view.accessibilityIdentifier = "meeting.inlineWave.\(tokenID)"
        self.host = host
        return host.view
        #else
        if let host { return host }
        let host = NSHostingView(rootView: root)
        host.setAccessibilityElement(false)
        host.setAccessibilityIdentifier("meeting.inlineWave.\(tokenID)")
        self.host = host
        return host
        #endif
    }

    override func image(for bounds: CGRect, attributes: [NSAttributedString.Key: Any],
                        location: any NSTextLocation, textContainer: NSTextContainer?) ->
        InlineCaptionImage? { nil }
}

@MainActor
private final class InlineCaptionWavePlacement {
    private nonisolated struct Placement: Equatable, Sendable {
        let id: UInt64
        let bounds: CGRect
    }
    private nonisolated struct LayoutReceipt: Equatable, Sendable {
        let input: InlineCaptionRenderReceipt
        let ready: Bool
        let bounds: CGRect
        let placements: [Placement]
        let missingIDs: [UInt64]
    }
    private var displayed: [UInt64: InlineCaptionAttachment] = [:]
    private var lastLayoutReceipt: LayoutReceipt?

    func layout(in view: InlineCaptionNativeView, manager: NSTextLayoutManager?, text: NSAttributedString?,
                receipt: InlineCaptionRenderReceipt?) {
        guard let text, let manager, let content = manager.textContentManager else {
            var removedIDs: [UInt64] = []
            if let text {
                var present: [UInt64: InlineCaptionAttachment] = [:]
                text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, _, _ in
                    guard let attachment = value as? InlineCaptionAttachment,
                          displayed[attachment.tokenID] === attachment else { return }
                    present[attachment.tokenID] = attachment
                }
                removedIDs = displayed.keys.filter { present[$0] == nil }.sorted()
                for id in removedIDs { displayed[id]?.waveformView.removeFromSuperview() }
                displayed = present
            }
            if let receipt {
                // An unavailable layout keeps only still-present hosts. Report those
                // mounted views separately from attachment removal and missing geometry.
                let mounted = displayed.sorted { $0.key < $1.key }
                    .prefix(MeetingPendingSpeechProjection.maximumTokens)
                    .map { Placement(id: $0.key, bounds: $0.value.waveformView.frame) }
                logLayout(receipt: receipt, ready: false, bounds: view.bounds, placements: mounted,
                    missingIDs: receipt.pendingIDs.filter { displayed[$0] == nil },
                    removedIDs: Array(removedIDs.prefix(MeetingPendingSpeechProjection.maximumTokens)))
            }
            return
        }
        manager.ensureLayout(for: content.documentRange)
        var retained: [UInt64: InlineCaptionAttachment] = [:]
        var placements: [Placement] = []
        var missingIDs: [UInt64] = []
        let captureDiagnostics = receipt != nil
        func retainExistingPlacement(_ attachment: InlineCaptionAttachment) {
            // A transient TextKit miss is not text replacement. Preserve only the
            // exact host still represented by this attachment, never a reused ID.
            guard displayed[attachment.tokenID] === attachment,
                  attachment.waveformView.superview === view else { return }
            retained[attachment.tokenID] = attachment
            if captureDiagnostics, placements.count < MeetingPendingSpeechProjection.maximumTokens {
                placements.append(Placement(id: attachment.tokenID, bounds: attachment.waveformView.frame))
            }
        }
        text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
            guard let attachment = value as? InlineCaptionAttachment else { return }
            guard let location = content.location(content.documentRange.location, offsetBy: range.location),
                  let fragment = manager.textLayoutFragment(for: location) else {
                if captureDiagnostics, missingIDs.count < MeetingPendingSpeechProjection.maximumTokens {
                    missingIDs.append(attachment.tokenID)
                }
                retainExistingPlacement(attachment)
                return
            }
            let local = fragment.frameForTextAttachment(at: location)
            guard local.width > 0, local.height > 0 else {
                if captureDiagnostics, missingIDs.count < MeetingPendingSpeechProjection.maximumTokens {
                    missingIDs.append(attachment.tokenID)
                }
                retainExistingPlacement(attachment)
                return
            }
            let rect = local.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                      dy: fragment.layoutFragmentFrame.minY)
            let waveform = attachment.waveformView
            if waveform.superview !== view { view.addSubview(waveform) }
            if waveform.frame != rect { waveform.frame = rect }
            retained[attachment.tokenID] = attachment
            if captureDiagnostics, placements.count < MeetingPendingSpeechProjection.maximumTokens {
                placements.append(Placement(id: attachment.tokenID, bounds: rect))
            }
        }
        let removedIDs = displayed.compactMap { id, attachment in
            retained[id] !== attachment ? id : nil
        }.sorted()
        for id in removedIDs {
            guard let attachment = displayed[id] else { continue }
            attachment.waveformView.removeFromSuperview()
        }
        displayed = retained
        logLayout(receipt: receipt, ready: true, bounds: view.bounds, placements: placements,
            missingIDs: missingIDs, removedIDs: Array(removedIDs.prefix(MeetingPendingSpeechProjection.maximumTokens)))
    }

    private func logLayout(receipt: InlineCaptionRenderReceipt?, ready: Bool, bounds: CGRect,
                           placements: [Placement], missingIDs: [UInt64], removedIDs: [UInt64] = []) {
        guard let receipt else { return }
        let current = LayoutReceipt(input: receipt, ready: ready, bounds: bounds,
            placements: placements, missingIDs: missingIDs)
        guard current != lastLayoutReceipt || !removedIDs.isEmpty else { return }
        lastLayoutReceipt = current
        let eventTime = ProcessInfo.processInfo.systemUptime
        DebugLogger.shared.logLazy(level: .debug, source: "MeetingPendingSpeech") {
            let mounted = placements.map { "\($0.id):\($0.bounds)" }.joined(separator: ",")
            return "inline_layout.changed t=\(eventTime) \(receipt.fields) layoutReady=\(ready) " +
                "viewBounds=\(bounds) mountedIDs=\(placements.map(\.id)) mountedBounds=[\(mounted)] " +
                "missingIDs=\(missingIDs) removedIDs=\(removedIDs)"
        }
    }
}

#if os(iOS)
@MainActor
private final class InlineCaptionTextView: UITextView {
    var retainedTextContentStorage: NSTextContentStorage?
    var renderReceipt: InlineCaptionRenderReceipt?
    private let waves = InlineCaptionWavePlacement()
    override func layoutSubviews() {
        super.layoutSubviews()
        waves.layout(in: self, manager: textLayoutManager, text: attributedText, receipt: renderReceipt)
    }
}
#else
@MainActor
private final class InlineCaptionTextView: NSTextView {
    var retainedTextContentStorage: NSTextContentStorage?
    var renderReceipt: InlineCaptionRenderReceipt?
    private let waves = InlineCaptionWavePlacement()
    override func layout() {
        super.layout()
        waves.layout(in: self, manager: textLayoutManager, text: attributedString(), receipt: renderReceipt)
    }
}
#endif

#if os(iOS)
private struct InlineCaptionNativeText: UIViewRepresentable {
    let configuration: InlineCaptionConfiguration
    func makeCoordinator() -> InlineCaptionContent { InlineCaptionContent() }

    func makeUIView(context: Context) -> UITextView {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: .zero)
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        let view = InlineCaptionTextView(frame: .zero, textContainer: container)
        view.retainedTextContentStorage = storage
        view.isEditable = false
        view.isSelectable = false
        view.isScrollEnabled = false
        view.isUserInteractionEnabled = false
        view.backgroundColor = .clear
        view.textContainerInset = .zero
        view.textContainer.lineFragmentPadding = 0
        view.textContainer.widthTracksTextView = false
        view.textContainer.heightTracksTextView = false
        view.isAccessibilityElement = false
        view.accessibilityIdentifier = "meeting.inlineCaption.text"
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateUIView(_ view: UITextView, context: Context) {
        let text = context.coordinator.attributedText(configuration)
        (view as? InlineCaptionTextView)?.renderReceipt = context.coordinator.renderReceipt
        if let text {
            view.attributedText = text
            context.coordinator.logAcceptedText()
        }
        view.setNeedsLayout()
    }

    static func dismantleUIView(_ view: UITextView, coordinator: InlineCaptionContent) {
        coordinator.logDismantled()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        view.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        guard let manager = view.textLayoutManager, let content = manager.textContentManager else { return nil }
        manager.ensureLayout(for: content.documentRange)
        let used = manager.usageBoundsForTextContainer
        let fittedWidth = configuration.documentStyle ? width : min(width, ceil(max(1, used.maxX)))
        return CGSize(width: fittedWidth, height: ceil(max(configuration.font.lineHeight, used.maxY)))
    }
}
#else
private struct InlineCaptionNativeText: NSViewRepresentable {
    let configuration: InlineCaptionConfiguration
    func makeCoordinator() -> InlineCaptionContent { InlineCaptionContent() }

    func makeNSView(context: Context) -> NSTextView {
        let storage = NSTextContentStorage()
        let manager = NSTextLayoutManager()
        let container = NSTextContainer(size: .zero)
        manager.textContainer = container
        storage.addTextLayoutManager(manager)
        let view = InlineCaptionTextView(frame: .zero, textContainer: container)
        view.retainedTextContentStorage = storage
        view.isEditable = false
        view.isSelectable = false
        view.isRichText = true
        view.drawsBackground = false
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.textContainer?.widthTracksTextView = false
        view.textContainer?.heightTracksTextView = false
        view.isHorizontallyResizable = false
        view.isVerticallyResizable = false
        view.setAccessibilityElement(false)
        view.setAccessibilityIdentifier("meeting.inlineCaption.text")
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return view
    }

    func updateNSView(_ view: NSTextView, context: Context) {
        let text = context.coordinator.attributedText(configuration)
        (view as? InlineCaptionTextView)?.renderReceipt = context.coordinator.renderReceipt
        if let text, let storage = view.textStorage {
            storage.setAttributedString(text)
            context.coordinator.logAcceptedText()
        }
        view.needsLayout = true
    }

    static func dismantleNSView(_ view: NSTextView, coordinator: InlineCaptionContent) {
        coordinator.logDismantled()
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        view.textContainer?.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        guard let manager = view.textLayoutManager, let content = manager.textContentManager else { return nil }
        manager.ensureLayout(for: content.documentRange)
        let font = configuration.font
        let used = manager.usageBoundsForTextContainer
        let fittedWidth = configuration.documentStyle ? width : min(width, ceil(max(1, used.maxX)))
        return CGSize(width: fittedWidth, height: ceil(max(font.ascender - font.descender + font.leading, used.maxY)))
    }
}
#endif
