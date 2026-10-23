import Darwin
import Foundation

/// Simple terminal command execution service
/// All responses are JSON-parsable for easy AI processing
nonisolated final class TerminalService: Sendable {
    // MARK: - JSON Response Types

    struct CommandResult: Codable, Sendable {
        let success: Bool
        let command: String
        let output: String
        let error: String?
        let exitCode: Int32
        let executionTimeMs: Int
    }

    // MARK: - Tool Definition for AI

    /// Returns the tool definition in OpenAI function calling format
    static var toolDefinition: [String: Any] {
        return [
            "type": "function",
            "function": [
                "name": "execute_terminal_command",
                "description": """
                Execute a terminal/shell command on the user's macOS computer.
                Use this for file operations (ls, cat, mkdir, rm), git commands, brew, npm, python, or any CLI tool.

                IMPORTANT: Follow the agentic workflow:
                1. ALWAYS check prerequisites first (file exists, command available)
                2. Execute the main action
                3. Verify the result

                Returns JSON with: success (bool), output (stdout), error (stderr), exitCode, purpose.
                """,
                "parameters": [
                    "type": "object",
                    "properties": [
                        "command": [
                            "type": "string",
                            "description": "The shell command to execute (e.g., 'ls -la', 'git status', 'rm file.txt')",
                        ],
                        "workingDirectory": [
                            "type": "string",
                            "description": "Optional working directory path. Defaults to user's home directory.",
                        ],
                        "purpose": [
                            "type": "string",
                            "description": """
                            Brief description of why this command is being run. Must be one of:
                            - 'checking' (verifying prerequisites)
                            - 'executing' (main action)
                            - 'verifying' (confirming result)
                            Example: 'Checking if config.json exists'
                            """,
                        ],
                    ],
                    "required": ["command", "purpose"],
                ],
            ],
        ]
    }

    // MARK: - Execution

    /// Execute a terminal command and return JSON-parsable result
    func execute(
        command: String,
        workingDirectory: String? = nil,
        timeout: TimeInterval = 30
    ) async -> CommandResult {
        let execution = TerminalCommandExecution(command: command, workingDirectory: workingDirectory, timeout: timeout)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(returning: execution.run())
                }
            }
        } onCancel: {
            execution.cancel()
        }
    }

    /// Convert result to JSON string for AI processing
    func resultToJSON(_ result: CommandResult) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]

        if let data = try? encoder.encode(result),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }

        // Fallback: always return valid JSON (avoid manual string interpolation of output)
        let fallbackPayload: [String: Any] = [
            "success": result.success,
            "output": result.output,
            "exitCode": Int(result.exitCode),
        ]

        if let data = try? JSONSerialization.data(withJSONObject: fallbackPayload, options: [.sortedKeys]),
           let json = String(data: data, encoding: .utf8)
        {
            return json
        }

        // If serialization fails for any reason, return minimal safe JSON
        return #"{"success":false,"output":"<json-serialization-failed>","exitCode":-1}"#
    }
}

/// Owns one shell attempt. Blocking OS waits stay off the cooperative executor.
/// The explicit process group contains only this attempt and its attached children.
private nonisolated final class TerminalCommandExecution: @unchecked Sendable {
    private let command: String
    private let workingDirectory: String
    private let timeout: TimeInterval
    private let lock = NSLock()
    private var cancelled = false
    private static let outputLimit = 4 * 1024 * 1024
    private static let terminationGrace: TimeInterval = 0.25

    init(command: String, workingDirectory: String?, timeout: TimeInterval) {
        self.command = command
        self.workingDirectory = workingDirectory.flatMap { $0.isEmpty ? nil : $0 }
            ?? FileManager.default.homeDirectoryForCurrentUser.path
        self.timeout = timeout.isFinite ? max(0, timeout) : 30
    }

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return cancelled
    }

    func run() -> TerminalService.CommandResult {
        let started = ProcessInfo.processInfo.systemUptime
        var output = Data()
        var errors = Data()
        var outputFDs: [Int32] = [-1, -1]
        var errorFDs: [Int32] = [-1, -1]
        defer {
            for fd in outputFDs + errorFDs where fd >= 0 { close(fd) }
        }
        func result(status: Int32, failure: String? = nil) -> TerminalService.CommandResult {
            let stderr = String(decoding: errors, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            let message = [stderr.isEmpty ? nil : stderr, failure].compactMap { $0 }.joined(separator: "\n")
            return .init(success: failure == nil && status == 0, command: command,
                         output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
                         error: message.isEmpty ? nil : message, exitCode: status,
                         executionTimeMs: Int((ProcessInfo.processInfo.systemUptime - started) * 1000))
        }
        if isCancelled { return result(status: -1, failure: "Command cancelled.") }
        do {
            guard pipe(&outputFDs) == 0, pipe(&errorFDs) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            for fd in outputFDs + errorFDs {
                guard fcntl(fd, F_SETFD, FD_CLOEXEC) != -1 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }
            for fd in [outputFDs[0], errorFDs[0]] {
                guard fcntl(fd, F_SETFL, O_NONBLOCK) != -1 else { throw POSIXError(.init(rawValue: errno) ?? .EIO) }
            }
            let pid = try spawn(output: outputFDs, errors: errorFDs)
            close(outputFDs[1]); outputFDs[1] = -1
            close(errorFDs[1]); errorFDs[1] = -1
            var exitInfo = siginfo_t()
            var exited = false
            var outputEnded = false
            var errorEnded = false
            var failure: String?
            var terminationStarted: TimeInterval?
            var killed = false
            var overflow = false
            while true {
                let now = ProcessInfo.processInfo.systemUptime
                if failure == nil {
                    if isCancelled { failure = "Command cancelled." }
                    else if now - started >= timeout { failure = "Command timed out." }
                    else if overflow { failure = "Command output exceeded the 4 MiB per stream limit." }
                }
                if failure != nil, terminationStarted == nil {
                    // The unreaped group leader reserves this PID until final joined cleanup.
                    kill(-pid, SIGTERM)
                    terminationStarted = now
                }
                if let stopping = terminationStarted, !killed, now - stopping >= Self.terminationGrace {
                    kill(-pid, SIGKILL)
                    killed = true
                }
                drain(outputFDs[0], into: &output, ended: &outputEnded, overflow: &overflow)
                drain(errorFDs[0], into: &errors, ended: &errorEnded, overflow: &overflow)
                if !exited {
                    // Observe without reaping so a later group signal cannot hit a reused PID.
                    if waitid(P_PID, id_t(pid), &exitInfo, WEXITED | WNOHANG | WNOWAIT) == 0 {
                        exited = exitInfo.si_pid == pid
                    } else if errno != EINTR {
                        // An external reaper or SIGCHLD policy can remove our unreaped-leader
                        // reservation. Its numeric PID/PGID is then unsafe to signal again.
                        // Our read descriptors remain owned and are closed by the outer defer.
                        return result(status: -1, failure: "Command wait ownership was lost; no further signals were sent.")
                    }
                }
                if exited && outputEnded && errorEnded && !overflow && (failure == nil || killed) { break }
                if exited && outputEnded && errorEnded && failure != nil && killed { break }
                if let stopping = terminationStarted, killed, now - stopping >= Self.terminationGrace + 1 {
                    // A detached descendant may retain a pipe outside our group. Do not wait on
                    // or signal unrelated groups; close only our read ends after joining the shell.
                    break
                }
                var descriptors = [pollfd(fd: outputFDs[0], events: Int16(POLLIN), revents: 0),
                                   pollfd(fd: errorFDs[0], events: Int16(POLLIN), revents: 0)]
                if outputEnded { descriptors[0].fd = -1 }
                if errorEnded { descriptors[1].fd = -1 }
                _ = poll(&descriptors, nfds_t(descriptors.count), 20)
            }
            var status: Int32 = 0
            while waitpid(pid, &status, 0) == -1 {
                if errno != EINTR { return result(status: -1, failure: failure ?? "Failed to join command exit.") }
            }
            return result(status: exitInfo.si_pid == pid ? exitInfo.si_status : SIGKILL, failure: failure)
        } catch {
            return result(status: -1, failure: "Failed to execute: \(error.localizedDescription)")
        }
    }

    private func drain(_ fd: Int32, into data: inout Data, ended: inout Bool, overflow: inout Bool) {
        guard !ended else { return }
        // Bound each turn so a noisy pipe cannot starve cancellation or the other stream.
        var bytes = [UInt8](repeating: 0, count: 16_384)
        for _ in 0..<4 {
            let count = read(fd, &bytes, bytes.count)
            if count > 0 {
                let available = max(0, Self.outputLimit - data.count)
                data.append(contentsOf: bytes.prefix(min(count, available)))
                if count > available { overflow = true }
            } else if count == 0 { ended = true; return }
            else if errno != EINTR { return }
        }
    }

    private func spawn(output: [Int32], errors: [Int32]) throws -> pid_t {
        var actions: posix_spawn_file_actions_t?
        var attributes: posix_spawnattr_t?
        func checked(_ code: Int32) throws {
            if code != 0 { throw POSIXError(.init(rawValue: code) ?? .EIO) }
        }
        try checked(posix_spawn_file_actions_init(&actions))
        defer { posix_spawn_file_actions_destroy(&actions) }
        try checked(posix_spawnattr_init(&attributes))
        defer { posix_spawnattr_destroy(&attributes) }
        try checked(posix_spawnattr_setpgroup(&attributes, 0))
        try checked(posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETPGROUP | POSIX_SPAWN_CLOEXEC_DEFAULT)))
        try checked(posix_spawn_file_actions_addopen(&actions, STDIN_FILENO, "/dev/null", O_RDONLY, 0))
        try checked(posix_spawn_file_actions_adddup2(&actions, output[1], STDOUT_FILENO))
        try checked(posix_spawn_file_actions_adddup2(&actions, errors[1], STDERR_FILENO))
        for fd in output + errors { try checked(posix_spawn_file_actions_addclose(&actions, fd)) }
        if #available(macOS 26, *) {
            try checked(posix_spawn_file_actions_addchdir(&actions, workingDirectory))
        } else {
            try checked(posix_spawn_file_actions_addchdir_np(&actions, workingDirectory))
        }
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + (environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
        let arguments = ["/bin/zsh", "-c", command].map { strdup($0) } + [nil]
        let variables = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer {
            for value in arguments + variables { free(value) }
        }
        var pid: pid_t = 0
        let status = arguments.withUnsafeBufferPointer { argv in
            variables.withUnsafeBufferPointer { env in
                posix_spawn(&pid, "/bin/zsh", &actions, &attributes, argv.baseAddress!, env.baseAddress!)
            }
        }
        try checked(status)
        return pid
    }
}
