import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class PichiReleaseHighlightsTests: XCTestCase {
    func testReleaseHistoryActionInSheetForUncuratedVersion() async throws {
        for eligible in [false, true] {
            var selected: ReleaseHighlightsContent.Destination?
            let sheet = ReleaseHighlightsView(canExplore: eligible, content: .current(version: "9.0.0")) {
                selected = $0
            }
            let host = NSHostingView(rootView: sheet.appTheme(.light).fixedSize())
            let frame = NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize)
            let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
            window.isReleasedWhenClosed = false
            window.contentView = host
            window.makeKeyAndOrderFront(nil)
            defer { window.close() }
            host.layoutSubtreeIfNeeded()

            // The only primary action sits above the footer along the leading edge.
            let buttonCenter = NSPoint(x: 80, y: 85)
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: buttonCenter, modifierFlags: [],
                    timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                    context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
                await Task.yield()
            }
            XCTAssertEqual(selected, eligible ? .changelog : nil)
        }
    }
}
