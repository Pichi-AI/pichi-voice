import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// Diagnostic process counters, never a scheduling policy. User plus system CPU
/// covers every thread in this app, including work outside the measured phase.
nonisolated struct DiagnosticProcessCPUTime: Sendable, Equatable {
    let userSeconds: Double
    let systemSeconds: Double

    static func capture() -> Self? {
        #if canImport(Darwin)
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return nil }
        return .init(userSeconds: Double(usage.ru_utime.tv_sec) + Double(usage.ru_utime.tv_usec) / 1_000_000,
                     systemSeconds: Double(usage.ru_stime.tv_sec) + Double(usage.ru_stime.tv_usec) / 1_000_000)
        #else
        return nil
        #endif
    }

    var totalMilliseconds: Int64? {
        guard userSeconds.isFinite, systemSeconds.isFinite, userSeconds >= 0, systemSeconds >= 0 else { return nil }
        return Self.milliseconds(userSeconds + systemSeconds)
    }

    func milliseconds(since earlier: Self) -> Int64? {
        guard totalMilliseconds != nil, earlier.totalMilliseconds != nil,
              userSeconds >= earlier.userSeconds, systemSeconds >= earlier.systemSeconds else { return nil }
        return Self.milliseconds((userSeconds - earlier.userSeconds) + (systemSeconds - earlier.systemSeconds))
    }

    private static func milliseconds(_ seconds: Double) -> Int64? {
        let value = seconds * 1_000
        guard value.isFinite, value >= 0, value < Double(Int64.max) else { return nil }
        return Int64(value)
    }
}

final nonisolated class DebugLogger: @unchecked Sendable {
    static let shared = DebugLogger()

    /// Production builds exclude verbose diagnostics; local Release investigations
    /// explicitly opt in with FLUIDVOICE_DIAGNOSTICS at compile time.
    static let diagnosticsEnabled: Bool = {
        #if DEBUG || FLUIDVOICE_DIAGNOSTICS
        true
        #else
        false
        #endif
    }()

    /// Request-local correlation survives actor hops without mutable global state.
    /// Capture explicitly before handing work to a DispatchQueue or detached task.
    @TaskLocal static var pipelineID: String?

    private let queue = DispatchQueue(label: "debug.logger", qos: .utility)

    private static let logFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    enum LogLevel: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
        case debug = "DEBUG"
    }

    private init() {}

    func log(_ message: @autoclosure () -> String, level: LogLevel = .info, source: String = "App") {
        guard level != .debug || Self.diagnosticsEnabled else { return }
        let message = message()
        let pipelineID = Self.pipelineID
        let profile = PrivateProfileStorage.current
        guard profile.isReadable else { return }
        self.queue.async {
            self.write(message, level: level, source: source, pipelineID: pipelineID, profile: profile)
        }
    }

    /// Defers expensive diagnostic string construction until after latency-sensitive
    /// work has continued on the caller's executor.
    func logLazy(
        level: LogLevel = .info,
        source: String = "App",
        _ message: @escaping @Sendable () -> String
    ) {
        guard level != .debug || Self.diagnosticsEnabled else { return }
        let pipelineID = Self.pipelineID
        let profile = PrivateProfileStorage.current
        guard profile.isReadable else { return }
        self.queue.async {
            self.write(message(), level: level, source: source, pipelineID: pipelineID, profile: profile)
        }
    }

    /// A queue barrier joins lazy message construction before FileLogger changes its descriptor.
    func joinForProfileTransition() async {
        await withCheckedContinuation { continuation in
            self.queue.async { continuation.resume() }
        }
    }

    private func write(_ message: String, level: LogLevel, source: String, pipelineID: String?, profile: PrivateProfileSnapshot) {
        let timestampString = Self.logFormatter.string(from: Date())
        let formattedLine = self.formatLogLine(
            timestamp: timestampString,
            level: level,
            source: source,
            message: message,
            pipelineID: pipelineID
        )

        // Retain ordinary support logs in production; verbose diagnostics are gated before enqueueing.
        FileLogger.shared.append(line: formattedLine, profile: profile)
        #if DEBUG || FLUIDVOICE_DIAGNOSTICS
        print(formattedLine)
        #endif
    }

    private func formatLogLine(timestamp: String, level: LogLevel, source: String, message: String, pipelineID: String?) -> String {
        let correlation = pipelineID.map { "pipelineID=\($0) " } ?? ""
        return "[\(timestamp)] [\(level.rawValue)] [\(source)] \(correlation)\(message)"
    }
}

// Convenience functions for easier logging
nonisolated extension DebugLogger {
    func info(_ message: String, source: String = "App") {
        self.log(message, level: .info, source: source)
    }

    func benchmark(_ marker: String, message: @autoclosure () -> String, source: String = "Benchmark") {
        guard Self.diagnosticsEnabled else { return }
        let now = ProcessInfo.processInfo.systemUptime
        self.info("\(marker) t=\(String(format: "%.6f", now)) \(message())", source: source)
    }

    func warning(_ message: String, source: String = "App") {
        self.log(message, level: .warning, source: source)
    }

    func error(_ message: String, source: String = "App") {
        self.log(message, level: .error, source: source)
    }

    func debug(_ message: @autoclosure () -> String, source: String = "App") {
        guard Self.diagnosticsEnabled else { return }
        self.log(message(), level: .debug, source: source)
    }
}
