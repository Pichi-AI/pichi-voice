import Darwin
@testable import FluidVoice_Debug
import Foundation
import XCTest

/// The reader self-check must give up on a helper that does not answer, and must still join the
/// process it owns when that helper ignores the polite termination request.
///
/// The deadline of `FluidServeSelfCheck.run` starts when the child is spawned and cannot be paused.
/// A fixture shell that is slow to start can receive TERM before it has installed its handler; such a
/// child dies on TERM, the kill fallback is never reached and the attempt proves nothing about the reader.
///
/// The slow part is the first launch of a file that was just written: the system evaluates it before it
/// runs, those evaluations queue up behind each other, and the wait grows with every concurrent launch
/// (measured 0.2 s idle, up to 2 s with eight concurrent first launches, against 0.07 s for later launches
/// of the same file). The test launches the fixture once before the timed run so that cost is paid
/// outside the deadline. As a second guard, the fixture writes a marker only after its handler is installed;
/// an attempt without the marker is discarded and repeated with a longer deadline, so only an attempt that
/// really reached the TERM-ignoring state is judged.
final class PichiFluidServeReaderTimeoutTests: XCTestCase {
    /// Doubling deadlines. The first is the quick path on an idle machine; the last tolerates a shell
    /// that needs several seconds to start. Waiting only grows on a loaded machine.
    private static let deadlines: [TimeInterval] = [1, 2, 4, 8]
    /// `FluidServeSelfCheck.run` waits this long after TERM before SIGKILL.
    private static let terminationGrace: TimeInterval = 2

    private var base: URL!

    override func setUpWithError() throws {
        let physical = try XCTUnwrap(realpath(FileManager.default.temporaryDirectory.path, nil))
        defer { free(physical) }
        self.base = URL(fileURLWithPath: String(cString: physical))
            .appendingPathComponent("PichiFluidServeReaderTimeoutTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: self.base, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: self.base)
    }

    private struct Attempt {
        let outcome: FluidServeSelfCheck.Outcome
        let elapsed: TimeInterval
        let ready: Bool
        let termHandled: Bool
        let pid: Int32?
    }

    func testReaderTimeoutJoinsItsOwnedProcessEvenWhenTerminationIsIgnored() async throws {
        var discarded: [TimeInterval] = []
        for (index, deadline) in Self.deadlines.enumerated() {
            let attempt = try await self.attempt(number: index, deadline: deadline)
            guard attempt.ready else {
                discarded.append(deadline)
                continue
            }
            XCTAssertEqual(attempt.outcome, .failed(PichiLocalization.text("The meeting reader did not answer in time.")))
            XCTAssertTrue(
                attempt.termHandled,
                "The reader must send TERM first; the helper handles it and keeps running until the kill fallback"
            )
            XCTAssertGreaterThanOrEqual(
                attempt.elapsed,
                deadline + Self.terminationGrace - 0.1,
                "A TERM-resistant helper must consume the two-second grace before joined SIGKILL"
            )
            let pid = try XCTUnwrap(attempt.pid, "A ready helper has recorded its process identifier")
            let alive = kill(pid, 0)
            let reason = errno
            XCTAssertEqual(alive, -1, "The owned helper must be reaped before timeout is returned")
            XCTAssertEqual(reason, ESRCH)
            if !discarded.isEmpty {
                // Not a failure, but a slow drift to the longer deadlines is worth seeing in the log.
                print("PichiFluidServeReaderTimeoutTests: judged the \(deadline) s attempt after discarding "
                    + discarded.map { "\($0) s" }.joined(separator: ", "))
            }
            return
        }
        XCTFail("The fixture shell never installed its TERM handler within the longest deadline "
            + "(\(discarded.map { "\($0) s" }.joined(separator: ", "))); the machine is too loaded to judge the reader")
    }

    /// One run of the reader against a fresh fixture in its own directory.
    private func attempt(number: Int, deadline: TimeInterval) async throws -> Attempt {
        let directory = self.base.appendingPathComponent("attempt-\(number)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let tool = directory.appendingPathComponent("synthetic-reader")
        let pidFile = directory.appendingPathComponent("reader.pid")
        let readyFile = directory.appendingPathComponent("reader.ready")
        let termFile = directory.appendingPathComponent("reader.handled-term")
        let handler = "echo handled > " + FluidServeSkill.shellQuoted(termFile.path)
        // Order matters: the handler first, then the pid, then the marker that tells the test the
        // handler is in place. The loop sleeps instead of spinning so a loaded machine still schedules the
        // shell; sh runs the handler when the current 50 ms sleep ends, well inside the two-second grace.
        let fixture = "#!/bin/sh\n"
            + "[ \"${1:-}\" = warm-up ] && exit 0\n"
            + "trap " + FluidServeSkill.shellQuoted(handler) + " TERM\n"
            + "echo $$ > " + FluidServeSkill.shellQuoted(pidFile.path) + "\n"
            + "echo ready > " + FluidServeSkill.shellQuoted(readyFile.path) + "\n"
            + "while :; do sleep 0.05; done\n"
        try Data(fixture.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: tool.path)
        try await Self.warmUp(tool)

        let started = ProcessInfo.processInfo.systemUptime
        let outcome: FluidServeSelfCheck.Outcome = await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: FluidServeSelfCheck.run(tool: tool, timeout: deadline))
            }
        }
        let elapsed = ProcessInfo.processInfo.systemUptime - started
        let manager = FileManager.default
        let pid = (try? String(contentsOf: pidFile, encoding: .utf8))
            .flatMap { Int32($0.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return Attempt(
            outcome: outcome,
            elapsed: elapsed,
            ready: manager.fileExists(atPath: readyFile.path),
            termHandled: manager.fileExists(atPath: termFile.path),
            pid: pid
        )
    }

    /// Launch the fixture once, returning at once, so the system's first-launch evaluation of the new file
    /// is finished before the reader's deadline starts.
    private static func warmUp(_ tool: URL) async throws {
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                let process = Process()
                process.executableURL = tool
                process.arguments = ["warm-up"]
                do {
                    try process.run()
                    process.waitUntilExit()
                    continuation.resume(returning: process.terminationStatus)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
        XCTAssertEqual(status, 0, "The fixture must exit at once when asked to warm up")
    }
}
