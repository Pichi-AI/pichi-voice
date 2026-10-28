#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/provider-dictation-capture-options-tests"
mkdir -p "$task_test_dir"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# Compile the actual provider admission declarations and effective configuration methods.
# Native speech/model neighbors are inert. No UserDefaults, weights, audio, UI or network.
python3 -S - "$task_test_dir/ProviderProjections.swift" <<'PYTHON'
from pathlib import Path
import sys

root = Path('Sources/Fluid/Services')
def source(name):
    return (root / (name + '.swift')).read_text()
def capture_region(text):
    start = text.index('    // MARK: - Dictation capture configuration')
    end = text.index('    // MARK: - ', start + 12)
    return text[start:end]
def method(text, signature):
    start = text.index(signature)
    opening = text.index('{', start)
    depth = 1
    for position in range(opening + 1, len(text)):
        if text[position] == '{': depth += 1
        elif text[position] == '}': depth -= 1
        if depth == 0: return text[start:position + 1]
    raise AssertionError('Unbalanced source method: ' + signature)
def remainder(text):
    return text.replace(capture_region(text), '')

whisper = source('WhisperProvider')
apple = source('AppleSpeechProvider')
nemotron = source('NemotronProvider')
cohere = source('ExternalCoreMLTranscriptionProvider')
# Guard the adapter call paths as well as executing their configuration functions.
assert 'SettingsStore.shared.' not in remainder(whisper)
assert 'SettingsStore.shared.' not in remainder(apple)
assert 'SettingsStore.shared.' not in remainder(nemotron)
assert 'let targetModel = self.selectedModel' in whisper
assert 'let loadedModelURL = self.modelURL' in whisper
assert 'self.resolvedLanguageCode(explicit: languageCode, model: active.speechModel)' in whisper
assert 'self.updateRecognizerIfNeeded()' in method(apple, '    func transcribe(')
for signature in ['    func prepare(', '    func transcribeStreaming(', '    func transcribeFinal(', '    private func transcribeSinglePass(']:
    assert 'self.applySelectedLanguage(to: manager)' in method(nemotron, signature)
assert remainder(cohere).count('SettingsStore.shared.') == 2 # Import persistence and artifact resolver only.
assert 'self.resolvedArtifactsDirectory(for: model, spec: spec)' in method(cohere, '    func prepare(')
for signature in ['    func transcribeStreaming(', '    func transcribeFinal(', '    func transcribeFile(']:
    assert 'self.coherePromptIDsForCurrentLanguage()' in method(cohere, signature)

parts = ['import Foundation\n']
parts += ['''final class WhisperProvider {
    private let overriddenModelDirectory: URL?
    private let modelOverride: SettingsStore.SpeechModel?
    private let languageCodeOverride: String?
    private let useAutomaticLanguageDetection: Bool
    init(model: SettingsStore.SpeechModel? = nil, language: String? = nil, automatic: Bool = false, directory: URL? = nil) {
        self.modelOverride = model; self.languageCodeOverride = language
        self.useAutomaticLanguageDetection = automatic; self.overriddenModelDirectory = directory
    }
    var observedModel: SettingsStore.SpeechModel { self.selectedModel }
    var observedDirectory: URL { self.modelDirectory }
''', capture_region(whisper), '}\n']
parts += ['''final class AppleSpeechProvider {
    private var recognizer: SFSpeechRecognizer?
    private var recognizerLocaleIdentifier: String?
    func observedRecognizer() -> SFSpeechRecognizer? { self.updateRecognizerIfNeeded() }
''', capture_region(apple), method(apple, '    private func updateRecognizerIfNeeded('), '}\n']
parts += ['''final class NemotronProvider {
    private var activeLanguageCode: String?
    init(activeLanguage: String? = nil) { self.activeLanguageCode = activeLanguage }
    func apply(to manager: NemotronStreamingAsrManager) async throws { try await self.applySelectedLanguage(to: manager) }
''', capture_region(nemotron), method(nemotron, '    private func applySelectedLanguage('),
    method(nemotron, '    private static func makeError('), '}\n']
parts += ['''final class ExternalCoreMLTranscriptionProvider {
    private let modelOverride: SettingsStore.SpeechModel?
    private var coherePromptTemplate: [Int] = [100, 201, 999]
    private var cohereLanguageTokenIDs: [SettingsStore.CohereLanguage: Int] = [.russian: 201, .english: 202, .german: 203]
    init(model: SettingsStore.SpeechModel? = nil) { self.modelOverride = model }
    var observedModel: SettingsStore.SpeechModel { self.selectedModel }
    var observedPrompt: [Int] { self.coherePromptIDsForCurrentLanguage() }
    var observedDirectory: URL? {
        guard let spec = self.selectedModel.externalCoreMLSpec else { return nil }
        return self.resolvedArtifactsDirectory(for: self.selectedModel, spec: spec)
    }
''', capture_region(cohere), method(cohere, '    private static func artifactsDirectory('),
    method(cohere, '    private func coherePromptIDsForCurrentLanguage('), method(cohere, '    private static func makeError('), '}\n']
Path(sys.argv[1]).write_text('\n'.join(parts))
print('Provider adapter call-path guards passed (4 actual sources).')
PYTHON
run_case() {
    task_case="$1"
    shift
    mkdir -p "$task_test_dir/$task_case"
    xcrun swiftc -swift-version 5 -parse-as-library "$@" \
        -module-cache-path "$task_test_dir/$task_case/ModuleCache" \
        "$task_test_dir/ProviderProjections.swift" Tests/ProviderDictationCaptureOptionsTests.swift \
        -o "$task_test_dir/$task_case/tests"
    "$task_test_dir/$task_case/tests"
}
run_case default
if xcrun swiftc -help | rg -q -- '-default-isolation'; then
    run_case main-actor -default-isolation MainActor
fi
