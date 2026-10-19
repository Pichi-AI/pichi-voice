import SwiftUI
#if os(iOS)
import UIKit
#endif

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

/// Presentation only. Timed word-sized rows flow together without changing their source,
/// text, IDs or the canonical transcript. Boundaries depend on committed preceding text,
/// so a growing partial stays in the same paragraph as it becomes final.
nonisolated enum MeetingLiveCaptionParagraphs {
    struct Paragraph: Identifiable, Equatable, Sendable {
        let rows: [MeetingLiveBubbleComposer.Row]
        var id: UUID { rows[0].id }
        var speaker: MeetingLiveSpeaker { rows[0].speaker }
        var showsLabel: Bool { rows[0].showsLabel }
        var participant: MeetingSpeakerPresentation? {
            guard let first = rows[0].participant else { return nil }
            return rows.contains { $0.participant?.isEstimated == true } ? first.markingEstimated() : first
        }

        func text(includingPartials: Bool = true) -> String {
            let visible = includingPartials ? rows : rows.filter { !$0.isPartial }
            return visible.enumerated().map { index, row in
                Self.separator(after: index > 0 ? visible[index - 1].text : nil, before: row.text) + row.text
            }.joined()
        }

        static func separator(after previous: String?, before next: String) -> String {
            MeetingTranscriptExporter.DisplayParagraph.separator(after: previous, before: next)
        }
    }

    /// A growing protected transcript is composed only when its rows change, not
    /// every time the microphone meter or pending waveform invalidates the view.
    static func composeForDisplay(_ rows: [MeetingLiveBubbleComposer.Row]) async throws -> [Paragraph] {
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let paragraphs = Self.compose(rows)
            try Task.checkCancellation()
            return paragraphs
        }
        return try await withTaskCancellationHandler {
            let result = try await work.value
            try Task.checkCancellation()
            return result
        } onCancel: { work.cancel() }
    }

    static func compose(_ rows: [MeetingLiveBubbleComposer.Row]) -> [Paragraph] {
        var paragraphs: [Paragraph] = []
        var members: [MeetingLiveBubbleComposer.Row] = []
        var committedLength = 0
        for row in rows {
            let previous = members.last
            let endsSentence = previous.map { !$0.isPartial && ".!?…".contains($0.text.last ?? " ") } ?? false
            let startsParagraph = previous.map {
                !$0.hasSameSpeaker(as: row) || (!$0.isPartial && $0.text.contains("\n"))
                    || committedLength >= 512 || (committedLength >= 320 && endsSentence)
            } ?? false
            if startsParagraph {
                paragraphs.append(Paragraph(rows: members))
                members = []; committedLength = 0
            }
            members.append(row)
            if !row.isPartial { committedLength += row.text.count + 1 }
        }
        if !members.isEmpty { paragraphs.append(Paragraph(rows: members)) }
        return paragraphs
    }
}

private extension MeetingLiveBubbleComposer.Row {
    var captionLabel: String {
        participant.map { MeetingTranscriptExporter.speakerLabel(for: $0, language: PichiLocalization.language) }
            ?? speaker.captionSourceLabel
    }
}

private extension MeetingLiveCaptionParagraphs.Paragraph {
    var captionLabel: String {
        participant.map { MeetingTranscriptExporter.speakerLabel(for: $0, language: PichiLocalization.language) }
            ?? speaker.captionSourceLabel
    }
}

private extension MeetingLiveSpeaker {
    var captionSourceLabel: String {
        self == .you ? PichiLocalization.text("Microphone") : PichiLocalization.text("Meeting audio")
    }
}

/// Snapshot-to-row work changes with protected recognition, not the much more frequent
/// capture meter and pending-waveform updates in the surrounding recording screen.
struct MeetingLiveTranscriptScrollList: View {
    let snapshot: MeetingLiveTranscriptSnapshot
    var pending: MeetingPendingSpeechSnapshot = .empty
    var hidesPartialFromAccessibility = true
    var documentStyle = false
    @State private var rows: [MeetingLiveBubbleComposer.Row] = []
    @State private var rowsRevision: UInt64?

    var body: some View {
        MeetingLiveBubbleScrollList(rows: self.rows, pending: self.pending,
            hidesPartialFromAccessibility: self.hidesPartialFromAccessibility, documentStyle: self.documentStyle,
            presentationRevision: self.rowsRevision)
            // The publication owner advances this revision for text, partials and speaker
            // refinements. Pending audio and health ticks must not compare the entire history.
            .task(id: self.snapshot.revision) {
                do {
                    let prepared = try await MeetingLiveBubbleComposer.rowsForDisplay(self.snapshot)
                    try Task.checkCancellation()
                    self.rows = prepared
                    self.rowsRevision = self.snapshot.revision
                } catch is CancellationError { }
                catch { assertionFailure("Caption row presentation failed: \(error)") }
            }
    }
}

/// Auto-follows the newest row only while the user is pinned to the bottom; scrolling up suspends
/// following and shows a jump-to-bottom button.
struct MeetingLiveBubbleScrollList: View {
    let rows: [MeetingLiveBubbleComposer.Row]
    var pending: MeetingPendingSpeechSnapshot = .empty
    var hidesPartialFromAccessibility = true
    var documentStyle = false
    /// Versioned production callers avoid full-history equality on every capture update.
    /// Unversioned preview/test callers retain value-based invalidation, including corrections.
    var presentationRevision: UInt64? = nil

    @Environment(\.theme) private var theme
    @Environment(\.locale) private var locale
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isPinnedToBottom = true
    @State private var paragraphs: [MeetingLiveCaptionParagraphs.Paragraph] = []
    @State private var renderedParagraphRevision: UInt64 = 0
    @Namespace private var scrollViewport
    private let bottomAnchor = "meeting.liveTranscript.bottom"

    private enum PresentationKey: Equatable {
        case revision(UInt64)
        case rows([MeetingLiveBubbleComposer.Row])
    }

    private var presentationKey: PresentationKey {
        if let presentationRevision { return .revision(presentationRevision) }
        return .rows(self.rows)
    }

    private struct RowInsertionKey: Equatable {
        let count: Int
        let lastID: UUID?
    }

    private var inlinePending: MeetingPendingSpeechSnapshot {
        var snapshot = self.pending
        snapshot.tokens = snapshot.tokens.filter { $0.source == self.rows.last?.speaker }
        return snapshot
    }

    private var separatePending: MeetingPendingSpeechSnapshot {
        var snapshot = self.pending
        snapshot.tokens = snapshot.tokens.filter { $0.source != self.rows.last?.speaker }
        return snapshot
    }

    var body: some View {
        let insertionKey = RowInsertionKey(count: self.rows.count, lastID: self.rows.last?.id)
        ScrollViewReader { proxy in
            ZStack(alignment: .bottomTrailing) {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: self.theme.metrics.spacing.sm) {
                        if self.documentStyle {
                            ForEach(self.paragraphs) { paragraph in
                                MeetingLiveParagraphRow(paragraph: paragraph,
                                    hidesPartialFromAccessibility: self.hidesPartialFromAccessibility,
                                    interfaceLanguageID: self.locale.identifier,
                                    isTail: paragraph.id == self.paragraphs.last?.id,
                                    pending: paragraph.id == self.paragraphs.last?.id ? self.inlinePending : .empty)
                                    .equatable()
                                    .id(paragraph.id)
                                    .transition(.opacity)
                            }
                        } else {
                            ForEach(self.rows) { row in
                                MeetingLiveBubbleRow(row: row, hidesPartialFromAccessibility: self.hidesPartialFromAccessibility,
                                                     interfaceLanguageID: self.locale.identifier,
                                                     isTail: row.id == self.rows.last?.id,
                                                     pending: row.id == self.rows.last?.id ? self.inlinePending : .empty)
                                    .equatable()
                                    .id(row.id)
                                    .transition(.opacity)
                            }
                        }
                        if !self.separatePending.tokens.isEmpty {
                            MeetingPendingSpeechView(pending: self.separatePending)
                                .padding(.top, self.theme.metrics.spacing.xs)
                        }
                        Color.clear.frame(height: 1).id(self.bottomAnchor).accessibilityHidden(true)
                    }
                    .background {
                        if #available(iOS 18, macOS 15, *) {
                            EmptyView()
                        } else {
                            GeometryReader { geometry in
                                Color.clear.preference(
                                    key: MeetingCaptionScrollTracking.GeometryKey.self,
                                    value: .init(contentBottom: geometry.frame(in: .named(self.scrollViewport)).maxY,
                                                 contentHeight: geometry.size.height,
                                                 contentOffset: -geometry.frame(in: .named(self.scrollViewport)).minY)
                                )
                            }
                            .allowsHitTesting(false)
                            .accessibilityHidden(true)
                        }
                    }
                }
                .task(id: self.documentStyle ? self.presentationKey : nil) {
                    guard self.documentStyle else { return }
                    do {
                        let composed = try await MeetingLiveCaptionParagraphs.composeForDisplay(self.rows)
                        try Task.checkCancellation()
                        self.paragraphs = composed
                        self.renderedParagraphRevision &+= 1
                    } catch is CancellationError { }
                    catch { assertionFailure("Caption presentation failed: \(error)") }
                }
                .accessibilityIdentifier("meeting.liveTranscript.viewport")
                .animation(self.documentStyle || self.reduceMotion ? nil : .easeInOut(duration: 0.2), value: insertionKey)
                .modifier(MeetingCaptionScrollTracking(
                    viewport: self.scrollViewport, isPinnedToBottom: self.$isPinnedToBottom,
                    onLayoutChange: { self.scrollToBottomIfPinned(proxy: proxy) }
                ))
                .onChange(of: self.presentationKey) {
                    if !self.documentStyle { self.scrollToBottomIfPinned(proxy: proxy) }
                }
                .onChange(of: self.renderedParagraphRevision) {
                    // Detached composition may finish after the source update's layout.
                    // Follow the newly rendered paragraph IDs, not the preceding document.
                    if self.documentStyle { self.scrollToBottomIfPinned(proxy: proxy) }
                }
                .onChange(of: self.pending) {
                    self.scrollToBottomIfPinned(proxy: proxy)
                }
                .onAppear { self.scrollToBottomIfPinned(proxy: proxy) }

                if !self.isPinnedToBottom {
                    Button {
                        self.isPinnedToBottom = true
                        self.scrollToBottom(proxy: proxy, animated: true)
                    } label: {
                        Image(systemName: "chevron.down")
                            .font(.fluidSystem(size: 12, weight: .semibold))
                            .foregroundStyle(self.theme.palette.primaryText)
                            .frame(width: 44, height: 44)
                            .background(self.theme.palette.contentBackground, in: Circle())
                    }
                    .buttonStyle(.plain)
                    .help(PichiLocalization.text("Jump to latest captions"))
                    .accessibilityLabel(PichiLocalization.text("Jump to latest captions"))
                    .accessibilityIdentifier("meeting.liveTranscript.latest")
                    .padding(6)
                }
            }
        }
    }

    private func scrollToBottomIfPinned(proxy: ScrollViewProxy) {
        // Match the shared command workspace: wait for wrapped text's rendered height,
        // then recheck user intent instead of capturing a stale follow decision.
        guard self.isPinnedToBottom else { return }
        DispatchQueue.main.async {
            guard self.isPinnedToBottom else { return }
            self.scrollToBottom(proxy: proxy, animated: false)
        }
    }

    private func scrollToBottom(proxy: ScrollViewProxy, animated: Bool) {
        guard animated, !self.reduceMotion else {
            proxy.scrollTo(self.bottomAnchor, anchor: .bottom)
            return
        }
        withAnimation(.easeInOut(duration: 0.2)) {
            proxy.scrollTo(self.bottomAnchor, anchor: .bottom)
        }
    }
}

/// iOS 17 has no scroll-geometry callback. This adapter measures the same scroll viewport
/// through preferences; rendering, IDs, follow actions and transcript ownership remain shared.
struct MeetingCaptionScrollTracking: ViewModifier {
    let viewport: Namespace.ID
    @Binding var isPinnedToBottom: Bool
    let onLayoutChange: () -> Void
    @State private var isUserScrolling = false
    @State private var isDraggingUp = false
    @State private var previousGeometry: Geometry?

    private var accessibilityOffsetIntent: Bool {
        #if os(iOS)
        UIAccessibility.isVoiceOverRunning
        #else
        false
        #endif
    }

    nonisolated struct Geometry: Equatable, Sendable {
        var contentBottom: CGFloat? = nil
        var viewportHeight: CGFloat? = nil
        var viewportWidth: CGFloat? = nil
        var contentHeight: CGFloat? = nil
        var contentOffset: CGFloat? = nil

        var isPinnedToBottom: Bool? {
            guard let contentBottom, let viewportHeight,
                  contentBottom.isFinite, viewportHeight.isFinite, viewportHeight > 0 else { return nil }
            return contentBottom <= viewportHeight + 4
        }

        func offsetChanged(from previous: Self) -> Bool {
            guard let contentOffset, let oldOffset = previous.contentOffset else { return false }
            return abs(contentOffset - oldOffset) > 0.5
        }

        func movedTowardEarlierText(from previous: Self) -> Bool {
            guard let contentOffset, let oldOffset = previous.contentOffset else { return false }
            return contentOffset < oldOffset - 0.5
        }

        func layoutChanged(from previous: Self) -> Bool {
            contentHeight != previous.contentHeight || viewportChanged(from: previous)
        }

        func viewportChanged(from previous: Self) -> Bool {
            viewportHeight != previous.viewportHeight || viewportWidth != previous.viewportWidth
        }

        func fallbackFollowPreference(after previous: Self, currentlyFollowing: Bool,
                                      upwardDrag: Bool, accessibilityOffsetIntent: Bool = false) -> Bool {
            // On iOS 17 a LazyVStack/TextKit layout correction can move the offset
            // after its height preference has settled. Offset-only movement therefore
            // does not establish user intent. The actual drag latches reading mode;
            // momentum retains that choice, and reaching the end resumes following.
            // Preserve the prior semantic-scroll behavior for VoiceOver without
            // replacing its native scroll action. Its layout ambiguity remains;
            // ordinary touch must not infer a gesture from that ambiguity.
            let clampedToBottom: Bool
            if let contentHeight, let viewportHeight, let contentOffset,
               let previousOffset = previous.contentOffset {
                let bottomOffset = max(0, contentHeight - viewportHeight)
                clampedToBottom = previousOffset > bottomOffset + 0.5 && abs(contentOffset - bottomOffset) < 2
            } else { clampedToBottom = false }
            let semanticMotion = accessibilityOffsetIntent && !layoutChanged(from: previous) && !clampedToBottom
            return followPreference(after: previous, currentlyFollowing: currentlyFollowing,
                userIsScrolling: upwardDrag || semanticMotion, upwardDrag: upwardDrag)
        }

        func followPreference(after previous: Self, currentlyFollowing: Bool,
                              userIsScrolling: Bool, upwardDrag: Bool = false) -> Bool {
            guard let nearBottom = isPinnedToBottom else { return currentlyFollowing }
            let crossedDuringGrowth: Bool
            if viewportHeight == previous.viewportHeight,
               let offset = contentOffset, let oldOffset = previous.contentOffset,
               let height = contentHeight, let oldHeight = previous.contentHeight,
               offset.isFinite, oldOffset.isFinite, height.isFinite, oldHeight.isFinite {
                crossedDuringGrowth = offset - oldOffset > max(0, height - oldHeight) + 0.5
            } else { crossedDuringGrowth = false }
            // Reaching the end is a position, not a scroll phase. SwiftUI may publish the
            // final kinetic offset after the phase has already become idle. Once reached,
            // rubber-band recoil moves toward earlier offsets while still at the end;
            // that is not an instruction to stop following. Layout-only changes cannot
            // opt a reader back in. Only the existing four-point rendering tolerance counts.
            if nearBottom, offsetChanged(from: previous),
               (!layoutChanged(from: previous) || crossedDuringGrowth),
               currentlyFollowing || !movedTowardEarlierText(from: previous) {
                return true
            }
            guard userIsScrolling, offsetChanged(from: previous) else { return currentlyFollowing }
            // Actual upward movement wins over a simultaneous caption wrap or rotation.
            // Layout changes alone cannot pause following because no user scroll is active.
            if let contentHeight, let viewportHeight, contentHeight > viewportHeight + 1,
               movedTowardEarlierText(from: previous) { return false }
            guard !layoutChanged(from: previous) else { return currentlyFollowing }
            if upwardDrag {
                // A finger gesture may belong to the outer recording view or bounce a short
                // document. Pause only when older text in this viewport actually moves.
                if let contentHeight, let viewportHeight, contentHeight > viewportHeight + 1,
                   movedTowardEarlierText(from: previous) { return false }
                return currentlyFollowing
            }
            // The latest-button animation moves downward through older positions. It must
            // not suspend its own follow choice before reaching the bottom.
            if !currentlyFollowing {
                return !movedTowardEarlierText(from: previous) && nearBottom
            }
            if movedTowardEarlierText(from: previous) { return nearBottom }
            return currentlyFollowing
        }
    }

    struct GeometryKey: PreferenceKey {
        static let defaultValue = Geometry()
        static func reduce(value: inout Geometry, nextValue: () -> Geometry) {
            let next = nextValue()
            if let bottom = next.contentBottom { value.contentBottom = bottom }
            if let height = next.viewportHeight { value.viewportHeight = height }
            if let width = next.viewportWidth { value.viewportWidth = width }
            if let height = next.contentHeight { value.contentHeight = height }
            if let offset = next.contentOffset { value.contentOffset = offset }
        }
    }

    @ViewBuilder func body(content: Content) -> some View {
        if #available(iOS 18, macOS 15, *) {
            content
                .onScrollPhaseChange { _, phase in
                    self.isUserScrolling = phase == .interacting || phase == .decelerating
                }
                .onScrollGeometryChange(for: Geometry.self) { geometry in
                    .init(contentBottom: geometry.contentSize.height - geometry.visibleRect.minY,
                          viewportHeight: geometry.visibleRect.height, viewportWidth: geometry.visibleRect.width,
                          contentHeight: geometry.contentSize.height,
                          contentOffset: geometry.contentOffset.y)
                } action: { previous, current in
                    let following = current.followPreference(after: previous,
                        currentlyFollowing: self.isPinnedToBottom, userIsScrolling: self.isUserScrolling)
                    if following != self.isPinnedToBottom { self.isPinnedToBottom = following }
                    // Lazy realization can change estimated document height while browsing
                    // older paragraphs. Content updates have their own rendered revision;
                    // only a viewport resize warrants an independent layout follow request.
                    if current.viewportChanged(from: previous) { self.onLayoutChange() }
                }
        } else {
            content
                .coordinateSpace(name: self.viewport)
                .background {
                    GeometryReader { geometry in
                        Color.clear.preference(key: GeometryKey.self,
                            value: .init(viewportHeight: geometry.size.height, viewportWidth: geometry.size.width))
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
                }
                .onPreferenceChange(GeometryKey.self) { geometry in
                    defer { self.previousGeometry = geometry }
                    if let previous = self.previousGeometry {
                        // Geometry observes position, while the drag below owns the
                        // decision to pause. Layout corrections must not become gestures.
                        let wasFollowing = self.isPinnedToBottom
                        self.isPinnedToBottom = geometry.fallbackFollowPreference(after: previous,
                            currentlyFollowing: self.isPinnedToBottom,
                            upwardDrag: self.isDraggingUp,
                            accessibilityOffsetIntent: self.accessibilityOffsetIntent)
                        if wasFollowing != self.isPinnedToBottom {
                            DebugLogger.shared.debug("following=\(self.isPinnedToBottom) upwardDrag=\(self.isDraggingUp) layoutChanged=\(geometry.layoutChanged(from: previous)) offset=\(geometry.contentOffset ?? 0) previousOffset=\(previous.contentOffset ?? 0) height=\(geometry.contentHeight ?? 0)", source: "MeetingCaptionScroll")
                        }
                        if geometry.viewportChanged(from: previous) { self.onLayoutChange() }
                    }
                }
                .simultaneousGesture(DragGesture(minimumDistance: 2)
                    .onChanged { value in
                        self.isDraggingUp = value.translation.height > 2
                        // Latch manual reading before the next layout preference or queued
                        // auto-follow callback can move the same viewport back to the tail.
                        if self.isDraggingUp,
                           let geometry = self.previousGeometry,
                           let height = geometry.contentHeight, let viewport = geometry.viewportHeight,
                           height > viewport + 1 {
                            self.isPinnedToBottom = false
                        }
                    }
                    .onEnded { _ in self.isDraggingUp = false })
        }
    }
}

// Like bubble rows, unchanged paragraphs should not rebuild their attributed
// text when only microphone health or pending capture feedback changes.
private struct MeetingLiveParagraphRow: View, Equatable {
    let paragraph: MeetingLiveCaptionParagraphs.Paragraph
    let hidesPartialFromAccessibility: Bool
    let interfaceLanguageID: String
    var isTail = false
    var pending: MeetingPendingSpeechSnapshot = .empty
    @Environment(\.theme) private var theme

    static func == (lhs: MeetingLiveParagraphRow, rhs: MeetingLiveParagraphRow) -> Bool {
        lhs.paragraph == rhs.paragraph
            && lhs.hidesPartialFromAccessibility == rhs.hidesPartialFromAccessibility
            && lhs.interfaceLanguageID == rhs.interfaceLanguageID
            && lhs.isTail == rhs.isTail && lhs.pending == rhs.pending
    }

    private var flowingText: Text {
        var text = AttributedString()
        for (index, row) in self.paragraph.rows.enumerated() {
            let separator = MeetingLiveCaptionParagraphs.Paragraph.separator(
                after: index > 0 ? self.paragraph.rows[index - 1].text : nil, before: row.text)
            var fragment = AttributedString(separator + row.text)
            fragment.foregroundColor = row.isPartial ? self.theme.palette.secondaryText : self.theme.palette.primaryText
            text.append(fragment)
        }
        return Text(text)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if self.paragraph.showsLabel {
                Text(self.paragraph.captionLabel)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.paragraph.speaker == .you ? self.theme.palette.accentText : self.theme.palette.secondaryText)
            }
            Group {
                if self.isTail {
                    MeetingInlineCaptionText(rows: self.paragraph.rows, pending: self.pending)
                } else {
                    self.flowingText
                }
            }
                .font(self.theme.typography.body)
                .lineSpacing(5)
                .fixedSize(horizontal: false, vertical: true)
                .transaction { $0.animation = nil }
                .padding(.vertical, self.theme.metrics.spacing.sm)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(self.paragraph.captionLabel + ", "
            + self.paragraph.text(includingPartials: !self.hidesPartialFromAccessibility)
            + (self.pending.tokens.isEmpty ? "" : ", " + PichiLocalization.text("Audio captured, waiting for transcription")))
        .accessibilityHidden(self.hidesPartialFromAccessibility && self.paragraph.rows.allSatisfy(\.isPartial)
            && self.pending.tokens.isEmpty)
        .accessibilityIdentifier("meeting.liveParagraph.\(self.paragraph.id.uuidString)")
    }
}

struct MeetingLiveBubbleRow: View, Equatable {
    let row: MeetingLiveBubbleComposer.Row
    var hidesPartialFromAccessibility: Bool = true
    var documentStyle = false
    var interfaceLanguageID = PichiLocalization.language.rawValue
    var isTail = false
    var pending: MeetingPendingSpeechSnapshot = .empty

    @Environment(\.theme) private var theme
    @Environment(\.colorScheme) private var colorScheme

    static func == (lhs: MeetingLiveBubbleRow, rhs: MeetingLiveBubbleRow) -> Bool {
        lhs.row == rhs.row && lhs.hidesPartialFromAccessibility == rhs.hidesPartialFromAccessibility
            && lhs.documentStyle == rhs.documentStyle && lhs.interfaceLanguageID == rhs.interfaceLanguageID
            && lhs.isTail == rhs.isTail && lhs.pending == rhs.pending
    }

    private var isMicrophone: Bool { self.row.speaker == .you }

    private var sourceLabel: String {
        self.row.captionLabel
    }

    /// Distinguish capture sources without claiming that either source belongs to a person.
    private var fill: Color {
        let scheme = self.theme.palette.nativeColorScheme(fallback: self.colorScheme)
        let base = self.isMicrophone ? self.theme.palette.accent
            : MeetingSpeakerPalette.tint(forSpeakerIndex: 0, isDark: scheme == .dark)
        return base.opacity(self.row.isPartial ? 0.05 : 0.10)
    }

    var body: some View {
        VStack(alignment: self.isMicrophone && !self.documentStyle ? .trailing : .leading, spacing: 4) {
            if self.row.showsLabel {
                Text(self.sourceLabel)
                    .font(self.theme.typography.captionStrong)
                    .foregroundStyle(self.isMicrophone ? self.theme.palette.accentText : self.theme.palette.secondaryText)
            }
            Group {
                if self.isTail {
                    MeetingInlineCaptionText(rows: [self.row], pending: self.pending, documentStyle: self.documentStyle)
                } else {
                    Text(self.row.text)
                }
            }
                // The partial→final color swap solidifies in place; it must never animate.
                .transaction { $0.animation = nil }
                .meetingBubbleStyle(self.presentationStyle)
        }
        .frame(maxWidth: .infinity, alignment: self.isMicrophone && !self.documentStyle ? .trailing : .leading)
        .padding(self.isMicrophone ? .leading : .trailing, self.documentStyle ? 0 : 32)
        .accessibilityElement(children: .combine)
        .accessibilityLabel(self.sourceLabel + ", " + (self.hidesPartialFromAccessibility && self.row.isPartial ? "" : self.row.text)
            + (self.pending.tokens.isEmpty ? "" : ", " + PichiLocalization.text("Audio captured, waiting for transcription")))
        .accessibilityHidden(self.hidesPartialFromAccessibility && self.row.isPartial && self.pending.tokens.isEmpty)
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
