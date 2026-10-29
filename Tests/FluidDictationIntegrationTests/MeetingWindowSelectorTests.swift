@testable import FluidVoice_Debug
import Foundation
@preconcurrency import ScreenCaptureKit
import XCTest

final class MeetingWindowSelectorTests: XCTestCase {
    private func candidate(
        _ windowID: UInt32,
        title: String? = nil,
        frame: CGRect = CGRect(x: 0, y: 0, width: 800, height: 600),
        layer: Int = 0,
        zOrderIndex: Int = 0
    ) -> MeetingWindowCandidate {
        MeetingWindowCandidate(windowID: windowID, title: title, frame: frame, layer: layer, zOrderIndex: zOrderIndex)
    }

    func testEmptyCandidateListReturnsNil() {
        XCTAssertNil(MeetingWindowSelector.selectWindow(from: []))
    }

    func testTitledBeatsUntitledRegardlessOfArea() {
        let untitledLarge = self.candidate(1, title: nil, frame: CGRect(x: 0, y: 0, width: 2000, height: 2000), zOrderIndex: 0)
        let titledSmall = self.candidate(2, title: "Standup", frame: CGRect(x: 0, y: 0, width: 300, height: 300), zOrderIndex: 5)
        let winner = MeetingWindowSelector.selectWindow(from: [untitledLarge, titledSmall])
        XCTAssertEqual(winner?.windowID, 2)
    }

    func testFrontmostBeatsLargerButBehindAmongTitled() {
        let frontSmall = self.candidate(1, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 400, height: 300), zOrderIndex: 0)
        let behindLarge = self.candidate(2, title: "Other", frame: CGRect(x: 0, y: 0, width: 2000, height: 1500), zOrderIndex: 3)
        let winner = MeetingWindowSelector.selectWindow(from: [behindLarge, frontSmall])
        XCTAssertEqual(winner?.windowID, 1)
    }

    func testNonZeroLayerIsExcluded() {
        let panel = self.candidate(1, title: "Panel", layer: 25)
        XCTAssertNil(MeetingWindowSelector.selectWindow(from: [panel]))
    }

    func testSubMinimumSizeIsExcluded() {
        let sliver = self.candidate(1, title: "Toolbar", frame: CGRect(x: 0, y: 0, width: 150, height: 60))
        XCTAssertNil(MeetingWindowSelector.selectWindow(from: [sliver]))
    }

    func testDeterministicWindowIDTiebreakOnFullTies() {
        let frame = CGRect(x: 0, y: 0, width: 800, height: 600)
        let a = self.candidate(42, title: "Same", frame: frame, zOrderIndex: 1)
        let b = self.candidate(7, title: "Same", frame: frame, zOrderIndex: 1)
        let winner = MeetingWindowSelector.selectWindow(from: [a, b])
        XCTAssertEqual(winner?.windowID, 7)
    }

    /// Zoom-like fixture: a small floating toolbar (excluded by size), an untitled main window,
    /// and the frontmost titled meeting window. The meeting window should win.
    func testRealisticZoomFixture() {
        let toolbar = self.candidate(
            1, title: "Zoom Toolbar", frame: CGRect(x: 0, y: 0, width: 180, height: 60), layer: 0, zOrderIndex: 0
        )
        let mainWindow = self.candidate(
            2, title: nil, frame: CGRect(x: 0, y: 0, width: 1200, height: 800), layer: 0, zOrderIndex: 2
        )
        let meetingWindow = self.candidate(
            3, title: "Zoom Meeting", frame: CGRect(x: 0, y: 0, width: 1000, height: 700), layer: 0, zOrderIndex: 1
        )
        let winner = MeetingWindowSelector.selectWindow(from: [toolbar, mainWindow, meetingWindow])
        XCTAssertEqual(winner?.windowID, 3)
    }

    func testExactMinimumSizeIsIncludedAndOnePixelUnderIsNot() {
        let atMinimum = self.candidate(1, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 200, height: 100))
        XCTAssertEqual(MeetingWindowSelector.selectWindow(from: [atMinimum])?.windowID, 1)
        let underWidth = self.candidate(2, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 199, height: 100))
        let underHeight = self.candidate(3, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 200, height: 99))
        XCTAssertNil(MeetingWindowSelector.selectWindow(from: [underWidth, underHeight]))
    }

    func testWhitespaceOnlyTitleCountsAsUntitled() {
        let whitespace = self.candidate(1, title: "   \n", frame: CGRect(x: 0, y: 0, width: 2000, height: 1500), zOrderIndex: 0)
        let titled = self.candidate(2, title: "Meeting", frame: CGRect(x: 0, y: 0, width: 400, height: 300), zOrderIndex: 5)
        XCTAssertEqual(MeetingWindowSelector.selectWindow(from: [whitespace, titled])?.windowID, 2)
    }

    func testLargerAreaBeatsSmallerWindowIDWhenTitleAndZOrderTie() {
        let smallEarlyID = self.candidate(1, title: "A", frame: CGRect(x: 0, y: 0, width: 400, height: 300), zOrderIndex: 2)
        let largeLateID = self.candidate(9, title: "B", frame: CGRect(x: 0, y: 0, width: 900, height: 700), zOrderIndex: 2)
        XCTAssertEqual(MeetingWindowSelector.selectWindow(from: [smallEarlyID, largeLateID])?.windowID, 9)
    }

    func testFrontmostBeatsSmallerWindowID() {
        let behindEarlyID = self.candidate(1, title: "A", frame: CGRect(x: 0, y: 0, width: 800, height: 600), zOrderIndex: 4)
        let frontLateID = self.candidate(9, title: "B", frame: CGRect(x: 0, y: 0, width: 800, height: 600), zOrderIndex: 1)
        XCTAssertEqual(MeetingWindowSelector.selectWindow(from: [behindEarlyID, frontLateID])?.windowID, 9)
    }
}

/// Inspects the real production filter without starting a stream or requesting screen permission.
final class MeetingApplicationAudioFilterTests: XCTestCase {
    private func currentProcessContent() async throws -> (SCShareableContent, SCRunningApplication, SCDisplay) {
        let content = try await SCShareableContent.currentProcess
        guard let application = content.applications.first(where: {
            $0.processID == ProcessInfo.processInfo.processIdentifier
        }), let display = content.displays.first else {
            throw XCTSkip("ScreenCaptureKit has no current-process application or display")
        }
        return (content, application, display)
    }

    func testSelectedApplicationFilterDoesNotDependOnPreferredWindowEvidence() async throws {
        guard #available(macOS 15.2, *) else { throw XCTSkip("Filter inspection requires macOS 15.2") }
        let (content, application, display) = try await self.currentProcessContent()
        let existingWindowID = content.windows.first(where: {
            $0.owningApplication?.processID == application.processID
        })?.windowID
        // Detection evidence can describe an existing, removed/replaced, or absent/hidden window.
        // Production filter construction has no dependency on the current window list.
        let preferredWindowIDs: [UInt32?] = [existingWindowID, UInt32.max, nil]
        for windowID in preferredWindowIDs {
            let selection = MeetingApplicationIdentity(
                bundleIdentifier: application.bundleIdentifier, processID: application.processID,
                displayName: "Selected application", displayID: display.displayID, windowID: windowID
            )
            let result = try MeetingScreenCaptureAudioSettings.contentFilter(
                for: .application(selection), applications: content.applications, displays: content.displays
            )
            XCTAssertNotEqual(result.filter.style, .window)
            XCTAssertEqual(result.filter.includedApplications.map(\.processID), [application.processID])
            XCTAssertEqual(result.filter.includedApplications.map(\.bundleIdentifier), [application.bundleIdentifier])
            XCTAssertEqual(result.filter.includedDisplays.map(\.displayID), [display.displayID])
            guard case .display = result.scope else { return XCTFail("selected audio must retain application filtering on a display") }
        }
    }

    func testStaleOrReusedSavedPIDResolvesOnlyTheSelectedBundle() async throws {
        guard #available(macOS 15.2, *) else { throw XCTSkip("Filter inspection requires macOS 15.2") }
        let (content, application, display) = try await self.currentProcessContent()
        let unrelated = content.applications.first(where: { $0.bundleIdentifier != application.bundleIdentifier })
        let selection = MeetingApplicationIdentity(
            bundleIdentifier: application.bundleIdentifier, processID: unrelated?.processID ?? -1,
            displayName: "Selected application", displayID: display.displayID, windowID: UInt32.max
        )
        let result = try MeetingScreenCaptureAudioSettings.contentFilter(
            for: .application(selection), applications: content.applications, displays: content.displays
        )
        XCTAssertEqual(result.filter.includedApplications.map(\.processID), [application.processID])
        XCTAssertEqual(result.filter.includedApplications.map(\.bundleIdentifier), [application.bundleIdentifier])
        XCTAssertNotEqual(result.filter.style, .window)
    }

    func testUnavailableSelectedApplicationCannotCaptureAnUnrelatedProcessOrSystemAudio() async throws {
        let (content, application, display) = try await self.currentProcessContent()
        let selection = MeetingApplicationIdentity(
            bundleIdentifier: "example.invalid.missing-capture-target", processID: application.processID,
            displayName: "Missing application", displayID: display.displayID
        )
        XCTAssertThrowsError(try MeetingScreenCaptureAudioSettings.contentFilter(
            for: .application(selection), applications: content.applications, displays: content.displays
        ))
        XCTAssertThrowsError(try MeetingScreenCaptureAudioSettings.contentFilter(
            for: .application(selection), applications: [], displays: content.displays
        ))
        // System capture is available only through its explicit source, independently of apps.
        let system = try MeetingScreenCaptureAudioSettings.contentFilter(
            for: .systemAudio, applications: [], displays: content.displays
        )
        guard case .systemAudio = system.scope else { return XCTFail("explicit system capture must preserve its scope") }
    }

    func testSelectedDisplayFallbackKeepsTheApplicationRestriction() async throws {
        guard #available(macOS 15.2, *) else { throw XCTSkip("Filter inspection requires macOS 15.2") }
        let (content, application, display) = try await self.currentProcessContent()
        for preferredDisplayID in content.displays.map(\.displayID) + [UInt32.max] {
            let selection = MeetingApplicationIdentity(
                bundleIdentifier: application.bundleIdentifier, processID: application.processID,
                displayName: "Selected application", displayID: preferredDisplayID
            )
            let result = try MeetingScreenCaptureAudioSettings.contentFilter(
                for: .application(selection), applications: content.applications, displays: content.displays
            )
            let expectedDisplay = content.displays.first(where: { $0.displayID == preferredDisplayID }) ?? display
            XCTAssertEqual(result.filter.includedDisplays.map(\.displayID), [expectedDisplay.displayID])
            XCTAssertEqual(result.filter.includedApplications.map(\.processID), [application.processID])
            XCTAssertThrowsError(try MeetingScreenCaptureAudioSettings.contentFilter(
                for: .application(selection), applications: content.applications, displays: []
            ))
        }
        XCTAssertThrowsError(try MeetingScreenCaptureAudioSettings.contentFilter(
            for: .systemAudio, applications: content.applications, displays: []
        ))
    }
}
