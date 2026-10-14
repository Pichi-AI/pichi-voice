import XCTest
import Combine
import SwiftUI
import UIKit
@testable import PichiVoiceMobile

final class MeetingLiveCaptionPresentationTests: XCTestCase {
    private func row(_ text: String, speaker: MeetingLiveSpeaker = .you, id: UUID = UUID(),
                     partial: Bool = false, label: Bool = false) -> MeetingLiveBubbleComposer.Row {
        .init(id: id, speaker: speaker, text: text, isPartial: partial, showsLabel: label)
    }

    func testWordTimingRowsFlowWithoutChangingCanonicalMembers() {
        let rows = [row("Здравствуйте", label: true), row(","), row("давайте"), row("обсудим"), row("инструкцию.")]
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text(), "Здравствуйте, давайте обсудим инструкцию.")
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows, "Presentation must retain every original row and its ID")
        XCTAssertEqual(paragraphs[0].id, rows[0].id)
        XCTAssertTrue(paragraphs[0].showsLabel)
    }

    func testSourceChangeAndExplicitBreakRemainVisible() {
        let rows = [row("Первая строка\nВторая строка", label: true), row("Продолжение"),
                    row("English response", speaker: .them, label: true), row("follows", speaker: .them)]
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertEqual(paragraphs.map { $0.text() }, ["Первая строка\nВторая строка", "Продолжение", "English response follows"])
        XCTAssertEqual(paragraphs.map(\.speaker), [.you, .you, .them])
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows)
    }

    func testPartialGrowthCorrectionAndSolidificationKeepParagraphIdentity() {
        let committed = row("Начало", label: true)
        let partialID = UUID()
        let short = [committed, row("жду", id: partialID, partial: true)]
        let correction = [committed, row("иду", id: partialID, partial: true)]
        let long = [committed, row(String(repeating: "слово ", count: 150), id: partialID, partial: true)]
        let finalized = [committed, row(long[1].text, id: partialID)]
        XCTAssertNotEqual(short, correction, "Equal-length hypotheses must still invalidate content observers")
        for rows in [short, correction, long, finalized] {
            let paragraph = MeetingLiveCaptionParagraphs.compose(rows)
            XCTAssertEqual(paragraph.count, 1)
            XCTAssertEqual(paragraph[0].id, committed.id)
            XCTAssertEqual(paragraph[0].rows[1].id, partialID)
        }
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(short)[0].text(includingPartials: false), "Начало")
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(correction)[0].text(), "Начало иду")
    }

    func testLongWordStreamHasBoundedParagraphsWithoutDroppingWords() {
        let rows = (0..<600).map { row("слово\($0)", label: $0 == 0) }
        let paragraphs = MeetingLiveCaptionParagraphs.compose(rows)
        XCTAssertGreaterThan(paragraphs.count, 5)
        XCTAssertEqual(paragraphs.flatMap(\.rows), rows)
        XCTAssertTrue(paragraphs.allSatisfy { $0.text().count <= 530 })
        XCTAssertEqual(Set(paragraphs.map(\.id)).count, paragraphs.count)
        XCTAssertTrue(MeetingLiveCaptionParagraphs.compose([]).isEmpty)
    }

    func testChronologicalReorderingRetainsCanonicalMembersAndSourceBoundaries() {
        let first = row("Начало", label: true)
        let remote = row("Response", speaker: .them, label: true)
        let turnID = UUID()
        let partial = row("продолжение", id: turnID, partial: true, label: true)
        let liveRows = [first, remote, partial]
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(liveRows).flatMap(\.rows), liveRows)
        let finalRows = [first, row("продолжение", id: turnID), remote]
        let paragraphs = MeetingLiveCaptionParagraphs.compose(finalRows)
        XCTAssertEqual(paragraphs.map { $0.text() }, ["Начало продолжение", "Response"])
        XCTAssertEqual(paragraphs.flatMap(\.rows), finalRows)
        XCTAssertEqual(paragraphs[0].rows[1].id, turnID,
                       "Chronological reflow can regroup a turn but must retain its canonical identity")
    }

    func testSensitivePlaceholdersAndExistingWhitespaceAreNotRewritten() {
        let rows = [row("Позвоните "), row("[PERSON]"), row(" по адресу [ADDRESS]."), row("\n"), row("[PHONE]")]
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(rows).map { $0.text() }.joined(separator: "\n"),
                       "Позвоните [PERSON] по адресу [ADDRESS].\n\n[PHONE]")
        XCTAssertEqual(MeetingLiveCaptionParagraphs.compose(rows).flatMap(\.rows), rows)
    }

    func testGrowthIsLayoutChangeRatherThanScrollIntent() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let before = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 600, contentOffset: 300)
        let grown = Geometry(contentBottom: 900, viewportHeight: 300, contentHeight: 1200, contentOffset: 300)
        XCTAssertEqual(before.isPinnedToBottom, true)
        XCTAssertEqual(grown.isPinnedToBottom, false, "Proximity changes, but the follow preference must not")
        XCTAssertTrue(grown.layoutChanged(from: before))
        XCTAssertFalse(grown.offsetChanged(from: before))
        XCTAssertTrue(grown.followPreference(after: before, currentlyFollowing: true, userIsScrolling: true))
        let bottomBeforeShrink = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 900, contentOffset: 600)
        let shrink = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 600, contentOffset: 300)
        XCTAssertTrue(shrink.fallbackFollowPreference(after: bottomBeforeShrink,
            currentlyFollowing: true, upwardDrag: false), "iOS 17 layout shrink must not look like an upward drag")
        var heightPublishedBeforeClamp = shrink
        heightPublishedBeforeClamp.contentOffset = bottomBeforeShrink.contentOffset
        XCTAssertTrue(shrink.fallbackFollowPreference(after: heightPublishedBeforeClamp,
            currentlyFollowing: true, upwardDrag: false), "A later offset-only clamp belongs to the previous layout change")
        let userScrolled = Geometry(contentBottom: 450, viewportHeight: 300, contentHeight: 600, contentOffset: 150)
        XCTAssertFalse(userScrolled.layoutChanged(from: before))
        XCTAssertTrue(userScrolled.offsetChanged(from: before))
        XCTAssertEqual(userScrolled.isPinnedToBottom, false)
        XCTAssertFalse(userScrolled.followPreference(after: before, currentlyFollowing: true, userIsScrolling: true))
        let reflow = Geometry(contentBottom: 850, viewportHeight: 300, contentHeight: 1200, contentOffset: 350)
        XCTAssertTrue(reflow.followPreference(after: before, currentlyFollowing: true, userIsScrolling: true),
                      "A reflow that also adjusts the offset must retain the follow preference")
    }

    func testUpwardDragPausesOnlyScrollableTextAndLatestMotionKeepsFollowing() {
        typealias Geometry = MeetingCaptionScrollTracking.Geometry
        let short = Geometry(contentBottom: 100, viewportHeight: 300, contentHeight: 100, contentOffset: 0)
        let bounce = Geometry(contentBottom: 120, viewportHeight: 300, contentHeight: 100, contentOffset: -20)
        XCTAssertTrue(bounce.followPreference(after: short, currentlyFollowing: true, userIsScrolling: true, upwardDrag: true))
        let bottom = Geometry(contentBottom: 300, viewportHeight: 300, contentHeight: 900, contentOffset: 600)
        let up = Geometry(contentBottom: 320, viewportHeight: 300, contentHeight: 900, contentOffset: 580)
        XCTAssertFalse(up.followPreference(after: bottom, currentlyFollowing: true, userIsScrolling: true, upwardDrag: true))
        let growingWhileUp = Geometry(contentBottom: 360, viewportHeight: 300, contentHeight: 940, contentOffset: 580)
        XCTAssertFalse(growingWhileUp.followPreference(after: bottom, currentlyFollowing: true, userIsScrolling: true),
                       "New captions must not override simultaneous reading of older text")
        XCTAssertFalse(growingWhileUp.followPreference(after: bottom, currentlyFollowing: true, userIsScrolling: true, upwardDrag: true))
        XCTAssertFalse(growingWhileUp.fallbackFollowPreference(after: bottom,
            currentlyFollowing: true, upwardDrag: true), "iOS 17 must respect an upward drag during content growth")
        XCTAssertTrue(growingWhileUp.followPreference(after: bottom, currentlyFollowing: true, userIsScrolling: false),
                      "Layout growth without a user gesture must keep following")
        let momentumUp = Geometry(contentBottom: 330, viewportHeight: 300, contentHeight: 900, contentOffset: 570)
        XCTAssertFalse(momentumUp.followPreference(after: up, currentlyFollowing: false, userIsScrolling: true),
                       "A small deliberate upward drag must remain paused during deceleration")
        let older = Geometry(contentBottom: 700, viewportHeight: 300, contentHeight: 900, contentOffset: 200)
        let movingDown = Geometry(contentBottom: 600, viewportHeight: 300, contentHeight: 900, contentOffset: 300)
        XCTAssertTrue(movingDown.followPreference(after: older, currentlyFollowing: true, userIsScrolling: true),
                      "An explicit latest action must remain active during its animation")
        XCTAssertFalse(movingDown.followPreference(after: older, currentlyFollowing: false, userIsScrolling: true),
                       "A reader moving down through older text has not reached the bottom yet")
        XCTAssertFalse(up.followPreference(after: movingDown, currentlyFollowing: false, userIsScrolling: true),
                       "Twenty points above the bottom must not resume following")
        XCTAssertFalse(up.fallbackFollowPreference(after: movingDown, currentlyFollowing: false, upwardDrag: false))
        XCTAssertTrue(bottom.followPreference(after: movingDown, currentlyFollowing: false, userIsScrolling: true))
    }
}

/// Hosted native rendering tests. Input rows are synthetic; the caption view, SwiftUI
/// layout and backing UIScrollView are real. This fixture never composes audio services.
@MainActor
final class MeetingLiveCaptionNativeScrollTests: XCTestCase {
    func testNativeScrollingRemainsResponsiveWhileNativeWorkIsBlocked() async throws {
        let host = try CaptionNativeHost(rows: wordRows(count: 360), scheme: .light)
        defer { host.close() }
        let scroll = try await captionScroll(in: host)
        try await settle(host, "Initial native document follows the bottom") { self.nearBottom(scroll) }
        let probe = BlockingNativeProbe()
        let executor = TranscriptionExecutor()
        let work = Task { try await executor.runBlocking { probe.run() } }
        do {
            let deadline = ContinuousClock.now.advanced(by: .seconds(1))
            while !probe.hasEntered, ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
            XCTAssertTrue(probe.hasEntered)
            XCTAssertFalse(probe.hasFinished)
            XCTAssertFalse(probe.ranOnMainThread)
            let olderOffset = max(0, bottomOffset(scroll) - 250)
            scroll.setContentOffset(CGPoint(x: 0, y: olderOffset), animated: false)
            try await settle(host, "Native viewport can scroll while synchronous work is still running") {
                abs(scroll.contentOffset.y - olderOffset) < 3 && !probe.hasFinished
            }
            capture(host, step: "01-scrolled-during-native-work", scheme: .light)
            probe.release()
            let released = try await work.value
            XCTAssertTrue(released)
        } catch {
            probe.release()
            _ = await work.result
            throw error
        }
    }

    func testPendingWaveformsGrowAndBecomeRealTextInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let originalRows = wordRows(count: 260)
            let host = try CaptionNativeHost(rows: originalRows, scheme: scheme)
            defer { host.close() }
            let scroll = try await captionScroll(in: host)
            try await settle(host, "Initial transcript follows the bottom") { self.nearBottom(scroll) }
            let originalHeight = scroll.contentSize.height
            host.model.pending = pending(count: 12)
            try await settle(host, "Pending audio appears after the real text") {
                scroll.contentSize.height > originalHeight + 15 && self.nearBottom(scroll)
            }
            capture(host, step: "01-pending-waveforms", scheme: scheme)
            let shortHeight = scroll.contentSize.height
            host.model.pending = pending(count: 40)
            try await settle(host, "New pending words wrap and remain visible") {
                scroll.contentSize.height > shortHeight + 20 && self.nearBottom(scroll)
            }
            capture(host, step: "02-pending-growth", scheme: scheme)
            XCTAssertEqual(host.model.rows, originalRows, "Visual placeholders must not enter transcript rows")

            host.model.rows += [row("Распознанный текст. The real words replace pending audio.")]
            host.model.pending = .empty
            try await settle(host, "Approved text replaces the waveforms without losing following") { self.nearBottom(scroll) }
            capture(host, step: "03-recognized-text", scheme: scheme)
            XCTAssertEqual(host.model.rows.dropLast(), originalRows[...])
            let beforeMoreAudio = scroll.contentSize.height
            host.model.pending = pending(count: 32)
            try await settle(host, "Following survives pending-to-text replacement") {
                scroll.contentSize.height > beforeMoreAudio + 20 && self.nearBottom(scroll)
            }
            host.model.width *= 0.65
            try await settle(host, "Pending audio follows after viewport reflow") {
                abs(scroll.bounds.width - host.model.width) < 2 && self.nearBottom(scroll)
            }
            capture(host, step: "04-narrow-waveforms", scheme: scheme)
        }
    }

    private func pending(count: Int) -> MeetingPendingSpeechSnapshot {
        .init(tokens: (0..<count).map { index in
            .init(id: UInt64(index + 1), source: .you, start: Double(index) * 0.4,
                  end: Double(index + 1) * 0.4, widthHint: 0.55 + Double(index % 7) * 0.09, level: 0.65)
        }, isCapturing: true, revision: UInt64(count))
    }

    func testNativeWordRowsPartialCorrectionsAndReflowFollowLatestInBothThemes() async throws {
        for scheme in [ColorScheme.light, .dark] {
            let partialID = UUID()
            let initialPartial = row(String(repeating: "i", count: 120), id: partialID, partial: true)
            let initialRows = wordRows(count: 260) + [initialPartial]
            let host = try CaptionNativeHost(rows: initialRows, scheme: scheme)
            defer { host.close() }
            let scroll = try await captionScroll(in: host)
            try await settle(host, "Initial long document must follow the bottom") { self.nearBottom(scroll) }
            XCTAssertGreaterThan(scroll.contentSize.height, scroll.bounds.height + 200)
            capture(host, step: "01-word-rows-bottom", scheme: scheme)

            let beforeAppend = scroll.contentSize.height
            host.model.rows = Array(initialRows.dropLast()) + wordRows(count: 80) + [initialPartial]
            try await settle(host, "New committed word rows must stay visible") {
                scroll.contentSize.height > beforeAppend + 20 && self.nearBottom(scroll)
            }
            let beforeCorrectionImage = capture(host, step: "02-committed-words-appended", scheme: scheme)

            let beforeCorrection = scroll.contentSize.height
            let previousPartial = try XCTUnwrap(host.model.rows.last)
            var corrected = previousPartial
            corrected.text = String(repeating: "Ш", count: previousPartial.text.count)
            XCTAssertEqual(corrected.text.count, previousPartial.text.count)
            XCTAssertEqual(corrected.id, partialID)
            host.model.rows[host.model.rows.count - 1] = corrected
            try await settle(host, "An equal-length same-ID correction must retain the latest position") {
                scroll.contentSize.height >= beforeCorrection - 2 && self.nearBottom(scroll)
            }
            let correctedImage = capture(host, step: "03-equal-length-partial-correction", scheme: scheme)
            // Proportional fonts also reflow here. A supported monospaced brand can retain
            // identical geometry, so inspect actual native pixels rather than assuming glyph widths.
            let beforeBitmap = try XCTUnwrap(beforeCorrectionImage.cgImage)
            let correctedBitmap = try XCTUnwrap(correctedImage.cgImage)
            XCTAssertEqual(beforeBitmap.width, correctedBitmap.width)
            XCTAssertEqual(beforeBitmap.height, correctedBitmap.height)
            XCTAssertEqual(beforeBitmap.bitsPerPixel, correctedBitmap.bitsPerPixel)
            XCTAssertEqual(beforeBitmap.bytesPerRow, correctedBitmap.bytesPerRow)
            let beforePixels = try XCTUnwrap(beforeBitmap.dataProvider?.data) as Data
            let correctedPixels = try XCTUnwrap(correctedBitmap.dataProvider?.data) as Data
            XCTAssertNotEqual(beforePixels, correctedPixels, "Equal-length partial correction must change the rendered text")

            let beforeGrowth = scroll.contentSize.height
            host.model.rows[host.model.rows.count - 1].text += String(repeating: " продолжение", count: 55)
            try await settle(host, "A growing partial with unchanged row count and ID must follow") {
                scroll.contentSize.height > beforeGrowth + 80 && self.nearBottom(scroll)
            }
            capture(host, step: "04-same-id-partial-growth", scheme: scheme)

            let beforeNarrowing = scroll.contentSize.height
            let originalWidth = host.model.width
            host.model.width = originalWidth * 0.65
            try await settle(host, "Width reflow must retain the latest position") {
                abs(scroll.bounds.width - host.model.width) < 2
                    && scroll.contentSize.height > beforeNarrowing + 20 && self.nearBottom(scroll)
            }
            capture(host, step: "05-narrower-viewport-following", scheme: scheme)

            let beforeShrink = scroll.contentSize.height
            host.model.rows = wordRows(count: 100) + [row("Встреча продолжается. English version remains visible.", partial: true)]
            try await settle(host, "Content shrink must retain the latest position") {
                scroll.contentSize.height < beforeShrink - 100 && self.nearBottom(scroll)
            }
            capture(host, step: "06-content-shrink-following", scheme: scheme)
            let shrunkHeight = scroll.contentSize.height
            host.model.rows = Array(host.model.rows.dropLast()) + wordRows(count: 100)
                + [row("Новый текст после изменения размера.", partial: true)]
            try await settle(host, "Following must remain active after the previous content shrink") {
                scroll.contentSize.height > shrunkHeight + 100 && self.nearBottom(scroll)
            }
            capture(host, step: "07-append-after-shrink", scheme: scheme)
        }
    }

    func testIOS17NonTouchScrollToOlderTextStaysPausedWhenNewRowsArrive() async throws {
        guard #unavailable(iOS 18) else {
            throw XCTSkip("This exercises the iOS 17 offset-based fallback. Programmatic UIKit scrolling does not simulate a user scroll phase on iOS 18+.")
        }
        for scheme in [ColorScheme.light, .dark] {
            let host = try CaptionNativeHost(rows: wordRows(count: 360), scheme: scheme)
            defer { host.close() }
            let scroll = try await captionScroll(in: host)
            try await settle(host, "Initial captions must be bottom-pinned") { self.nearBottom(scroll) }
            capture(host, step: "01-before-non-touch-scroll", scheme: scheme)

            let olderOffset = max(-scroll.adjustedContentInset.top, self.bottomOffset(scroll) - 250)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: olderOffset), animated: false)
            try await settle(host, "UIKit non-touch movement must reach older text") {
                abs(scroll.contentOffset.y - olderOffset) < 3 && !self.nearBottom(scroll)
            }
            capture(host, step: "02-non-touch-older-text", scheme: scheme)

            let oldContentHeight = scroll.contentSize.height
            host.model.rows += wordRows(count: 120)
            try await settle(host, "New captions must not pull an older-text reader back to the bottom") {
                scroll.contentSize.height > oldContentHeight + 40
                    && abs(scroll.contentOffset.y - olderOffset) < 3 && !self.nearBottom(scroll)
            }
            capture(host, step: "03-appended-while-paused", scheme: scheme)
            let heightBeforePending = scroll.contentSize.height
            host.model.pending = pending(count: 40)
            try await settle(host, "Pending waveforms must also respect reading older text") {
                scroll.contentSize.height > heightBeforePending + 20
                    && abs(scroll.contentOffset.y - olderOffset) < 3 && !self.nearBottom(scroll)
            }
            capture(host, step: "04-pending-while-paused", scheme: scheme)
            let heightBeforeQuietCleanup = scroll.contentSize.height
            host.model.pending = .empty
            try await settle(host, "Quiet cleanup must preserve the reader's position") {
                scroll.contentSize.height < heightBeforeQuietCleanup - 20
                    && abs(scroll.contentOffset.y - olderOffset) < 3 && !self.nearBottom(scroll)
            }
            capture(host, step: "05-quiet-cleanup-while-paused", scheme: scheme)
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: self.bottomOffset(scroll) - 20), animated: false)
            try await settle(host, "Almost reaching the bottom does not resume following") { !self.nearBottom(scroll) }
            scroll.setContentOffset(CGPoint(x: scroll.contentOffset.x, y: self.bottomOffset(scroll)), animated: false)
            try await settle(host, "Reaching the actual bottom resumes following") { self.nearBottom(scroll) }
            host.model.pending = pending(count: 64)
            try await settle(host, "New pending audio follows after reaching the bottom") { self.nearBottom(scroll) }
            capture(host, step: "06-bottom-resumes-pending", scheme: scheme)
        }
    }

    private func row(_ text: String, id: UUID = UUID(), partial: Bool = false,
                     label: Bool = false) -> MeetingLiveBubbleComposer.Row {
        .init(id: id, speaker: .you, text: text, isPartial: partial, showsLabel: label)
    }

    private func wordRows(count: Int) -> [MeetingLiveBubbleComposer.Row] {
        let words = ["Сегодня", "мы", "обсудим", "инструкцию.", "Please", "review", "the", "English", "version.",
                     "Препарат", "и", "дозировка", "указаны", "в", "документе."]
        return (0..<count).map { row(words[$0 % words.count], label: $0 == 0) }
    }

    private func captionScroll(in host: CaptionNativeHost) async throws -> UIScrollView {
        try await settle(host, "The real caption UIScrollView must be attached and scrollable") {
            self.scrollViews(in: host.controller.view).contains {
                $0.window === host.window && $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height + 200
            }
        }
        let candidates = scrollViews(in: host.controller.view).filter {
            $0.window === host.window && $0.bounds.height > 0 && $0.contentSize.height > $0.bounds.height + 200
        }
        XCTAssertEqual(candidates.count, 1, "The fixture must inspect the component's only scroll view")
        let scroll = try XCTUnwrap(candidates.first)
        // Fixture-only chrome control: a fading OS indicator must not masquerade as an
        // equal-length text correction in the native-pixel assertion. No app preference changes.
        scroll.showsVerticalScrollIndicator = false
        scroll.showsHorizontalScrollIndicator = false
        return scroll
    }

    private func scrollViews(in view: UIView) -> [UIScrollView] {
        ((view as? UIScrollView).map { [$0] } ?? []) + view.subviews.flatMap { scrollViews(in: $0) }
    }

    private func bottomOffset(_ scroll: UIScrollView) -> CGFloat {
        max(-scroll.adjustedContentInset.top,
            scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)
    }

    private func nearBottom(_ scroll: UIScrollView) -> Bool {
        abs(bottomOffset(scroll) - scroll.contentOffset.y) < 4
    }

    private func settle(_ host: CaptionNativeHost, _ reason: String,
                        predicate: () -> Bool) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        var previous: [NativeScrollGeometry]?
        var stableSince: TimeInterval?
        while ProcessInfo.processInfo.systemUptime < deadline {
            host.window.layoutIfNeeded()
            let now = ProcessInfo.processInfo.systemUptime
            let geometry = scrollViews(in: host.controller.view).map {
                NativeScrollGeometry(identity: ObjectIdentifier($0), window: $0.window.map { ObjectIdentifier($0) },
                    bounds: $0.bounds, contentSize: $0.contentSize, contentOffset: $0.contentOffset,
                    inset: $0.adjustedContentInset)
            }
            if predicate(), geometry == previous {
                if let stableSince, now - stableSince >= 0.3 { return }
                if stableSince == nil { stableSince = now }
            } else { stableSince = nil }
            previous = geometry
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        print("[NATIVE_CAPTION] timeout=\(reason) geometry=\(String(describing: previous))")
        capture(host, step: "timeout", scheme: host.controller.overrideUserInterfaceStyle == .dark ? .dark : .light)
        XCTFail(reason)
        throw CaptionNativeHost.LayoutTimeout()
    }

    private struct NativeScrollGeometry: Equatable {
        let identity: ObjectIdentifier
        let window: ObjectIdentifier?
        let bounds: CGRect
        let contentSize: CGSize
        let contentOffset: CGPoint
        let inset: UIEdgeInsets
    }

    @discardableResult
    private func capture(_ host: CaptionNativeHost, step: String, scheme: ColorScheme) -> UIImage {
        host.window.layoutIfNeeded()
        let caption = scrollViews(in: host.controller.view).first
        let captureBounds = caption.map { $0.convert($0.bounds, to: host.window) } ?? host.window.bounds
        var drewHierarchy = false
        // Crop only the owned caption viewport, preserving native scale and pixels. This
        // bounds evidence memory on older iPads and never draws another window or user data.
        let image = UIGraphicsImageRenderer(size: captureBounds.size).image { context in
            context.cgContext.translateBy(x: -captureBounds.minX, y: -captureBounds.minY)
            drewHierarchy = host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drewHierarchy, "Capture only the test-owned native window after its layout settled")
        let revision = ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree"
        let appearance = scheme == .dark ? "dark" : "light"
        let attachment = XCTAttachment(image: image)
        attachment.name = "\(name)-\(step)-\(appearance)-\(revision)"
        attachment.lifetime = .keepAlways
        add(attachment)
        return image
    }
}

@MainActor
private final class CaptionNativeRows: ObservableObject {
    @Published var rows: [MeetingLiveBubbleComposer.Row]
    @Published var pending: MeetingPendingSpeechSnapshot = .empty
    @Published var width: CGFloat
    let height: CGFloat

    init(rows: [MeetingLiveBubbleComposer.Row], width: CGFloat, height: CGFloat) {
        self.rows = rows; self.width = width; self.height = height
    }
}

private struct CaptionNativeDocument: View {
    @ObservedObject var model: CaptionNativeRows
    let scheme: ColorScheme

    var body: some View {
        let theme = AppTheme.adaptive(accent: FluidBrandColors.blue, colorScheme: scheme)
        ZStack {
            theme.palette.windowBackground
            MeetingLiveBubbleScrollList(rows: model.rows, pending: model.pending, documentStyle: true)
                .frame(width: model.width, height: model.height)
                .background(theme.palette.contentBackground)
        }
        .appTheme(theme)
        .environment(\.colorScheme, scheme)
        .environment(\.locale, Locale(identifier: "ru"))
    }
}

@MainActor
private final class CaptionNativeHost {
    struct LayoutTimeout: Error {}
    let model: CaptionNativeRows
    let window: UIWindow
    let controller: UIHostingController<CaptionNativeDocument>
    private weak var previousKeyWindow: UIWindow?

    init(rows: [MeetingLiveBubbleComposer.Row], scheme: ColorScheme) throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }) else { throw XCTSkip("Requires the hosted iOS test app's foreground UIWindowScene") }
        self.previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        self.window = UIWindow(windowScene: scene)
        self.window.frame = scene.coordinateSpace.bounds
        self.model = CaptionNativeRows(rows: rows, width: min(520, scene.coordinateSpace.bounds.width - 48),
                                       height: max(160, min(320, scene.coordinateSpace.bounds.height - 96)))
        self.controller = UIHostingController(rootView: CaptionNativeDocument(model: model, scheme: scheme))
        self.controller.overrideUserInterfaceStyle = scheme == .dark ? .dark : .light
        self.window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        self.window.rootViewController = controller
        self.window.makeKeyAndVisible()
        self.window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        previousKeyWindow?.makeKey()
    }
}

final class MeetingSavedTranscriptPresentationTests: XCTestCase {
    private func session() -> MeetingSession {
        MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic transcript",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
            timebase: .init(startedHostTime: 0, machTimebaseNumerator: 1,
                machTimebaseDenominator: 1, firstPresentationTime: nil))
    }

    private func segment(_ text: String, track: UUID, start: Double, speaker: UUID? = nil,
                         attribution: MeetingTranscriptAttributionState = .unassigned) -> MeetingTranscriptSegment {
        .init(id: UUID(), start: .init(value: Int64(start * 1000), timescale: 1000),
              end: .init(value: Int64((start + 0.4) * 1000), timescale: 1000), sourceTrackID: track,
              speakerID: speaker, text: text, originalText: "Synthetic original", revision: 2,
              status: .final, overlap: .none, completeness: .complete, attributionState: attribution)
    }

    func testWordFragmentsReadAsParagraphWithoutRewritingEvidence() {
        let track = UUID()
        let words = ["Здравствуйте", ",", "давайте", "обсудим", "[PERSON]", ".", "English", "response", "."]
        let rows = words.enumerated().map { segment($0.element, track: track, start: Double($0.offset) / 2) }
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: session())
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, "Здравствуйте, давайте обсудим [PERSON]. English response.")
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
        XCTAssertEqual(paragraphs[0].id, rows[0].id)
        XCTAssertEqual(paragraphs[0].firstSegment.start, rows[0].start)
    }

    func testUnknownAttributionStatesFlowWithoutInventingASpeaker() {
        let track = UUID()
        var rows = [segment("Слова", track: track, start: 0),
                    segment("при", track: track, start: 0.5, attribution: .overlappingSpeakers),
                    segment("неуверенном", track: track, start: 1, attribution: .timingUncertain),
                    segment("времени.", track: track, start: 1.5)]
        rows[1].overlap = .ambiguous
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: session())
        XCTAssertEqual(paragraphs.count, 1)
        XCTAssertEqual(paragraphs[0].text, "Слова при неуверенном времени.")
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
        XCTAssertTrue(paragraphs[0].segments.allSatisfy { $0.speakerID == nil })
        XCTAssertEqual(paragraphs[0].segments.map(\.attributionState), rows.map(\.attributionState))
    }

    func testActualSpeakerIDsAndKnownToUnknownStateRemainBoundaries() {
        let track = UUID(), firstID = UUID(), secondID = UUID()
        var source = session()
        source.speakers = [firstID, secondID].map {
            .init(id: $0, displayName: "Same visible name", diarizationClusterID: nil, trackKind: .microphone,
                  isLocalUser: false, identityCandidates: [])
        }
        let rows = [segment("First", track: track, start: 0, speaker: firstID, attribution: .assigned),
                    segment("second", track: track, start: 0.5, speaker: secondID, attribution: .assigned),
                    segment("uncertain", track: track, start: 1, speaker: secondID, attribution: .timingUncertain),
                    segment("unknown", track: track, start: 1.5)]
        XCTAssertEqual(MeetingTranscriptExporter.displayParagraphs(for: rows, in: source).map(\.segments), rows.map { [$0] })
    }

    func testSourceStatusCompletenessAndPauseBoundariesRemainExplicit() {
        let track = UUID()
        var rows = [segment("Source", track: track, start: 0), segment("change", track: UUID(), start: 0.5),
                    segment("status", track: track, start: 1), segment("completeness", track: track, start: 1.5),
                    segment("pause", track: track, start: 6)]
        rows[2].status = .provisional
        rows[3].completeness = .incompleteTrack
        XCTAssertEqual(MeetingTranscriptExporter.displayParagraphs(for: rows, in: session()).count, rows.count)
    }

    func testLongWordStreamAndExplicitNewlinesStayBoundedAndLossless() {
        let track = UUID()
        var rows = (0..<600).map { segment("слово\($0)", track: track, start: Double($0) / 10) }
        rows[80].text += "\n"
        let paragraphs = MeetingTranscriptExporter.displayParagraphs(for: rows, in: session())
        XCTAssertGreaterThan(paragraphs.count, 5)
        XCTAssertEqual(paragraphs.flatMap(\.segments), rows)
        XCTAssertTrue(paragraphs.allSatisfy { $0.text.count <= 530 })
        XCTAssertEqual(Set(paragraphs.map(\.id)).count, paragraphs.count)
        XCTAssertTrue(MeetingTranscriptExporter.displayParagraphs(for: [], in: session()).isEmpty)
        XCTAssertTrue(paragraphs.contains { $0.segments.last?.id == rows[80].id })
    }

    func testParagraphPlaybackStartsAtFirstWordAndCoversEveryMember() throws {
        let track = UUID()
        let rows = [segment("One", track: track, start: 4), segment("two", track: track, start: 4.5),
                    segment("three.", track: track, start: 5)]
        var source = session(); source.transcriptSegments = rows
        let range = try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: rows.map(\.id))
        XCTAssertEqual(range.id, rows[0].id)
        XCTAssertEqual(range.sourceTrackID, track)
        XCTAssertEqual(range.start, rows[0].start)
        XCTAssertEqual(range.end, rows.last?.end)
        XCTAssertEqual(source.transcriptSegments, rows)
        XCTAssertEqual(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: [rows[1].id]), rows[1])
    }

    func testParagraphPlaybackRefusesStaleOrCrossBoundaryMemberSelections() throws {
        let track = UUID()
        let rows = [segment("One", track: track, start: 0), segment("two", track: track, start: 0.5)]
        var source = session(); source.transcriptSegments = rows
        for ids in [[], [UUID()], [rows[0].id, rows[0].id], rows.map(\.id).reversed().map { $0 }, [rows[0].id, UUID()]] {
            XCTAssertThrowsError(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: ids))
        }
        source.transcriptSegments[1].attributionState = .assigned
        source.transcriptSegments[1].speakerID = UUID()
        XCTAssertThrowsError(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: rows.map(\.id)))
        source.transcriptSegments = rows
        source.transcriptSegments[1].sourceTrackID = UUID()
        XCTAssertThrowsError(try MeetingSegmentPlaybackPlan.segmentRange(in: source, segmentIDs: rows.map(\.id)))
    }
}
