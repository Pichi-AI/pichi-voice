import SwiftUI

/// Shared bubble look for final transcript and live captions; callers own alignment, labels, and insets.
struct MeetingBubbleStyle {
    var font: Font
    var lineSpacing: CGFloat
    var horizontalPadding: CGFloat
    var verticalPadding: CGFloat
    var cornerRadius: CGFloat
    var fill: Color
    var foreground: Color

    static func final(fill: Color, foreground: Color) -> MeetingBubbleStyle {
        MeetingBubbleStyle(
            font: .fluidSystem(size: 15, design: .monospaced),
            lineSpacing: 5,
            horizontalPadding: 18,
            verticalPadding: 12,
            cornerRadius: 18,
            fill: fill,
            foreground: foreground
        )
    }
}

extension View {
    func meetingBubbleStyle(_ style: MeetingBubbleStyle) -> some View {
        self
            .font(style.font)
            .lineSpacing(style.lineSpacing)
            .foregroundStyle(style.foreground)
            .padding(.horizontal, style.horizontalPadding)
            .padding(.vertical, style.verticalPadding)
            .background(style.fill, in: RoundedRectangle(cornerRadius: style.cornerRadius, style: .continuous))
    }
}

/// Auto-follows the newest row only while the user is pinned to the bottom; scrolling up suspends
/// following and shows a jump-to-bottom button.
struct MeetingLiveBubbleScrollList: View {
    let rows: [MeetingLiveBubbleComposer.Row]
    var hidesPartialFromAccessibility = true
    var documentStyle = false

    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPinnedToBottom = true
    @Namespace private var scrollViewport

    private var trailingPartialLength: Int {
        guard let last = self.rows.last, last.isPartial else { return 0 }
        return last.text.count
    }

    var body: some View {
        let rowIDs = self.rows.map(\.id)
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    VStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        ForEach(self.rows) { row in
                            MeetingLiveBubbleRow(row: row, hidesPartialFromAccessibility: self.hidesPartialFromAccessibility,
                                                 documentStyle: self.documentStyle, interfaceLanguageID: self.locale.identifier)
                                .equatable()
                                .id(row.id)
                                .transition(.opacity)
                        }
                    }
                    .background {
                        if #available(iOS 18, macOS 15, *) {
                            EmptyView()
                        } else {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: MeetingCaptionScrollTracking.GeometryKey.self,
                                    value: .init(contentBottom: geometry.frame(in: .named(self.scrollViewport)).maxY)
                                )
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .animation(self.reduceMotion ? nil : .easeInOut(duration: 0.2), value: rowIDs)
                .modifier(MeetingCaptionScrollTracking(
                    viewport: self.scrollViewport, isPinnedToBottom: self.$isPinnedToBottom
                ))
                .onChange(of: self.rows.count) {
                    self.scrollToBottomIfPinned(proxy: proxy)
                }
                .onChange(of: self.trailingPartialLength) {
                    self.scrollToBottomIfPinned(proxy: proxy)
                }

                if !self.isPinnedToBottom {
                    Button {
                        self.isPinnedToBottom = true
                        self.scrollToBottom(proxy: proxy, animated: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.fluidSystem(size: 12, weight: .semibold))
                            .foregroundStyle(self.theme.palette.primaryText)
                            .frame(width: 28, height: 28)
                            .background(self.theme.palette.contentBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help("Jump to latest captions")
                    .accessibilityLabel("Jump to latest captions")
                    .padding(6)
                }
            }
        }
    }

    private func scrollToBottomIfPinned(proxy: ScrollViewProxy) {
        guard self.isPinnedToBottom else { return }
        self.scrollToBottom(proxy: proxy, animated: false)
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard let lastID = self.rows.last?.id else { return }
        guard animated, !self.reduceMotion else {
            proxy.scrollTo(lastID, anchor: .bottom)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(lastID, anchor: .bottom)
        }
    }
}

/// iOS 17 has no scroll-geometry callback. This adapter measures the same scroll viewport
/// through preferences; rendering, IDs, follow actions and transcript ownership remain shared.
private struct MeetingCaptionScrollTracking: ViewModifier {
    let viewport: Namespace.ID
    @Binding var isPinnedToBottom: Bool

    nonisolated struct Geometry: Equatable, Sendable {
        var contentBottom: CGFloat? = nil
        var viewportHeight: CGFloat? = nil

        var isPinnedToBottom: Bool? {
            guard let contentBottom, let viewportHeight,
                  contentBottom.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return nil }
            // Match the existing wide threshold so one wrapped partial line cannot disengage
            // follow before scrollTo runs; deliberate upward scrolling still suspends it.
            return contentBottom <= viewportHeight + 80
        }
    }

    struct GeometryKey: PreferenceKey {
        static let defaultValue = Geometry()
        static func reduce(value: inout Geometry, nextValue: () -> Geometry) {
            let next = nextValue()
            if let bottom = next.contentBottom { value.contentBottom = bottom }
            if let height = next.viewportHeight { value.viewportHeight = height }
        }
    }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content.onScrollGeometryChange(for: Bool.self) { geometry in
                let bottomOffset = geometry.contentSize.height - geometry.containerSize.height
                return geometry.contentOffset.y >= bottomOffset - 80
            } action: { _, isPinned in
                self.isPinnedToBottom = isPinned
            }
        } else {
            content
                .coordinateSpace(name: self.viewport)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: GeometryKey.self, value: .init(viewportHeight: geometry.size.height))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onPreferenceChange(GeometryKey.self) { geometry in
                    if let isPinned = geometry.isPinnedToBottom, isPinned != self.isPinnedToBottom {
                        self.isPinnedToBottom = isPinned
                    }
                }
        }
    }
}

struct MeetingLiveBubbleRow: View, Equatable {
    let row: MeetingLiveBubbleComposer.Row
    var hidesPartialFromAccessibility: Bool = true
    var documentStyle = false
    var interfaceLanguageID = PichiLocalization.language.rawValue

    @Environment(\.theme) private var theme

    static func == (lhs: MeetingLiveBubbleRow, rhs: MeetingLiveBubbleRow) -> Bool {
        lhs.row == rhs.row && lhs.hidesPartialFromAccessibility == rhs.hidesPartialFromAccessibility
            && lhs.documentStyle == rhs.documentStyle && lhs.interfaceLanguageID == rhs.interfaceLanguageID
    }

    private var isMicrophone: Bool { self.row.speaker == .you }

    private var sourceLabel: String {
        self.isMicrophone ? PichiLocalization.text("Microphone") : PichiLocalization.text("Meeting audio")
    }

    /// Distinguish capture sources without claiming that either source belongs to a person.
    private var fill: Color {
        let base = self.isMicrophone ? self.theme.palette.accent : MeetingSpeakerPalette.tint(forSpeakerIndex: 0)
        return base.opacity(self.row.isPartial ? 0.05 : 0.10)
    }

    var body: some View {
        VStack(alignment: self.isMicrophone && !self.documentStyle ? .trailing : .leading, spacing: 4) {
            if self.row.showsLabel {
                Text(self.sourceLabel)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.isMicrophone ? self.theme.palette.accent : self.theme.palette.secondaryText)
            }
            Text(self.row.text)
                // The partial→final color swap solidifies in place; it must never animate.
                .transaction { $0.animation = nil }
                .meetingBubbleStyle(self.presentationStyle)
        }
        .frame(maxWidth: .infinity, alignment: self.isMicrophone && !self.documentStyle ? .trailing : .leading)
        .padding(self.isMicrophone ? .leading : .trailing, self.documentStyle ? 0 : 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(self.sourceLabel), \(self.row.text)")
        .accessibilityHidden(self.hidesPartialFromAccessibility && self.row.isPartial)
    }

    private var presentationStyle: MeetingBubbleStyle {
        let foreground = self.row.isPartial ? self.theme.palette.secondaryText : self.theme.palette.primaryText
        guard self.documentStyle else { return .final(fill: self.fill, foreground: foreground) }
        return MeetingBubbleStyle(
            font: self.theme.typography.body,
            lineSpacing: 5,
            horizontalPadding: 0,
            verticalPadding: self.theme.metrics.spacing.sm,
            cornerRadius: 0,
            fill: .clear,
            foreground: foreground
        )
    }
}
