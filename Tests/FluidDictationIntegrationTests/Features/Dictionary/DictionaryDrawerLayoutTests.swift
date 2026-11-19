import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class DictionaryDrawerLayoutTests: XCTestCase {
    func testAudioSummaryExcludesFeatureOnlyReferencesAndUsesLatestLinkedTimestamp() {
        var legacy = PronunciationEnrollmentCapture(values: [1], sourceFrameCount: 1, modelKey: "fixture")
        legacy.capturedAt = Date(timeIntervalSince1970: 300)
        var inspection = legacy
        inspection.inspectionID = UUID()
        inspection.capturedAt = Date(timeIntervalSince1970: 100)
        var original = legacy
        original.originalAudioID = UUID()
        original.capturedAt = Date(timeIntervalSince1970: 200)
        let summary = DictionarySavedAudioSummary.from([legacy, inspection, original])
        XCTAssertEqual(summary.count, 2)
        XCTAssertEqual(summary.latestCapture, original.capturedAt)
        let empty = DictionarySavedAudioSummary.from([legacy])
        XCTAssertEqual(empty.count, 0)
        XCTAssertNil(empty.latestCapture)
    }

    func testShortReplacementGetsFullDrawerWidthAndVisibleActions() throws {
        try self.verifyLayouts(replacement: "E2E Тест Ёжик", aliases: ["e2e ёлка", "e2e ежик"], attachment: "short")
    }

    func testUnbrokenCyrillicAndLongAliasesWrapWithoutHidingActions() throws {
        try self.verifyLayouts(
            replacement: String(repeating: "Ёжикёжик", count: 9),
            aliases: [String(repeating: "синтетический вариант ёлка ", count: 8), "another synthetic alias"],
            attachment: "long"
        )
    }

    private func verifyLayouts(replacement: String, aliases: [String], attachment: String) throws {
        for language in ["en", "ru"] {
            for scheme in [ColorScheme.light, .dark] {
                for design in BrandStyle.FontDesign.allCases {
                    for scale in [1.0, 1.3] {
                        let style = BrandStyle(spacingScale: scale, bodyFontDesign: design, titleFontDesign: design)
                        let theme = AppTheme.adaptive(accent: .purple, colorScheme: scheme,
                                                      package: BrandPackage(profile: .neutral, style: style))
                        for drawerWidth: CGFloat in [230, 240, 320] {
                            let contentWidth = drawerWidth - 2 * theme.metrics.spacing.lg
                            let context = "\(language)/\(scheme)/\(design)/\(scale)/\(drawerWidth)"
                            var frames: [DictionaryDrawerEntryRow.Part: CGRect] = [:]
                            var actions = 0
                            let entry = SettingsStore.CustomDictionaryEntry(triggers: aliases, replacement: replacement)
                            let row = DictionaryDrawerEntryRow(
                                entry: entry, audioSummary: .init(count: 10, latestCapture: Date(timeIntervalSince1970: 1_700_000_000)), isTestDisabled: false,
                                onTest: { actions += 1 }, onEdit: { actions += 1 }, onDelete: { actions += 1 },
                                onLayout: { frames[$0] = $1 }
                            )
                            .frame(width: contentWidth)
                            .padding(.horizontal, theme.metrics.spacing.lg)
                            .appTheme(theme)
                            .environment(\.locale, Locale(identifier: language))
                            .environment(\.colorScheme, scheme)
                            // A surrounding compact UI must not truncate the user replacement.
                            .lineLimit(1)
                            let controller = NSHostingController(rootView: row)
                            let size = controller.sizeThatFits(in: NSSize(width: drawerWidth, height: 1000))
                            controller.view.frame = NSRect(origin: .zero, size: size)
                            controller.view.layoutSubtreeIfNeeded()
                            controller.view.displayIfNeeded()
                            let deadline = Date().addingTimeInterval(1)
                            while frames.count < DictionaryDrawerEntryRow.Part.allCases.count, Date() < deadline {
                                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                                controller.view.layoutSubtreeIfNeeded()
                            }
                            XCTAssertEqual(frames.count, DictionaryDrawerEntryRow.Part.allCases.count, context)
                            let title = try XCTUnwrap(frames[.replacement], context)
                            let triggerFrame = try XCTUnwrap(frames[.aliases], context)
                            let samples = try XCTUnwrap(frames[.samples], context)
                            XCTAssertGreaterThanOrEqual(samples.minY, triggerFrame.maxY, context)
                            XCTAssertEqual(title.minX, 0, accuracy: 0.5, context)
                            // Compare native bounds with native bounds. An unbroken sans word
                            // can fit at 189 points for a fractional 188.4-point proposal, with
                            // its edges aligned at -0.5 and 188.5. Do not widen the tolerance
                            // or compare that measured CGRect with an unrounded formula.
                            var referenceFrames: [DictionaryDrawerEntryRow.Part: CGRect] = [:]
                            let referenceID = UUID()
                            let reference = NSHostingController(rootView: VStack(alignment: .leading, spacing: theme.metrics.spacing.sm) {
                                Text(verbatim: entry.replacement)
                                    .font(theme.typography.bodyStrong)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(referenceID)) } action: {
                                        referenceFrames[.replacement] = $0
                                    }
                                Text(verbatim: PichiLocalization.format("Auto-replace: %@", entry.triggers.joined(separator: ", ")))
                                    .font(theme.typography.caption)
                                    .lineLimit(2)
                                    .fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                    .onGeometryChange(for: CGRect.self) { $0.frame(in: .named(referenceID)) } action: {
                                        referenceFrames[.aliases] = $0
                                    }
                            }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .coordinateSpace(name: referenceID)
                                .frame(width: contentWidth)
                                .padding(.horizontal, theme.metrics.spacing.lg)
                                .appTheme(theme)
                                .environment(\.locale, Locale(identifier: language))
                                .environment(\.colorScheme, scheme))
                            let referenceSize = reference.sizeThatFits(in: NSSize(width: drawerWidth, height: 1000))
                            reference.view.frame = NSRect(origin: .zero, size: referenceSize)
                            reference.view.layoutSubtreeIfNeeded()
                            reference.view.displayIfNeeded()
                            let referenceDeadline = Date().addingTimeInterval(1)
                            while referenceFrames.count < 2, Date() < referenceDeadline {
                                RunLoop.main.run(until: Date().addingTimeInterval(0.01))
                                reference.view.layoutSubtreeIfNeeded()
                            }
                            let expectedTitle = try XCTUnwrap(referenceFrames[.replacement], context)
                            let expectedAliases = try XCTUnwrap(referenceFrames[.aliases], context)
                            // Each native edge may round independently. Comparing
                            // the summed width would double-count that rounding.
                            XCTAssertEqual(title.minX, expectedTitle.minX, accuracy: 0.5, context)
                            XCTAssertEqual(title.maxX, expectedTitle.maxX, accuracy: 0.5, context)
                            XCTAssertEqual(triggerFrame.minX, expectedAliases.minX, accuracy: 0.5, context)
                            XCTAssertEqual(triggerFrame.maxX, expectedAliases.maxX, accuracy: 0.5, context)
                            XCTAssertEqual(title.height, expectedTitle.height, accuracy: 0.5, context)
                            let rowBounds = CGRect(x: 0, y: 0, width: contentWidth, height: size.height)
                            for part in DictionaryDrawerEntryRow.Part.allCases {
                                let frame = try XCTUnwrap(frames[part], "\(context)/\(part)")
                                XCTAssertTrue(frame.width.isFinite && frame.height.isFinite, context)
                                XCTAssertGreaterThan(frame.width, 0, context)
                                XCTAssertGreaterThan(frame.height, 0, context)
                                XCTAssertGreaterThanOrEqual(frame.minX, rowBounds.minX - 0.5, context)
                                XCTAssertGreaterThanOrEqual(frame.minY, rowBounds.minY - 0.5, context)
                                XCTAssertLessThanOrEqual(frame.maxX, rowBounds.maxX + 0.5, "\(context)/\(part) outside drawer")
                                XCTAssertLessThanOrEqual(frame.maxY, rowBounds.maxY + 0.5, context)
                            }
                            let controls = try [DictionaryDrawerEntryRow.Part.test, .edit, .delete].map { part -> CGRect in
                                let frame = try XCTUnwrap(frames[part], context)
                                XCTAssertGreaterThanOrEqual(frame.width, 22, context)
                                XCTAssertGreaterThanOrEqual(frame.height, 22, context)
                                XCTAssertGreaterThanOrEqual(frame.minY, samples.maxY, context)
                                return frame
                            }
                            for index in controls.indices {
                                for other in controls.indices where other > index {
                                    let intersection = controls[index].intersection(controls[other])
                                    XCTAssertTrue(intersection.isNull || intersection.width * intersection.height < 0.5,
                                                  "\(context): action hit targets overlap")
                                }
                            }
                            XCTAssertEqual(actions, 0, "Rendering must not test, edit or delete a word")
                            if design == .sans, scale == 1, drawerWidth == 240 {
                                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                                let imageAttachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                               uniformTypeIdentifier: "public.png")
                                imageAttachment.name = "dictionary-drawer-\(attachment)-\(language)-\(scheme)-240"
                                imageAttachment.lifetime = .keepAlways
                                add(imageAttachment)
                            }
                        }
                    }
                }
            }
        }
    }
}
