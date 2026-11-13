#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="${PICHI_CREDENTIAL_TEST_OUTPUT_DIR:-$PWD/.build/credential-startup-tests}"
mkdir -p "$task_test_dir"
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import re
import sys
out = Path(sys.argv[1])
source = Path('Tests/FluidDictationIntegrationTests/KeychainServiceCacheTests.swift').read_text()
assert source.count('@testable import FluidVoice_Debug') == 1
(out / 'CacheTests.swift').write_text(source.replace('@testable import FluidVoice_Debug', 'import Foundation'))
names = re.findall(r'^    func (test\w+)\(\)(?: throws)? \{', source, re.M)
assert len(names) == 26, names
(out / 'main.swift').write_text('import XCTest\nimport Foundation\nlet suite = KeychainServiceCacheTests.defaultTestSuite\nprecondition(suite.testCaseCount == 26, "Native XCTest discovery must include every synthetic regression")\nsuite.run()\nguard let run = suite.testRun, run.executionCount == 26, run.failureCount == 0 else { exit(1) }\nprint("PASS: 26 exact native Keychain cache/startup tests; injected backend only")\n')
# Values are inert and the real singleton initializer is guarded at compile time.
(out / 'Brand.swift').write_text('import Foundation; nonisolated enum AppBrand { static let keychainService = "synthetic-unused-service"; static let keychainAccount = "synthetic-unused-account"; static let storageNamespace = "synthetic-credential-tests"; static let applicationSupportDirectory = FileManager.default.temporaryDirectory.appendingPathComponent(storageNamespace) }\n')
(out / 'ProfileTypes.swift').write_text('import Foundation; nonisolated struct AccountIdentity: Equatable, Sendable { let issuer: String; let subject: String; let internalUserID: String; var storageComponents: [String] { [issuer, subject, internalUserID] } }; nonisolated struct AccountContext: Equatable, Sendable { let identity: AccountIdentity; let organizationID: String?; let workspaceID: String?; let generation: UUID }; nonisolated enum AccountError: Error { case invalidAccount, isolationRequired }')
settings = Path('Sources/Fluid/Persistence/SettingsStore.swift').read_text()
initializer = settings.split('    private func initializeDesktopPreferences(refreshDeviceState: Bool = true) {', 1)[1].split('\n    static func clampPrivateAI', 1)[0]
assert 'self.initializeDesktopPreferences()' in settings.split('    init(defaults:', 1)[1].split('    #if os(macOS)', 2)[1]
assert 'SecItem' not in initializer and 'fetchAllKeys' not in initializer
assert 'DispatchQueue.main.async { self.refreshProviderAPIKeys() }' in initializer
assert 'self.keychain.cachedKeys ?? [:]' in settings
assert 'verifiedKeys: migratedKeys' in settings
assert 'self.pendingUserActions == 0' in Path('Sources/Fluid/Persistence/KeychainService.swift').read_text()
assert 'guard let keys = self.keychain.loadedKeys else { return nil }' in settings
assert '(try? self.keychain.fetchAllKeys()) ?? [:]' not in settings
viewmodel = Path('Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift').read_text()
assert 'SecItemCopyMatching' not in viewmodel and 'SecItemAdd' not in viewmodel and 'probeKeychainAccess' not in viewmodel
assert 'try await self.settings.saveProviderAPIKeys(draft, replacing: known, removing: providerIDs)' in viewmodel
assert 'try await self.settings.loadProviderAPIKeysForUserAction()' in viewmodel
PY
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
run_isolation_case() {
    task_isolation_name="$1"
    shift
    task_isolation_dir="$task_test_dir/$task_isolation_name"
    mkdir -p "$task_isolation_dir"
    printf 'Credential test isolation: %s\n' "$task_isolation_name"
    xcrun swiftc -I "$task_libraries" -L "$task_libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$task_libraries" -F "$task_frameworks" -Xlinker -rpath -Xlinker "$task_frameworks" -swift-version 5 -D PICHI_CREDENTIAL_TEST_BACKEND_ONLY -module-cache-path "$task_isolation_dir/ModuleCache" "$@" \
        Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Persistence/KeychainService.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
        "$task_test_dir/ProfileTypes.swift" "$task_test_dir/Brand.swift" \
        "$task_test_dir/CacheTests.swift" "$task_test_dir/main.swift" -o "$task_isolation_dir/tests"
    "$task_isolation_dir/tests"
}
run_isolation_case default
task_swift_help=$(xcrun swiftc -help)
case "$task_swift_help" in
    *-default-isolation*) run_isolation_case main-actor -default-isolation MainActor ;;
    *) printf '%s\n' 'SKIP: MainActor-default credential tests require a Swift compiler with -default-isolation; only 26 default-isolation tests ran.' ;;
esac
