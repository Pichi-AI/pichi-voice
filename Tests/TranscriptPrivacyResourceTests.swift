import Foundation
import PichiTextPrivacy

@main
struct TranscriptPrivacyResourceTests {
    static func main() async throws {
        let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/pii-resource-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let broken = PichiTranscriptPrivacyModelStore(directory: root.appendingPathComponent("broken")) { url, _, _ in
            let temporary = root.appendingPathComponent(UUID().uuidString)
            try Data("not a model".utf8).write(to: temporary)
            return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
        }
        do { _ = try await broken.ensureInstalled(); fatalError("corrupt model must not publish") }
        catch { precondition(error is TextPrivacyError) }
        let brokenInstalled = await broken.isInstalled()
        precondition(!brokenInstalled)
        let brokenFolder = root.appendingPathComponent("broken")
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: brokenFolder.path)
        precondition(leftovers.isEmpty, "failed install must remove staged artifacts")

        let started = AsyncStream<Void>.makeStream()
        let waiting = PichiTranscriptPrivacyModelStore(directory: root.appendingPathComponent("cancel")) { _, _, _ in
            started.continuation.yield(())
            try await Task.sleep(nanoseconds: 5_000_000_000)
            throw URLError(.cancelled)
        }
        let operation = Task { try await waiting.ensureInstalled() }
        var iterator = started.stream.makeAsyncIterator()
        _ = await iterator.next()
        operation.cancel()
        do { _ = try await operation.value; fatalError("must cancel") } catch { precondition(error is CancellationError) }
        let cancelledFolder = root.appendingPathComponent("cancel")
        let cancelledContents = try FileManager.default.contentsOfDirectory(atPath: cancelledFolder.path)
        precondition(cancelledContents.isEmpty)

        if let source = ProcessInfo.processInfo.environment["PICHI_PII_TEST_MODEL_DIRECTORY"] {
            let sourceRoot = URL(fileURLWithPath: source, isDirectory: true)
            let installedRoot = root.appendingPathComponent("valid")
            let model = PichiTranscriptPrivacyModelStore(directory: installedRoot) { url, _, progress in
                let artifact = PIIModelDescriptor.russianTiny.artifacts.first { $0.remotePath.split(separator: "/").last.map(String.init) == url.lastPathComponent }!
                let temporary = root.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(artifact.filename), to: temporary)
                progress(artifact.byteCount, artifact.byteCount)
                return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            let service = PichiTranscriptPrivacyService(modelStore: model)
            try await service.prepare()
            let redacted = try await service.redact("Врач Иван Иванов, email test@example.org.")
            precondition(!redacted.contains("Иванов") && !redacted.contains("test@example.org"))
            let attemptedAgain = Task {
                withUnsafeCurrentTask { $0?.cancel() }
                try await service.prepare()
            }
            do { try await attemptedAgain.value; fatalError("cancelled preparation must report cancellation") }
            catch { precondition(error is CancellationError) }
            let retainedReady = await service.isReady
            precondition(retainedReady, "A cancelled later preparation must preserve the ready meeting resource")
            let continued = try await service.redact("Иван Иванов, test@example.org")
            precondition(!continued.contains("Иванов") && !continued.contains("test@example.org"))
            let installed = await model.isInstalled()
            precondition(installed)
            try await service.deleteModel()
            let deletedInstalled = await model.isInstalled()
            precondition(!deletedInstalled)
            do { _ = try await service.redact("Иван Иванов"); fatalError("unloaded service must fail closed") }
            catch { precondition(error as? TextPrivacyError == .notPrepared) }
        }
        print("Transcript privacy resource tests passed: corrupt stage, joined cancel, opt-in public install/inference/delete")
    }
}
