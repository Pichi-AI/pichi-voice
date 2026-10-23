import Darwin
import Foundation
import MachO

/// Build identity comes from signed metadata and loaded code, never imported appearance
/// or preferences. The bounded load-command copy performs no startup file I/O.
nonisolated enum RuntimeBuildProvenance {
    static func sanitizedSourceRevision(_ value: Any?) -> String {
        guard let value = value as? String, value.utf8.count == 40,
              value.utf8.allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }) else {
            return "unavailable"
        }
        return value.lowercased()
    }

    static func line(sourceRevision: Any?) -> String {
        #if DEBUG
        let configuration = "Debug"
        #else
        let configuration = "Release"
        #endif
        // A test plug-in may remain on disk after testing. Only a loaded class counts.
        let xctestLoaded = NSClassFromString("XCTestCase") != nil
        let executable = _dyld_get_image_header(0)
        let executableUUID = executable.flatMap { $0.pointee.filetype == MH_EXECUTE ? loadedUUID($0) : nil }
        let marker: @convention(c) () -> Void = fileLoggerBuildImageMarker
        var image = Dl_info()
        let foundCodeImage = dladdr(unsafeBitCast(marker, to: UnsafeRawPointer.self), &image) != 0
        let codeHeader = foundCodeImage ? image.dli_fbase.map { UnsafePointer($0.assumingMemoryBound(to: mach_header.self)) } : nil
        let codeUUID = loadedUUID(codeHeader)
        let codeKind = foundCodeImage && image.dli_fname != nil && String(cString: image.dli_fname).hasSuffix(".debug.dylib")
            ? "debug-dylib" : (codeHeader == executable ? "executable" : "other")
        return "[RUN] BUILDPROVENANCE Configuration=\(configuration) Diagnostics=\(DebugLogger.diagnosticsEnabled) XCTestLoaded=\(xctestLoaded) ExecutableUUID=\(executableUUID ?? "unavailable") CodeImageUUID=\(codeUUID ?? "unavailable") CodeImageKind=\(codeKind) SourceRevision=\(sanitizedSourceRevision(sourceRevision))"
    }

    private static func loadedUUID(_ header: UnsafePointer<mach_header>?) -> String? {
        // dyld owns these validated, loaded headers. The main executable and this
        // executing code image cannot be unloaded while this function runs.
        guard let header, header.pointee.magic == MH_MAGIC_64 else { return nil }
        let count = Int(header.pointee.ncmds)
        let size = Int(header.pointee.sizeofcmds)
        guard size >= 8, size <= 64 * 1024, count > 0, count <= size / 8 else { return nil }
        let commands = UnsafeRawPointer(header).advanced(by: MemoryLayout<mach_header_64>.size)
        return uuid(loadCommands: Data(bytes: commands, count: size), commandCount: count)
    }

    /// Checked parsing also accepts synthetic malformed commands in diagnostics tests.
    static func uuid(loadCommands: Data, commandCount: Int) -> String? {
        let bytes = [UInt8](loadCommands)
        guard bytes.count <= 64 * 1024, commandCount > 0, commandCount <= bytes.count / 8 else { return nil }
        func uint32(_ offset: Int) -> UInt32 {
            (0..<4).reduce(0) { $0 | (UInt32(bytes[offset + $1]) << (8 * $1)) }
        }
        var offset = 0
        var identifier: String?
        for _ in 0..<commandCount {
            guard offset <= bytes.count - 8 else { return nil }
            let command = uint32(offset)
            let size = Int(uint32(offset + 4))
            guard size >= 8, size % 8 == 0, size <= bytes.count - offset else { return nil }
            if command == LC_UUID {
                guard size == MemoryLayout<uuid_command>.size, identifier == nil else { return nil }
                let hex = bytes[(offset + 8)..<(offset + 24)].map { String(format: "%02X", $0) }
                identifier = hex[0..<4].joined() + "-" + hex[4..<6].joined() + "-" + hex[6..<8].joined()
                    + "-" + hex[8..<10].joined() + "-" + hex[10..<16].joined()
            }
            offset += size
        }
        guard offset == bytes.count else { return nil }
        return identifier
    }
}

private nonisolated func fileLoggerBuildImageMarker() {}

/// A lightweight file-backed logger that mirrors in-app debug logs to disk for diagnostics.
final nonisolated class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    private let queue = DispatchQueue(label: "file.logger.queue", qos: .utility)
    private let fileManager = FileManager.default
    private var profile: PrivateProfileSnapshot
    private var acceptsWrites = true
    private var logDirectory: URL
    private var logFileURL: URL
    private var backupLogURL: URL
    private let maxLogFileSize: UInt64 = 1 * 1024 * 1024 // 1 MB limit per log file
    private let maxLogFileAge: TimeInterval = 72 * 60 * 60 // Rotate every 72 hours
    private static var crashFileDescriptor: Int32 = -1
    private static var crashHandlersInstalled = false
    private static let sigAbrtLine = Array("[CRASH] Fatal signal SIGABRT\n".utf8)
    private static let sigIllLine = Array("[CRASH] Fatal signal SIGILL\n".utf8)
    private static let sigSegvLine = Array("[CRASH] Fatal signal SIGSEGV\n".utf8)
    private static let sigBusLine = Array("[CRASH] Fatal signal SIGBUS\n".utf8)
    private static let sigTrapLine = Array("[CRASH] Fatal signal SIGTRAP\n".utf8)
    private static let sigUnknownLine = Array("[CRASH] Fatal signal UNKNOWN\n".utf8)

    private init() {
        let profile = PrivateProfileStorage.current
        self.profile = profile
        #if FLUID_ASR_BASELINE
        // Baseline runs log to an isolated per-process temp root, never user Library.
        let baseDirectory = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("FluidASRBaseline-\(UUID().uuidString)", isDirectory: true)
        #else
        let baseDirectory = self.fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first ?? URL(fileURLWithPath: NSTemporaryDirectory())
        #endif
        #if FLUID_ASR_BASELINE
        self.logDirectory = AppBrand.logsDirectory(in: baseDirectory, storageNamespace: AppBrand.storageNamespace)
        #else
        self.logDirectory = profile.isGuest
            ? AppBrand.logsDirectory(in: baseDirectory, storageNamespace: AppBrand.storageNamespace)
            : profile.directory("Logs")
        #endif
        self.logFileURL = self.logDirectory.appendingPathComponent("diagnostics.log", isDirectory: false)
        self.backupLogURL = self.logDirectory.appendingPathComponent("diagnostics.log.1", isDirectory: false)

        self.queue.sync {
            self.createLogDirectoryIfNeeded()
            self.rotateIfNeeded(force: false)
            self.prepareCrashLogging()
            self.appendRunMetadata()
        }
        self.installCrashHandlersIfNeeded()
    }

    func append(line: String, profile: PrivateProfileSnapshot = PrivateProfileStorage.current) {
        guard profile.isReadable else { return }
        self.queue.async { [weak self] in
            guard let self = self else { return }
            guard self.accepts(profile) else { return }
            self.appendUnlocked(line: line)
        }
    }

    func appendSync(line: String) {
        let profile = PrivateProfileStorage.current
        self.queue.sync {
            guard self.accepts(profile) else { return }
            self.appendUnlocked(line: line)
        }
    }

    func currentLogFileURL() -> URL {
        let profile = PrivateProfileStorage.current
        return self.queue.sync {
            self.accepts(profile) ? self.logFileURL
                : profile.directory("Unavailable-" + profile.generation.uuidString).appendingPathComponent("diagnostics.log")
        }
    }

    private func accepts(_ profile: PrivateProfileSnapshot) -> Bool {
        self.acceptsWrites && profile.isReadable && profile.id == self.profile.id
            && profile.generation == self.profile.generation
    }

    /// Call after joining DebugLogger. Old admitted writes finish in their original file;
    /// no queued line can be redirected when the descriptor is rebound.
    func suspendForProfileTransition() async {
        await withCheckedContinuation { continuation in
            self.queue.async {
                self.acceptsWrites = false
                let descriptor = Self.crashFileDescriptor
                Self.crashFileDescriptor = -1
                if descriptor >= 0 { close(descriptor) }
                continuation.resume()
            }
        }
    }

    func activateProfile(_ profile: PrivateProfileSnapshot) async {
        await withCheckedContinuation { continuation in
            self.queue.async {
                self.profile = profile
                #if !FLUID_ASR_BASELINE
                let library = self.fileManager.urls(for: .libraryDirectory, in: .userDomainMask).first
                    ?? URL(fileURLWithPath: NSTemporaryDirectory())
                self.logDirectory = profile.isGuest
                    ? AppBrand.logsDirectory(in: library, storageNamespace: AppBrand.storageNamespace)
                    : profile.directory("Logs")
                self.logFileURL = self.logDirectory.appendingPathComponent("diagnostics.log")
                self.backupLogURL = self.logDirectory.appendingPathComponent("diagnostics.log.1")
                #endif
                self.acceptsWrites = profile.isReadable
                if profile.isReadable {
                    self.createLogDirectoryIfNeeded()
                    self.rotateIfNeeded(force: false)
                    self.prepareCrashLogging()
                    self.appendRunMetadata()
                }
                continuation.resume()
            }
        }
    }

    // MARK: - Private helpers

    private func createLogDirectoryIfNeeded() {
        guard !self.fileManager.fileExists(atPath: self.logDirectory.path) else { return }
        do {
            try self.fileManager.createDirectory(at: self.logDirectory, withIntermediateDirectories: true)
        } catch {
            // If the directory cannot be created, fall back to /tmp
        }
    }

    private func appendUnlocked(line: String) {
        self.createLogDirectoryIfNeeded()
        self.rotateIfNeeded(force: false)
        let data = (line + "\n").data(using: .utf8) ?? Data()
        if !self.fileManager.fileExists(atPath: self.logFileURL.path) {
            self.fileManager.createFile(atPath: self.logFileURL.path, contents: data)
            self.prepareCrashLogging()
            return
        }
        guard let handle = try? FileHandle(forWritingTo: self.logFileURL) else {
            self.prepareCrashLogging()
            return
        }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: data)
            try handle.close()
        } catch {
            try? handle.close()
        }
        self.prepareCrashLogging()
    }

    private func appendRunMetadata() {
        let bundle = Bundle.main
        let appVersion = bundle.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
        let build = bundle.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "unknown"
        let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
        let pid = ProcessInfo.processInfo.processIdentifier
        self.appendUnlocked(line: "[RUN] PID=\(pid) AppVersion=\(appVersion) Build=\(build) OS=\(osVersion)")
        self.appendUnlocked(line: "[RUN] Processed by \(Bundle.main.bundleIdentifier ?? "unknown")")
        self.appendUnlocked(line: RuntimeBuildProvenance.line(sourceRevision: bundle.object(forInfoDictionaryKey: "AppSourceRevision")))
    }

    private func rotateIfNeeded(force: Bool) {
        guard self.fileManager.fileExists(atPath: self.logFileURL.path) else { return }

        let shouldRotate: Bool
        if force {
            shouldRotate = true
        } else {
            let attributes = try? self.fileManager.attributesOfItem(atPath: self.logFileURL.path)
            let size = attributes?[.size] as? UInt64 ?? 0
            let modifiedDate = attributes?[.modificationDate] as? Date ?? Date()
            let ageExceedsLimit = Date().timeIntervalSince(modifiedDate) >= self.maxLogFileAge
            shouldRotate = size >= self.maxLogFileSize || ageExceedsLimit
        }

        guard shouldRotate else { return }

        // Remove existing backup if present
        if self.fileManager.fileExists(atPath: self.backupLogURL.path) {
            try? self.fileManager.removeItem(at: self.backupLogURL)
        }

        // Move current log to backup and create a fresh file
        try? self.fileManager.moveItem(at: self.logFileURL, to: self.backupLogURL)
        self.fileManager.createFile(atPath: self.logFileURL.path, contents: nil)
        self.prepareCrashLogging()
    }

    private func prepareCrashLogging() {
        if Self.crashFileDescriptor >= 0 {
            let descriptor = Self.crashFileDescriptor
            Self.crashFileDescriptor = -1
            close(descriptor)
        }
        Self.crashFileDescriptor = open(self.logFileURL.path, O_WRONLY | O_CREAT | O_APPEND, S_IRUSR | S_IWUSR)
    }

    private func installCrashHandlersIfNeeded() {
        guard !Self.crashHandlersInstalled else { return }
        Self.crashHandlersInstalled = true

        NSSetUncaughtExceptionHandler { exception in
            let line = "[CRASH] Uncaught exception \(exception.name.rawValue): \(exception.reason ?? "Unknown reason")"
            FileLogger.writeCrashLineDirect(line)
            if !exception.callStackSymbols.isEmpty {
                FileLogger.writeCrashLineDirect("[CRASH] Stack: \(exception.callStackSymbols.joined(separator: " | "))")
            }
        }

        signal(SIGABRT, fileLoggerSignalHandler)
        signal(SIGILL, fileLoggerSignalHandler)
        signal(SIGSEGV, fileLoggerSignalHandler)
        signal(SIGBUS, fileLoggerSignalHandler)
        signal(SIGTRAP, fileLoggerSignalHandler)
    }

    static func writeCrashSignalLine(_ signalNumber: Int32) {
        guard self.crashFileDescriptor >= 0 else { return }
        let bytes: [UInt8]
        switch signalNumber {
        case SIGABRT: bytes = Self.sigAbrtLine
        case SIGILL: bytes = Self.sigIllLine
        case SIGSEGV: bytes = Self.sigSegvLine
        case SIGBUS: bytes = Self.sigBusLine
        case SIGTRAP: bytes = Self.sigTrapLine
        default: bytes = Self.sigUnknownLine
        }
        bytes.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            _ = write(Self.crashFileDescriptor, baseAddress, rawBuffer.count)
        }
    }

    static func writeCrashLineDirect(_ line: String) {
        guard self.crashFileDescriptor >= 0 else { return }
        let message = line.hasSuffix("\n") ? line : "\(line)\n"
        message.withCString { ptr in
            _ = write(Self.crashFileDescriptor, ptr, strlen(ptr))
        }
    }
}

private nonisolated func fileLoggerSignalHandler(_ signalNumber: Int32) {
    FileLogger.writeCrashSignalLine(signalNumber)
    signal(signalNumber, SIG_DFL)
    raise(signalNumber)
}
