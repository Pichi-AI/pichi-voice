import AVFoundation
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

    @MainActor
    func testAudioShareOffersOneCompressedPlayableM4AAndCleansItsDirectory() async throws {
        let source = fixtureRoot.appendingPathComponent("audio", isDirectory: true)
        try manager.createDirectory(at: source, withIntermediateDirectories: true)
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        var chunks: [MeetingAudioChunk] = []
        for index in 0..<2 {
            let path = "tone-\(index).caf"
            let url = source.appendingPathComponent(path)
            do {
                let file = try AVAudioFile(forWriting: url, settings: format.settings)
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 16_000))
                buffer.frameLength = 16_000
                let samples = try XCTUnwrap(buffer.floatChannelData?[0])
                for frame in 0..<16_000 { samples[frame] = Float(sin(Double(frame) * 2 * .pi * 440 / 16_000) * 0.3) }
                try file.write(from: buffer)
            }
            chunks.append(.init(id: UUID(), sequence: index, relativeFilePath: path,
                presentationStart: .init(value: Int64(index), timescale: 1),
                presentationEnd: .init(value: Int64(index + 1), timescale: 1), discontinuities: [],
                sha256: "synthetic", byteCount: Int64(try Data(contentsOf: url).count), finalizationState: .finalized))
        }
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Встреча Ёё",
            microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")), startedAt: Date(), timebase: timebase)
        session.state = .completed
        session.audioTracks = [.init(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting, chunks: chunks)]
        let payload = try await MeetingSharePayload.audio(session: session, directory: source)
        defer { payload.cleanup() }
        XCTAssertTrue(payload.includesAudio)
        XCTAssertEqual(payload.items.count, 1)
        let url = try XCTUnwrap(payload.items.first as? URL)
        XCTAssertEqual(url.lastPathComponent, "Встреча Ёё.m4a")
        XCTAssertEqual(url.deletingLastPathComponent(), payload.directory)
        XCTAssertEqual(try manager.contentsOfDirectory(atPath: payload.directory.path), [url.lastPathComponent])
        XCTAssertEqual(try AVAudioFile(forReading: url).length, 32_000)
        XCTAssertLessThan(try Data(contentsOf: url).count, Int(chunks.reduce(0) { $0 + $1.byteCount }) / 2)
        let original = try Data(contentsOf: chunks[0].fileURL(relativeTo: source))
        payload.cleanup()
        XCTAssertFalse(manager.fileExists(atPath: payload.directory.path))
        XCTAssertEqual(try Data(contentsOf: chunks[0].fileURL(relativeTo: source)), original)
        let existingShares = try Set(manager.contentsOfDirectory(atPath: manager.temporaryDirectory.path).filter { $0.hasPrefix("meeting-share-") })
        try manager.removeItem(at: chunks[1].fileURL(relativeTo: source))
        do { _ = try await MeetingSharePayload.audio(session: session, directory: source); XCTFail("Missing chunk") } catch {}
        let sharesAfterFailure = try Set(manager.contentsOfDirectory(atPath: manager.temporaryDirectory.path).filter { $0.hasPrefix("meeting-share-") })
        XCTAssertEqual(sharesAfterFailure, existingShares, "Failure cleans only its own share staging")
    }

    func testTranscriptSharePreservesCyrillicFileNameAndBytes() throws {
        let title = "Синтетическая проверка атрибуции Ёё"
        let data = Data("{\"synthetic\":true}".utf8)
        let payload = try MeetingSharePayload.transcript(data: data, title: title, fileExtension: "json")
        defer { payload.cleanup() }
        let url = try XCTUnwrap(payload.items.first as? URL)
        XCTAssertEqual(url.lastPathComponent, title + ".json")
        XCTAssertEqual(try Data(contentsOf: url), data)
        XCTAssertEqual(url.deletingLastPathComponent(), payload.directory)
    }

    func testExportNameRejectsTraversalControlsAndHiddenComponents() {
        let hazardous = "  ../Секрет/папка\\имя:\u{0000}\n\u{202E}. "
        let result = MeetingAudioExporter.sanitizedExportName(hazardous)
        XCTAssertFalse(result.hasPrefix("."))
        XCTAssertFalse(result.contains("/"))
        XCTAssertFalse(result.contains("\\"))
        XCTAssertFalse(result.contains(":"))
        XCTAssertFalse(result.contains("\u{202E}"))
        XCTAssertFalse(result.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) })
        XCTAssertTrue(result.contains("Секрет"))
        for emptyComponent in ["", ".", "..", " ... "] {
            let safe = MeetingAudioExporter.sanitizedExportName(emptyComponent)
            XCTAssertFalse(safe.isEmpty)
            XCTAssertFalse(safe.hasPrefix("."))
        }
    }

    func testExportNameBoundsBytesWithoutSplittingUnicodeCharacters() throws {
        let decomposed = "И\u{0306}ван Е\u{0308}лкин"
        XCTAssertEqual(MeetingAudioExporter.sanitizedExportName(decomposed), "Йван Ёлкин")
        let title = String(repeating: "会議Ё", count: 100)
        let name = MeetingAudioExporter.sanitizedExportName(title)
        XCTAssertLessThanOrEqual(name.utf8.count, 160)
        XCTAssertTrue(title.hasPrefix(name))
        XCTAssertLessThanOrEqual(name.count, 80)
        // The longest existing staging suffix must still fit one file component.
        let component = ".\(name) 999999.\(UUID().uuidString).export-tmp"
        XCTAssertLessThan(component.utf8.count, 255)
        let directory = temporaryRoot.appendingPathComponent(component, isDirectory: true)
        try manager.createDirectory(at: directory, withIntermediateDirectories: false)
        XCTAssertTrue(manager.fileExists(atPath: directory.path))
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
