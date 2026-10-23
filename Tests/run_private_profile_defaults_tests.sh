#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="${PICHI_PRIVATE_SETTINGS_TEST_OUTPUT_DIR:-$PWD/.build/private-settings-tests}"
mkdir -p "$task_test_dir"
cat > "$task_test_dir/Synthetic.swift" <<'SWIFT'
import Foundation
nonisolated enum PichiLocalization { static func text(_ key: String) -> String { key }; static func format(_ value: String, _ arguments: CVarArg...) -> String { String(format: value, arguments: arguments) } }
nonisolated enum AppBrand {
    static let storageNamespace = "synthetic-private-settings-" + UUID().uuidString
    static let keychainService = "synthetic-unused-service"
    static let keychainAccount = "synthetic-unused-account"
    static let applicationSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(storageNamespace)
}
nonisolated struct AccountIdentity: Equatable, Sendable { let issuer: String; let subject: String; let internalUserID: String }
nonisolated struct AccountContext: Equatable, Sendable { let identity: AccountIdentity; let organizationID: String?; let workspaceID: String?; let generation: UUID }
nonisolated enum AccountError: Error { case invalidAccount, isolationRequired }
SWIFT
python3 -S - "$task_test_dir" <<'PYTHON'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Persistence/SettingsStore.swift').read_text()
start = source.index('    var onboardingCurrentStep: Int {')
end = source.index('    var onboardingAISkipped:', start)
(out := Path(sys.argv[1]) / 'DesktopOnboardingStepProjection.swift').write_text(
    'import Foundation\nimport Combine\nfinal class DesktopOnboardingStepProjection: ObservableObject {\n'
    'let defaults: UserDefaults; init(defaults: UserDefaults) { self.defaults = defaults }\n'
    'enum Keys { static let onboardingCurrentStep = "OnboardingCurrentStep" }\n'
    + source[start:end] + '}\n')
PYTHON
run_case() {
    task_case="$1"
    shift
    mkdir -p "$task_test_dir/$task_case"
    xcrun swiftc -swift-version 5 -D PICHI_CREDENTIAL_TEST_BACKEND_ONLY "$@" -module-cache-path "$task_test_dir/$task_case/ModuleCache" \
        Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Account/PrivateProfileDefaults.swift \
        Sources/Fluid/Persistence/KeychainService.swift Sources/Fluid/Services/CloudTextProvider.swift \
        Sources/Fluid/Services/ModelTemperatureSupport.swift Sources/Fluid/UI/AISettings/ProviderModelVerificationStore.swift \
        "$task_test_dir/Synthetic.swift" "$task_test_dir/DesktopOnboardingStepProjection.swift" \
        Tests/Standalone/PrivateProfileDefaultsTests.swift -o "$task_test_dir/$task_case/tests"
    "$task_test_dir/$task_case/tests"
}
run_case default
if xcrun swiftc -help | rg -q -- '-default-isolation'; then
    run_case main-actor -default-isolation MainActor
fi
