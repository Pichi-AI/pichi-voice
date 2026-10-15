import SwiftUI
#if os(iOS)
import UIKit
private typealias InlineCaptionFont = UIFont
private typealias InlineCaptionColor = UIColor
private typealias InlineCaptionNativeView = UIView
#else
import AppKit
private typealias InlineCaptionFont = NSFont
private typealias InlineCaptionColor = NSColor
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

/// Stable attachment/hosting identities preserve waveform state while only text or pending
/// tokens change. Their fixed bounds mean waveform animation never requests text layout.
@MainActor
private final class InlineCaptionContent {
    private var attachments: [UInt64: InlineCaptionAttachment] = [:]
    private var previousText: NSAttributedString?

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
        guard boundsChanged || previousText?.isEqual(to: result) != true else { return nil }
        previousText = result.copy() as? NSAttributedString
        return result
    }
}

@MainActor
private final class InlineCaptionAttachment: NSTextAttachment {
    let tokenID: UInt64
    private var root = AnyView(EmptyView())
    private weak var activeProvider: InlineCaptionAttachmentProvider?

    init(tokenID: UInt64) {
        self.tokenID = tokenID
        super.init(data: nil, ofType: nil)
        allowsTextAttachmentView = true
    }

    required init?(coder: NSCoder) { nil }
    override var usesTextAttachmentView: Bool { true }

    func update(_ root: AnyView) {
        self.root = root
        activeProvider?.update(root)
    }

    override func viewProvider(for parentView: InlineCaptionNativeView?, location: any NSTextLocation,
                               textContainer: NSTextContainer?) -> NSTextAttachmentViewProvider? {
        let manager = textContainer?.textLayoutManager
        // A provider's location is immutable. Retain it only while TextKit still asks for the
        // same location; the attachment identity itself survives preceding text corrections.
        if let activeProvider, activeProvider.parent === parentView,
           activeProvider.textLayoutManager === manager,
           activeProvider.location.compare(location) == .orderedSame {
            return activeProvider
        }
        let provider = InlineCaptionAttachmentProvider(textAttachment: self,
            parentView: parentView, textLayoutManager: manager, location: location)
        provider.parent = parentView
        provider.update(root)
        activeProvider = provider
        return provider
    }
}

@MainActor
private final class InlineCaptionAttachmentProvider: NSTextAttachmentViewProvider {
    weak var parent: InlineCaptionNativeView?
    private var root = AnyView(EmptyView())
    #if os(iOS)
    private var host: UIHostingController<AnyView>?
    #else
    private var host: NSHostingView<AnyView>?
    #endif

    func update(_ root: AnyView) {
        self.root = root
        host?.rootView = root
    }

    override func loadView() {
        #if os(iOS)
        let host = UIHostingController(rootView: root)
        host.view.backgroundColor = .clear
        host.view.isUserInteractionEnabled = false
        host.view.isAccessibilityElement = false
        host.view.accessibilityIdentifier = (textAttachment as? InlineCaptionAttachment)
            .map { "meeting.inlineWave.\($0.tokenID)" }
        self.host = host
        view = host.view
        #else
        let host = NSHostingView(rootView: root)
        host.setAccessibilityElement(false)
        host.setAccessibilityIdentifier((textAttachment as? InlineCaptionAttachment)
            .map { "meeting.inlineWave.\($0.tokenID)" })
        self.host = host
        view = host
        #endif
        tracksTextAttachmentViewBounds = false
    }
}

#if os(iOS)
private struct InlineCaptionNativeText: UIViewRepresentable {
    let configuration: InlineCaptionConfiguration
    func makeCoordinator() -> InlineCaptionContent { InlineCaptionContent() }

    func makeUIView(context: Context) -> UITextView {
        let view = UITextView(usingTextLayoutManager: true)
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
        if let text = context.coordinator.attributedText(configuration) { view.attributedText = text }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView view: UITextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        view.textContainer.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        guard let manager = view.textLayoutManager, let content = manager.textContentManager else { return nil }
        manager.ensureLayout(for: content.documentRange)
        return CGSize(width: width, height: ceil(max(configuration.font.lineHeight, manager.usageBoundsForTextContainer.maxY)))
    }
}
#else
private struct InlineCaptionNativeText: NSViewRepresentable {
    let configuration: InlineCaptionConfiguration
    func makeCoordinator() -> InlineCaptionContent { InlineCaptionContent() }

    func makeNSView(context: Context) -> NSTextView {
        let view = NSTextView(usingTextLayoutManager: true)
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
        if let text = context.coordinator.attributedText(configuration) { view.textStorage?.setAttributedString(text) }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: NSTextView, context: Context) -> CGSize? {
        guard let width = proposal.width, width.isFinite, width > 0 else { return nil }
        view.textContainer?.size = CGSize(width: width, height: .greatestFiniteMagnitude)
        guard let manager = view.textLayoutManager, let content = manager.textContentManager else { return nil }
        manager.ensureLayout(for: content.documentRange)
        let font = configuration.font
        return CGSize(width: width, height: ceil(max(font.ascender - font.descender + font.leading,
            manager.usageBoundsForTextContainer.maxY)))
    }
}
#endif
