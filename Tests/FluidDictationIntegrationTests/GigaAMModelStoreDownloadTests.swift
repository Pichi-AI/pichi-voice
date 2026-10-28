import CryptoKit
@testable import FluidVoice_Debug
import Foundation
import PichiGigaAM
import XCTest

final nonisolated class GigaAMModelStoreDownloadTests: XCTestCase {
    func testNestedCoreMLArtifactsUseTheSameVerifiedInstallationOperation() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let files = ["Ready.mlpackage/Manifest.json": Data("synthetic manifest".utf8),
                     "Ready.mlpackage/Data/model.mlmodel": Data("synthetic graph".utf8),
                     "Ready.mlpackage/Data/weights/weight.bin": Data("synthetic weights".utf8),
                     "vocabulary.txt": fixture.vocabularyBytes]
        let artifacts = files.keys.sorted().map { name in
            GigaAMModelArtifact(path: name, sha256: SHA256.hash(data: files[name]!).map { String(format: "%02x", $0) }.joined(),
                               byteCount: Int64(files[name]!.count))
        }
        let descriptor = GigaAMModelDescriptor(id: "synthetic-package", modelFile: "Ready.mlpackage", modelSHA256: artifacts[0].sha256,
                                               vocabularyFile: "vocabulary.txt", vocabularySHA256: artifacts.last!.sha256,
                                               endOfUtteranceThreshold: nil, downloadBaseURL: URL(string: "https://fixture.invalid/revision/")!,
                                               artifacts: artifacts)
        let store = PichiGigaAMModelStore(directory: fixture.directory, downloadDescriptor: descriptor,
                                         preferences: fixture.preferences, environment: [:]) { url, limit, progress in
            let name = String(url.path.dropFirst("/revision/".count))
            let bytes = try XCTUnwrap(files[name])
            XCTAssertEqual(limit, Int64(bytes.count))
            let temporary = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try bytes.write(to: temporary)
            progress(Int64(bytes.count), Int64(bytes.count))
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        let installed = try await store.ensureInstalled()
        try descriptor.verify(in: installed.directory)
        for (name, bytes) in files { XCTAssertEqual(try Data(contentsOf: installed.directory.appendingPathComponent(name)), bytes) }
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path), [descriptor.id])
    }

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
        let store = PichiGigaAMModelStore(directory: fixture.directory, downloadDescriptor: fixture.descriptor, preferences: fixture.preferences, environment: [:]) { _, _, _ in
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
        let store = PichiGigaAMModelStore(directory: alias, downloadDescriptor: fixture.descriptor, preferences: fixture.preferences, environment: [:]) { _, _, _ in
            XCTFail("Unsafe model directory must fail before downloading")
            throw URLError(.unknown)
        }
        do { _ = try await store.ensureInstalled(); XCTFail("Symlinked destination must fail") }
        catch GigaAMError.incompatibleModel {}
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: fixture.directory.path).isEmpty)
    }

    func testPublicDefaultIgnoresOldPrivateFilesAndLegacyDirectoryPreference() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let old = try fixture.writeImported(to: fixture.directory)
        fixture.preferences.set(old.path, forKey: "pichiGigaAMModelDirectory")
        let store = fixture.store()
        XCTAssertFalse(store.modelsExistOnDisk(), "Old private weights must not satisfy public-source readiness")
        XCTAssertFalse(store.usesImportedModelSource)
        let installed = try await store.ensureInstalled()
        XCTAssertEqual(installed.descriptor, fixture.descriptor)
        XCTAssertEqual(try store.installedModelFingerprint(), fixture.descriptor.fingerprint)
        XCTAssertTrue(fixture.importedDescriptor.filesExist(in: old), "Changing defaults must retain private files")
    }

    func testVerifiedImportPersistsExplicitSelectionAndRestoringDefaultRetainsBothArtifacts() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("import-source", isDirectory: true)
        try fixture.writeImported(to: source)
        let store = fixture.store()
        _ = try await store.ensureInstalled()
        try await store.importModel(from: source)
        let imported = try store.installedModel()
        XCTAssertTrue(store.usesImportedModelSource)
        XCTAssertEqual(imported.descriptor, fixture.importedDescriptor)
        XCTAssertEqual(imported.directory.lastPathComponent, fixture.importedDescriptor.id)
        XCTAssertEqual(try fixture.store().installedModelFingerprint(), fixture.importedDescriptor.fingerprint,
                       "Explicit import selection must survive a new provider/store")
        try await store.restoreDefaultModelSource()
        XCTAssertFalse(store.usesImportedModelSource)
        XCTAssertEqual(try fixture.store().installedModelFingerprint(), fixture.descriptor.fingerprint)
        XCTAssertTrue(fixture.importedDescriptor.filesExist(in: imported.directory))
        XCTAssertTrue(fixture.descriptor.filesExist(in: try store.installedModel().directory))
        let pinned = try store.installedModel(matchingFingerprint: fixture.importedDescriptor.fingerprint)
        XCTAssertEqual(pinned.directory, imported.directory, "Existing meetings must still locate their pinned import")
        let pinnedStore = PichiGigaAMModelStore(directory: imported.directory, downloadDescriptor: fixture.descriptor,
                                              importDescriptors: [fixture.importedDescriptor], preferences: fixture.preferences,
                                              environment: [:])
        XCTAssertEqual(try pinnedStore.installedModelFingerprint(), fixture.importedDescriptor.fingerprint)
    }

    func testFailedOrCancelledImportNeverSelectsPrivateArtifact() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("import-source", isDirectory: true)
        try fixture.writeImported(to: source)
        let store = fixture.store()
        let cancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            try await store.importModel(from: source)
        }
        do { try await cancelled.value; XCTFail("Cancelled import must not commit selection") }
        catch is CancellationError {}
        XCTAssertFalse(store.usesImportedModelSource)
        try Data("corrupt".utf8).write(to: source.appendingPathComponent(fixture.importedDescriptor.modelFile))
        do { try await store.importModel(from: source); XCTFail("Import must verify full digests before selection") }
        catch GigaAMError.checksumMismatch {}
        XCTAssertFalse(store.usesImportedModelSource)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fixture.directory.appendingPathComponent(fixture.importedDescriptor.id).path))
    }

    func testMissingExplicitImportDoesNotSilentlyFallBackToPublicDownload() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("import-source", isDirectory: true)
        try fixture.writeImported(to: source)
        let store = fixture.store()
        try await store.importModel(from: source)
        try FileManager.default.removeItem(at: try store.installedModel().directory)
        XCTAssertFalse(store.modelsExistOnDisk())
        do { _ = try await store.ensureInstalled(); XCTFail("An explicit missing source must remain missing") }
        catch GigaAMError.missingModels {}
        XCTAssertTrue(store.usesImportedModelSource)
        try await store.restoreDefaultModelSource()
        let installed = try await store.ensureInstalled()
        XCTAssertEqual(installed.descriptor, fixture.descriptor)
    }

    func testPublicPreparationFreezesArtifactWhileExplicitSelectionChanges() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let source = fixture.directory.appendingPathComponent("import-source", isDirectory: true)
        try fixture.writeImported(to: source)
        let gate = DownloadGate()
        let store = fixture.store(downloadGate: gate)
        let operation = Task { try await store.ensureInstalled() }
        await gate.waitUntilStarted()
        do { try await store.importModel(from: source) }
        catch {
            await gate.open()
            _ = try? await operation.value
            throw error
        }
        await gate.open()
        let installed = try await operation.value
        XCTAssertEqual(installed.descriptor, fixture.descriptor, "The operation must return its captured public artifact")
        XCTAssertEqual(try store.installedModel().descriptor, fixture.importedDescriptor,
                       "A later source selection governs only subsequent operations")
        let pinned = try store.installedModel(matchingFingerprint: fixture.descriptor.fingerprint)
        XCTAssertEqual(pinned.directory, installed.directory)
    }

    func testEnvironmentOverrideIsExplicitAndReadOnly() async throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let store = PichiGigaAMModelStore(downloadDescriptor: fixture.descriptor,
                                         importDescriptors: [fixture.importedDescriptor], preferences: fixture.preferences,
                                         environment: ["PICHI_GIGAAM_MODEL_DIR": fixture.directory.path]) { _, _, _ in
            XCTFail("External override must never receive downloaded weights")
            throw URLError(.unknown)
        }
        do { _ = try await store.ensureInstalled(); XCTFail("Empty external source must remain read-only") }
        catch GigaAMError.missingModels {}
        try fixture.writeImported(to: fixture.directory)
        let installed = try await store.ensureInstalled()
        XCTAssertEqual(installed.descriptor, fixture.importedDescriptor)
    }

    private struct Fixture: @unchecked Sendable {
        let directory: URL
        let descriptor: GigaAMModelDescriptor
        let importedDescriptor: GigaAMModelDescriptor
        let preferences: UserDefaults
        let preferencesSuite: String
        let modelBytes = Data("synthetic ONNX artifact fixture".utf8)
        let vocabularyBytes = Data("<unk> 0\n<blk> 1\n".utf8)

        init() throws {
            self.preferencesSuite = "GigaAMModelStoreTests.\(UUID().uuidString)"
            self.preferences = UserDefaults(suiteName: self.preferencesSuite)!
            self.directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: self.directory, withIntermediateDirectories: true)
            self.descriptor = GigaAMModelDescriptor(
                id: "synthetic-download", modelFile: "model.onnx", modelSHA256: Self.hash(self.modelBytes),
                vocabularyFile: "vocab.txt", vocabularySHA256: Self.hash(self.vocabularyBytes), endOfUtteranceThreshold: nil,
                downloadBaseURL: URL(string: "https://fixture.invalid/pinned-revision/")!,
                modelByteCount: Int64(self.modelBytes.count), vocabularyByteCount: Int64(self.vocabularyBytes.count)
            )
            self.importedDescriptor = GigaAMModelDescriptor(
                id: "synthetic-import", modelFile: "local.fp16.onnx", modelSHA256: Self.hash(self.modelBytes),
                vocabularyFile: "local-vocab.txt", vocabularySHA256: Self.hash(self.vocabularyBytes), endOfUtteranceThreshold: 0.48
            )
        }

        @discardableResult
        func writeImported(to root: URL) throws -> URL {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try self.modelBytes.write(to: root.appendingPathComponent(self.importedDescriptor.modelFile))
            try self.vocabularyBytes.write(to: root.appendingPathComponent(self.importedDescriptor.vocabularyFile!))
            return root
        }

        func store(modelOverride: Data? = nil, statusCode: Int = 200, downloadGate: DownloadGate? = nil) -> PichiGigaAMModelStore {
            PichiGigaAMModelStore(directory: self.directory, downloadDescriptor: self.descriptor,
                                 importDescriptors: [self.importedDescriptor], preferences: self.preferences, environment: [:]) { source, maximumBytes, progress in
                if let downloadGate { await downloadGate.started(); await downloadGate.waitUntilOpen() }
                let bytes = source.lastPathComponent == self.descriptor.modelFile ? modelOverride ?? self.modelBytes : self.vocabularyBytes
                let temporaryURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
                try bytes.write(to: temporaryURL)
                progress(Int64(bytes.count), maximumBytes)
                return (temporaryURL, HTTPURLResponse(url: source, statusCode: statusCode, httpVersion: "HTTP/1.1", headerFields: nil)!)
            }
        }

        func remove() {
            try? FileManager.default.removeItem(at: self.directory)
            self.preferences.removePersistentDomain(forName: self.preferencesSuite)
        }
        private static func hash(_ bytes: Data) -> String { SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined() }
    }

    private actor DownloadGate {
        private var didStart = false
        private var isOpen = false
        private var openWaiter: CheckedContinuation<Void, Never>?
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
        func waitUntilOpen() async {
            if self.isOpen { return }
            await withCheckedContinuation { self.openWaiter = $0 }
        }
        func open() {
            self.isOpen = true
            self.openWaiter?.resume()
            self.openWaiter = nil
        }
    }
}
