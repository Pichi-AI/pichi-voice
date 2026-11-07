@testable import FluidVoice_Debug
import Foundation
import XCTest

/// Stage E of `MEETING_TRANSCRIPTION_IMPLEMENTATION_PLAN.md` (§5): local Nemotron model
/// readiness. Injected URLs for tests, the development environment override, the versioned cache
/// location, and fail-closed structure validation. No network and no bundled 190 MB weights.
@MainActor
final class MeetingNemotronModelLocatorTests: XCTestCase {
    func testSilenceEmbeddingDecodesLittleEndianBitsFromMisalignedStorage() throws {
        // Synthetic IEEE 754 values include signed zero, finite values, infinities and
        // a NaN payload. Comparing bits avoids treating NaN or -0 as ordinary equality.
        let patterns: [UInt32] = [0, 0x8000_0000, 0x3F80_0000, 0xC020_0000, 0x0000_0001,
                                  0x7F80_0000, 0xFF80_0000, 0x7FC0_1234]
        let expected = (0..<512).map { patterns[$0 % patterns.count] }
        let allocation = UnsafeMutableRawPointer.allocate(byteCount: 2_049, alignment: MemoryLayout<UInt32>.alignment)
        defer { allocation.deallocate() }
        let start = allocation.advanced(by: 1)
        XCTAssertNotEqual(Int(bitPattern: start) % MemoryLayout<UInt32>.alignment, 0)
        let bytes = UnsafeMutableRawBufferPointer(start: start, count: 2_048)
        for (index, bits) in expected.enumerated() {
            for byte in 0..<4 {
                bytes[index * 4 + byte] = UInt8(truncatingIfNeeded: bits >> (byte * 8))
            }
        }

        let decoded = try MeetingModelInstaller.decodeSilenceEmbedding(UnsafeRawBufferPointer(bytes))

        XCTAssertEqual(decoded.map(\.bitPattern), expected)
    }

    func testSilenceEmbeddingDecoderRejectsTruncatedAndOversizedStorage() {
        let bytes = [UInt8](repeating: 0, count: 2_049)
        bytes.withUnsafeBytes { storage in
            for count in [0, 3, 2_047, 2_049] {
                let payload = UnsafeRawBufferPointer(rebasing: storage[..<count])
                XCTAssertThrowsError(try MeetingModelInstaller.decodeSilenceEmbedding(payload)) { error in
                    guard case MeetingModelInstaller.InstallError.wrongPackage = error else {
                        return XCTFail("Unexpected rejection: \(error)")
                    }
                }
            }
        }
    }

    func testSilenceEmbeddingInstallCreatesFreshParentAndPreservesExistingFiles() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scratch/nemotron-diar/hf-upload/learnable_sil_emb.f32")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Published silence embedding fixture is not available")
        }
        let root = try self.makeTempDirectory()
        let destination = root.appendingPathComponent("fresh/v1/model.mlpackage")
        let parent = destination.deletingLastPathComponent()
        XCTAssertFalse(FileManager.default.fileExists(atPath: parent.path))
        try MeetingModelInstaller.installSilenceEmbedding(from: source, besides: destination)
        let installed = MeetingModelInstaller.silenceEmbeddingURL(besides: destination)
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: source))
        XCTAssertEqual(try MeetingModelInstaller.validatedSilenceEmbedding(at: installed).count, 512)
        let marker = parent.appendingPathComponent("existing-model-marker")
        try Data("keep".utf8).write(to: marker)
        try MeetingModelInstaller.installSilenceEmbedding(from: source, besides: destination)
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        let invalid = root.appendingPathComponent("invalid.f32")
        try Data("invalid".utf8).write(to: invalid)
        XCTAssertThrowsError(try MeetingModelInstaller.installSilenceEmbedding(from: invalid, besides: destination))
        XCTAssertEqual(try Data(contentsOf: installed), try Data(contentsOf: source))
    }

    func testInvalidSilenceEmbeddingDoesNotCreateDestinationDirectory() throws {
        let root = try self.makeTempDirectory()
        let source = root.appendingPathComponent("invalid.f32")
        // A correctly sized synthetic file must still fail the published SHA256 gate.
        try Data(repeating: 0, count: 512 * MemoryLayout<UInt32>.size).write(to: source)
        let destination = root.appendingPathComponent("fresh/v1/model.mlpackage")
        XCTAssertThrowsError(try MeetingModelInstaller.validatedSilenceEmbedding(at: source))
        XCTAssertThrowsError(try MeetingModelInstaller.installSilenceEmbedding(from: source, besides: destination))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.deletingLastPathComponent().path))
    }

    func testInvalidImportPreservesInstalledPackage() throws {
        let root = try self.makeTempDirectory()
        let source = try self.makeFakePackage(at: root.appendingPathComponent("source"))
        let destination = try self.makeFakePackage(at: root.appendingPathComponent("installed"))
        let manifest = destination.appendingPathComponent("Manifest.json")
        let original = try Data(contentsOf: manifest)
        XCTAssertThrowsError(try MeetingModelInstaller.install(from: source, to: destination))
        XCTAssertEqual(try Data(contentsOf: manifest), original)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: destination.deletingLastPathComponent().path), [destination.lastPathComponent])
    }

    func testPublishedPackageInstallPersistsForFreshLocatorAndReplacement() throws {
        let source = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("scratch/nemotron-diar/hf-upload/nemotron_3_diarization.mlpackage")
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw XCTSkip("Published model fixture is not available")
        }
        let root = try self.makeTempDirectory()
        let destination = root.appendingPathComponent("installed/model.mlpackage")
        _ = try MeetingModelInstaller.install(from: source, to: destination)
        // A fresh locator has no reference to the install task or original download.
        XCTAssertEqual(try MeetingNemotronModelLocator(injectedURL: destination).locate().totalByteCount, 199_258_287)
        _ = try MeetingModelInstaller.install(from: source, to: destination)
        XCTAssertEqual(try MeetingModelInstaller.validate(destination).totalByteCount, 199_258_287)
        XCTAssertEqual(try MeetingModelInstaller.validate(source).totalByteCount, 199_258_287)
    }

    private func makeTempDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("nemotron-locator-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        self.addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    @discardableResult
    private func makeFakePackage(at url: URL) throws -> URL {
        let package = url.appendingPathComponent("nemotron_diar_fp16.mlpackage", isDirectory: true)
        let coreML = package.appendingPathComponent("Data/com.apple.CoreML", isDirectory: true)
        try FileManager.default.createDirectory(at: coreML, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        try Data("model".utf8).write(to: coreML.appendingPathComponent("model.mlmodel"))
        let weights = coreML.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: weights.appendingPathComponent("weight.bin"))
        return package
    }

    private func makeFakeCompiledBundle(at url: URL) throws -> URL {
        let package = url.appendingPathComponent(MeetingNemotronModelLocator.packageFileName, isDirectory: true)
        let compiled = package.appendingPathComponent(MeetingNemotronModelLocator.compiledModelFileName, isDirectory: true)
        let files = ["model.mil", "coremldata.bin", "analytics/coremldata.bin", "weights/weight.bin"]
        for file in files {
            let destination = compiled.appendingPathComponent(file)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic-\(file)".utf8).write(to: destination)
        }
        try Data("synthetic-silence".utf8).write(to: package.appendingPathComponent("learnable_sil_emb.bin"))
        try Data("synthetic-projection".utf8).write(to: package.appendingPathComponent(MeetingNemotronModelLocator.projectionFileName))
        return package
    }

    func testCompiledBundleUnderSystemVarAliasUsesRelativeEntries() throws {
        let root = try self.makeTempDirectory().standardizedFileURL
        guard root.path.hasPrefix("/var/") else {
            throw XCTSkip("This regression requires Foundation's /var temporary-directory alias")
        }
        let package = try self.makeFakeCompiledBundle(at: root)
        let entries = try XCTUnwrap(FileManager.default.enumerator(at: package, includingPropertiesForKeys: nil))
        let firstEntry = try XCTUnwrap(entries.nextObject() as? URL)
        XCTAssertTrue(firstEntry.path.hasPrefix("/private/var/"), "Exercise the alias returned by URL enumeration")
        XCTAssertFalse(firstEntry.path.hasPrefix(package.path + "/"))

        let locator = MeetingNemotronModelLocator(injectedURL: package)
        let artifact = try locator.locate()
        XCTAssertEqual(artifact.fileCount, 6)
        XCTAssertNotNil(artifact.compiledModelURL)
        XCTAssertEqual(try locator.recheck(artifact), artifact)
        let canonical = URL(fileURLWithPath: "/private" + package.path, isDirectory: true)
        XCTAssertEqual(try MeetingNemotronModelLocator(injectedURL: canonical).locate(), artifact)
    }

    func testCompiledBundleKeepsCaseAliasesAndRejectsLinkedEntries() throws {
        let root = try self.makeTempDirectory()
        let package = try self.makeFakeCompiledBundle(at: root.appendingPathComponent("lowercase"))
        let alias = root.appendingPathComponent("LOWERCASE").appendingPathComponent(package.lastPathComponent, isDirectory: true)
        guard FileManager.default.fileExists(atPath: alias.path) else {
            throw XCTSkip("Capitalization aliases require a case-insensitive volume")
        }
        XCTAssertEqual(try MeetingNemotronModelLocator(injectedURL: alias).locate().fileCount, 6)
        let weights = package.appendingPathComponent(MeetingNemotronModelLocator.compiledModelFileName + "/weights/weight.bin")
        try FileManager.default.removeItem(at: weights)
        try FileManager.default.createSymbolicLink(atPath: weights.path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: alias).locate()) {
            XCTAssertEqual($0 as? MeetingNemotronModelReadinessError, .invalidModelPackage(reason: "packageContainsSymlink"))
        }
    }

    func testHomeDirectoryCapitalizationDoesNotLookLikeASymlink() throws {
        let root = try self.makeTempDirectory()
        let home = root.appendingPathComponent("gabriel/Library/Application Support/FluidVoice/MeetingModels")
        let package = try self.makeFakePackage(at: home)
        let alternate = root.appendingPathComponent("Gabriel/Library/Application Support/FluidVoice/MeetingModels")
            .appendingPathComponent(package.lastPathComponent, isDirectory: true)
        guard FileManager.default.fileExists(atPath: alternate.path) else {
            throw XCTSkip("Capitalization aliases require a case-insensitive volume")
        }
        XCTAssertNotEqual(alternate, alternate.resolvingSymlinksInPath().standardizedFileURL)
        let locator = MeetingNemotronModelLocator(injectedURL: alternate)
        let artifact = try locator.locate()
        XCTAssertEqual(artifact.fileCount, 3)
        XCTAssertEqual(try locator.recheck(artifact), artifact)
        XCTAssertEqual(artifact.manifestSHA256, try MeetingNemotronModelLocator(injectedURL: package).locate().manifestSHA256)
    }

    func testSymlinkedParentRemainsRejected() throws {
        let root = try self.makeTempDirectory()
        let real = root.appendingPathComponent("real")
        let package = try self.makeFakePackage(at: real)
        let link = root.appendingPathComponent("linked")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real)
        let alternate = link.appendingPathComponent(package.lastPathComponent, isDirectory: true)
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: alternate).locate()) {
            XCTAssertEqual($0 as? MeetingNemotronModelReadinessError, .invalidModelPackage(reason: "packagePathContainsSymlink"))
        }
    }

    func testInjectedURLValidatesStructureAndRechecks() throws {
        let root = try self.makeTempDirectory()
        let package = try self.makeFakePackage(at: root)
        let locator = MeetingNemotronModelLocator(injectedURL: package)

        let artifact = try locator.locate()
        XCTAssertEqual(artifact.packageURL, package.standardizedFileURL)
        XCTAssertEqual(artifact.fileCount, 3)
        XCTAssertGreaterThan(artifact.totalByteCount, 0)
        XCTAssertFalse(artifact.manifestSHA256.isEmpty)
        XCTAssertFalse(artifact.entryMetadataSHA256.isEmpty)

        XCTAssertEqual(try locator.recheck(artifact), artifact)

        // A changed artifact is refused at open time.
        try Data("{\"changed\":true}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        XCTAssertThrowsError(try locator.recheck(artifact)) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .artifactChanged(path: package.standardizedFileURL.path)
            )
        }

        // Restore the manifest, locate again, then replace weights with the same byte count.
        // Entry metadata still changes, so recheck cannot be bypassed by preserving file size.
        try Data("{}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        let sameSizeBaseline = try locator.locate()
        try Data("changed".utf8).write(
            to: package.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        )
        XCTAssertThrowsError(try locator.recheck(sameSizeBaseline)) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .artifactChanged(path: package.standardizedFileURL.path)
            )
        }
    }

    func testStructureValidationRefusesMissingPiecesAndSymlinks() throws {
        let root = try self.makeTempDirectory()

        // Missing entirely.
        let missing = root.appendingPathComponent("nope.mlpackage")
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: missing).locate()) {
            guard case .modelNotInstalled = $0 as? MeetingNemotronModelReadinessError else {
                return XCTFail("expected modelNotInstalled, got \($0)")
            }
        }

        // No Manifest.json.
        let noManifest = root.appendingPathComponent("bad1.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: noManifest, withIntermediateDirectories: true)
        try Data("model".utf8).write(to: noManifest.appendingPathComponent("model.mlmodel"))
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: noManifest).locate()) {
            XCTAssertEqual($0 as? MeetingNemotronModelReadinessError, .invalidModelPackage(reason: "manifestMissing"))
        }

        // No model.mlmodel.
        let noModel = root.appendingPathComponent("bad2.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: noModel, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: noModel.appendingPathComponent("Manifest.json"))
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: noModel).locate()) {
            XCTAssertEqual($0 as? MeetingNemotronModelReadinessError, .invalidModelPackage(reason: "modelMissing"))
        }

        // A symlink anywhere inside the package is rejected.
        let linked = try self.makeFakePackage(at: root)
        let symlinkedWeights = linked.appendingPathComponent("Data/com.apple.CoreML/weights/weight.bin")
        try FileManager.default.removeItem(at: symlinkedWeights)
        try FileManager.default.createSymbolicLink(atPath: symlinkedWeights.path, withDestinationPath: "/etc/hosts")
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: linked).locate()) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .invalidModelPackage(reason: "packageContainsSymlink")
            )
        }

        // The package itself may not be a symlink either.
        let real = try self.makeFakePackage(at: root.appendingPathComponent("real", isDirectory: true))
        let link = root.appendingPathComponent("linked.mlpackage")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: real.path)
        XCTAssertThrowsError(try MeetingNemotronModelLocator(injectedURL: link).locate()) {
            XCTAssertEqual(
                $0 as? MeetingNemotronModelReadinessError,
                .invalidModelPackage(reason: "packageIsSymlink")
            )
        }
    }

    func testEnvironmentOverrideAndDefaultLocation() throws {
        let root = try self.makeTempDirectory()
        let package = try self.makeFakePackage(at: root)

        let key = MeetingNemotronModelLocator.environmentOverrideKey
        let overridden = MeetingNemotronModelLocator(environment: [key: package.path])
        XCTAssertEqual(try overridden.locate().packageURL, package.standardizedFileURL)

        // Blank override falls through to the versioned cache location. Whether a model is
        // installed there is developer-machine state and is covered separately through injected
        // present/missing paths; this routing test must not depend on that state.
        let blank = MeetingNemotronModelLocator(environment: [key: "  "])
        XCTAssertEqual(
            blank.resolvedPackageURL(),
            MeetingNemotronModelLocator.defaultPackageURL()
        )
    }

    /// The supplied development package must pass structural validation — this catches a broken
    /// or moved checkout before any CoreML load is attempted.
    func testSuppliedDevelopmentPackageIsStructurallyValid() throws {
        let repoRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // FluidDictationIntegrationTests
            .deletingLastPathComponent() // Tests
            .deletingLastPathComponent() // repo root
        let supplied = repoRoot
            .appendingPathComponent("nemotron-3-diarization/models/nemotron_diar_fp16.mlpackage")
        guard FileManager.default.fileExists(atPath: supplied.path) else {
            throw XCTSkip("the supplied Nemotron package is not present in this checkout")
        }
        let artifact = try MeetingNemotronModelLocator(injectedURL: supplied).locate()
        XCTAssertGreaterThan(artifact.fileCount, 0)
        XCTAssertGreaterThan(artifact.totalByteCount, 100_000_000, "the real package carries its weights")
    }
}

@MainActor
final class MeetingDiarizationModelStoreTests: XCTestCase {
    private static let artifact = MeetingNemotronModelArtifact(
        packageURL: URL(fileURLWithPath: "/tmp/stub-nemotron.mlpackage"),
        totalByteCount: 199_258_287,
        fileCount: 3,
        manifestSHA256: "stub",
        entryMetadataSHA256: "stub"
    )

    private struct Missing: Error {}

    private final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var value = 0
        func increment() -> Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            self.value += 1
            return self.value
        }

        var count: Int {
            self.lock.lock()
            defer { self.lock.unlock() }
            return self.value
        }
    }

    override func setUpWithError() throws {
        guard CPUArchitecture.isAppleSilicon else { throw XCTSkip("Speaker labels require Apple silicon") }
    }

    func testPinnedDownloadFilesAcceptCompiledGraphWithoutMetadataAndRequireEveryAsset() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("nemotron-download-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let items = MeetingDiarizationModelStore.requiredDownloadItems
        let expectedPaths = Set([
            "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/analytics/coremldata.bin",
            "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/coremldata.bin",
            "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/model.mil",
            "split/Nemotron3Diarizer_s32_split_w8a8.mlmodelc/weights/weight.bin",
            "learnable_sil_emb.bin", "pre_encode_proj_t.bin",
        ])
        XCTAssertEqual(Set(items.map(\.path)), expectedPaths)
        XCTAssertEqual(items.count, 6)
        XCTAssertTrue(items.allSatisfy { !$0.isDirectory })
        for item in items {
            let destination = root.appendingPathComponent(item.path)
            try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("synthetic-artifact".utf8).write(to: destination)
        }
        let compiled = root.appendingPathComponent(MeetingNemotronModelLocator.remoteModelPath)
        XCTAssertFalse(FileManager.default.fileExists(atPath: compiled.appendingPathComponent("metadata.json").path))
        XCTAssertFalse(HuggingFaceModelDownloader.artifactIsComplete(at: compiled, isDirectory: true),
                       "The generic compiled-directory contract remains unchanged")
        XCTAssertTrue(HuggingFaceModelDownloader.artifactsAreComplete(root: root, items: items))
        for item in items {
            let destination = root.appendingPathComponent(item.path)
            try FileManager.default.removeItem(at: destination)
            XCTAssertFalse(HuggingFaceModelDownloader.artifactsAreComplete(root: root, items: items), item.path)
            try Data("synthetic-artifact".utf8).write(to: destination)
        }
    }

    func testExperimentalProfilesReusePinnedDownloadContractWithoutSplitProjection() {
        for profile in MeetingNemotronModelProfile.allCases where profile.isExperimental {
            let items = MeetingDiarizationModelStore.requiredDownloadItems(for: profile)
            XCTAssertEqual(items.map(\.path), profile.remoteFilePaths)
            XCTAssertEqual(items.count, 5)
            XCTAssertTrue(items.allSatisfy { !$0.isDirectory })
            XCTAssertFalse(items.contains { $0.path == MeetingNemotronModelLocator.projectionFileName })
            XCTAssertTrue(items.contains { $0.path == "learnable_sil_emb.bin" })
            XCTAssertEqual(profile.computePreference, .cpuOnly)
            XCTAssertTrue(profile.implementationFingerprint.contains("compute=cpuOnly"))
            XCTAssertNotEqual(MeetingNemotronModelLocator.defaultPackageURL(profile: profile),
                              MeetingNemotronModelLocator.defaultPackageURL())
        }
    }

    func testInstalledModelIsReadyWithoutDownloading() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { Self.artifact },
            install: { _ in
                _ = installs.increment()
                return Self.artifact
            }
        )

        let installed = try await store.ensureInstalled()

        XCTAssertEqual(installed, Self.artifact)
        XCTAssertEqual(store.state, .ready(Self.artifact))
        XCTAssertEqual(installs.count, 0, "an installed model must never be downloaded again")
    }

    func testConcurrentCallersShareOneDownload() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { throw Missing() },
            install: { progress in
                _ = installs.increment()
                progress(0.5)
                try await Task.sleep(nanoseconds: 50_000_000)
                return Self.artifact
            }
        )

        async let first = store.ensureInstalled()
        async let second = store.ensureInstalled()
        let results = try await [first, second]

        XCTAssertEqual(results, [Self.artifact, Self.artifact])
        XCTAssertEqual(installs.count, 1, "opening FluidMeet and finishing a meeting must not download twice")
        XCTAssertEqual(store.state, .ready(Self.artifact))
    }

    func testFailedDownloadShowsPlainMessageAndRetryStartsFresh() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            canDownload: { true },
            validate: { throw Missing() },
            install: { _ in
                if installs.increment() == 1 {
                    throw NSError(domain: NSURLErrorDomain, code: NSURLErrorNotConnectedToInternet)
                }
                return Self.artifact
            }
        )

        do {
            try await store.ensureInstalled()
            XCTFail("the first download must fail")
        } catch let error as MeetingDiarizationModelStore.DownloadError {
            XCTAssertEqual(
                error.localizedDescription,
                "Couldn't download the speaker model. Check your internet connection and try again."
            )
        }
        guard case .failed = store.state else { return XCTFail("expected failed state, got \(store.state)") }

        let installed = try await store.ensureInstalled()

        XCTAssertEqual(installed, Self.artifact)
        XCTAssertEqual(installs.count, 2)
        XCTAssertEqual(store.state, .ready(Self.artifact))
    }

    func testDevelopmentOverrideNeverDownloads() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            canDownload: { false },
            validate: { throw Missing() },
            install: { _ in
                _ = installs.increment()
                return Self.artifact
            }
        )

        do {
            try await store.ensureInstalled()
            XCTFail("an invalid development path must fail")
        } catch {}

        XCTAssertEqual(installs.count, 0, "a development override must never be replaced by a download")
        guard case .failed = store.state else { return XCTFail("expected failed state, got \(store.state)") }
    }

    func testCompleteReadinessIncludesVoiceEncoderAndConcurrentCallersShareItsInstall() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(
            validate: { Self.artifact },
            validateVoice: { if installs.count == 0 { throw Missing() } },
            installVoice: { progress in
                progress(0.5)
                try await Task.sleep(nanoseconds: 30_000_000)
                _ = installs.increment()
            }
        )
        async let first = store.ensureInstalled(includingVoiceEncoder: true)
        async let second = store.ensureInstalled(includingVoiceEncoder: true)
        _ = try await [first, second]
        XCTAssertEqual(installs.count, 1)
        XCTAssertTrue(store.voiceMatchingReady)
        XCTAssertTrue(store.allSpeakerResourcesReady)
    }

    func testInstalledSeparationAloneCannotClaimCompleteSpeakerReadiness() async throws {
        let store = MeetingDiarizationModelStore(validate: { Self.artifact }, validateVoice: { throw Missing() }, installVoice: { _ in throw Missing() })
        _ = try await store.ensureInstalled()
        XCTAssertFalse(store.allSpeakerResourcesReady)
        do {
            _ = try await store.ensureInstalled(includingVoiceEncoder: true)
            XCTFail("Missing voice matching must fail readiness")
        } catch { }
        XCTAssertFalse(store.voiceMatchingReady)
        XCTAssertFalse(store.allSpeakerResourcesReady)
        guard case .failed = store.state else { return XCTFail("Expected failed dependency state") }
    }

    func testAlreadyInstalledVoiceEncoderIsNotDownloadedAgain() async throws {
        let installs = Counter()
        let store = MeetingDiarizationModelStore(validate: { Self.artifact }, validateVoice: {}, installVoice: { _ in _ = installs.increment() })
        _ = try await store.ensureInstalled(includingVoiceEncoder: true)
        XCTAssertEqual(installs.count, 0)
        XCTAssertTrue(store.allSpeakerResourcesReady)
    }

    func testVoicePackageRejectsSymlinkedAncestorBeforeReadingWeights() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let package = root.appendingPathComponent("model.mlmodelc", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: package.appendingPathComponent("analytics"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createSymbolicLink(at: package.appendingPathComponent("weights"), withDestinationURL: outside)
        XCTAssertThrowsError(try MeetingSpeakerVoiceModelArtifacts.validatePackageDirectories(at: package))
    }

    func testUnavailableRepositoryMessage() {
        XCTAssertEqual(
            MeetingDiarizationModelStore.userMessage(for: NSError(domain: "HF", code: 401)),
            "The speaker model isn't available for download right now. Try again later."
        )
    }
}
