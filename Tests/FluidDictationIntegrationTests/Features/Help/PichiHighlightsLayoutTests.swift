import AppKit
@testable import FluidVoice_Debug
import SwiftUI
import XCTest

@MainActor
final class PichiHighlightsLayoutTests: XCTestCase {
    func testCardActionsStayOnTheSameRowWithUnequalCopy() async throws {
        let content = ReleaseHighlightsContent(
            release: "test", title: "Highlights", subtitle: "Layout fixture",
            features: [
                .init(id: "short", preview: .meeting, eyebrow: "One", title: "Short title",
                      detail: "One line.", action: "Open meetings", destination: .meetings),
                .init(id: "long", preview: .meeting, eyebrow: "Two", title: "Longer title",
                      detail: String(repeating: "Meeting changes across apps. ", count: 14),
                      action: "Open Voice Engine", destination: .voiceEngine),
            ]
        )
        try await self.checkActions(in: content, expected: [.meetings, .voiceEngine])
    }

    func testPublishedMeetingAndPrivacyActionsOpenTheirOwnDestinations() async throws {
        try await self.checkActions(in: .current(version: "0.3.0"), expected: [.meetingSources, .analyticsPrivacy])
    }

    private func checkActions(in content: ReleaseHighlightsContent, expected: [ReleaseHighlightsContent.Destination]) async throws {
        var actions: [ReleaseHighlightsContent.Destination] = []
        let sheet = ReleaseHighlightsView(canExplore: true, content: content) {
            if let action = $0 { actions.append(action) }
        }
        let host = NSHostingView(rootView: sheet.appTheme(.light).fixedSize())
        let frame = NSRect(origin: NSPoint(x: -10000, y: -10000), size: host.fittingSize)
        let window = NSWindow(contentRect: frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }
        host.layoutSubtreeIfNeeded()

        // Locate the left button by its action, then press the right button at the same height.
        func click(at point: NSPoint) async throws {
            for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
                let event = try XCTUnwrap(NSEvent.mouseEvent(
                    with: type, location: point, modifierFlags: [], timestamp: ProcessInfo.processInfo.systemUptime,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1
                ))
                window.sendEvent(event)
                await Task.yield()
            }
        }
        for y in stride(from: 110.0, through: frame.height - 70, by: 8) {
            actions.removeAll()
            try await click(at: NSPoint(x: 65, y: y))
            if actions == [expected[0]] {
                try await click(at: NSPoint(x: frame.width / 2 + 55, y: y))
                XCTAssertEqual(actions, expected)
                return
            }
        }
        XCTFail("The primary action of the first card must be reachable.")
    }
}
