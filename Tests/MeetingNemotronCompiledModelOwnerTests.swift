import Foundation

// Branding-only linker stub for the isolated production resource/locator contract. This
// executable never loads CoreML, model weights or app services.
enum AppBrand {
    static let storageNamespace = "compiled-model-owner-tests"
    static func format(_ key: String, _ argument: String) -> String { key.replacingOccurrences(of: "%@", with: argument) }
}

private enum CompileTestContext { @TaskLocal static var id: String? }

private actor Counter {
    private var value = 0
    func increment() -> Int { value += 1; return value }
    var count: Int { value }
}
private actor Latch {
    private var continuation: CheckedContinuation<Void, Never>?
    private var released = false
    private(set) var entered = false
    func wait() async {
        entered = true
        if released { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func release() { released = true; continuation?.resume(); continuation = nil }
}
private final class Completion: @unchecked Sendable {
    private let lock = NSLock()
    private var complete = false
    func finish() { lock.withLock { complete = true } }
    var isComplete: Bool { lock.withLock { complete } }
}

@main
struct MeetingNemotronCompiledModelOwnerTests {
    private static func require(_ condition: Bool, _ message: String) throws {
        if !condition { throw NSError(domain: "CompiledModelOwnerTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
    }
    private static func fixture(in base: URL) throws -> MeetingNemotronModelLocator {
        let package = base.appendingPathComponent("source.mlpackage", isDirectory: true)
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: package.appendingPathComponent("Manifest.json"))
        try Data("synthetic-model-descriptor".utf8).write(to: package.appendingPathComponent("model.mlmodel"))
        return MeetingNemotronModelLocator(injectedURL: package)
    }
    private static func writeDerivative(at target: URL) throws {
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: false)
        try Data("synthetic-compiled-derivative".utf8).write(to: target.appendingPathComponent("model.bin"))
    }
    private static func waitFor(_ latch: Latch) async throws {
        for _ in 0..<1_000 {
            if await latch.entered { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        throw NSError(domain: "CompiledModelOwnerTests", code: 2)
    }
    private static func directories(in base: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: base, includingPropertiesForKeys: nil)
            .filter { $0.lastPathComponent.hasPrefix("meeting-nemotron-compiled-") }
    }
    private static func subtest(_ root: URL, _ name: String,
                                body: @Sendable (URL, MeetingNemotronModelLocator, MeetingNemotronModelArtifact) async throws -> Void) async throws {
        let base = root.appendingPathComponent(name, isDirectory: true)
        let locator = try fixture(in: base)
        try await body(base, locator, locator.locate())
        print("PASS " + name)
    }

    private static func profileContracts(in root: URL) async throws {
        let production = MeetingNemotronModelProfile.fast32SplitW8A8
        try require(production.implementationFingerprint == MeetingNemotronModelLocator.implementationFingerprint,
                    "Default attempt and checkpoint identity must remain byte-compatible")
        try require(production.computePreference == .devicePreferred && !production.isExperimental,
                    "Registering candidates cannot change the default compute route")
        try require(production.packageFileName == MeetingNemotronModelLocator.packageFileName
                    && production.cacheVersion == MeetingNemotronModelLocator.cacheVersion
                    && production.remoteModelPath == MeetingNemotronModelLocator.remoteModelPath,
                    "Default artifact storage and download remain unchanged")
        try require(Set(MeetingNemotronModelProfile.allCases.map(\.implementationFingerprint)).count == 3,
                    "Each preset and compute profile needs a distinct frozen identity")
        try require(Set(MeetingNemotronModelProfile.allCases.map(\.packageFileName)).count == 3,
                    "Candidate publication cannot overwrite the production package")
        try require(production.supportsOwnerVoiceVerification
                    && MeetingNemotronModelLocator().supportsOwnerVoiceVerification,
                    "The established offline composite keeps its optional owner verification")
        print("PASS profile-default-compatibility-and-identities")

        for profile in MeetingNemotronModelProfile.allCases {
            let candidate = profile.isExperimental
            try require(profile.supportsOwnerVoiceVerification == !candidate,
                        "Anonymous experimental profiles cannot advertise an unprepared voice encoder")
            try require(MeetingNemotronModelLocator(profile: profile).supportsOwnerVoiceVerification
                        == profile.supportsOwnerVoiceVerification,
                        "The request-bound locator must expose its exact immutable profile capability")
            try require(MeetingNemotronModelProfile.matching(implementationFingerprint: profile.implementationFingerprint) == profile,
                        "Only exact registered identities select a profile")
            try require(MeetingNemotronModelProfile.matching(implementationFingerprint: profile.implementationFingerprint + ";voice=fixture") == profile,
                        "Composite voice lineage preserves the exact diarizer profile")
            try require(MeetingNemotronModelProfile.matching(implementationFingerprint: profile.implementationFingerprint + "-changed") == nil,
                        "A partial identity cannot match a changed implementation")
            try require(MeetingNemotronModelProfile.matching(implementationFingerprint: profile.implementationFingerprint + ";compute=cpuAndGPU") == nil,
                        "Appended compute overrides cannot relabel a frozen profile")
            try require(profile.hostFileNames.count == (candidate ? 1 : 2), "Only the split graph requires host projection")
            try require(profile.expectedFiles.count == (candidate ? 5 : 6), "Checksums bind all model and host files")
            try require(!candidate || profile.computePreference == .cpuOnly, "Experimental compute policy is frozen")
            try require(profile.expectedFiles.values.allSatisfy {
                $0.count == 64 && $0.allSatisfy { "0123456789abcdef".contains($0) }
            }, "Every published file uses a complete SHA-256")
            let localPaths = Set(profile.remoteFilePaths.map { path in
                path.hasPrefix(profile.remoteModelPath + "/")
                    ? profile.compiledModelFileName + path.dropFirst(profile.remoteModelPath.count) : path
            })
            try require(localPaths == Set(profile.expectedFiles.keys), "Download and installer require the same exact files")
        }
        print("PASS profile-hash-download-and-host-contracts")

        let override = root.appendingPathComponent("explicit-default-model.nemotronbundle")
        let environment = [MeetingNemotronModelLocator.environmentOverrideKey: override.path]
        try require(MeetingNemotronModelLocator(environment: environment).resolvedPackageURL() == override,
                    "The existing production development override remains supported")
        for profile in MeetingNemotronModelProfile.allCases where profile.isExperimental {
            let defaultURL = MeetingNemotronModelLocator.defaultPackageURL(profile: profile)
            try require(MeetingNemotronModelLocator(environment: environment, profile: profile).resolvedPackageURL() == defaultURL,
                        "A production override cannot silently relabel its W8 package as FP16")
            try require(defaultURL != MeetingNemotronModelLocator.defaultPackageURL(), "Candidate stores are isolated")
        }
        print("PASS profile-explicit-selection-and-storage")

        for profile in MeetingNemotronModelProfile.allCases {
            let package = root.appendingPathComponent(profile.packageFileName, isDirectory: true)
            for path in profile.expectedFiles.keys {
                let file = package.appendingPathComponent(path)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data("synthetic-\(path)".utf8).write(to: file)
            }
            let locator = MeetingNemotronModelLocator(injectedURL: package, profile: profile)
            let artifact = try locator.locate()
            try require(artifact.profile == profile && artifact.implementationFingerprint == profile.implementationFingerprint,
                        "Located artifacts carry the frozen registered model identity")
            try require(artifact.compiledModelURL == package.appendingPathComponent(profile.compiledModelFileName, isDirectory: true),
                        "The selected compiled URL must match the actual graph")
            try require(try locator.recheck(artifact) == artifact, "Unchanged profile-bound artifacts can reopen")
            let counter = Counter()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: root) { _, _ in _ = await counter.increment() }
            _ = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            await owner.cancelAndCleanup()
            try require(await counter.count == 0 && FileManager.default.fileExists(atPath: package.path),
                        "Every author-compiled profile bypasses compilation and retains installed data")

            let wrongProfile: MeetingNemotronModelProfile = profile == .experimentalFast128FP16CPU
                ? .experimentalFast32FP16CPU : .experimentalFast128FP16CPU
            let relabeled = MeetingNemotronModelArtifact(packageURL: artifact.packageURL,
                totalByteCount: artifact.totalByteCount, fileCount: artifact.fileCount,
                manifestSHA256: artifact.manifestSHA256, entryMetadataSHA256: artifact.entryMetadataSHA256,
                profile: wrongProfile)
            do { _ = try locator.recheck(relabeled); throw NSError(domain: "UnexpectedRelabeledArtifact", code: 1) }
            catch MeetingNemotronModelReadinessError.artifactChanged { }
            do {
                _ = try MeetingNemotronModelLocator(injectedURL: package, profile: wrongProfile).locate()
                throw NSError(domain: "UnexpectedGraphSubstitution", code: 1)
            } catch MeetingNemotronModelReadinessError.invalidModelPackage { }

            // Synthetic structure can exercise ownership, but never pass the pinned installer.
            let installed = root.appendingPathComponent("preserve-" + profile.packageFileName, isDirectory: true)
            try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: false)
            let sentinel = installed.appendingPathComponent("existing-marker")
            try Data("keep".utf8).write(to: sentinel)
            do {
                _ = try MeetingModelInstaller.install(from: package, to: installed, profile: profile)
                throw NSError(domain: "UnexpectedUnpinnedInstall", code: 1)
            } catch MeetingModelInstaller.InstallError.wrongPackage { }
            try require(try Data(contentsOf: sentinel) == Data("keep".utf8), "Invalid candidate cannot replace an installed package")
        }
        print("PASS profile-bound-compiled-ownership-and-drift")
        print("PASS profile-pinned-install-rejects-synthetic-data-without-replacement")

        let legacy = try fixture(in: root.appendingPathComponent("legacy-profile-refusal"))
        for profile in MeetingNemotronModelProfile.allCases where profile.isExperimental {
            do {
                _ = try MeetingNemotronModelLocator(injectedURL: legacy.resolvedPackageURL(), profile: profile).locate()
                throw NSError(domain: "UnexpectedLegacyCandidate", code: 1)
            } catch MeetingNemotronModelReadinessError.invalidModelPackage { }
        }
        print("PASS experimental-profile-refuses-legacy-package")
    }
    static func main() async throws {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try await self.profileContracts(in: root)
        try await subtest(root, "reuse-and-cleanup") { base, locator, artifact in
            let counter = Counter()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                _ = await counter.increment(); try writeDerivative(at: target)
            }
            let first = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            for _ in 0..<8 {
                let next = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
                try require(next == first, "Each PCM window must reuse the exact private derivative")
            }
            try require(await counter.count == 1, "Repeated windows must not recompile")
            try require(first.pathExtension == "mlmodelc", "FluidAudio must receive a compiled directory")
            try require(try directories(in: base).count == 1, "Only one derivative root is owned")
            try require(try locator.locate() == artifact, "Compilation must not mutate source identity")
            await owner.cancelAndCleanup(); await owner.cancelAndCleanup()
            try require(try directories(in: base).isEmpty, "Terminal cleanup removes only owned derivatives")
            try require(FileManager.default.fileExists(atPath: artifact.packageURL.path), "Source remains installed")
        }
        try await subtest(root, "author-compiled-bundle-never-recompiled-or-deleted") { base, _, _ in
            let bundle = base.appendingPathComponent("source.nemotronbundle", isDirectory: true)
            let model = bundle.appendingPathComponent(MeetingNemotronModelLocator.compiledModelFileName, isDirectory: true)
            try FileManager.default.createDirectory(at: model, withIntermediateDirectories: true)
            try Data("synthetic-mil".utf8).write(to: model.appendingPathComponent("model.mil"))
            try Data("synthetic-compiled-descriptor".utf8).write(to: model.appendingPathComponent("coremldata.bin"))
            let locator = MeetingNemotronModelLocator(injectedURL: bundle)
            let artifact = try locator.locate()
            let counter = Counter()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, _ in _ = await counter.increment() }
            let supplied = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            try require(supplied == model, "Author-compiled model must be passed directly")
            try require(await counter.count == 0, "Author-compiled bundle cannot enter package compiler")
            await owner.cancelAndCleanup()
            try require(FileManager.default.fileExists(atPath: model.path), "Cleanup cannot delete installed compiled model")
        }
        try await subtest(root, "concurrent-single-compile") { base, locator, artifact in
            let counter = Counter(); let latch = Latch()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                _ = await counter.increment(); await latch.wait(); try writeDerivative(at: target)
            }
            let first = Task { try await owner.compiledModel(for: artifact) { try locator.recheck($0) } }
            try await waitFor(latch)
            let secondEntered = Completion()
            let second = Task {
                try await owner.compiledModel(for: artifact) { value in
                    secondEntered.finish(); return try locator.recheck(value)
                }
            }
            for _ in 0..<1_000 {
                if secondEntered.isComplete { break }
                try await Task.sleep(for: .milliseconds(1))
            }
            try require(secondEntered.isComplete, "Second caller must enter while the first compiler is parked")
            await latch.release()
            let one = try await first.value; let two = try await second.value
            let compiledCount = await counter.count
            try require(one == two && compiledCount == 1, "Concurrent warmup callers must join one compilation")
            await owner.cancelAndCleanup()
        }
        try await subtest(root, "artifact-drift") { base, locator, artifact in
            let counter = Counter()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                _ = await counter.increment(); try writeDerivative(at: target)
            }
            _ = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            try Data("changed manifest".utf8).write(to: artifact.packageURL.appendingPathComponent("Manifest.json"))
            do { _ = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }; throw NSError(domain: "UnexpectedReuse", code: 1) }
            catch MeetingNemotronModelReadinessError.artifactChanged { }
            let changed = try locator.locate()
            do { _ = try await owner.compiledModel(for: changed) { try locator.recheck($0) }; throw NSError(domain: "UnexpectedReplacement", code: 1) }
            catch MeetingNemotronModelReadinessError.artifactChanged { }
            try require(await counter.count == 1, "A changed package cannot replace the frozen model")
            await owner.cancelAndCleanup()
        }
        try await subtest(root, "drift-during-compilation") { base, locator, artifact in
            let latch = Latch()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                await latch.wait(); try writeDerivative(at: target)
            }
            let preparing = Task { try await owner.compiledModel(for: artifact) { try locator.recheck($0) } }
            try await waitFor(latch)
            try Data("changed while compiling".utf8).write(to: artifact.packageURL.appendingPathComponent("Manifest.json"))
            await latch.release()
            do { _ = try await preparing.value; throw NSError(domain: "UnexpectedPublish", code: 1) }
            catch MeetingNemotronModelReadinessError.artifactChanged { }
            try require(try directories(in: base).isEmpty, "Stale compilation output must not be published")
        }
        try await subtest(root, "cancel-joins-native-compiler") { base, locator, artifact in
            let latch = Latch(); let completion = Completion()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                await latch.wait(); try writeDerivative(at: target) // Deliberately cancellation-deaf.
            }
            let preparing = Task {
                defer { completion.finish() }
                return try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            }
            try await waitFor(latch); preparing.cancel()
            try await Task.sleep(for: .milliseconds(10))
            try require(!completion.isComplete, "Cancellation cannot abandon owned native compilation")
            await latch.release()
            do { _ = try await preparing.value; throw NSError(domain: "UnexpectedCancellationSuccess", code: 1) }
            catch is CancellationError { }
            try require(try directories(in: base).isEmpty, "Cancelled unpublished output must be deleted after join")
        }
        try await subtest(root, "terminal-cleanup-joins-compilation") { base, locator, artifact in
            let latch = Latch(); let completion = Completion()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                await latch.wait(); try writeDerivative(at: target)
            }
            let preparing = Task { try await owner.compiledModel(for: artifact) { try locator.recheck($0) } }
            try await waitFor(latch)
            let cleanup = Task { await owner.cancelAndCleanup(); completion.finish() }
            try await Task.sleep(for: .milliseconds(10))
            try require(!completion.isComplete, "Terminal cleanup must join an active native compiler")
            await latch.release(); await cleanup.value
            do { _ = try await preparing.value; throw NSError(domain: "UnexpectedCleanupSuccess", code: 1) }
            catch is CancellationError { }
            try require(try directories(in: base).isEmpty, "Joined terminal cleanup removes all owned output")
        }
        try await subtest(root, "request-correlation-inherited") { base, locator, artifact in
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                try require(CompileTestContext.id == "test-compile-pipeline", "Compiler must inherit request-local correlation")
                try writeDerivative(at: target)
            }
            _ = try await CompileTestContext.$id.withValue("test-compile-pipeline") {
                try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            }
            await owner.cancelAndCleanup()
        }
        try await subtest(root, "ready-resource-survives-cancelled-reuse") { base, locator, artifact in
            let counter = Counter(); let gate = Latch()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                _ = await counter.increment(); try writeDerivative(at: target)
            }
            let ready = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            let reuse = Task {
                await gate.wait()
                return try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            }
            try await waitFor(gate); reuse.cancel(); await gate.release()
            do { _ = try await reuse.value; throw NSError(domain: "UnexpectedCancelledReuse", code: 1) }
            catch is CancellationError { }
            let stillReady = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            let compiledCount = await counter.count
            try require(stillReady == ready && compiledCount == 1, "Cancelled reuse must preserve an existing ready resource")
            await owner.cancelAndCleanup()
        }
        try await subtest(root, "failed-compile-can-retry-same-artifact") { base, locator, artifact in
            let counter = Counter()
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                if await counter.increment() == 1 {
                    try writeDerivative(at: target)
                    throw CocoaError(.fileReadCorruptFile)
                }
                try writeDerivative(at: target)
            }
            do { _ = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }; throw NSError(domain: "UnexpectedFailureSuccess", code: 1) }
            catch let error as CocoaError { try require(error.code == .fileReadCorruptFile, "Original compilation failure is preserved") }
            try require(try directories(in: base).isEmpty, "Failed partial derivatives are removed")
            _ = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }
            try require(await counter.count == 2, "A clean retry may compile the same original artifact")
            await owner.cancelAndCleanup()
        }
        try await subtest(root, "invalid-derivative-is-not-adopted") { base, locator, artifact in
            let owner = MeetingNemotronCompiledModelOwner(baseDirectory: base) { _, target in
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: artifact.packageURL)
            }
            do { _ = try await owner.compiledModel(for: artifact) { try locator.recheck($0) }; throw NSError(domain: "UnexpectedSymlinkSuccess", code: 1) }
            catch MeetingNemotronModelReadinessError.invalidModelPackage { }
            try require(try directories(in: base).isEmpty, "An untrusted compiler derivative is never retained")
            try require(FileManager.default.fileExists(atPath: artifact.packageURL.path), "Cleanup cannot remove the installed package")
        }
        try await subtest(root, "deinit-cleanup") { base, locator, artifact in
            var owner: MeetingNemotronCompiledModelOwner? = .init(baseDirectory: base) { _, target in try writeDerivative(at: target) }
            _ = try await owner!.compiledModel(for: artifact) { try locator.recheck($0) }
            owner = nil
            try require(try directories(in: base).isEmpty, "Ending the joined runtime releases its temporary derivative")
        }
        print("12 compiled model ownership tests and 6 profile contract groups passed")
    }
}
