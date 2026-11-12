@testable import FluidVoice_Debug
import Foundation
import XCTest

final nonisolated class UpdateDMGStagerTests: XCTestCase {
    func testReadOnlyMountCopiesSoleCanonicalAppAndDetachesBeforeReturning() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let app = try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: fixture.operations)
        XCTAssertEqual(app.lastPathComponent, "Pichi Voice.app")
        XCTAssertTrue(FileManager.default.fileExists(atPath: app.appendingPathComponent("payload").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("mount").path))
        XCTAssertEqual(fixture.commands.map { $0.first! }, ["attach", "detach"])
        XCTAssertTrue(fixture.commands[0].contains("-readonly"))
        XCTAssertTrue(fixture.commands[0].contains("-noautoopen"))
    }

    func testNoncanonicalMultipleAndSymlinkAppsDetachWithoutCopy() throws {
        for kind in [Fixture.Kind.wrongName, .multiple, .symlink] {
            let fixture = try Fixture(kind: kind)
            defer { fixture.cleanup() }
            XCTAssertThrowsError(try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: fixture.operations))
            XCTAssertEqual(fixture.commands.last?.first, "detach")
            XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("Pichi Voice.app").path))
        }
    }

    func testOversizedAppIsRejectedBeforeCopyAndStillDetaches() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var operations = fixture.operations
        let runner = operations.run
        operations.run = { path, args, root, cancellable in
            try runner(path, args, root, cancellable)
            if args.first == "attach" {
                let file = try FileHandle(forWritingTo: root.appendingPathComponent("mount/Pichi Voice.app/payload"))
                defer { try? file.close() }
                try file.truncate(atOffset: UInt64(UpdateDMGStager.maximumAppBytes + 1))
            }
        }
        operations.copy = { _, _ in XCTFail("An oversized app must fail before copying") }
        XCTAssertThrowsError(try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: operations))
        XCTAssertEqual(fixture.commands.last?.first, "detach")
    }

    func testCopyFailureStillDetaches() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var operations = fixture.operations
        operations.copy = { _, _ in throw CocoaError(.fileWriteOutOfSpace) }
        XCTAssertThrowsError(try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: operations))
        XCTAssertEqual(fixture.commands.last?.first, "detach")
    }

    func testCancellationAfterAttachJoinsDetach() async throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        let attached = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        var operations = fixture.operations
        let runner = operations.run
        operations.run = { path, args, root, cancellable in
            try runner(path, args, root, cancellable)
            if args.first == "attach" {
                attached.signal()
                guard resume.wait(timeout: .now() + 3) == .success else { throw URLError(.timedOut) }
            }
        }
        let frozen = operations
        let task = Task.detached { try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: frozen) }
        XCTAssertEqual(attached.wait(timeout: .now() + 3), .success)
        task.cancel()
        resume.signal()
        do { _ = try await task.value; XCTFail("Cancelled staging must not produce an app") }
        catch { XCTAssertTrue(error is CancellationError) }
        XCTAssertEqual(fixture.commands.last?.first, "detach")
        XCTAssertFalse(fixture.detachWasCancellable)
    }

    func testDetachFailureRetainsRecoveryPath() throws {
        let fixture = try Fixture(kind: .detachFails)
        defer { fixture.cleanup() }
        XCTAssertThrowsError(try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: fixture.operations)) {
            XCTAssertEqual(($0 as? UpdateDMGStager.Failure)?.retainedRoot, fixture.root)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("mount").path))
    }

    func testRejectedAttachWithoutMountCanBeCleanedAndRetried() throws {
        let fixture = try Fixture()
        defer { fixture.cleanup() }
        var operations = fixture.operations
        operations.run = { _, _, _, _ in throw SimpleUpdateError.unzipFailed }
        operations.isMounted = UpdateDMGStager.isMounted
        XCTAssertThrowsError(try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: operations)) {
            XCTAssertFalse($0 is UpdateDMGStager.Failure, "A rejected image must not invent a retained mount")
        }
        try FileManager.default.removeItem(at: fixture.root.appendingPathComponent("mount"))
        _ = try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: fixture.operations)
    }

    func testUnknownMountStatePreservesRecoveryInsteadOfRemovingFiles() throws {
        let fixture = try Fixture(kind: .detachFails)
        defer { fixture.cleanup() }
        var operations = fixture.operations
        operations.isMounted = { _, _ in throw CocoaError(.fileReadNoPermission) }
        XCTAssertThrowsError(try UpdateDMGStager.stage(image: fixture.image, root: fixture.root, appName: "Pichi Voice.app", operations: operations)) {
            XCTAssertTrue($0 is UpdateDMGStager.Failure)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: fixture.root.appendingPathComponent("mount/Pichi Voice.app/payload").path))
    }
}

private final nonisolated class Fixture: @unchecked Sendable {
    enum Kind { case normal, wrongName, multiple, symlink, detachFails }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("UpdateDMGStagerTests-" + UUID().uuidString)
    var image: URL { root.appendingPathComponent("fixture.dmg") }
    let kind: Kind
    private let lock = NSLock()
    private var calls: [[String]] = []
    private var cancellableDetach = true
    var commands: [[String]] { lock.withLock { calls } }
    var detachWasCancellable: Bool { lock.withLock { cancellableDetach } }
    init(kind: Kind = .normal) throws {
        self.kind = kind
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    }
    var operations: UpdateDMGStager.Operations {
        .init(run: { [self] _, args, root, cancellable in
            lock.withLock { calls.append(args); if args.first == "detach" { cancellableDetach = cancellable } }
            let mount = root.appendingPathComponent("mount")
            if args.first == "attach" {
                let name = kind == .wrongName ? "Unrelated.app" : "Pichi Voice.app"
                let app = mount.appendingPathComponent(name)
                if kind == .symlink {
                    try FileManager.default.createSymbolicLink(at: app, withDestinationURL: root)
                } else {
                    try FileManager.default.createDirectory(at: app, withIntermediateDirectories: false)
                    try Data("synthetic".utf8).write(to: app.appendingPathComponent("payload"))
                    if kind == .multiple { try FileManager.default.createDirectory(at: mount.appendingPathComponent("Extra.app"), withIntermediateDirectories: false) }
                }
            } else {
                if kind == .detachFails { throw URLError(.cannotCloseFile) }
                for entry in try FileManager.default.contentsOfDirectory(at: mount, includingPropertiesForKeys: nil) { try FileManager.default.removeItem(at: entry) }
            }
        }, isMounted: { [self] _, _ in kind == .detachFails })
    }
    func cleanup() { try? FileManager.default.removeItem(at: root) }
}
