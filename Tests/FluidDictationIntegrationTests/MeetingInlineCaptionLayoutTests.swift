import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

/// Native TextKit and SwiftUI hosting coverage with synthetic captions only.
/// Windows stay invisible and cannot take focus, microphone or application ownership.
@MainActor
final class MeetingInlineCaptionLayoutTests: XCTestCase {
    func testLiveSourceHeadersRenderInDocumentAndFloatingCaptionStyles() throws {
        var snapshot = MeetingLiveTranscriptSnapshot.empty
        snapshot.utterances = [
            .init(id: UUID(), speaker: .them, text: "Давайте обсудим план встречи.", start: 0, end: 2),
            .init(id: UUID(), speaker: .you, text: "Да, я подготовил предложения. Ёжик и ёлка.", start: 3, end: 6),
            .init(id: UUID(), speaker: .them, text: "Добавим время на вопросы.", start: 7, end: 9,
                participant: .init(identity: "synthetic-participant",
                    label: .identified(.init(displayName: "Анна", isLocalUser: false)))),
        ]
        snapshot.partials[.you] = .init(id: UUID(), text: "Сейчас уточню детали", start: 10)
        let rows = MeetingLiveBubbleComposer.rows(for: snapshot)
        XCTAssertEqual(rows.map(\.showsLabel), [true, true, true, true])
        for scheme in [ColorScheme.light, .dark] {
            for documentStyle in [true, false] {
                let theme = AppTheme.adaptive(accent: .purple, colorScheme: scheme)
                let content = VStack(alignment: .leading, spacing: 20) {
                    ForEach(rows) { row in
                        MeetingLiveBubbleRow(row: row, hidesPartialFromAccessibility: false,
                            documentStyle: documentStyle)
                    }
                    Spacer(minLength: 0)
                }
                .padding(24)
                .frame(width: 520, height: 480, alignment: .topLeading)
                .background(theme.palette.contentBackground)
                .appTheme(theme)
                .environment(\.colorScheme, scheme)
                let controller = NSHostingController(rootView: content)
                let window = CaptionHost.QuietWindow(contentRect: CGRect(x: -10000, y: -10000, width: 520, height: 480),
                    styleMask: [.borderless], backing: .buffered, defer: false)
                window.isReleasedWhenClosed = false
                window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
                window.contentViewController = controller
                defer { window.close() }
                for _ in 0..<8 {
                    controller.view.layoutSubtreeIfNeeded()
                    RunLoop.main.run(until: Date().addingTimeInterval(0.005))
                }
                try self.saveCapture(controller.view,
                    step: documentStyle ? "source-labels-document" : "source-labels-floating", scheme: scheme)
                XCTAssertFalse(window.isVisible)
                XCTAssertFalse(window.isKeyWindow)
            }
        }
    }

    func testPendingWordsKeepTheirSizesAndWrapAfterEnglishAndRussianText() throws {
        for scheme in [ColorScheme.light, .dark] {
            for text in ["Ёжик идёт.", "Ready now."] {
                let fixture = CaptionHost(text: text, scheme: scheme)
                defer { fixture.close() }
                let native = try nativeText(in: fixture)
                try verifyWaves(in: native, pending: fixture.pending)
                XCTAssertTrue(native.string.hasPrefix(text), "User text is preserved verbatim")
                let first = try wave(1, in: native)
                let initial = first.frame
                XCTAssertGreaterThan(initial.minX, 10, "Pending audio begins after the last recognized word")
                XCTAssertLessThan(initial.minY, 30, "Short recognized text and its first waveform share a line")
                try capture(fixture, step: text.contains("Ё") ? "inline-ru-wide" : "inline-en-wide", scheme: scheme)

                // Keep the entire text on the line but leave insufficient space for
                // the first waveform. TextKit must move that whole attachment.
                fixture.resize(width: ceil(initial.minX + initial.width / 2) + 32, height: 180)
                fixture.settle()
                XCTAssertLessThan(first.frame.minX, 3, "A pending word wraps to the beginning of the next line")
                XCTAssertGreaterThan(first.frame.minY, initial.minY + 10)
                try verifyWaves(in: native, pending: fixture.pending)
                try capture(fixture, step: text.contains("Ё") ? "inline-ru-wrapped" : "inline-en-wrapped", scheme: scheme)
                XCTAssertFalse(fixture.window.isVisible)
                XCTAssertFalse(fixture.window.isKeyWindow)
            }
        }
    }

    func testHeightAndScrollChangesRetainWaveHostsAndTextGeometry() throws {
        for scheme in [ColorScheme.light, .dark] {
            let text = String(repeating: "Ёжик и ёлка. Review the English document. ", count: 22)
            let fixture = CaptionHost(text: text, scheme: scheme)
            defer { fixture.close() }
            let native = try nativeText(in: fixture)
            let frames = try waveFrames(in: native, pending: fixture.pending)
            let identities = try fixture.pending.tokens.map { ObjectIdentifier(try wave($0.id, in: native)) }
            let used = try XCTUnwrap(native.textLayoutManager).usageBoundsForTextContainer
            for height: CGFloat in [90, 420, 180] {
                fixture.resize(width: 392, height: height)
                for offset: CGFloat in [0, 80, 220] {
                    fixture.scroll.contentView.scroll(to: CGPoint(x: 0, y: offset))
                    fixture.scroll.reflectScrolledClipView(fixture.scroll.contentView)
                    fixture.settle()
                    XCTAssertEqual(try waveFrames(in: native, pending: fixture.pending), frames,
                                   "A viewport change cannot relocate waves inside the text document")
                    XCTAssertEqual(try fixture.pending.tokens.map { ObjectIdentifier(try wave($0.id, in: native)) }, identities,
                                   "Scrolling retains the original waveform hosting views")
                    XCTAssertEqual(try XCTUnwrap(native.textLayoutManager).usageBoundsForTextContainer, used)
                    try verifyWaves(in: native, pending: fixture.pending)
                }
            }
            try capture(fixture, step: "inline-long-scrolled", scheme: scheme)
        }
    }

    func testSpeculativeWidthMeasurementsDoNotChangeDisplayedTextOrWaveLayout() throws {
        let fixture = CaptionHost(text: "Русский текст с Ё и ё. English captions continue on the same line.", scheme: .dark)
        defer { fixture.close() }
        let native = try nativeText(in: fixture)
        let container = try XCTUnwrap(native.textContainer)
        let displayedWidth = native.bounds.width
        let displayedFrames = try waveFrames(in: native, pending: fixture.pending)
        let used = try XCTUnwrap(native.textLayoutManager).usageBoundsForTextContainer
        for proposal: CGFloat in [100, 1200, 190, 2000] {
            let size = fixture.controller.sizeThatFits(in: CGSize(width: proposal, height: 1600))
            XCTAssertTrue(size.width.isFinite && size.height.isFinite)
            XCTAssertEqual(native.bounds.width, displayedWidth, accuracy: 0.5)
            XCTAssertEqual(container.size.width, displayedWidth, accuracy: 0.5,
                           "Fitting proposals must use a separate TextKit measurement owner")
            XCTAssertEqual(try waveFrames(in: native, pending: fixture.pending), displayedFrames)
            XCTAssertEqual(try XCTUnwrap(native.textLayoutManager).usageBoundsForTextContainer, used,
                           "A speculative width cannot change the displayed glyph wrapping")
        }
        // Reproduce a rejected proposal directly, independently of SwiftUI's
        // proposal ordering on a particular macOS release.
        container.size = CGSize(width: displayedWidth * 2, height: .greatestFiniteMagnitude)
        native.needsLayout = true
        native.layoutSubtreeIfNeeded()
        XCTAssertEqual(container.size.width, displayedWidth, accuracy: 0.5)
        fixture.settle()
        try verifyWaves(in: native, pending: fixture.pending)
    }

    private func nativeText(in fixture: CaptionHost) throws -> NSTextView {
        fixture.settle()
        return try XCTUnwrap(descendants(in: fixture.controller.view).compactMap { $0 as? NSTextView }.first {
            $0.accessibilityIdentifier() == "meeting.inlineCaption.text"
        })
    }

    private func wave(_ id: UInt64, in native: NSTextView) throws -> NSView {
        try XCTUnwrap(native.subviews.first { $0.accessibilityIdentifier() == "meeting.inlineWave.\(id)" })
    }

    private func waveFrames(in native: NSTextView, pending: MeetingPendingSpeechSnapshot) throws -> [CGRect] {
        try pending.tokens.map { try wave($0.id, in: native).frame }
    }

    private func verifyWaves(in native: NSTextView, pending: MeetingPendingSpeechSnapshot) throws {
        XCTAssertNotNil(native.textLayoutManager, "Inline captions retain TextKit 2")
        XCTAssertEqual(try XCTUnwrap(native.textContainer).size.width, native.bounds.width, accuracy: 0.5,
                       "The committed native bounds own displayed text wrapping")
        XCTAssertEqual(native.subviews.filter { $0.accessibilityIdentifier().hasPrefix("meeting.inlineWave.") }.count,
                       pending.tokens.count)
        for token in pending.tokens {
            let host = try wave(token.id, in: native)
            XCTAssertEqual(host.bounds.width, 56 * CGFloat(token.widthHint), accuracy: 0.5)
            XCTAssertEqual(host.bounds.height, 18, accuracy: 0.5,
                           "A word waveform cannot inherit viewport or titlebar height")
            XCTAssertEqual(host.safeAreaInsets.top, 0, accuracy: 0.5)
            XCTAssertEqual(host.safeAreaInsets.bottom, 0, accuracy: 0.5)
            XCTAssertGreaterThanOrEqual(host.frame.minX, -0.5)
            XCTAssertLessThanOrEqual(host.frame.maxX, native.bounds.width + 0.5)
            XCTAssertLessThanOrEqual(host.frame.maxY, native.bounds.height + 0.5)
        }
    }

    private func descendants(in view: NSView) -> [NSView] {
        [view] + view.subviews.flatMap { descendants(in: $0) }
    }

    private func capture(_ fixture: CaptionHost, step: String, scheme: ColorScheme) throws {
        let native = try nativeText(in: fixture)
        let view = fixture.controller.view
        let region = native.convert(native.bounds, to: view).insetBy(dx: -16, dy: -16).intersection(view.bounds)
        try self.saveCapture(view, region: region, step: step, scheme: scheme)
    }

    private func saveCapture(_ view: NSView, region: CGRect? = nil, step: String, scheme: ColorScheme) throws {
        let region = region ?? view.bounds
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: region))
        view.cacheDisplay(in: region, to: bitmap)
        let data = try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        let environment = ProcessInfo.processInfo.environment
        let revision = (environment["PICHI_WAVEFORM_TEST_REVISION"] ?? "unspecified").map {
            $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") ? String($0) : "_"
        }.joined()
        let name = "\(step)-\(scheme == .dark ? "dark" : "light")-\(revision)"
        let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.png")
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
        if let path = environment["PICHI_WAVEFORM_TEST_CAPTURE_DIR"], !path.isEmpty {
            let directory = URL(fileURLWithPath: path, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try data.write(to: directory.appendingPathComponent(name + ".png"), options: .atomic)
        }
    }

    private final class CaptionHost {
        final class QuietWindow: NSWindow {
            override var canBecomeKey: Bool { false }
            override var canBecomeMain: Bool { false }
        }

        let window: NSWindow
        let scroll = NSScrollView()
        let controller: NSHostingController<AnyView>
        let pending: MeetingPendingSpeechSnapshot

        init(text: String, scheme: ColorScheme) {
            let theme = AppTheme.adaptive(accent: .purple, colorScheme: scheme)
            let row = MeetingLiveBubbleComposer.Row(id: UUID(), speaker: .you, text: text,
                                                    isPartial: false, showsLabel: false)
            let pending = MeetingPendingSpeechSnapshot(tokens: [0.65, 1, 1.35, 0.8].enumerated().map { index, width in
                .init(id: UInt64(index + 1), source: .you, start: Double(index), end: Double(index + 1),
                      widthHint: width, level: 0.7)
            }, isCapturing: false, revision: 1)
            self.pending = pending
            controller = NSHostingController(rootView: AnyView(VStack(alignment: .leading, spacing: 0) {
                MeetingInlineCaptionText(rows: [row], pending: pending)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .background(theme.palette.contentBackground)
                .appTheme(theme)
                .environment(\.colorScheme, scheme)))
            window = QuietWindow(contentRect: CGRect(x: -10000, y: -10000, width: 392, height: 180),
                                 styleMask: [.titled, .fullSizeContentView], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.appearance = NSAppearance(named: scheme == .dark ? .darkAqua : .aqua)
            window.contentView = scroll
            scroll.drawsBackground = false
            scroll.hasVerticalScroller = false
            scroll.hasHorizontalScroller = false
            scroll.documentView = controller.view
            resize(width: 392, height: 180)
        }

        func resize(width: CGFloat, height: CGFloat) {
            window.setContentSize(CGSize(width: width, height: height))
            scroll.frame.size = CGSize(width: width, height: height)
            controller.view.frame = CGRect(x: 0, y: 0, width: width, height: 1200)
            settle()
        }

        func settle() {
            for _ in 0..<8 {
                window.contentView?.layoutSubtreeIfNeeded()
                controller.view.layoutSubtreeIfNeeded()
                RunLoop.main.run(until: Date().addingTimeInterval(0.005))
            }
        }

        func close() {
            window.close()
        }
    }
}
