#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/apple-speech-lifecycle-tests"
mkdir -p "$task_test_dir"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# Execute the actual providers' admission, transcription and ownership code with
# inert speech/audio neighbors. No recognizer, authorization, audio, model or UI runs.
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
root = Path('Sources/Fluid/Services')
legacy = (root / 'AppleSpeechProvider.swift').read_text()
analyzer = (root / 'AppleSpeechAnalyzerProvider.swift').read_text()
def method(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    for position in range(opening + 1, len(text)):
        if text[position] == '{': depth += 1
        elif text[position] == '}': depth -= 1
        if depth == 0: return text[start:position + 1]
    raise AssertionError(signature)
start = legacy.index('    // MARK: - Dictation capture configuration')
end = legacy.index('    // MARK: - Provider initialization', start)
legacy_config = legacy[start:end]
start = analyzer.index('    private let captureLock')
end = analyzer.index('    /// Thread-safe cache', start)
analyzer_config = analyzer[start:end]
parts = ['import Foundation\n']
parts += ['''final class AppleSpeechProvider {
    var isAvailable: Bool { true }
    private var recognizer: SFSpeechRecognizer?
    private var recognizerLocaleIdentifier: String?
    var observedLocale: String { self.selectedSpeechLocale.identifier }
''', legacy_config, method(legacy, '    func transcribe('), method(legacy, '    private func updateRecognizerIfNeeded('),
'''    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? { AVAudioPCMBuffer() }
}\n''', legacy[legacy.index('// MARK: - Legacy recognition ownership'):]]
parts += ['''final class AppleSpeechAnalyzerProvider {
    var isReady = true
    var analyzerFormat: AVAudioFormat? = AVAudioFormat()
    var preparedLocale: Locale? = nil
    private var converter: BufferConverter? = nil
    var observedLocale: String { self.selectedSpeechLocale().identifier }
''', analyzer_config, method(analyzer, '    func transcribe('), method(analyzer, '    private func selectedSpeechLocale('),
'''    private func createPCMBuffer(from samples: [Float]) -> AVAudioPCMBuffer? { AVAudioPCMBuffer() }
}\n''', analyzer[analyzer.index('// MARK: - Analyzer worker ownership'):analyzer.index('// MARK: - Buffer Converter')]]
(out / 'ProviderProjections.swift').write_text('\n'.join(parts))
(out / 'SDKStubs.swift').write_text('''import Foundation
nonisolated struct ASRTranscriptionResult: Sendable { let text: String; let confidence: Float }
struct ModelPreparationProgress {
    static let preparingDownload = Self(), optimizing = Self(), loading = Self()
    static func downloading(_ value: Double) -> Self { Self() }
}
protocol TranscriptionProvider {
    @MainActor func beginAdmittedTranscription(leaseID: UUID) throws
    @MainActor func endAdmittedTranscription(leaseID: UUID) async
}
final class SettingsStore { static let shared = SettingsStore(); var selectedAppleSpeechLocale = Locale(identifier: "en-US") }
final class DebugLogger {
    static let shared = DebugLogger()
    func debug(_ message: String, source: String) {}
    func info(_ message: String, source: String) {}
    func warning(_ message: String, source: String) {}
}
''')
PY
run_case() {
    task_case="$1"
    shift
    mkdir -p "$task_test_dir/$task_case"
    xcrun swiftc -swift-version 5 -parse-as-library "$@" \
        -module-cache-path "$task_test_dir/$task_case/ModuleCache" \
        "$task_test_dir/ProviderProjections.swift" Tests/AppleSpeechLifecycleTests.swift \
        -o "$task_test_dir/$task_case/tests"
    "$task_test_dir/$task_case/tests"
    # Full production files against the actual local Speech/AVFoundation SDK.
    # Type checking alone never creates a recognizer or requests authorization.
    xcrun swiftc -swift-version 5 -typecheck -target arm64-apple-macos26.0 "$@" \
        -module-cache-path "$task_test_dir/$task_case/ModuleCache" \
        "$task_test_dir/SDKStubs.swift" \
        Sources/Fluid/Services/AppleSpeechProvider.swift \
        Sources/Fluid/Services/AppleSpeechAnalyzerProvider.swift
    echo "Apple Speech actual-SDK type check passed ($task_case)."
}
run_case default
if xcrun swiftc -help | rg -q -- '-default-isolation'; then
    run_case main-actor -default-isolation MainActor
fi
