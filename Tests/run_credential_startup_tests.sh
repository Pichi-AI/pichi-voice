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
assert len(names) == 20, names
(out / 'main.swift').write_text('import XCTest\nimport Foundation\nlet suite = KeychainServiceCacheTests.defaultTestSuite\nprecondition(suite.testCaseCount == 20, "Native XCTest discovery must include every synthetic regression")\nsuite.run()\nguard let run = suite.testRun, run.executionCount == 20, run.failureCount == 0 else { exit(1) }\nprint("PASS: 20 exact native Keychain cache/startup tests; injected backend only")\n')
# Values are inert and the real singleton initializer is guarded at compile time.
(out / 'Brand.swift').write_text('enum PichiLocalization { static func text(_ key: String) -> String { key } }; enum AppBrand { static let keychainService = "synthetic-unused-service"; static let keychainAccount = "synthetic-unused-account" }\n')
settings = Path('Sources/Fluid/Persistence/SettingsStore.swift').read_text()
initializer = settings.split('    private init() {', 1)[1].split('\n    static func clampPrivateAI', 1)[0]
assert 'SecItem' not in initializer and 'fetchAllKeys' not in initializer
assert 'DispatchQueue.main.async { self.refreshProviderAPIKeys() }' in initializer
assert 'self.keychain.cachedKeys ?? [:]' in settings
assert 'verifiedKeys: result.migratedKeys' in settings
assert 'guard let keys = self.keychain.loadedKeys else { return nil }' in settings
assert '(try? self.keychain.fetchAllKeys()) ?? [:]' not in settings
viewmodel = Path('Sources/Fluid/UI/AISettings/AIEnhancementSettingsViewModel.swift').read_text()
assert 'SecItemCopyMatching' not in viewmodel and 'SecItemAdd' not in viewmodel and 'probeKeychainAccess' not in viewmodel
assert 'try await self.settings.saveProviderAPIKeys(draft, replacing: known, removing: providerIDs)' in viewmodel
assert 'try await self.settings.loadProviderAPIKeysForUserAction()' in viewmodel
PY
task_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
task_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -I "$task_libraries" -L "$task_libraries" -lXCTestSwiftSupport -Xlinker -rpath -Xlinker "$task_libraries" -F "$task_frameworks" -Xlinker -rpath -Xlinker "$task_frameworks" -swift-version 5 -D PICHI_CREDENTIAL_TEST_BACKEND_ONLY -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Persistence/KeychainService.swift "$task_test_dir/Brand.swift" \
    "$task_test_dir/CacheTests.swift" "$task_test_dir/main.swift" -o "$task_test_dir/tests"
"$task_test_dir/tests"
