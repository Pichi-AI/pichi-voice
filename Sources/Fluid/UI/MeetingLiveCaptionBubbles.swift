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
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
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
        #if os(iOS)
        ZStack(alignment: .bottomTrailing) {
            MeetingNativeCaptionTable(rows: self.rows, paragraphs: self.paragraphs,
                revision: self.documentStyle ? self.renderedParagraphRevision : self.presentationRevision,
                textSize: self.dynamicTypeSize,
                documentStyle: self.documentStyle, pending: self.inlinePending,
                separatePending: self.separatePending,
                hidesPartialFromAccessibility: self.hidesPartialFromAccessibility,
                isPinned: self.$isPinnedToBottom)
            if !self.isPinnedToBottom {
                self.latestButton { self.isPinnedToBottom = true }
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
        #else
        self.legacyViewport
        #endif
    }

    private func latestButton(action: @escaping () -> Void) -> some View {
        Button(action: action) {
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

    #if !os(iOS)
    private var legacyViewport: some View {
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
                .onChange(of: self.dynamicTypeSize) {
                    self.scrollToBottomIfPinned(proxy: proxy)
                }
                .onChange(of: self.locale.identifier) {
                    self.scrollToBottomIfPinned(proxy: proxy)
                }
                .onAppear { self.scrollToBottomIfPinned(proxy: proxy) }

                if !self.isPinnedToBottom {
                    self.latestButton {
                        self.isPinnedToBottom = true
                        self.scrollToBottom(proxy: proxy, animated: true)
                    }
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
    #endif
}

#if os(iOS)
/// UIKit owns only the viewport. Composition, protected text and the shared row views
/// remain unchanged; stable cells give native text a measured scrolling extent.
private struct MeetingNativeCaptionTable: UIViewRepresentable {
    let rows: [MeetingLiveBubbleComposer.Row]
    let paragraphs: [MeetingLiveCaptionParagraphs.Paragraph]
    let revision: UInt64?
    let textSize: DynamicTypeSize
    let documentStyle: Bool
    let pending: MeetingPendingSpeechSnapshot
    let separatePending: MeetingPendingSpeechSnapshot
    let hidesPartialFromAccessibility: Bool
    @Binding var isPinned: Bool
    @Environment(\.self) private var environment

    private enum Item: Equatable {
        case paragraph(MeetingLiveCaptionParagraphs.Paragraph)
        case bubble(MeetingLiveBubbleComposer.Row)
        case pending
        var id: ID {
            switch self {
            case .paragraph(let value): .text(value.id)
            case .bubble(let value): .text(value.id)
            case .pending: .pending
            }
        }
    }
    private enum ID: Hashable { case text(UUID), pending }

    // Only presentation inputs used by the hosted views invalidate unchanged cells.
    // In particular, microphone ticks do not compare the transcript or rebuild its cells.
    private struct Appearance: Equatable {
        let colors: [Color]
        let fonts: [Font]
        let brandStyle: BrandStyle?
        let spacing: [CGFloat]
        let locale: String
        let typeSize: DynamicTypeSize
        let scheme: ColorScheme
        let direction: LayoutDirection
        let phase: ScenePhase
        let reduceMotion: Bool
    }
    private var appearance: Appearance {
        let theme = environment.theme, palette = theme.palette
        return Appearance(colors: [palette.primaryText, palette.secondaryText, palette.accent,
            palette.accentText, palette.contentBackground],
            fonts: [theme.typography.body, theme.typography.captionStrong],
            brandStyle: theme.typography.brandStyle,
            spacing: [theme.metrics.spacing.xs, theme.metrics.spacing.sm],
            locale: environment.locale.identifier, typeSize: textSize,
            scheme: environment.colorScheme, direction: environment.layoutDirection,
            phase: environment.scenePhase, reduceMotion: environment.accessibilityReduceMotion)
    }

    final class Table: UITableView {
        let measurementContainer = UIView()
        var didLayout: ((Table) -> Void)?
        override func didMoveToWindow() {
            super.didMoveToWindow()
            if window != nil { setNeedsLayout() }
        }
        override func layoutSubviews() {
            super.layoutSubviews()
            didLayout?(self)
        }
    }

    /// A cell owns its ordinary host; the coordinator retains just the live tail
    /// and pending hosts so fitting never creates a second waveform renderer.
    final class Cell: UITableViewCell {
        var ordinaryHost: (UIView & UIContentView)?
        private var installedHost: UIView?
        func install(_ host: UIView) {
            guard installedHost !== host || host.superview !== contentView else { return }
            if installedHost?.superview === contentView { installedHost?.removeFromSuperview() }
            installedHost = host
            host.removeFromSuperview()
            host.translatesAutoresizingMaskIntoConstraints = false
            contentView.addSubview(host)
            NSLayoutConstraint.activate([
                host.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                host.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
                host.topAnchor.constraint(equalTo: contentView.topAnchor),
                host.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
            ])
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator() }
    func makeUIView(context: Context) -> Table {
        let table = Table(frame: .zero, style: .plain)
        table.backgroundColor = .clear
        table.separatorStyle = .none
        table.contentInsetAdjustmentBehavior = .never
        // Exact delegate heights keep scrolling independent of estimate replacement.
        table.estimatedRowHeight = 0
        table.estimatedSectionHeaderHeight = 0
        table.estimatedSectionFooterHeight = 0
        table.selfSizingInvalidation = .disabled
        table.sectionHeaderTopPadding = 0
        table.allowsSelection = false
        table.register(Cell.self, forCellReuseIdentifier: "caption")
        table.measurementContainer.isHidden = true
        table.addSubview(table.measurementContainer)
        table.accessibilityIdentifier = "meeting.liveTranscript.viewport"
        table.dataSource = context.coordinator
        table.delegate = context.coordinator
        table.didLayout = { [weak coordinator = context.coordinator] table in coordinator?.didLayout(table) }
        return table
    }
    func updateUIView(_ table: Table, context: Context) { context.coordinator.update(self, table: table) }

    final class Coordinator: NSObject, UITableViewDataSource, UITableViewDelegate {
        private var input: MeetingNativeCaptionTable?
        private var queuedInput: MeetingNativeCaptionTable?
        private var items: [Item] = []
        private var following = true
        private var publishedFollowing = true
        private var applying = false
        private var correctingOffset = false
        private var needsFollow = false
        private var lastContentSize = CGSize.zero
        private var lastViewportSize = CGSize.zero
        private var previousOffset: CGFloat = 0
        private var userScroll = false
        private var heights: [ID: CGFloat] = [:]
        private var measuredWidth: CGFloat = 0
        private var sizingHost: (UIView & UIContentView)?
        private var activeHosts: [ID: UIView & UIContentView] = [:]
        private var dirtyHosts: Set<ID> = []

        private var tailIndex: Int { items.count - (items.last?.id == .pending ? 2 : 1) }
        private func isActive(_ index: Int) -> Bool { index == tailIndex || items[index].id == .pending }

        fileprivate func update(_ next: MeetingNativeCaptionTable, table: Table) {
            guard !applying, table.window != nil, table.bounds.width > 0 else {
                queuedInput = next
                return
            }
            let previous = input
            let widthChanged = measuredWidth != table.bounds.width
            measuredWidth = table.bounds.width
            let sourceChanged: Bool
            if let previous, previous.documentStyle == next.documentStyle {
                sourceChanged = next.revision != nil && previous.revision != nil
                    ? next.revision != previous.revision
                    : (next.documentStyle ? next.paragraphs != previous.paragraphs : next.rows != previous.rows)
            } else { sourceChanged = true }
            let appearanceChanged = previous?.appearance != next.appearance
                || previous?.hidesPartialFromAccessibility != next.hidesPartialFromAccessibility
            let metricsChanged = widthChanged || previous?.appearance.fonts != next.appearance.fonts
                || previous?.appearance.brandStyle != next.appearance.brandStyle
                || previous?.appearance.spacing != next.appearance.spacing
                || previous?.appearance.locale != next.appearance.locale
                || previous?.appearance.typeSize != next.appearance.typeSize
                || previous?.appearance.direction != next.appearance.direction
            let pendingChanged = previous?.pending != next.pending || previous?.separatePending != next.separatePending
            let jumpRequested = next.isPinned != publishedFollowing
            if jumpRequested { following = next.isPinned; publishedFollowing = next.isPinned }
            input = next
            guard sourceChanged || appearanceChanged || pendingChanged || widthChanged else {
                if jumpRequested && following { needsFollow = true; table.setNeedsLayout() }
                return
            }

            let oldItems = sourceChanged ? items : []
            let firstVisible = table.indexPathsForVisibleRows?.min()
            let anchor = !following ? firstVisible.flatMap { path -> (ID, Int, CGFloat)? in
                guard items.indices.contains(path.row) else { return nil }
                return (items[path.row].id, path.row, table.rectForRow(at: path).minY - table.contentOffset.y)
            } : nil
            var removals: [IndexPath] = [], insertions: [IndexPath] = [], changed: [IndexPath] = []
            if sourceChanged {
                items = next.documentStyle ? next.paragraphs.map(Item.paragraph) : next.rows.map(Item.bubble)
                if !next.separatePending.tokens.isEmpty { items.append(.pending) }
                let oldIDs = oldItems.map(\.id), newIDs = items.map(\.id)
                for change in newIDs.difference(from: oldIDs) {
                    switch change {
                    case .remove(let index, _, _): removals.append(IndexPath(row: index, section: 0))
                    case .insert(let index, _, _): insertions.append(IndexPath(row: index, section: 0))
                    }
                }
                let oldByID = Dictionary(uniqueKeysWithValues: oldItems.map { ($0.id, $0) })
                let oldTail = oldItems.last(where: { $0.id != .pending })?.id
                let newTail = items.last(where: { $0.id != .pending })?.id
                changed = items.enumerated().compactMap { index, item in
                    guard let old = oldByID[item.id] else { return nil }
                    return appearanceChanged || old != item || item.id == oldTail || item.id == newTail || item.id == .pending
                        ? IndexPath(row: index, section: 0) : nil
                }
            } else {
                // Pending updates have bounded work: only the last text cell and the
                // optional pending cell change, retaining their hosting/attachment identity.
                let hadPending = items.last?.id == .pending
                let hasPending = !next.separatePending.tokens.isEmpty
                if hadPending && !hasPending {
                    removals = [IndexPath(row: items.count - 1, section: 0)]; items.removeLast()
                } else if !hadPending && hasPending {
                    insertions = [IndexPath(row: items.count, section: 0)]; items.append(.pending)
                }
                let first = appearanceChanged ? 0 : max(0, items.count - (hasPending ? 2 : 1))
                changed = (first..<items.count).map { IndexPath(row: $0, section: 0) }.filter { !insertions.contains($0) }
            }
            // Heights survive ordinary capture ticks and unchanged source rows. Global
            // text metrics require one full remeasurement, not a replacement of live cells.
            if metricsChanged { heights.removeAll(keepingCapacity: true) }
            for path in changed + insertions {
                if sourceChanged || pendingChanged || metricsChanged { heights.removeValue(forKey: items[path.row].id) }
                dirtyHosts.insert(items[path.row].id)
            }
            if sourceChanged {
                let retained = Set(items.map(\.id))
                heights = heights.filter { retained.contains($0.key) }
            }
            let activeIDs = Set([tailIndex, items.count - 1].filter { items.indices.contains($0) }.map { items[$0].id })
            activeHosts = activeHosts.filter { id, host in
                if activeIDs.contains(id) { return true }
                // A recycled cell may still retain this host after it leaves the
                // viewport. Retire its native attachments before creating a new tail.
                host.configuration = UIHostingConfiguration { AnyView(EmptyView()) }.margins(.all, 0)
                if host.superview === table.measurementContainer { host.removeFromSuperview() }
                return false
            }
            dirtyHosts.formIntersection(activeIDs)
            if appearanceChanged || widthChanged { dirtyHosts.formUnion(activeIDs) }
            applying = true
            needsFollow = following
            let finish: () -> Void = { [weak self, weak table] in
                guard let self, let table else { return }
                // Reconfigure after structural changes so paths address the final model.
                // Unlike reloadRows, this keeps an existing hosted native text view alive.
                table.reconfigureRows(at: changed)
                // Delegate heights, including offscreen rows, must be refreshed after
                // a fit changes. An empty update preserves all existing cell hosts.
                table.beginUpdates()
                table.endUpdates()
                table.layoutIfNeeded()
                let anchorIndex = anchor.flatMap { value in
                    sourceChanged ? self.items.firstIndex(where: { $0.id == value.0 })
                        : (self.items.indices.contains(value.1) && self.items[value.1].id == value.0 ? value.1 : nil)
                }
                if let anchor, let index = anchorIndex, !self.following {
                    let y = table.rectForRow(at: IndexPath(row: index, section: 0)).minY - anchor.2
                    table.setContentOffset(CGPoint(x: table.contentOffset.x, y: y), animated: false)
                }
                self.applying = false
                self.didLayout(table)
                if let queued = self.queuedInput {
                    self.queuedInput = nil
                    self.update(queued, table: table)
                }
            }
            UIView.performWithoutAnimation {
                if previous == nil { table.reloadData(); finish() }
                else if removals.isEmpty && insertions.isEmpty { finish() }
                else {
                    table.performBatchUpdates {
                        table.deleteRows(at: removals, with: .none)
                        table.insertRows(at: insertions, with: .none)
                    } completion: { _ in finish() }
                }
            }
        }

        func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int { items.count }
        func tableView(_ tableView: UITableView, heightForRowAt indexPath: IndexPath) -> CGFloat {
            let id = items[indexPath.row].id
            if let height = heights[id] { return height }
            guard let table = tableView as? Table, table.window != nil, table.bounds.width > 0 else { return 1 }
            let host: UIView & UIContentView
            if isActive(indexPath.row) {
                host = activeHost(at: indexPath.row, table: table)
            } else {
                let configuration = configuration(at: indexPath.row)
                if let sizingHost { sizingHost.configuration = configuration; host = sizingHost }
                else {
                    host = configuration.makeContentView()
                    sizingHost = host
                    table.measurementContainer.addSubview(host)
                }
            }
            host.bounds.size.width = table.bounds.width
            host.invalidateIntrinsicContentSize()
            host.setNeedsLayout()
            host.layoutIfNeeded()
            let fitted = host.systemLayoutSizeFitting(CGSize(width: table.bounds.width, height: 0),
                withHorizontalFittingPriority: .required, verticalFittingPriority: .fittingSizeLevel)
            let scale = table.window?.screen.scale ?? 1
            let height = max(1, ceil(fitted.height * scale) / scale)
            heights[id] = height
            return height
        }

        private func activeHost(at index: Int, table: Table) -> UIView & UIContentView {
            let id = items[index].id
            if let host = activeHosts[id] {
                if dirtyHosts.remove(id) != nil { host.configuration = configuration(at: index) }
                return host
            }
            let host = configuration(at: index).makeContentView()
            activeHosts[id] = host
            dirtyHosts.remove(id)
            table.measurementContainer.addSubview(host)
            return host
        }

        func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
            let cell = tableView.dequeueReusableCell(withIdentifier: "caption", for: indexPath) as! Cell
            guard let table = tableView as? Table else { return cell }
            let host: UIView & UIContentView
            if isActive(indexPath.row) { host = activeHost(at: indexPath.row, table: table) }
            else {
                let configuration = configuration(at: indexPath.row)
                if let ordinary = cell.ordinaryHost { ordinary.configuration = configuration; host = ordinary }
                else { host = configuration.makeContentView(); cell.ordinaryHost = host }
            }
            cell.backgroundColor = .clear
            cell.selectionStyle = .none
            cell.install(host)
            return cell
        }

        private func configuration(at index: Int) -> UIHostingConfiguration<AnyView, EmptyView> {
            let input = self.input!
            let item = items[index]
            let isTail = index == tailIndex
            let pending = isTail ? input.pending : .empty
            let bottomPadding = index == items.count - 1 ? 1 : input.environment.theme.metrics.spacing.sm
            return UIHostingConfiguration {
                AnyView(Group {
                    switch item {
                    case .paragraph(let paragraph):
                        MeetingLiveParagraphRow(paragraph: paragraph,
                            hidesPartialFromAccessibility: input.hidesPartialFromAccessibility,
                            interfaceLanguageID: input.environment.locale.identifier, isTail: isTail, pending: pending)
                    case .bubble(let row):
                        MeetingLiveBubbleRow(row: row,
                            hidesPartialFromAccessibility: input.hidesPartialFromAccessibility,
                            interfaceLanguageID: input.environment.locale.identifier, isTail: isTail, pending: pending)
                    case .pending:
                        MeetingPendingSpeechView(pending: input.separatePending)
                            .padding(.top, input.environment.theme.metrics.spacing.xs)
                    }
                }
                .padding(.bottom, bottomPadding)
                .frame(maxWidth: .infinity, alignment: .leading)
                .environment(\.self, input.environment)
                .environment(\.dynamicTypeSize, input.textSize)
                .id(item.id))
            }.margins(.all, 0)
        }

        private func bottom(_ scroll: UIScrollView) -> CGFloat {
            max(-scroll.adjustedContentInset.top,
                scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
        }
        fileprivate func didLayout(_ table: Table) {
            guard !applying, !correctingOffset, table.window != nil, table.bounds.width > 0 else { return }
            if let queued = queuedInput {
                queuedInput = nil
                update(queued, table: table)
                return
            }
            if measuredWidth != table.bounds.width, let input {
                update(input, table: table)
                return
            }
            let viewportChanged = lastViewportSize != table.bounds.size
            let extentChanged = lastContentSize != table.contentSize
            lastContentSize = table.contentSize; lastViewportSize = table.bounds.size
            let tailVisible = table.indexPathsForVisibleRows?.contains(IndexPath(row: items.count - 1, section: 0)) == true
            // An unrelated programmatic offset must remain reachable. Only new data or
            // reflow of an already visible tail may correct a following viewport.
            guard following, !table.isDragging, !table.isDecelerating,
                  needsFollow || viewportChanged || (extentChanged && tailVisible), !items.isEmpty, table.bounds.height > 0 else { return }
            needsFollow = false
            correctingOffset = true
            table.scrollToRow(at: IndexPath(row: items.count - 1, section: 0), at: .bottom, animated: false)
            table.layoutIfNeeded()
            table.setContentOffset(CGPoint(x: table.contentOffset.x, y: bottom(table)), animated: false)
            correctingOffset = false
            previousOffset = table.contentOffset.y
        }

        func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
            userScroll = true; previousOffset = scrollView.contentOffset.y
        }
        func scrollViewDidScroll(_ scrollView: UIScrollView) {
            defer { previousOffset = scrollView.contentOffset.y }
            // VoiceOver can move its reading viewport without a pan gesture. Owned
            // layout corrections remain excluded by the same guards as native drags.
            guard userScroll || UIAccessibility.isVoiceOverRunning, !applying, !correctingOffset else { return }
            let nearBottom = scrollView.contentOffset.y >= bottom(scrollView) - 4
            let canReadEarlier = bottom(scrollView) > -scrollView.adjustedContentInset.top + 1
            let next = nearBottom ? true
                : (canReadEarlier && scrollView.contentOffset.y < previousOffset - 0.5 ? false : following)
            guard next != following else { return }
            following = next
            needsFollow = false
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.publishedFollowing = self.following
                self.input?.isPinned = self.following
            }
        }
        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            scrollViewDidScroll(scrollView)
            if !decelerate { userScroll = false }
        }
        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            scrollViewDidScroll(scrollView); userScroll = false
        }
    }
}
#endif

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
