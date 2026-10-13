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
    static func main() async throws {
        let parent = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true).resolvingSymlinksInPath()
        let root = parent.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
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
        print("11 compiled model ownership tests passed")
    }
}
