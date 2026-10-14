import Foundation
import XCTest
@testable import PichiVoiceMobile

final class MobileSharingCleanupTests: XCTestCase {
    private var fixtureRoot: URL!
    private var temporaryRoot: URL { fixtureRoot.appendingPathComponent("tmp", isDirectory: true) }
    private let manager = FileManager.default

    override func setUpWithError() throws {
        fixtureRoot = manager.temporaryDirectory.appendingPathComponent("mobile-sharing-test-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporaryRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureRoot { try manager.removeItem(at: fixtureRoot) }
        fixtureRoot = nil
    }

    func testCleanupRemovesOnlyOwnedUUIDDirectoriesAndIsIdempotent() throws {
        let owned = temporaryRoot.appendingPathComponent("meeting-share-\(UUID().uuidString)", isDirectory: true)
        let lowercaseOwned = temporaryRoot.appendingPathComponent("meeting-share-\(UUID().uuidString.lowercased())", isDirectory: true)
        for directory in [owned, lowercaseOwned] {
            try manager.createDirectory(at: directory, withIntermediateDirectories: true)
            try Data("synthetic export".utf8).write(to: directory.appendingPathComponent("transcript.txt"))
        }

        let preservedNames = [
            "meeting-share-", "meeting-share-not-a-uuid",
            "meeting-share-\(UUID().uuidString)-extra", "other-share-\(UUID().uuidString)",
            "other-meeting-share-\(UUID().uuidString)", "Meeting-share-\(UUID().uuidString)"
        ]
        for name in preservedNames {
            try manager.createDirectory(at: temporaryRoot.appendingPathComponent(name), withIntermediateDirectories: true)
        }
        let ownedNameFile = temporaryRoot.appendingPathComponent("meeting-share-\(UUID().uuidString)")
        try Data("preserve file".utf8).write(to: ownedNameFile)

        try MeetingSharePayload.cleanupAbandonedShares(in: temporaryRoot)
        try MeetingSharePayload.cleanupAbandonedShares(in: temporaryRoot)

        XCTAssertFalse(manager.fileExists(atPath: owned.path))
        XCTAssertFalse(manager.fileExists(atPath: lowercaseOwned.path))
        for name in preservedNames {
            XCTAssertTrue(manager.fileExists(atPath: temporaryRoot.appendingPathComponent(name).path), name)
        }
        XCTAssertEqual(try Data(contentsOf: ownedNameFile), Data("preserve file".utf8))
    }

    func testCleanupDoesNotDescendIntoUnrelatedDirectories() throws {
        let unrelated = temporaryRoot.appendingPathComponent("unrelated", isDirectory: true)
        let nestedOwnedName = unrelated.appendingPathComponent("meeting-share-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: nestedOwnedName, withIntermediateDirectories: true)
        let nestedFile = nestedOwnedName.appendingPathComponent("preserve.txt")
        try Data("preserve nested export".utf8).write(to: nestedFile)

        try MeetingSharePayload.cleanupAbandonedShares(in: temporaryRoot)

        XCTAssertEqual(try Data(contentsOf: nestedFile), Data("preserve nested export".utf8))
    }

    func testOwnedNameSymlinksAndTheirTargetsArePreserved() throws {
        let target = fixtureRoot.appendingPathComponent("external-target", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let targetFile = target.appendingPathComponent("preserve.txt")
        try Data("preserve linked target".utf8).write(to: targetFile)
        let link = temporaryRoot.appendingPathComponent("meeting-share-\(UUID().uuidString)")
        try manager.createSymbolicLink(at: link, withDestinationURL: target)
        let brokenLink = temporaryRoot.appendingPathComponent("meeting-share-\(UUID().uuidString)")
        let missingTarget = fixtureRoot.appendingPathComponent("missing-target")
        try manager.createSymbolicLink(at: brokenLink, withDestinationURL: missingTarget)

        try MeetingSharePayload.cleanupAbandonedShares(in: temporaryRoot)

        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: link.path), target.path)
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: brokenLink.path), missingTarget.path)
        XCTAssertEqual(try Data(contentsOf: targetFile), Data("preserve linked target".utf8))
    }

    func testRemovingOwnedDirectoryDoesNotFollowItsNestedSymlinks() throws {
        let target = fixtureRoot.appendingPathComponent("external-target", isDirectory: true)
        try manager.createDirectory(at: target, withIntermediateDirectories: true)
        let targetFile = target.appendingPathComponent("preserve.txt")
        try Data("preserve nested link target".utf8).write(to: targetFile)
        let owned = temporaryRoot.appendingPathComponent("meeting-share-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: owned, withIntermediateDirectories: true)
        try manager.createSymbolicLink(at: owned.appendingPathComponent("link"), withDestinationURL: target)

        try MeetingSharePayload.cleanupAbandonedShares(in: temporaryRoot)

        XCTAssertFalse(manager.fileExists(atPath: owned.path))
        XCTAssertEqual(try Data(contentsOf: targetFile), Data("preserve nested link target".utf8))
    }

    func testSymlinkRootIsRejectedWithoutChangingItsTarget() throws {
        let owned = temporaryRoot.appendingPathComponent("meeting-share-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: owned, withIntermediateDirectories: true)
        let export = owned.appendingPathComponent("transcript.txt")
        try Data("preserve export through root link".utf8).write(to: export)
        let rootLink = fixtureRoot.appendingPathComponent("tmp-link", isDirectory: true)
        try manager.createSymbolicLink(at: rootLink, withDestinationURL: temporaryRoot)

        XCTAssertThrowsError(try MeetingSharePayload.cleanupAbandonedShares(in: rootLink))

        XCTAssertEqual(try Data(contentsOf: export), Data("preserve export through root link".utf8))
        XCTAssertEqual(try manager.destinationOfSymbolicLink(atPath: rootLink.path), temporaryRoot.path)
    }

    func testMissingAndFileRootsAreRejectedWithoutChangingFiles() throws {
        let missingRoot = fixtureRoot.appendingPathComponent("missing", isDirectory: true)
        XCTAssertThrowsError(try MeetingSharePayload.cleanupAbandonedShares(in: missingRoot))
        let file = fixtureRoot.appendingPathComponent("not-a-directory")
        try Data("preserve root file".utf8).write(to: file)

        XCTAssertThrowsError(try MeetingSharePayload.cleanupAbandonedShares(in: file))
        XCTAssertThrowsError(try MeetingSharePayload.cleanupAbandonedShares(in: URL(string: "https://example.org/tmp")!))

        XCTAssertEqual(try Data(contentsOf: file), Data("preserve root file".utf8))
    }
}
