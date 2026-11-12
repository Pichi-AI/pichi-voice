@testable import FluidVoice_Debug
import Foundation
import XCTest

/// A crash during a save must leave the previous file whole, so a save has to replace the file.
/// A second hard link shows the difference: it keeps the old bytes only if the file was replaced.
final class MeetingSessionStoreAtomicWriteXCTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        self.root = FileManager.default.temporaryDirectory
            .appendingPathComponent("meeting-store-atomic-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.root)
    }

    private func makeSession() -> MeetingSession {
        let configuration = MeetingCaptureConfiguration(
            mode: .inRoom, title: "Synthetic", microphone: MeetingMicrophoneIdentity(captureDeviceID: "mic-1", displayName: "Mic"))
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1, machTimebaseDenominator: 1,
                                               firstPresentationTime: nil)
        return MeetingSession(configuration: configuration, startedAt: Date(timeIntervalSince1970: 1_000), timebase: timebase)
    }

    private func assertReplaced(_ file: URL, by change: () async throws -> Void) async throws {
        let before = try Data(contentsOf: file)
        let link = self.root.appendingPathComponent("link-\(UUID().uuidString)")
        try FileManager.default.linkItem(at: file, to: link)
        try await change()
        XCTAssertNotEqual(try Data(contentsOf: file), before, "The change should reach the file")
        XCTAssertEqual(try Data(contentsOf: link), before, "\(file.lastPathComponent) was rewritten in place")
    }

    func testSavingReplacesTheSessionFile() async throws {
        let store = MeetingSessionStore(rootDirectory: self.root)
        var session = self.makeSession()
        try await store.create(session)
        let file = try await store.sessionDirectory(for: session.id).appendingPathComponent("session.json")
        try await self.assertReplaced(file) {
            session.updatedAt = Date(timeIntervalSince1970: 2_000)
            try await store.save(session)
        }
    }

    func testAddingASessionReplacesTheIndex() async throws {
        let store = MeetingSessionStore(rootDirectory: self.root)
        try await store.create(self.makeSession())
        try await self.assertReplaced(self.root.appendingPathComponent("index.json")) {
            try await store.create(self.makeSession())
        }
    }
}
