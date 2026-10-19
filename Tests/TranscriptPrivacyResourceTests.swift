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

        if let source = ProcessInfo.processInfo.environment["PICHI_PII_A1_TEST_MODEL_DIRECTORY"] {
            let sourceRoot = URL(fileURLWithPath: source, isDirectory: true)
            let installedRoot = root.appendingPathComponent("valid")
            let model = PichiTranscriptPrivacyModelStore(directory: installedRoot) { url, _, progress in
                let artifact = PichiTranscriptPrivacyModelStore.descriptor.artifacts.first { $0.remotePath.split(separator: "/").last.map(String.init) == url.lastPathComponent }!
                let temporary = root.appendingPathComponent(UUID().uuidString)
                try FileManager.default.copyItem(at: sourceRoot.appendingPathComponent(artifact.filename), to: temporary)
                progress(artifact.byteCount, artifact.byteCount)
                return (temporary, HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!)
            }
            // Explicit test setup installs an isolated copy from the approved public fixture.
            // The startup operation below must only open that already installed artifact.
            _ = try await model.ensureInstalled()
            let service = PichiTranscriptPrivacyService(modelStore: model)
            guard let idleToken = try await service.prepareInstalledForIdle() else { fatalError("Installed A1 should prepare for idle") }
            let idleReady = await service.isReady
            precondition(idleReady)
            async let recording: Void = service.prepareForMeeting()
            async let settings: Void = service.prepare()
            _ = try await (recording, settings)
            await service.releaseIdlePreparation(idleToken)
            let adoptedReady = await service.isReady
            precondition(adoptedReady, "A real service caller adopts the prepared A1 model")
            let redacted = try await service.redact("Врач Иван Иванов, email test@example.org.")
            precondition(!redacted.contains("Иванов") && !redacted.contains("test@example.org"))
            try await service.unload()
            guard let unadopted = try await service.prepareInstalledForIdle() else { fatalError("A fresh idle A1 should prepare") }
            await service.releaseIdlePreparation(unadopted)
            let retiredReady = await service.isReady
            precondition(!retiredReady, "Retiring an unadopted native A1 resource releases its actual runtime")
            try await service.prepare()
            for phrase in [
                "обсудили планы",
                "обсудили планы.",
                "обсудили номер задачи и телефон в справочнике затем продолжили обсуждение графика",
                "Это вот они буквально недавно в апреле запустили там новую версию приложения и теперь мы обсуждаем работу интерфейса пока устройство распознаёт речь и показывает текст затем делаем паузу и ждём завершения обработки"
            ] {
                let completed = try await service.redactSpeechBoundaryWithSpans(phrase)
                precondition(completed.text == phrase && completed.spans.isEmpty,
                    "Production A1 must not replace ordinary completed words with privacy masks")
            }
            let closedPII = try await service.redactSpeechBoundaryWithSpans("Врач Иван Иванов, телефон +7 916 123-45-67 и продолжили обсуждение")
            precondition(!closedPII.text.contains("Иванов") && !closedPII.text.contains("916"))
            precondition(closedPII.text.hasSuffix("и продолжили обсуждение"),
                "Entity cleanup must preserve surrounding ordinary completed words")
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
        print("Transcript privacy resource tests passed: corrupt stage, joined cancel, opt-in public A1 idle/adoption/retirement/inference/delete")
    }
}
