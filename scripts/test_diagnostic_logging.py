#!/usr/bin/env python3
"""Compile the actual logger and clipboard audit in production and diagnostic modes.

Uses a FileLogger stub and a named pasteboard; never writes the general clipboard.
Run with DEVELOPER_DIR pointing to a full Xcode installation.
"""
import os
import re
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
HARNESS = r'''
import AppKit
import Foundation

final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()
    let lock = NSLock()
    var lines: [String] = []
    let drained = DispatchSemaphore(value: 0)
    func append(line: String) {
        lock.lock()
        lines.append(line)
        lock.unlock()
        if line.contains("SUPPORT_END") { drained.signal() }
    }
}
final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func message() -> String { lock.lock(); defer { lock.unlock() }; value += 1; return "DIAGNOSTIC_PAYLOAD" }
    var count: Int { lock.lock(); defer { lock.unlock() }; return value }
}
@main struct Harness {
    static func main() {
        let counter = Counter()
        let boardCounter = Counter()
        func board() -> NSPasteboard {
            _ = boardCounter.message()
            return NSPasteboard(name: .init("FluidVoiceDiagnosticGateTest"))
        }
        let logger = DebugLogger.shared
        logger.debug(counter.message())
        logger.log(counter.message(), level: .debug)
        logger.benchmark("TEST_BENCH", message: counter.message())
        logger.logLazy(level: .debug) { counter.message() }
        ClipboardAudit.record("test", pasteboard: board(), detail: counter.message())
        logger.info("SUPPORT_INFO")
        logger.warning("SUPPORT_WARNING")
        logger.error("SUPPORT_ERROR")
        logger.info("SUPPORT_END")
        precondition(FileLogger.shared.drained.wait(timeout: .now() + 5) == .success)
        let enabled = DebugLogger.diagnosticsEnabled
        precondition(counter.count == (enabled ? 5 : 0), "Eager diagnostic construction")
        precondition(boardCounter.count == (enabled ? 1 : 0), "Production accessed pasteboard")
        let lines = FileLogger.shared.lines
        precondition(lines.count == (enabled ? 9 : 4), "Unexpected logging work")
        for marker in ["SUPPORT_INFO", "SUPPORT_WARNING", "SUPPORT_ERROR"] {
            precondition(lines.contains { $0.contains(marker) })
        }
        print("PASS diagnosticsEnabled=\(enabled)")
    }
}
'''

PROVENANCE_STUB = r'''
import Foundation
nonisolated enum AppBrand {
    static let storageNamespace = "test-only"
    static func logsDirectory(in: URL, storageNamespace: String) -> URL {
        URL(fileURLWithPath: ProcessInfo.processInfo.environment["PROVENANCE_LOG_ROOT"]!, isDirectory: true)
    }
}
'''

PROVENANCE_HARNESS = r'''
import Foundation
import MachO
#if PROVENANCE_XCTEST
import XCTest
#endif
@main struct ProvenanceHarness {
    static func main() throws { try run() }
    nonisolated static func run() throws {
        let revision = "0123456789ABCDEF0123456789ABCDEF01234567"
        precondition(RuntimeBuildProvenance.sanitizedSourceRevision(revision) == revision.lowercased())
        for value: Any? in [nil, 123, "unknown", "$(PICHI_SOURCE_REVISION)", String(repeating: "0", count: 39),
                           String(repeating: "0", count: 41), String(repeating: "\u{ff10}", count: 40),
                           String(repeating: "g", count: 40), String(repeating: "0", count: 39) + "\n"] {
            precondition(RuntimeBuildProvenance.sanitizedSourceRevision(value) == "unavailable")
        }
        func command(_ kind: UInt32, _ size: UInt32, _ payload: [UInt8] = []) -> Data {
            Data([kind, size].flatMap { word in (0..<4).map { UInt8(truncatingIfNeeded: word >> (8 * $0)) } } + payload)
        }
        let uuid = command(UInt32(LC_UUID), 24, Array(0..<16))
        let other = command(UInt32(LC_SOURCE_VERSION), 16, Array(repeating: 0, count: 8))
        precondition(RuntimeBuildProvenance.uuid(loadCommands: other + uuid, commandCount: 2)
            == "00010203-0405-0607-0809-0A0B0C0D0E0F")
        precondition(RuntimeBuildProvenance.uuid(loadCommands: other, commandCount: 1) == nil)
        for (bytes, count) in [(Data(uuid.dropLast()), 1), (uuid, 2), (uuid, -1), (uuid, Int.max),
                               (uuid + uuid, 2), (command(UInt32(LC_UUID), UInt32.max), 1),
                               (command(UInt32(LC_UUID), 0), 1), (command(UInt32(LC_UUID), 16, Array(0..<8)), 1),
                               (command(UInt32(LC_UUID), 23, Array(0..<15)), 1),
                               (uuid + Data(repeating: 0, count: 8), 1),
                               (Data(repeating: 0, count: 65_537), 1)] {
            precondition(RuntimeBuildProvenance.uuid(loadCommands: bytes, commandCount: count) == nil)
        }
        #if PROVENANCE_XCTEST
        precondition(NSClassFromString(NSStringFromClass(XCTestCase.self)) != nil)
        let expectedLoaded = true
        #else
        let expectedLoaded = false
        #endif
        let before = ProcessInfo.processInfo.systemUptime
        let line = RuntimeBuildProvenance.line(sourceRevision: revision)
        precondition(line.contains("XCTestLoaded=\(expectedLoaded)"))
        #if PROVENANCE_DYLIB
        precondition(line.contains("CodeImageKind=debug-dylib"))
        #else
        precondition(line.contains("CodeImageKind=executable"))
        #endif
        // The actual startup logger must persist the same runtime identity.
        FileLogger.shared.appendSync(line: "PROVENANCE_END")
        let log = try String(contentsOf: FileLogger.shared.currentLogFileURL(), encoding: .utf8)
        precondition(log.contains("BUILDPROVENANCE") && log.contains("XCTestLoaded=\(expectedLoaded)"))
        print(line)
        print("PASS provenance startupMs=\(Int((ProcessInfo.processInfo.systemUptime - before) * 1_000))")
    }
}
#if PROVENANCE_DYLIB
@_cdecl("provenance_entry") public func provenanceEntry() { try! ProvenanceHarness.run() }
#endif
'''

PROVENANCE_DYLIB_DRIVER = r'''
import Darwin
let library = dlopen(CommandLine.arguments[1], RTLD_NOW | RTLD_LOCAL)!
let entry = dlsym(library, "provenance_entry")!
unsafeBitCast(entry, to: (@convention(c) () -> Void).self)()
// Keep the image loaded until process exit, including its logger's crash handler.
'''


def main():
    developer_dir = os.environ.get("DEVELOPER_DIR") or subprocess.check_output(
        ["xcode-select", "-p"], text=True
    ).strip()
    if not (Path(developer_dir) / "Platforms/MacOSX.platform").is_dir():
        raise SystemExit("Set DEVELOPER_DIR to a full Xcode installation.")
    private_root = ROOT / ".build/diagnostic-logging"
    private_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix="fv-diagnostic-gate-", dir=private_root) as folder:
        folder = Path(folder)
        harness = folder / "Harness.swift"
        harness.write_text(HARNESS)
        for name, flags in [("production", []), ("debug", ["-D", "DEBUG"]),
                            ("diagnostic", ["-D", "FLUIDVOICE_DIAGNOSTICS"])]:
            binary = folder / name
            subprocess.run([
                "xcrun", "swiftc", "-parse-as-library", *flags,
                str(ROOT / "Sources/Fluid/Services/DebugLogger.swift"),
                str(ROOT / "Sources/Fluid/Services/ClipboardService.swift"),
                str(harness), "-o", str(binary),
            ], check=True)
            output = subprocess.check_output([str(binary)], text=True)
            if name == "production":
                assert output == "PASS diagnosticsEnabled=false\n", output
            else:
                assert "PASS diagnosticsEnabled=true" in output, output
            print(f"PASS {name}: logging and message evaluation gates")

        stub = folder / "ProvenanceStub.swift"
        stub.write_text(PROVENANCE_STUB)
        provenance_harness = folder / "ProvenanceHarness.swift"
        provenance_harness.write_text(PROVENANCE_HARNESS)
        xctest_frameworks = Path(developer_dir) / "Platforms/MacOSX.platform/Developer/Library/Frameworks"
        modes = [("production", [], "Release", False), ("debug", ["-D", "DEBUG"], "Debug", True),
                 ("diagnostic", ["-D", "FLUIDVOICE_DIAGNOSTICS"], "Release", True),
                 ("loaded-xctest", ["-D", "PROVENANCE_XCTEST", "-F", str(xctest_frameworks),
                  "-Xlinker", "-rpath", "-Xlinker", str(xctest_frameworks)], "Release", False)]
        for name, flags, configuration, diagnostics in modes:
            binary = folder / ("provenance-" + name)
            subprocess.run([
                "xcrun", "swiftc", "-parse-as-library", "-O", *flags,
                str(ROOT / "Sources/Fluid/Services/DebugLogger.swift"),
                str(ROOT / "Sources/Fluid/Services/FileLogger.swift"),
                str(stub), str(provenance_harness), "-o", str(binary),
            ], check=True)
            environment = dict(os.environ, PROVENANCE_LOG_ROOT=str(folder / (name + "-logs")))
            output = subprocess.check_output([str(binary)], text=True, env=environment)
            uuid = re.search(r"UUID: ([A-F0-9-]{36})", subprocess.check_output(
                ["xcrun", "dwarfdump", "--uuid", str(binary)], text=True)).group(1)
            assert f"ExecutableUUID={uuid}" in output, output
            assert f"CodeImageUUID={uuid}" in output, output
            assert f"Configuration={configuration} Diagnostics={str(diagnostics).lower()}" in output, output
            elapsed = re.search(r"startupMs=(\d+)", output).group(1)
            print(f"PASS {name}: runtime UUID matches dwarfdump, revision bounds, loaded XCTest and persisted startup metadata; startupMs={elapsed}")

        library = folder / "Provenance.debug.dylib"
        subprocess.run([
            "xcrun", "swiftc", "-parse-as-library", "-emit-library", "-O", "-D", "DEBUG", "-D", "PROVENANCE_DYLIB",
            str(ROOT / "Sources/Fluid/Services/DebugLogger.swift"), str(ROOT / "Sources/Fluid/Services/FileLogger.swift"),
            str(stub), str(provenance_harness), "-o", str(library),
        ], check=True)
        driver = folder / "ProvenanceDriver.swift"
        driver.write_text(PROVENANCE_DYLIB_DRIVER)
        binary = folder / "provenance-dylib-driver"
        subprocess.run(["xcrun", "swiftc", str(driver), "-o", str(binary)], check=True)
        output = subprocess.check_output([str(binary), str(library)], text=True,
            env=dict(os.environ, PROVENANCE_LOG_ROOT=str(folder / "dylib-logs")))
        for path, field in [(binary, "ExecutableUUID"), (library, "CodeImageUUID")]:
            uuid = re.search(r"UUID: ([A-F0-9-]{36})", subprocess.check_output(
                ["xcrun", "dwarfdump", "--uuid", str(path)], text=True)).group(1)
            assert f"{field}={uuid}" in output, output
        print("PASS debug-dylib: executable and loaded code UUIDs independently match dwarfdump")


if __name__ == "__main__":
    main()
