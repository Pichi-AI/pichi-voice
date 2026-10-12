#!/usr/bin/env python3
"""Run production Swift method bodies against deterministic, gated dependency fakes.

This avoids loading ASR models or the app UI. It verifies method control flow,
not the real provider, disk store, or SwiftUI integration.
"""
from pathlib import Path
import os
import re
import subprocess
import sys
import tempfile

repo = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
selected_toolchain = subprocess.check_output(["xcode-select", "-p"], text=True, timeout=10).strip()
developer_dir = os.environ.get("DEVELOPER_DIR", selected_toolchain)
if ".app/Contents/Developer" not in developer_dir or not (Path(developer_dir) / "usr/bin/xcodebuild").is_file():
    raise SystemExit("Set DEVELOPER_DIR to an installed full Xcode before running this test.")
os.environ["DEVELOPER_DIR"] = developer_dir

def skip_non_code(text: str, index: int) -> int | None:
    """Skip Swift comments or strings, including raw strings and interpolation."""
    if text.startswith("//", index):
        end = text.find("\n", index)
        return len(text) if end == -1 else end
    if text.startswith("/*", index):
        depth, cursor = 1, index + 2
        while cursor < len(text):
            if text.startswith("/*", cursor):
                depth += 1
                cursor += 2
            elif text.startswith("*/", cursor):
                depth -= 1
                cursor += 2
                if depth == 0:
                    return cursor
            else:
                cursor += 1
        raise ValueError("Unterminated Swift block comment")
    cursor = index
    while cursor < len(text) and text[cursor] == "#":
        cursor += 1
    if not text.startswith('"', cursor):
        return None
    hashes = text[index:cursor]
    quotes = '"""' if text.startswith('"""', cursor) else '"'
    closing = quotes + hashes
    escape = "\\" + hashes
    cursor += len(quotes)
    while cursor < len(text):
        if text.startswith(closing, cursor):
            return cursor + len(closing)
        if text.startswith(escape, cursor):
            cursor += len(escape)
            if text.startswith("(", cursor):
                depth = 1
                cursor += 1
                while cursor < len(text) and depth:
                    skipped = skip_non_code(text, cursor)
                    if skipped is not None:
                        cursor = skipped
                    else:
                        depth += (text[cursor] == "(") - (text[cursor] == ")")
                        cursor += 1
                if depth:
                    raise ValueError("Unterminated Swift interpolation")
            else:
                cursor += 1
        else:
            cursor += 1
    raise ValueError("Unterminated Swift string")


def declaration(text: str, kind: str, name: str) -> str:
    """Copy one complete production declaration verbatim, never neighboring methods."""
    # Find declarations only in code. A removed/commented implementation must not
    # be reconstructed from a comment or a documentation string and then "tested".
    code = list(text)
    cursor = 0
    while cursor < len(text):
        skipped = skip_non_code(text, cursor)
        if skipped is None:
            cursor += 1
            continue
        for position in range(cursor, skipped):
            if code[position] != "\n":
                code[position] = " "
        cursor = skipped
    modifiers = r"(?:(?:private|fileprivate|internal|public|package|final|nonisolated)\s+)*"
    pattern = rf"(?m)^[ \t]*{modifiers}{re.escape(kind)}\s+{re.escape(name)}\b"
    matches = list(re.finditer(pattern, "".join(code)))
    if len(matches) != 1:
        raise ValueError(f"Expected exactly one {kind} {name}; found {len(matches)}")
    start = cursor = matches[0].start()
    parentheses = depth = 0
    in_body = False
    while cursor < len(text):
        skipped = skip_non_code(text, cursor)
        if skipped is not None:
            cursor = skipped
            continue
        char = text[cursor]
        if not in_body:
            parentheses += (char == "(") - (char == ")")
            if char == "{" and parentheses == 0:
                in_body, depth = True, 1
        else:
            depth += (char == "{") - (char == "}")
            if depth == 0:
                return text[start:cursor + 1]
        cursor += 1
    raise ValueError(f"Unterminated body for {kind} {name}")


def verify_extraction() -> int:
    checks = 0
    fixtures = [
        'func target() { /* { /* } */ } */ return 1 }',
        r'func target() { let value = "escaped \" }"; return value }',
        'func target() { let value = #"{ ignored }"#; return value }',
        'func target() { let value = """\n}\\(String("}"))\n"""; return value }',
        'func target(_ work: () -> Int = { 1 }) { return work() }',
    ]
    for fixture in fixtures:
        assert declaration(fixture + '\nfunc unrelated() { }', 'func', 'target') == fixture
        checks += 1
    for visibility in ['', 'private ']:
        fixture = visibility + 'actor TranscriptionExecutor { func run() { } }'
        assert declaration(fixture, 'actor', 'TranscriptionExecutor') == fixture
        checks += 1
    commented = [
        '/*\nfunc target() { }\n*/',
        'let value = """\nfunc target() { }\n"""',
        'let value = #"""\nfunc target() { }\n"""#',
    ]
    for invalid in ['func target() {', 'func target() {}\nfunc target() {}', 'func unrelated() {}'] + commented:
        try:
            declaration(invalid, 'func', 'target')
        except ValueError:
            pass
        else:
            raise AssertionError("Invalid or ambiguous declarations must fail closed")
        checks += 1
    for comment in commented:
        live = 'func target() { return 1 }'
        assert declaration(comment + '\n' + live, 'func', 'target') == live
        checks += 1
    return checks


extraction_checks = verify_extraction()
print(f"PASS {extraction_checks} Swift declaration extraction fixtures", flush=True)
source = (repo / 'Sources/Fluid/Services/ASRService.swift').read_text()
methods = '\n'.join(declaration(source, 'func', name) for name in (
    'transcribeSamplesForAPI', 'transcribeSamplesForAPIWithLease', 'transcribeFileForAPI',
))
leases = '\n'.join(declaration(source, 'func', name) for name in (
    'acquireExclusiveActivity', 'releaseExclusiveActivity',
))
types = '\n'.join(declaration(source, kind, name) for kind, name in (
    ('enum', 'ASRExclusiveActivity'), ('struct', 'ASRActivityLease'), ('enum', 'ASRActivityError'),
))
executor = declaration(source, 'actor', 'TranscriptionExecutor')
swift = r'''
import Foundation
TYPES
EXECUTOR
func logTranscriptionExecutorPhase(_ phase: String, sessionID: Int?) {}
struct ASRTranscriptionResult { let text: String; let confidence: Float }
final class DictionaryAudioLearningService {
    static let shared = DictionaryAudioLearningService()
    func cancelForRecording() {}
    func activityDidEnd() {}
}
actor Gate {
    var entered = false
    var waiting: CheckedContinuation<Void, Never>?
    func pause() async { entered = true; await withCheckedContinuation { waiting = $0 } }
    func release() { waiting?.resume(); waiting = nil }
}
struct LocalAPIAudioDecoder {
    static var sampleCount = 0
    static var throwDecoding = false
    static func estimatedSampleCount(for url: URL) throws -> Int {
        if throwDecoding { throw CancellationError() }
        return sampleCount
    }
    final class ChunkReader {
        var hasRead = false
        init(fileURL: URL) throws {}
        func nextSamples() async throws -> [Float] {
            if hasRead { return [] }
            hasRead = true
            return [Float](repeating: 0.1, count: LocalAPIAudioDecoder.sampleCount)
        }
    }
}
final class Provider {
    var isReady = true
    var prefersNativeFileTranscription = true
    var finalCalls: [[Float]] = []
    var fileCalls = 0
    var shouldFail = false
    var gate: Gate?
    func transcribeFinal(_ samples: [Float]) async throws -> ASRTranscriptionResult {
        finalCalls.append(samples)
        if let gate { await gate.pause() }
        if shouldFail { throw CancellationError() }
        return ASRTranscriptionResult(text: "sample result", confidence: 0.8)
    }
    func transcribeFile(at url: URL) async throws -> ASRTranscriptionResult {
        fileCalls += 1
        if shouldFail { throw CancellationError() }
        return ASRTranscriptionResult(text: "file result", confidence: 0.8)
    }
}
@MainActor final class ASRService {
    var activeActivityLease: ASRActivityLease?
    var activeExclusiveActivity: ASRExclusiveActivity?
    var deferredMeetingActivityLeaseRelease: ASRActivityLease?
    var providerResetPending = false
    var transcriptionProvider = Provider()
    private let transcriptionExecutor = TranscriptionExecutor()
    var hasCompletedFirstTranscription = false
    var isLoadingModel = true
    var modelPreparationPhase: String? = "loading"
    var prepareFails = false
    var outputCount = 0
    func isMeetingASRClaimBlocking(lease: ASRActivityLease) -> Bool { false }
    func resetTranscriptionProvider() {}
    func ensureAsrReady() async throws { if prepareFails { throw CancellationError() } }
    static func applySpokenPunctuationFormatting(_ text: String) -> String { text }
    static func applyCustomDictionary(_ text: String) -> String { text }
    static func removeFillerWords(_ text: String) -> String { text }
    func recordWordBoostHitIfAny(transcribedText: String) { outputCount += 1 }
    LEASES
    METHODS
}
func check(_ condition: @autoclosure () -> Bool, _ message: String) { if !condition() { fatalError(message) } }
@main struct Runner {
    @MainActor static func main() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data([0]).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        var passes = 0
        for native in [false, true] {
            for count in [0, 1, 15999, 16000, 32000] {
                let service = ASRService()
                service.transcriptionProvider.prefersNativeFileTranscription = native
                LocalAPIAudioDecoder.sampleCount = count
                let (result, originalCount) = try await service.transcribeFileForAPI(url)
                check(originalCount == count, "Response must retain unpadded source duration")
                let expectedFileCalls = native && (count == 0 || count >= 16000) ? 1 : 0
                check(service.transcriptionProvider.fileCalls == expectedFileCalls, "Native route must preserve boundary behavior")
                if count > 0 && expectedFileCalls == 0 {
                    let samples = service.transcriptionProvider.finalCalls
                    check(samples.count == 1 && samples[0].count == max(16000, count), "Samples must be padded to one second exactly once")
                    check(samples[0].prefix(count).allSatisfy { $0 == 0.1 }, "Padding must preserve input samples")
                    check(samples[0].dropFirst(count).allSatisfy { $0 == 0 }, "Padding must append silence")
                    check(result.text == "sample result", "Sample result must be returned")
                }
                check(service.activeActivityLease == nil, "Successful API request must release the lease")
                passes += 1
            }
        }
        for failure in 0..<4 {
            let service = ASRService()
            LocalAPIAudioDecoder.sampleCount = 8000
            LocalAPIAudioDecoder.throwDecoding = failure == 1
            service.prepareFails = failure == 2
            service.transcriptionProvider.shouldFail = failure == 3
            do {
                _ = try await service.transcribeFileForAPI(failure == 0 ? url.appendingPathExtension("missing") : url)
                fatalError("Expected failure \(failure)")
            } catch {}
            check(service.activeActivityLease == nil && service.activeExclusiveActivity == nil, "Failure must release lease")
            LocalAPIAudioDecoder.throwDecoding = false
            passes += 1
        }
        do {
            let service = ASRService()
            let dictation = try service.acquireExclusiveActivity(.dictation)
            do { _ = try await service.transcribeFileForAPI(url); fatalError("Existing recording must reject API") } catch ASRActivityError.activityInProgress(.dictation) {} catch { fatalError("Wrong busy error") }
            check(service.activeActivityLease == dictation, "Rejected request must not release another recording")
            check(service.transcriptionProvider.finalCalls.isEmpty && service.transcriptionProvider.fileCalls == 0, "Rejected request must not call provider")
            service.releaseExclusiveActivity(dictation)
            passes += 1
        }
        do {
            let service = ASRService()
            LocalAPIAudioDecoder.sampleCount = 8000
            let gate = Gate()
            service.transcriptionProvider.gate = gate
            let request = Task { try await service.transcribeFileForAPI(url) }
            while !(await gate.entered) { await Task.yield() }
            check(service.activeExclusiveActivity == .localAPI, "Short upload must keep API ownership during provider work")
            do { _ = try service.acquireExclusiveActivity(.dictation); fatalError("Concurrent recording must be rejected") } catch ASRActivityError.activityInProgress(.localAPI) {} catch { fatalError("Wrong activity error") }
            await gate.release()
            _ = try await request.value
            check(service.activeActivityLease == nil, "Short upload must release ownership when provider completes")
            _ = try service.acquireExclusiveActivity(.dictation)
            passes += 1
        }
        do {
            let service = ASRService()
            _ = try await service.transcribeSamplesForAPI([0.1])
            check(service.transcriptionProvider.finalCalls.first?.count == 16000 && service.activeActivityLease == nil, "Direct samples API still acquires/releases and pads")
            passes += 1
        }
        print("PASS \(passes) API scenarios using production API methods, activity ownership and transcription executor")
    }
}
'''.replace('TYPES', types).replace('EXECUTOR', executor).replace('LEASES', leases).replace('METHODS', methods)
with tempfile.TemporaryDirectory(prefix="fluidvoice-api-regression-") as directory:
    root = Path(directory)
    (root / 'api-proof.swift').write_text(swift)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', '-module-cache-path', str(root/'module-cache'),
                    str(root/'api-proof.swift'), '-o', str(root/'api-proof')], check=True, timeout=120)
    subprocess.run([str(root/'api-proof')], check=True, timeout=30)
