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
(out / 'AdmissionRoute.swift').write_text('import Combine\nimport CryptoKit\nimport Foundation\n' + selection + route + kind + remote)
def declaration(text, marker):
    start = text.index(marker)
    brace = text.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]
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
process = dictation[dictation.index('    struct Result {'):dictation.rindex('\n}')]
(out / 'AdmissionDictation.swift').write_text(route + '\n@MainActor final class DictationPostProcessingService {\n    static let shared = DictationPostProcessingService()\n' + interactive + process + '\n}\n')
errors = Path('Sources/Fluid/ContentView.swift').read_text()
errors = errors[errors.index('nonisolated enum AIProcessingError:'):errors.index('nonisolated enum DictationAIFailurePresentationPolicy {')]
(out / 'AdmissionErrors.swift').write_text('import Foundation\n' + errors)
PY
xcrun swiftc -parse-as-library -swift-version 5 -D PICHI_CREDENTIAL_TEST_BACKEND_ONLY \
    -module-cache-path "$task_test_dir/AdmissionModuleCache" \
    "$task_test_dir/ModelRepository.swift" "$task_test_dir/AdmissionMetadata.swift" \
    "$task_test_dir/AdmissionCredentials.swift" "$task_test_dir/AdmissionRoute.swift" "$task_test_dir/AdmissionCommand.swift" \
    "$task_test_dir/AdmissionTemplateUI.swift" \
    "$task_test_dir/AdmissionDictation.swift" "$task_test_dir/AdmissionErrors.swift" \
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
    Tests/MeetingSummaryAdmissionTests.swift -o "$task_test_dir/admission-tests"
task_source_dirty=1
if [ -z "$(git status --porcelain=v1)" ]; then task_source_dirty=0; fi
PICHI_ADMISSION_REPORT_PATH="$task_output_dir/admission-report.json" \
PICHI_ADMISSION_SOURCE_REVISION="$(git rev-parse HEAD)" \
PICHI_ADMISSION_SOURCE_DIRTY="$task_source_dirty" "$task_test_dir/admission-tests"
