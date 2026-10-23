import Darwin
import Foundation

@main struct TerminalServiceLifecycleTests {
    @MainActor static var checks = 0
    @MainActor static func check(_ value: Bool, _ message: String) {
        checks += 1
        if !value { fatalError(message) }
    }

    static func quote(_ value: String) -> String { "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'" }

    static func flood() -> Never {
        let chunk = [UInt8](repeating: 120, count: 32_768)
        let rounds = Int(CommandLine.arguments.last ?? "96")!
        for _ in 0..<rounds {
            for fd in [STDOUT_FILENO, STDERR_FILENO] {
                chunk.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let count = write(fd, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if count < 0 { exit(2) }
                        offset += count
                    }
                }
            }
        }
        exit(0)
    }

    @MainActor static func waitForFile(_ url: URL) async {
        for _ in 0..<200 {
            if FileManager.default.fileExists(atPath: url.path) { return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        fatalError("Owned command did not publish its PID: \(url.lastPathComponent)")
    }

    static func readPID(_ url: URL) throws -> pid_t {
        let text = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let pid = pid_t(text), pid > 1 else { fatalError("Invalid owned PID") }
        return pid
    }

    @MainActor static func checkStopped(_ pid: pid_t, _ message: String) async {
        for _ in 0..<200 {
            if kill(pid, 0) == -1 && errno == ESRCH { check(true, message); return }
            try? await Task.sleep(for: .milliseconds(10))
        }
        check(false, message)
    }

    @MainActor static func main() async throws {
        if CommandLine.arguments.contains("--flood") { flood() }
        if CommandLine.arguments.contains("--auto-reap") {
            _ = signal(SIGCHLD, SIG_IGN)
            let result = await TerminalService().execute(command: "printf completed", timeout: 2)
            precondition(!result.success && result.error?.contains("wait ownership was lost") == true)
            precondition(result.executionTimeMs < 1_000)
            print("PASS: lost wait ownership returns without signalling")
            return
        }
        let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let service = TerminalService()
        let ordinary = await service.execute(command: "printf 'out'; printf 'err' >&2; exit 7", workingDirectory: root.path)
        check(!ordinary.success && ordinary.exitCode == 7, "Nonzero command exit was changed")
        check(ordinary.output == "out" && ordinary.error == "err", "Both command streams must be retained")
        let json = try JSONSerialization.jsonObject(with: Data(service.resultToJSON(ordinary).utf8)) as! [String: Any]
        check(json["command"] as? String == ordinary.command && json["exitCode"] as? Int == 7, "Existing JSON contract changed")
        let cwd = await service.execute(command: "/bin/pwd", workingDirectory: root.path)
        check(cwd.success && URL(fileURLWithPath: cwd.output).resolvingSymlinksInPath() == root.resolvingSymlinksInPath(), "Command working directory changed")
        let invalid = await service.execute(command: "printf must-not-start", workingDirectory: root.appendingPathComponent("absent").path)
        check(!invalid.success && invalid.exitCode == -1 && invalid.output.isEmpty, "Invalid cwd must fail before executing")

        let executable = quote(URL(fileURLWithPath: CommandLine.arguments[0]).standardized.path)
        let ownership = await service.execute(command: executable + " --auto-reap", timeout: 3)
        check(ownership.success && ownership.output.contains("PASS: lost wait ownership"),
            "Lost wait ownership must close owned IO and stop signalling numeric process IDs")
        let flooded = await service.execute(command: executable + " --flood 96", timeout: 8)
        check(flooded.success && flooded.exitCode == 0, "Concurrent stream flood deadlocked or timed out")
        check(flooded.output.utf8.count == 96 * 32_768, "Stdout pipe lost bytes")
        check(flooded.error?.utf8.count == 96 * 32_768, "Stderr pipe lost bytes")
        let limited = await service.execute(command: executable + " --flood 256", timeout: 8)
        check(!limited.success && limited.error?.contains("output exceeded") == true, "Output overflow must be explicit failure")
        check(limited.output.utf8.count <= 4 * 1024 * 1024, "Stdout must have bounded retained memory")
        check((limited.error?.utf8.count ?? 0) < 4 * 1024 * 1024 + 128, "Stderr must have bounded retained memory")

        let cancelledPID = root.appendingPathComponent("cancelled-leader.pid")
        let childPID = root.appendingPathComponent("cancelled-child.pid")
        let command = "trap '' TERM; printf '%s' $$ > " + quote(cancelledPID.path)
            + "; /bin/sleep 30 & printf '%s' $! > " + quote(childPID.path) + "; wait"
        let canaryPID = root.appendingPathComponent("canary.pid")
        let canary = Task { await service.execute(command: "printf '%s' $$ > " + quote(canaryPID.path) + "; /bin/sleep 0.8; printf canary", timeout: 5) }
        let cancelled = Task { await service.execute(command: command, timeout: 10) }
        await waitForFile(childPID)
        await waitForFile(canaryPID)
        let leader = try readPID(cancelledPID)
        let child = try readPID(childPID)
        let canaryLeader = try readPID(canaryPID)
        check(getpgid(leader) == leader && getpgid(child) == leader, "Only the explicit owned command group may be signaled")
        check(getpgid(canaryLeader) != leader, "Independent command needs a separate process group")
        let cancelTime = ProcessInfo.processInfo.systemUptime
        cancelled.cancel()
        let cancelledResult = await cancelled.value
        check(!cancelledResult.success && cancelledResult.error?.contains("cancelled") == true, "Cancellation must reach the running command")
        check(ProcessInfo.processInfo.systemUptime - cancelTime < 2, "Joined cancellation exceeded its bound")
        await checkStopped(leader, "Cancelled leader was not reaped")
        await checkStopped(child, "TERM-ignoring owned child survived cancellation")
        let canaryResult = await canary.value
        check(canaryResult.success && canaryResult.output == "canary", "Cancellation signaled an independent command")
        await checkStopped(canaryLeader, "Independent completed command was not reaped")

        let timeoutPID = root.appendingPathComponent("timeout-leader.pid")
        let timeoutChildPID = root.appendingPathComponent("timeout-child.pid")
        let timed = await service.execute(command: "trap '' TERM; printf '%s' $$ > " + quote(timeoutPID.path)
            + "; /bin/sleep 30 & printf '%s' $! > " + quote(timeoutChildPID.path) + "; wait", timeout: 0.2)
        check(!timed.success && timed.error?.contains("timed out") == true && timed.executionTimeMs < 2_000, "Timeout must escalate and join")
        await checkStopped(try readPID(timeoutPID), "Timed-out leader was not reaped")
        await checkStopped(try readPID(timeoutChildPID), "Timed-out child survived")

        let exitedLeaderPID = root.appendingPathComponent("exited-leader.pid")
        let heldPipePID = root.appendingPathComponent("held-pipe.pid")
        let held = await service.execute(command: "printf '%s' $$ > " + quote(exitedLeaderPID.path)
            + "; /bin/sleep 30 & printf '%s' $! > " + quote(heldPipePID.path) + "; exit 0", timeout: 0.2)
        check(!held.success && held.error?.contains("timed out") == true, "A background child holding pipes must remain bounded")
        await checkStopped(try readPID(exitedLeaderPID), "Exited leader was not reaped after pipe cleanup")
        await checkStopped(try readPID(heldPipePID), "Child holding output pipes survived cleanup")

        let preCancelledPID = root.appendingPathComponent("must-not-start.pid")
        let preCancelled = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return await service.execute(command: "printf '%s' $$ > " + quote(preCancelledPID.path))
        }
        let preResult = await preCancelled.value
        check(!preResult.success && preResult.error?.contains("cancelled") == true, "Pre-cancelled attempt must return cancellation")
        check(!FileManager.default.fileExists(atPath: preCancelledPID.path), "Pre-cancelled attempt launched a process")

        for _ in 0..<12 {
            let short = await service.execute(command: "printf short", timeout: 2)
            check(short.success && short.output == "short", "Later commands were affected by an earlier retirement")
        }
        let pids = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "pid" }.map { try readPID($0) }
        let cleanup = pids.map { ["pid": Int($0), "absent": kill($0, 0) == -1 && errno == ESRCH] as [String: Any] }
        let data = try JSONSerialization.data(withJSONObject: ["checks": checks, "ownedProcesses": cleanup], options: [.prettyPrinted, .sortedKeys])
        try data.write(to: root.appendingPathComponent("cleanup.json"))
        print("TerminalService lifecycle checks passed: \(checks)")
    }
}
