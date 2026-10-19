import XCTest
import SwiftUI
import UIKit
@testable import PichiVoiceMobile

/// Exercises the real native table, its retained live host and TextKit attachments.
/// Synthetic protected text only; no audio services, models or durable stores.
@MainActor
final class MeetingInlineCaptionBoundsTests: XCTestCase {
    func testFinalViewWidthOverridesARejectedTextContainerProbe() async throws {
        let host = try InlineBoundsHost()
        defer { host.close() }
        let native = try await caption(in: host)
        try await settle(host) { self.waves(in: native).count == 64 }
        let committedWidth = native.bounds.width

        // UIViewRepresentable may be measured at an unused width after the
        // enclosing table has committed its cell frame. Force the historical
        // state rather than depending on one OS version's proposal ordering.
        native.textContainer.size = CGSize(width: committedWidth * 2, height: .greatestFiniteMagnitude)
        native.setNeedsLayout()
        native.layoutIfNeeded()
        XCTAssertEqual(native.textContainer.size.width, committedWidth, accuracy: 0.5)
        try assertGeometry(native, expectedTokens: 64)
        capture(host, step: "committed-width-after-probe")
    }

    func testGrowingTextAndPendingWordsStayInsideNarrowAndWideCells() async throws {
        let host = try InlineBoundsHost()
        defer { host.close() }
        var firstWave: UIView?
        for (step, width, typeSize, count) in [
            ("narrow", CGFloat(260), DynamicTypeSize.large, 64),
            ("wide-large-type", CGFloat(600), DynamicTypeSize.accessibility2, 64),
            ("narrow-large-type", CGFloat(280), DynamicTypeSize.accessibility2, 31),
            ("wide-updated-text", CGFloat(560), DynamicTypeSize.large, 64)
        ] {
            host.model.width = min(width, host.window.bounds.width - 40)
            host.model.textSize = typeSize
            host.model.text = String(repeating: "Ёжик обсуждает English [PERSON] и продолжает. ", count: 3)
                + "Изменение \(step)."
            host.model.pending = inlinePending(count)
            let native = try await caption(in: host)
            try await settle(host) {
                abs(native.bounds.width - host.model.width) < 1
                    && native.attributedText.string.contains("Изменение \(step).")
                    && self.waves(in: native).count == count
            }
            try assertGeometry(native, expectedTokens: count)
            let currentFirst = waves(in: native).first { $0.accessibilityIdentifier == "meeting.inlineWave.1" }
            if let firstWave { XCTAssertTrue(firstWave === currentFirst, "Retained token IDs keep their original waveform host") }
            firstWave = currentFirst
            capture(host, step: step)
        }
    }

    private func assertGeometry(_ native: UITextView, expectedTokens: Int,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertFalse(native.isScrollEnabled, file: file, line: line)
        XCTAssertEqual(native.textContainer.size.width, native.bounds.width, accuracy: 0.5, file: file, line: line)
        let manager = try XCTUnwrap(native.textLayoutManager, file: file, line: line)
        let content = try XCTUnwrap(manager.textContentManager, file: file, line: line)
        manager.ensureLayout(for: content.documentRange)
        manager.enumerateTextLayoutFragments(from: nil, options: [.ensuresLayout]) { fragment in
            for textLine in fragment.textLineFragments {
                let rect = textLine.typographicBounds.offsetBy(dx: fragment.layoutFragmentFrame.minX,
                                                               dy: fragment.layoutFragmentFrame.minY)
                XCTAssertGreaterThanOrEqual(rect.minX, -1, file: file, line: line)
                XCTAssertLessThanOrEqual(rect.maxX, native.bounds.width + 1,
                    "Every line must wrap before the right cell edge", file: file, line: line)
            }
            return true
        }
        let mounted = Dictionary(uniqueKeysWithValues: waves(in: native).map { ($0.accessibilityIdentifier!, $0) })
        var attachmentCount = 0
        native.attributedText.enumerateAttribute(.attachment,
            in: NSRange(location: 0, length: native.attributedText.length)) { value, range, _ in
            guard value is NSTextAttachment else { return }
            attachmentCount += 1
            let key = "meeting.inlineWave.\(attachmentCount)"
            guard let wave = mounted[key],
                  let location = content.location(content.documentRange.location, offsetBy: range.location),
                  let fragment = manager.textLayoutFragment(for: location) else {
                XCTFail("Every pending attachment must have a mounted waveform and geometry", file: file, line: line)
                return
            }
            let expected = fragment.frameForTextAttachment(at: location)
                .offsetBy(dx: fragment.layoutFragmentFrame.minX, dy: fragment.layoutFragmentFrame.minY)
            XCTAssertGreaterThan(expected.width, 0, file: file, line: line)
            XCTAssertGreaterThan(expected.height, 0, file: file, line: line)
            XCTAssertEqual(wave.frame.minX, expected.minX, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(wave.frame.minY, expected.minY, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(wave.frame.width, expected.width, accuracy: 0.5, file: file, line: line)
            XCTAssertEqual(wave.frame.height, expected.height, accuracy: 0.5, file: file, line: line)
            XCTAssertGreaterThanOrEqual(wave.frame.minX, -1, file: file, line: line)
            XCTAssertLessThanOrEqual(wave.frame.maxX, native.bounds.width + 1, file: file, line: line)
            XCTAssertLessThanOrEqual(wave.frame.maxY, native.bounds.height + 1,
                "Measured row height must contain the final attachment", file: file, line: line)
            XCTAssertEqual(wave.safeAreaInsets, .zero,
                "Word-sized hosts must not inherit offscreen window safe areas", file: file, line: line)
        }
        XCTAssertEqual(attachmentCount, expectedTokens, file: file, line: line)
        XCTAssertEqual(mounted.count, expectedTokens, file: file, line: line)
    }

    private func descendants(_ view: UIView) -> [UIView] { [view] + view.subviews.flatMap(descendants) }
    private func waves(in view: UIView) -> [UIView] {
        descendants(view).filter { $0.accessibilityIdentifier?.hasPrefix("meeting.inlineWave.") == true }
    }
    private func caption(in host: InlineBoundsHost) async throws -> UITextView {
        try await settle(host) {
            self.descendants(host.controller.view).contains { $0.accessibilityIdentifier == "meeting.inlineCaption.text" }
        }
        return try XCTUnwrap(descendants(host.controller.view).compactMap { $0 as? UITextView }.first {
            $0.accessibilityIdentifier == "meeting.inlineCaption.text"
        })
    }
    private func settle(_ host: InlineBoundsHost, predicate: () -> Bool) async throws {
        for _ in 0..<80 {
            host.window.layoutIfNeeded()
            if predicate() {
                try await Task.sleep(for: .milliseconds(100))
                host.window.layoutIfNeeded()
                if predicate() { return }
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTFail("The owned caption fixture did not settle")
        throw InlineBoundsHost.LayoutTimeout()
    }
    private func capture(_ host: InlineBoundsHost, step: String) {
        let viewport = descendants(host.controller.view).first { $0.accessibilityIdentifier == "meeting.liveTranscript.viewport" }
        let rect = viewport.map { $0.convert($0.bounds, to: host.window) } ?? host.window.bounds
        var drew = false
        let image = UIGraphicsImageRenderer(size: rect.size).image { context in
            context.cgContext.translateBy(x: -rect.minX, y: -rect.minY)
            drew = host.window.drawHierarchy(in: host.window.bounds, afterScreenUpdates: true)
        }
        XCTAssertTrue(drew)
        let attachment = XCTAttachment(image: image)
        attachment.name = "inline-bounds-\(step)-\(ProcessInfo.processInfo.environment["PICHI_TEST_REVISION"] ?? "working-tree")"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}

private func inlinePending(_ count: Int) -> MeetingPendingSpeechSnapshot {
    .init(tokens: (0..<count).map {
        .init(id: UInt64($0 + 1), source: .you, start: Double($0) * 0.4, end: Double($0 + 1) * 0.4,
              widthHint: 0.55 + Double($0 % 7) * 0.09, level: 0.65)
    }, isCapturing: false, revision: UInt64(count))
}

@MainActor
private final class InlineBoundsModel: ObservableObject {
    let rowID = UUID()
    @Published var text = String(repeating: "Ёжик обсуждает English [PERSON] и продолжает. ", count: 3)
    @Published var pending = inlinePending(64)
    @Published var width: CGFloat = 280
    @Published var textSize: DynamicTypeSize = .large
}

private struct InlineBoundsDocument: View {
    @ObservedObject var model: InlineBoundsModel
    var body: some View {
        let theme = AppTheme.adaptive(accent: FluidBrandColors.blue, colorScheme: .light)
        ZStack {
            theme.palette.windowBackground
            MeetingLiveBubbleScrollList(rows: [
                .init(id: model.rowID, speaker: .you, text: model.text, isPartial: false, showsLabel: false)
            ], pending: model.pending, documentStyle: true)
                .frame(width: model.width, height: 420)
                .background(theme.palette.contentBackground)
        }
        .appTheme(theme)
        .environment(\.dynamicTypeSize, model.textSize)
        .environment(\.accessibilityReduceMotion, true)
    }
}

@MainActor
private final class InlineBoundsHost {
    struct LayoutTimeout: Error {}
    let model = InlineBoundsModel()
    let window: UIWindow
    let controller: UIHostingController<InlineBoundsDocument>
    private weak var previousKeyWindow: UIWindow?

    init() throws {
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first(where: {
            $0.activationState == .foregroundActive || $0.activationState == .foregroundInactive
        }) else { throw XCTSkip("Requires the hosted iOS test app's foreground UIWindowScene") }
        previousKeyWindow = scene.windows.first(where: \.isKeyWindow)
        window = UIWindow(windowScene: scene)
        window.frame = scene.coordinateSpace.bounds
        controller = UIHostingController(rootView: InlineBoundsDocument(model: model))
        window.windowLevel = UIWindow.Level(rawValue: UIWindow.Level.normal.rawValue + 1)
        window.rootViewController = controller
        window.makeKeyAndVisible()
        window.layoutIfNeeded()
    }

    func close() {
        window.isHidden = true
        window.rootViewController = nil
        window.windowScene = nil
        previousKeyWindow?.makeKey()
    }
}
