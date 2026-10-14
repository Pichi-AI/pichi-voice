#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_output_dir="${PICHI_COMMAND_CATALOG_TEST_OUTPUT_DIR:-$PWD/.build/command-model-catalog-tests}"
mkdir -p "$task_output_dir"
task_test_dir=$(mktemp -d "$task_output_dir/run.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT
# Keep the actual model metadata/key rules; network model fetching is unavailable in this harness.
sed '/^    \/\/ MARK: - Fetch Models from API/,$d' Sources/Fluid/Services/ModelRepository.swift > "$task_test_dir/ModelRepository.swift"
echo '}' >> "$task_test_dir/ModelRepository.swift"
xcrun swiftc -parse-as-library \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ModelRepository.swift" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/CloudTextProvider.swift \
    Sources/Fluid/Services/LocalTextModelCatalog.swift \
    Sources/Fluid/UI/ModelDisplayName.swift \
    Sources/Fluid/Views/CommandModelCatalog.swift \
    Sources/Fluid/Persistence/SettingsStore+CommandMode.swift \
    Tests/CommandModelCatalogTests.swift \
    -o "$task_test_dir/catalog-tests"
"$task_test_dir/catalog-tests"

# The second executable runs actual credential ownership, catalog verification,
# summary resolution and HTTP transport against injected storage/URLProtocol.
# Only Settings metadata and unrelated app services are inert doubles.
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import os
import subprocess
import sys
out = Path(sys.argv[1])
fixture = Path('Tests/CommandModelCatalogTests.swift').read_text().split('@main enum CommandModelCatalogTests {', 1)[0]
marker = '    var credentials: [String: String] = [:]'
assert fixture.count(marker) == 1
fixture = fixture.replace(marker, marker + '\n    let keychain: KeychainService\n    init(keychain: KeychainService) { self.keychain = keychain }')
fixture = fixture.replace('final class SettingsStore: ObservableObject {', 'final class SettingsStore: ObservableObject {\n    private static var sharedStorage: SettingsStore?\n    static var shared: SettingsStore { get { self.sharedStorage! } set { self.sharedStorage = newValue } }\n    let enableAIStreaming = false')
assert fixture.count('    var loadedProviderAPIKeys: [String: String]? { self.credentials }') == 1
fixture = fixture.replace('    var loadedProviderAPIKeys: [String: String]? { self.credentials }\n', '')
fixture = fixture.replace('return self.credentials', 'return self.keychain.cachedKeys ?? self.credentials')
(out / 'AdmissionMetadata.swift').write_text(fixture)
settings = Path('Sources/Fluid/Persistence/SettingsStore.swift').read_text()
getter_start = settings.index('    var loadedProviderAPIKeys:')
getter_end = settings.index('\n', getter_start)
key_start = settings.index('    func getAPIKey(for providerID: String)')
key_end = settings.index('\n    }', key_start) + len('\n    }')
(out / 'AdmissionCredentials.swift').write_text('extension SettingsStore {\n' + settings[getter_start:getter_end] + '\n' + settings[key_start:key_end] + '\n}\n')
def declaration(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
source = Path('Sources/Fluid/Services/Meeting/MeetingSummaryProvider.swift').read_text()
baseline = os.environ.get('PICHI_SUMMARY_ADMISSION_BASELINE_REF')
if baseline:
    source = subprocess.check_output(['git', 'show', baseline + ':Sources/Fluid/Services/Meeting/MeetingSummaryProvider.swift'], text=True)
selection = source[source.index('nonisolated struct MeetingSummarySelection:'):source.index('/// The summary model that runs')]
route = source[source.index('nonisolated struct MeetingSummaryRoute {'):source.index('/// Uses a dedicated session')]
# Grounded generation is tested elsewhere; this executable tests the exact
# resolver plus actual legacy RemoteService/LLMClient request admission.
route = route[:route.index('    /// Provider selection is shared;')] + '}\n'
remote = source[source.index('/// Uses a dedicated session'):]
kind_source = Path('Sources/Fluid/Services/Meeting/MeetingSummaryController.swift').read_text()
kind = kind_source[kind_source.index('nonisolated enum MeetingSummaryKind:'):kind_source.index('nonisolated enum MeetingSummaryInput {')]
# The prompt uses the controller's pure source-language contract. Keep the
# actual declaration without linking capture, persistence or model services.
language_input = ('nonisolated enum MeetingSummaryInput {\n'
    + declaration(kind_source, '    static func transcriptLanguageName(') + '\n}\n')
(out / 'AdmissionRoute.swift').write_text('import Combine\nimport CryptoKit\nimport Foundation\n' + selection + route + kind + language_input + remote)
# Exercise the current production prompt even when admission uses an earlier
# resolver as its negative control. This fixture performs no HTTP or inference.
current_prompt = declaration(Path('Sources/Fluid/Services/Meeting/MeetingSummaryProvider.swift').read_text(), '    static func prompt(for kind:')
(out / 'LanguageProjectionTests.swift').write_text('import Foundation\n' + kind + language_input
    + '\nnonisolated enum MeetingSummaryRemotePromptProjection {\n' + current_prompt + '\n}\n' + '''
@main enum LanguageProjectionTests {
    static func main() {
        var checks = 0
        func check(_ value: Bool, _ message: String) {
            precondition(value, message)
            checks += 1
        }
        check(MeetingSummaryInput.transcriptLanguageName(" RU ") == "Russian (ru)", "Production metadata normalizes the Russian source language")
        check(MeetingSummaryRemotePromptProjection.prompt(for: .executive, languageCode: "ru").contains("Required output language: Russian (ru)"), "Production template prompt retains Russian language guidance")
        for code in ["auto", "und", "mul", "not-an-iso-code"] {
            check(MeetingSummaryInput.transcriptLanguageName(code) == nil
                && MeetingSummaryRemotePromptProjection.prompt(for: .executive, languageCode: code).contains("Infer the output language from the spoken transcript text"), "Unknown metadata must not choose a default language")
        }
        let custom = MeetingSummaryRemotePromptProjection.prompt(for: .custom, customInstructions: "Write in English.", languageCode: "ru")
        check(custom.contains("Default output language: Russian (ru)") && custom.contains("use that requested language") && custom.hasSuffix("Write in English."), "Explicit custom language instructions retain precedence")
        print("Template language projection: \\(checks) checks passed")
    }
}
''')
# Exercise the restored UI's exact Generate click and fresh route resolution,
# without creating a SwiftUI view or an application service. Effects are captured
# by an inert controller before the same explicit, intercepted transport is used.
ui = Path('Sources/Fluid/UI/MeetingSummaryView.swift').read_text()
preferences = declaration(Path('Sources/Fluid/Services/Meeting/MeetingSummaryProvider.swift').read_text(), 'final class MeetingSummaryPreferences:')
generate = declaration(ui, 'private func generate()').replace('private ', '', 1)
if os.environ.get('PICHI_TEMPLATE_UI_ADMISSION_NEGATIVE_CACHE_ONLY') == '1':
    assert generate.count('self.resolveRoute()') == 1
    generate = generate.replace('self.resolveRoute()', '// Negative control: reuse the stale displayed route')
resolve = declaration(ui, 'private func resolveRoute()').replace('private ', '', 1)
(out / 'AdmissionTemplateUI.swift').write_text('import Combine\nimport Foundation\n@MainActor\n' + preferences
    + '\n@MainActor extension TemplateSummaryAdmissionOwner {\n' + generate + '\n' + resolve + '\n}\n')
command = Path('Sources/Fluid/Services/CommandModeService.swift').read_text()
assert 'init(llmClient: LLMClient = .shared)' in command and 'self.llmClient = llmClient' in command
command_baseline = os.environ.get('PICHI_COMMAND_ADMISSION_BASELINE_REF')
if command_baseline:
    command = subprocess.check_output(['git', 'show', command_baseline + ':Sources/Fluid/Services/CommandModeService.swift'], text=True)
    # Keep the baseline admission unchanged; use the current explicit transport
    # injection so a negative control cannot escape the fixture URLSession.
    assert command.count('LLMClient.shared.call(config)') == 1
    command = command.replace('LLMClient.shared.call(config)', 'self.llmClient.call(config)')
assert 'self.llmClient.call(config)' in command
client = Path('Sources/Fluid/Services/LLMClient.swift').read_text()
injected = client[client.index('    init(session: URLSession,'):client.index('    // MARK: - Response Types')]
for assignment in ['self.session = session', 'self.localSession = session', 'self.cloudSession = session']:
    assert assignment in injected
assert 'self.localSession.configuration.copy()' in client
command = command[command.index('    private struct LLMResponse {'):command.rindex('\n}')]
# Access is widened only inside the isolated owner so its actual admission,
# configuration, transport and result handling can be exercised together.
command = command.replace('private struct LLMResponse', 'struct LLMResponse', 1).replace('private func callLLM', 'func callLLM', 1)
(out / 'AdmissionCommand.swift').write_text('import Foundation\n@MainActor extension CommandAdmissionOwner {\n' + command + '\n}\n')
dictation = Path('Sources/Fluid/Services/DictationPostProcessingService.swift').read_text()
normal_baseline = os.environ.get('PICHI_NORMAL_DICTATION_ADMISSION_BASELINE_REF')
if normal_baseline:
    dictation = subprocess.check_output(['git', 'show', normal_baseline + ':Sources/Fluid/Services/DictationPostProcessingService.swift'], text=True)
dictation_baseline = os.environ.get('PICHI_DICTATION_ADMISSION_BASELINE_REF')
if dictation_baseline:
    dictation = subprocess.check_output(['git', 'show', dictation_baseline + ':Sources/Fluid/Services/DictationPostProcessingService.swift'], text=True)
    # Baseline admission/route/gates remain verbatim; only its HTTP test seam is
    # backported, so the negative control cannot use a default network client.
    signature = 'func process(_ inputText: String, dictationSlot: SettingsStore.DictationShortcutSlot = .primary)'
    assert dictation.count(signature) == 1 and dictation.count('LLMClient.shared.call(config)') == 1
    dictation = dictation.replace(signature, signature[:-1] + ', client: LLMClient = .shared)')
    dictation = dictation.replace('LLMClient.shared.call(config)', 'client.call(config)')
route = dictation[:dictation.index('@MainActor\nfinal class DictationPostProcessingService')]
interactive = dictation[dictation.index('    nonisolated static func configureInteractiveLocalRequest('):dictation.index('    /// A tiny synthetic inference')]
prewarm = declaration(dictation, '    func prewarmLocalModel(')
process = dictation[dictation.index('    struct Result {'):dictation.rindex('\n}')]
(out / 'AdmissionDictation.swift').write_text(route + '\n@MainActor final class DictationPostProcessingService {\n    static let shared = DictationPostProcessingService()\n' + interactive + prewarm + '\n' + process + '\n}\n')
normal = Path('Sources/Fluid/ContentView.swift').read_text()
snapshot = Path('Sources/Fluid/Services/DictationStopSnapshot.swift').read_text()
services = Path('Sources/Fluid/Services/AppServices.swift').read_text()
if normal_baseline:
    normal = subprocess.check_output(['git', 'show', normal_baseline + ':Sources/Fluid/ContentView.swift'], text=True)
    snapshot = subprocess.check_output(['git', 'show', normal_baseline + ':Sources/Fluid/Services/DictationStopSnapshot.swift'], text=True)
    services = subprocess.check_output(['git', 'show', normal_baseline + ':Sources/Fluid/Services/AppServices.swift'], text=True)
processor = declaration(normal, '    private func processTextWithAIMetrics(').replace('private ', '', 1)
if normal_baseline:
    # Only the current explicit test seam is backported to the negative source.
    marker = 'stopSnapshot: DictationStopSnapshot? = nil'
    assert processor.count(marker) == 1 and processor.count('LLMClient.shared.call(') == 3
    processor = processor.replace(marker, marker + ',\n        client: LLMClient = .shared')
    processor = processor.replace('LLMClient.shared.call(', 'client.call(')
assert processor.count('client.call(') == 3 and 'LLMClient.shared.call(' not in processor
plain_processor = declaration(normal, '    private func processTextWithAI(').replace('private ', '', 1)
assert plain_processor.count('benchmarkID: benchmarkID') == 1
plain_processor = plain_processor.replace('benchmarkID: benchmarkID', 'benchmarkID: benchmarkID, client: self.llmClient')
manual = declaration(normal, '    private func callOpenAIChat()').replace('private ', '', 1)
reprocess_start = normal.index('    private func reprocessDictationText(')
reprocess_start = normal.index('        let shouldUseAI = DictationAIPostProcessingGate.isConfigured(for: .primary', reprocess_start)
reprocess_end = normal.index('        finalText = ASRService.applyDictationLiteralFormatting(', reprocess_start)
reprocess = normal[reprocess_start:reprocess_end]
marker = 'dictationSlot: .primary\n                )'
assert reprocess.count(marker) == 1
reprocess = reprocess.replace(marker, 'dictationSlot: .primary, client: self.llmClient\n                )')
reprocess_wrapper = '''
    func finishReprocess(_ normalizedTranscribedText: String) async -> String {
        let appInfo = self.getCurrentAppInfo()
        var finalText = normalizedTranscribedText
        var aiFallbackReason: String?
        var postProcessingModel: String?
        var aiProcessingDurationMilliseconds: Int?
        var aiTokensPerSecond: Double?
        var aiFallbackNotificationError: String?
'''
block_start = normal.index('        let practiceModelID = route == .onboardingSandbox')
block_end = normal.index('        // Normalize literal command and mention syntax', block_start)
post_asr = normal[block_start:block_end]
assert post_asr.count('stopSnapshot: stopSnapshot') == 1
post_asr = post_asr.replace('stopSnapshot: stopSnapshot', 'stopSnapshot: stopSnapshot, client: self.llmClient')
wrapper = '''
    func finish(_ normalizedTranscribedText: String, snapshot: DictationStopSnapshot?, slot: SettingsStore.DictationShortcutSlot = .primary) async -> String {
        let stopSnapshot = snapshot
        let activeDictationSlot: SettingsStore.DictationShortcutSlot? = slot
        let route = DictationOutputRoute.normal
        let appInfo = snapshot?.appInfo ?? self.getCurrentAppInfo()
        let sendsExistingDraft = false
        let expectedOverlayLifecycleID: UInt64 = 1
        let pipelineID = "synthetic-normal-dictation"
        let promptOverride: String? = nil
        var finalText = normalizedTranscribedText
        var postProcessingModel: String?
        var aiTokensPerSecond: Double?
        var aiFallbackReason: String?
        var aiFallbackNotificationError: String?
        var aiProcessingDurationMilliseconds: Int?
'''
policies = declaration(normal, 'nonisolated enum DictationAIFailurePresentationPolicy {') + '\n' + declaration(normal, 'nonisolated enum DictationStreamingFallbackPolicy {')
(out / 'AdmissionNormalProcessor.swift').write_text('import Foundation\n' + policies + '\n@MainActor extension NormalDictationAdmissionOwner {\n'
    + processor + '\n' + plain_processor + '\n' + manual + '\n' + wrapper + post_asr + '\n        return finalText\n    }\n'
    + reprocess_wrapper + reprocess + '\n        return finalText\n    }\n}\n')
(out / 'AdmissionStopSnapshot.swift').write_text(snapshot)
selected_start = services.index('                selectedRoute: { [weak self] in')
selected_start = services.index('\n', selected_start) + 1
selected_end = services.index('\n                },\n                canWarm:', selected_start)
(out / 'AdmissionWarmSelection.swift').write_text('import Foundation\n@MainActor extension NormalDictationWarmAdmissionOwner {\n'
    + '    func selectedRoute() -> DictationProviderRoute? {\n        let operation: () -> DictationProviderRoute? = { [weak self] in\n'
    + services[selected_start:selected_end] + '\n        }\n        return operation()\n    }\n}\n')
residency = Path('Sources/Fluid/Services/LocalAIModelResidency.swift').read_text()
policy = declaration(residency, 'nonisolated final class LocalAIModelResidencyPolicy:')
ready_start = residency.index('nonisolated enum LocalAIModelResidencyTransport {')
ready_end = residency.index('    /// Ordinary selection changes', ready_start)
running = declaration(residency, '    private static func runningModels(')
assert running.count('let configuration = URLSessionConfiguration.ephemeral') == 1
running = running.replace('let configuration = URLSessionConfiguration.ephemeral', 'let configuration = NormalDictationHTTPConfiguration.make()')
(out / 'AdmissionResidency.swift').write_text('import CryptoKit\nimport Foundation\n' + policy + '\n' + residency[ready_start:ready_end]
    + declaration(residency, '    private static func matches(') + '\n' + running + '\n}\n')
errors = Path('Sources/Fluid/ContentView.swift').read_text()
errors = errors[errors.index('nonisolated enum AIProcessingError:'):errors.index('nonisolated enum DictationAIFailurePresentationPolicy {')]
(out / 'AdmissionErrors.swift').write_text('import Foundation\n' + errors)
PY
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/AdmissionModuleCache" \
    "$task_test_dir/LanguageProjectionTests.swift" -o "$task_test_dir/language-tests"
"$task_test_dir/language-tests"
xcrun swiftc -parse-as-library -swift-version 5 -D PICHI_CREDENTIAL_TEST_BACKEND_ONLY \
    -module-cache-path "$task_test_dir/AdmissionModuleCache" \
    "$task_test_dir/ModelRepository.swift" "$task_test_dir/AdmissionMetadata.swift" \
    "$task_test_dir/AdmissionCredentials.swift" "$task_test_dir/AdmissionRoute.swift" "$task_test_dir/AdmissionCommand.swift" \
    "$task_test_dir/AdmissionTemplateUI.swift" \
    "$task_test_dir/AdmissionDictation.swift" "$task_test_dir/AdmissionErrors.swift" \
    "$task_test_dir/AdmissionStopSnapshot.swift" "$task_test_dir/AdmissionNormalProcessor.swift" \
    "$task_test_dir/AdmissionWarmSelection.swift" "$task_test_dir/AdmissionResidency.swift" Tests/NormalDictationAdmissionSupport.swift \
    Sources/Fluid/Services/DictationPromptRequest.swift Sources/Fluid/Services/DictationAIPostProcessingGate.swift \
    Sources/Fluid/Services/LocalAPI/LocalAPIModels.swift Sources/Fluid/Services/LocalAPI/InferenceAPIController.swift \
    Tests/LocalAPICredentialAdmissionSupport.swift \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Persistence/KeychainService.swift \
    Sources/Fluid/Persistence/SettingsStore+CommandMode.swift \
    Sources/Fluid/Services/CloudTextProvider.swift \
    Sources/Fluid/Services/LocalTextModelCatalog.swift \
    Sources/Fluid/Services/ModelTemperatureSupport.swift \
    Sources/Fluid/Services/OllamaChatAdapter.swift \
    Sources/Fluid/Services/LLMClient.swift \
    Sources/Fluid/Services/ThinkingParsers.swift \
    Sources/Fluid/UI/ModelDisplayName.swift Sources/Fluid/Views/CommandModelCatalog.swift \
    Tests/MeetingSummaryAdmissionTests.swift Tests/NormalDictationCredentialTests.swift -o "$task_test_dir/admission-tests"
task_source_dirty=1
if [ -z "$(git status --porcelain=v1)" ]; then task_source_dirty=0; fi
PICHI_ADMISSION_REPORT_PATH="$task_output_dir/admission-report.json" \
PICHI_ADMISSION_SOURCE_REVISION="$(git rev-parse HEAD)" \
PICHI_ADMISSION_SOURCE_DIRTY="$task_source_dirty" "$task_test_dir/admission-tests"
