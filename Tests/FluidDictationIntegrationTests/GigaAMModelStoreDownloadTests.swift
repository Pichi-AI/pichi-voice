import CryptoKit
@testable import FluidVoice_Debug
import Foundation
import PichiGigaAM
import XCTest

final nonisolated class GigaAMModelStoreDownloadTests: XCTestCase {
    func testDownloadPublishesCompleteHashVerifiedFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let installed = try await fixture.store().ensureInstalled()
        XCTAssertEqual(installed.descriptor, fixture.descriptor)
        XCTAssertEqual(installed.directory.lastPathComponent, fixture.descriptor.id)
        XCTAssertEqual(try Data(contentsOf: installed.directory.appendingPathComponent(fixture.descriptor.modelFile)), fixture.modelBytes)
        try installed.descriptor.verify(in: installed.directory)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [fixture.descriptor.id])
    }

    func testCorruptDownloadNeverPublishesModelFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = fixture.store(modelOverride: Data(repeating: 120, count: fixture.modelBytes.count))
        do {
            _ = try await store.ensureInstalled()
            XCTFail("Corrupt model must fail before publication")
        } catch GigaAMError.checksumMismatch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testWrongSizeDownloadNeverPublishesModelFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        do {
            _ = try await fixture.store(modelOverride: Data("short".utf8)).ensureInstalled()
            XCTFail("Downloaded bytes must equal the registered artifact size")
        } catch GigaAMError.checksumMismatch {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testHTTPErrorNeverPublishesModelFolder() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        do {
            _ = try await fixture.store(statusCode: 403).ensureInstalled()
            XCTFail("HTTP error must not become an installed model")
        } catch let error as URLError {
            XCTAssertEqual(error.code, .badServerResponse)
        }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testCancellationJoinsDownloaderAndRemovesIncompleteStage() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let gate = DownloadGate()
        let store = PichiGigaAMModelStore(directory: fixture.directory, downloadDescriptor: fixture.descriptor) { _, _, _ in
            await gate.started()
            do {
                try await Task.sleep(for: .seconds(30))
                throw URLError(.unknown)
            } catch {
                await gate.ended()
                throw error
            }
        }
        let operation = Task { try await store.ensureInstalled() }
        await gate.waitUntilStarted()
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Cancelled installation must fail") }
        catch is CancellationError {}
        let didEnd = await gate.didEnd
        XCTAssertTrue(didEnd, "Cancellation must await the downloader before returning")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testSymlinkedDownloadDirectoryIsNeverWritten() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let alias = fixture.directory.deletingLastPathComponent().appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: alias) }
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: fixture.directory)
        let store = PichiGigaAMModelStore(directory: alias, downloadDescriptor: fixture.descriptor) { _, _, _ in
            XCTFail("Unsafe model directory must fail before downloading")
            throw URLError(.unknown)
        }
        do { _ = try await store.ensureInstalled(); XCTFail("Symlinked destination must fail") }
        catch GigaAMError.incompatibleModel {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testExistingRegisteredLocalImportKeepsPriorityWithoutDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let existing = try XCTUnwrap(GigaAMModelCatalog.models.first)
        for name in [existing.modelFile] + [existing.vocabularyFile].compactMap({ $0 }) {
            try Data("synthetic probe".utf8).write(to: fixture.directory.appendingPathComponent(name))
        }
        let store = PichiGigaAMModelStore(directory: fixture.directory, downloadDescriptor: fixture.descriptor) { _, _, _ in
            XCTFail("An existing registered import must keep its selection")
            throw URLError(.unknown)
        }
        let installed = try await store.ensureInstalled()
        XCTAssertEqual(installed.descriptor.id, existing.id)
        // Discovery is a cheap UI probe. Native load still requires the full digests.
        XCTAssertThrowsError(try installed.descriptor.verify(in: installed.directory))
    }

    private struct Fixture: Sendable {
        let directory: URL
        let descriptor: GigaAMModelDescriptor
        let modelBytes = Data("synthetic ONNX artifact fixture".utf8)
        let vocabularyBytes = Data("<unk> 0\n<blk> 1\n".utf8)

        init() throws {
            self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            self.descriptor = GigaAMModelDescriptor(
                id: "synthetic-download", modelFile: "model.onnx", modelSHA256: Self.hash(self.modelBytes),
                vocabularyFile: "vocab.txt", vocabularySHA256: Self.hash(self.vocabularyBytes), endOfUtteranceThreshold: nil,
                downloadBaseURL: URL(string: "https://fixture.invalid/pinned-revision/")!,
                modelByteCount: Int64(self.modelBytes.count), vocabularyByteCount: Int64(self.vocabularyBytes.count)
            )
        }

        func store(modelOverride: Data? = nil, statusCode: Int = 200) -> PichiGigaAMModelStore {
            PichiGigaAMModelStore(directory: self.directory, downloadDescriptor: self.descriptor) { source, maximumBytes, progress in
                let bytes = source.lastPathComponent == self.descriptor.modelFile ? modelOverride ?? self.modelBytes : self.vocabularyBytes
                let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try bytes.write(to: temporaryURL)
                progress(Int64(bytes.count), maximumBytes)
                return (temporaryURL, HTTPURLResponse(url: source, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
        }

        func remove() { try? FileManager.default.removeItem(at: self.directory) }
        private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }

    private actor DownloadGate {
        private var didStart = false
        private var waiter: CheckedContinuation<Void, Never>?
        private(set) var didEnd = false

        func started() {
            self.didStart = true
            self.waiter?.resume()
            self.waiter = nil
        }
        func waitUntilStarted() async {
            if self.didStart { return }
            await withCheckedContinuation { self.waiter = $0 }
        }
        func ended() { self.didEnd = true }
    }
}
