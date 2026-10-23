import Foundation

/// Synthetic regular-file fixtures exercise the shared exporter; no bytes are played.
@main
struct MeetingAudioExporterTests {
    nonisolated final class CopyGate: @unchecked Sendable {
        private let lock = NSLock()
        private let release = DispatchSemaphore(value: 0)
        private var entered = false
        private var finished = false
        private var copies = 0
        var hasEntered: Bool { lock.withLock { entered } }
        var hasFinished: Bool { lock.withLock { finished } }
        var copyCount: Int { lock.withLock { copies } }
        func finish() { lock.withLock { finished = true } }
        func open() { release.signal() }
        func pause() throws {
            lock.withLock { entered = true; copies += 1 }
            guard release.wait(timeout: .now() + 5) == .success else { throw CocoaError(.fileWriteUnknown) }
        }
    }

    static var assertions = 0
    static func check(_ condition: Bool, _ message: String) {
        assertions += 1
        precondition(condition, message)
    }
    static func waitForEntry(_ gate: CopyGate) async throws {
        for _ in 0..<400 {
            if gate.hasEntered { return }
            try await Task.sleep(for: .milliseconds(5))
        }
        preconditionFailure("Synthetic copy did not reach gate")
    }
    static func expectCancellation(_ task: Task<URL, Error>) async {
        do { _ = try await task.value; preconditionFailure("Expected cancellation") }
        catch { check(error is CancellationError, "Cancellation reaches caller") }
    }
    static func session(chunks count: Int = 1) -> MeetingSession {
        let timebase = MeetingTimebaseMetadata(startedHostTime: 0, machTimebaseNumerator: 1,
            machTimebaseDenominator: 1, firstPresentationTime: nil)
        var session = MeetingSession(configuration: .init(mode: .inRoom, title: "Synthetic export",
            languageCode: "en", microphone: .init(captureDeviceID: "synthetic", displayName: "Synthetic")),
            startedAt: Date(timeIntervalSince1970: 1_700_000_000), timebase: timebase)
        session.state = .completed
        session.audioTracks = [.init(id: UUID(), kind: .microphone, sourceIdentifier: "synthetic",
            sourceDisplayName: "Synthetic", format: nil, timebase: timebase, health: .waiting,
            chunks: (0..<count).map { index in
                .init(id: UUID(), sequence: index, relativeFilePath: "fixture-\(index).caf",
                    presentationStart: .init(value: 0, timescale: 1000),
                    presentationEnd: .init(value: 1000, timescale: 1000), discontinuities: [],
                    sha256: "synthetic", byteCount: 16, finalizationState: .finalized)
            })]
        return session
    }

    static func main() async throws {
        let fm = FileManager.default
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        defer { try? fm.removeItem(at: root) }
        let source = root.appendingPathComponent("source", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true)
        let bytes = Data("synthetic-placeholder".utf8)
        for index in 0..<2 { try bytes.write(to: source.appendingPathComponent("fixture-\(index).caf")) }
        func destination(_ name: String) throws -> URL {
            let value = root.appendingPathComponent(name, isDirectory: true)
            try fm.createDirectory(at: value, withIntermediateDirectories: true)
            return value
        }
        func names(_ folder: URL) throws -> Set<String> { Set(try fm.contentsOfDirectory(atPath: folder.path)) }
        let value = session()

        let cancelledDestination = try destination("pre-cancelled")
        let admission = CopyGate()
        let cancelled = Task.detached {
            try admission.pause()
            return try await MeetingAudioExporter.export(of: value, from: source, into: cancelledDestination)
        }
        try await waitForEntry(admission)
        cancelled.cancel(); admission.open()
        await expectCancellation(cancelled)
        check(try names(cancelledDestination).isEmpty, "Pre-cancelled invocation creates no staging or destination")

        // Hold the last copy after its bytes exist but before its synchronous call
        // returns. Cancellation must join it, then reject publication and clean up.
        let blockedDestination = try destination("blocked-copy")
        let gate = CopyGate()
        let blocked = Task.detached {
            defer { gate.finish() }
            return try await MeetingAudioExporter.export(of: value, from: source, into: blockedDestination) { from, to in
                try FileManager.default.copyItem(at: from, to: to)
                try gate.pause()
            }
        }
        defer { gate.open() }
        try await waitForEntry(gate)
        blocked.cancel()
        try await Task.sleep(for: .milliseconds(30))
        check(!gate.hasFinished, "Cancellation remains joined until synchronous copy retires")
        check(try names(blockedDestination).count == 1, "Only owned staging exists while last copy is blocked")
        check(try names(blockedDestination).allSatisfy { $0.hasSuffix(".export-tmp") }, "No final directory is published while copying")
        gate.open()
        await expectCancellation(blocked)
        check(gate.hasFinished && gate.copyCount == 1, "Caller resumes only after worker retirement")
        check(try names(blockedDestination).isEmpty, "Cancellation after last copy cleans staging and prevents publication")

        let multipleDestination = try destination("multiple-chunks")
        let multipleGate = CopyGate()
        let multipleValue = session(chunks: 2)
        let multiple = Task.detached {
            try await MeetingAudioExporter.export(of: multipleValue, from: source, into: multipleDestination) { from, to in
                try FileManager.default.copyItem(at: from, to: to)
                try multipleGate.pause()
            }
        }
        defer { multipleGate.open() }
        try await waitForEntry(multipleGate)
        multiple.cancel(); multipleGate.open()
        await expectCancellation(multiple)
        check(multipleGate.copyCount == 1, "Cancellation between chunks prevents the next copy")
        check(try names(multipleDestination).isEmpty, "Cancellation between chunks removes prior copied bytes")

        let successDestination = try destination("success")
        let committed = try await MeetingAudioExporter.export(of: value, from: source, into: successDestination)
        check(try Data(contentsOf: committed.appendingPathComponent("microphone-000.caf")) == bytes, "Successful export commits exact bytes")
        let later = Task { try await MeetingAudioExporter.export(of: value, from: source, into: successDestination) }
        let committedAgain = try await later.value
        later.cancel()
        check(committed != committedAgain, "Repeated exports preserve earlier destination")
        check(try names(successDestination) == ["Synthetic export", "Synthetic export 2"], "Late cancellation preserves committed destinations")
        check(try Data(contentsOf: committed.appendingPathComponent("microphone-000.caf")) == bytes, "Previously committed bytes survive")

        let failedDestination = try destination("failed-copy")
        do {
            _ = try await MeetingAudioExporter.export(of: value, from: source, into: failedDestination) { _, to in
                try bytes.write(to: to)
                throw CocoaError(.fileWriteNoPermission)
            }
            preconditionFailure("Expected copy failure")
        } catch let error as CocoaError { check(error.code == .fileWriteNoPermission, "Copy failure is preserved") }
        check(try names(failedDestination).isEmpty, "Copy failure removes partial owned bytes and staging")

        let collisionDestination = try destination("collision")
        let colliding = collisionDestination.appendingPathComponent("Synthetic export", isDirectory: true)
        let sentinel = colliding.appendingPathComponent("keep.txt")
        let collision = try await MeetingAudioExporter.export(of: value, from: source, into: collisionDestination) { from, to in
            try FileManager.default.copyItem(at: from, to: to)
            try FileManager.default.createDirectory(at: colliding, withIntermediateDirectories: true)
            try Data("keep".utf8).write(to: sentinel)
        }
        check(collision.lastPathComponent == "Synthetic export 2", "Race collision retries with a fresh destination")
        check(try Data(contentsOf: sentinel) == Data("keep".utf8), "Collision never overwrites unrelated output")
        check(try names(collisionDestination) == ["Synthetic export", "Synthetic export 2"], "Collision leaves no staging directory")
        check(try Data(contentsOf: source.appendingPathComponent("fixture-0.caf")) == bytes, "All outcomes preserve source")
        print("PASS: \(assertions) shared audio-export synthetic assertions")
    }
}
