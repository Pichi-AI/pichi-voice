#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/sensitive-policy-settings"
mkdir -p "$task_test_dir"
task_artifact="${PICHI_SENSITIVE_TOPIC_ARTIFACT:-}"
if [[ -z "$task_artifact" ]]; then
    python3 tools/sensitive_topic_classifier.py \
        --cases Tests/Fixtures/SensitiveTopics/synthetic-exploratory-v1.jsonl \
        --output-directory "$task_test_dir/artifact"
    task_artifact="$task_test_dir/artifact/sensitive-topics-v1.json"
fi
cat > "$task_test_dir/Synthetic.swift" <<'SWIFT'
import Foundation
import Combine
nonisolated enum AppBrand {
    static let storageNamespace = "synthetic-sensitive-policy-" + UUID().uuidString
    static let keychainService = "synthetic-unused-service"
    static let applicationSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(storageNamespace)
}
nonisolated struct AccountIdentity: Equatable, Sendable {
    let issuer: String; let subject: String; let internalUserID: String
    var storageComponents: [String] { [issuer, subject, internalUserID] }
}
nonisolated struct AccountContext: Equatable, Sendable {
    let identity: AccountIdentity; let organizationID: String?; let workspaceID: String?; let generation: UUID
}
nonisolated enum AccountError: Error { case invalidAccount, isolationRequired }
SWIFT
python3 -S - "$task_test_dir/SettingsStoreShell.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Persistence/SettingsStore.swift').read_text()
start = source.index('    func boundToCurrentPrivateProfile() -> SettingsStore {')
end = source.index('\n    #if os(macOS)', start)
# Keep the production binding method unchanged. The shell supplies only the
# ObservableObject/defaults shape, excluding unrelated application initialization.
Path(sys.argv[1]).write_text('import Foundation\nimport Combine\n@MainActor final class SettingsStore: ObservableObject {\n'
    'let defaults: UserDefaults\ninit(defaults: UserDefaults, initializeDesktop: Bool = false) { self.defaults = defaults }\n'
    + source[start:end] + '\n}\n')
PY
task_morphology_dir="$task_test_dir/morphology"
swift build --package-path Vendor/RussianMorphology --scratch-path "$task_morphology_dir" --jobs 2
task_products="$task_morphology_dir/out/Products/Debug"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    -I "$task_products" -L "$task_products" -lPichiRussianMorphology -lc++ \
    -Xcc "-fmodule-map-file=$task_morphology_dir/out/Intermediates.noindex/GeneratedModuleMaps/CRussianMorphology.modulemap" \
    -Xcc "-I$PWD/Vendor/RussianMorphology/Sources/CRussianMorphology/include" \
    "$task_test_dir/Synthetic.swift" "$task_test_dir/SettingsStoreShell.swift" \
    Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Sources/Fluid/Services/Privacy/TranscriptTextRedacting.swift \
    Sources/Fluid/Services/Privacy/TranscriptSensitiveDictionary.swift \
    Sources/Fluid/Services/Privacy/SensitiveBusinessGroupCatalog.swift \
    Sources/Fluid/Services/Privacy/SensitiveTopicClassifier.swift \
    Sources/Fluid/Persistence/SettingsStore+SensitiveDataDictionary.swift \
    Tests/Standalone/SensitivePolicySettingsTests.swift -o "$task_test_dir/tests"
PICHI_PRIVATE_SETTINGS_DOMAIN_MANIFEST="$task_test_dir/domains.json" "$task_test_dir/tests" "$task_artifact"
python3 -S Tests/Support/remove_empty_synthetic_preferences.py "$task_test_dir/domains.json"
