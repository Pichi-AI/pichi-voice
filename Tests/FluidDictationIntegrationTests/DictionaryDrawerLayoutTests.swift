import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class DictionaryDrawerLayoutTests: XCTestCase {
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
                                entry: entry, isTestDisabled: false,
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
                            XCTAssertEqual(title.minX, 0, accuracy: 0.5, context)
                            XCTAssertEqual(title.width, contentWidth, accuracy: 0.5, context)
                            XCTAssertEqual(triggerFrame.width, contentWidth, accuracy: 0.5, context)
                            // Independent native Text at the intended width is the wrapping oracle.
                            // The old compressed text column has a larger line count for the short phrase.
                            let reference = NSHostingController(rootView: Text(verbatim: entry.replacement)
                                .font(theme.typography.bodyStrong)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(width: contentWidth)
                                .environment(\.locale, Locale(identifier: language)))
                            let expectedTitle = reference.sizeThatFits(in: NSSize(width: contentWidth, height: 1))
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
                                XCTAssertGreaterThanOrEqual(frame.minY, triggerFrame.maxY, context)
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
                            if language == "ru", scheme == .dark, design == .sans, scale == 1, drawerWidth == 240 {
                                let bitmap = try XCTUnwrap(controller.view.bitmapImageRepForCachingDisplay(in: controller.view.bounds))
                                controller.view.cacheDisplay(in: controller.view.bounds, to: bitmap)
                                let imageAttachment = XCTAttachment(data: try XCTUnwrap(bitmap.representation(using: .png, properties: [:])),
                                                               uniformTypeIdentifier: "public.png")
                                imageAttachment.name = "dictionary-drawer-\(attachment)-ru-dark-240"
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
