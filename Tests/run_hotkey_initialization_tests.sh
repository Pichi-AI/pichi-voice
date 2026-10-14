#!/bin/sh
set -eu
hotkey_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$hotkey_repo_dir"
hotkey_test_dir="$hotkey_repo_dir/.build/hotkey-initialization-tests"
mkdir -p "$hotkey_test_dir"

# Compile actual owner/lifecycle bodies. Only native setup/health dependencies and
# waiting are inert, deterministic test doubles; real Swift Task cancellation stays.
python3 -S - "$hotkey_test_dir" "${1:-}" <<'PY'
from pathlib import Path
import re
import subprocess
import sys

output, reference = Path(sys.argv[1]), sys.argv[2]
path = 'Sources/Fluid/Services/GlobalHotkeyManager.swift'
source = subprocess.check_output(['git', 'show', f'{reference}:{path}'], text=True) if reference else Path(path).read_text()
def method(name):
    matches = list(re.finditer(r'(?m)^    (?:private )?func '+re.escape(name)+r'\(', source))
    assert len(matches) == 1, f'Expected one lifecycle method {name}'
    start = matches[0].start()
    # These bounded lifecycle methods have no multiline string literals or
    # nested declarations at the enclosing class indentation. Reject either.
    end = source.index('\n    }', start) + len('\n    }')
    body = source[start:end]
    assert '"""' not in body and not re.search(r'\n    (?:private )?func ', body), name
    return body.replace('private func', 'func', 1)
names = ['initializeWithDelay', 'setupGlobalHotkeyWithRetry', 'reinitialize', 'startHealthCheckTimer']
if reference:
    if re.search(r'^    private func startHotkeyInitialization\(', source, re.M):
        names += ['startHotkeyInitialization']
else:
    names += ['startHotkeyInitialization']
methods = '\n'.join(method(name) for name in names)
assert methods.count('Task.sleep(nanoseconds:') == 3, 'The three existing lifecycle waits changed'
methods = methods.replace('Task.sleep(nanoseconds:', 'HotkeyInitializationTestClock.sleep(nanoseconds:')
properties = []
for name in ['isInitialized', 'initializationTask', 'initializationGeneration', 'healthCheckTask', 'maxRetryAttempts', 'retryDelay', 'healthCheckInterval']:
    matches = re.findall(r'^    private var '+name+r'\b[^\n]*', source, re.M)
    if reference and name == 'initializationGeneration' and not matches:
        # Old source has no generation. This inert field only lets the same
        # reentrancy test compile; old production bodies never consult it.
        properties.append('    var initializationGeneration = UUID()')
    else:
        assert len(matches) == 1, f'Expected one owner property {name}'
        properties.append(matches[0].replace('private var', 'var', 1))
marker = '    deinit {'
assert source.count(marker) == 1
start = source.index(marker)
deinit = source[start:source.index('\n    }', start)+len('\n    }')]
assert deinit.count('initializationTask?.cancel()') == deinit.count('healthCheckTask?.cancel()') == 1
fixture = ('import Foundation\n@MainActor final class GlobalHotkeyManager: NSObject {\n'
           + '\n'.join(properties) + '\n' + methods + '\n' + deinit + '\n'
           + '''
    var muteReleaseRecoveryTask: Task<Void, Never>?
    var setupCount = 0
    var recoverMouseCount = 0
    var resetCount = 0
    var setupResult = false
    var tapHealthy = true
    var onSetup: ((GlobalHotkeyManager) -> Bool)?
    var onValidate: ((GlobalHotkeyManager) -> Bool)?
    enum ResetReason { case reinitialize }
    func setupGlobalHotkey() -> Bool { setupCount += 1; return onSetup?(self) ?? setupResult }
    func validateEventTapHealth() -> Bool { onValidate?(self) ?? tapHealthy }
    func recoverMouseTapsIfNeeded() { recoverMouseCount += 1 }
    func resetModifierOnlyShortcutTracking(reason: ResetReason) { resetCount += 1 }
    nonisolated func cleanupEventTap() {}
}\n''')
(output / 'ProductionHotkeyInitialization.swift').write_text(fixture)
PY

xcrun swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -module-cache-path "$hotkey_test_dir/ModuleCache" \
    "$hotkey_test_dir/ProductionHotkeyInitialization.swift" Tests/HotkeyInitializationTests.swift \
    -o "$hotkey_test_dir/tests"
"$hotkey_test_dir/tests"

# The same native XCTest methods run against the complete production shortcut
# model without an application host, event taps, preferences, or captured input.
python3 -S - "$hotkey_test_dir" "${1:-}" <<'PY'
from pathlib import Path
import subprocess
import sys

output, reference = Path(sys.argv[1]), sys.argv[2]
model_path = 'Sources/Fluid/Models/HotkeyShortcut.swift'
model = subprocess.check_output(['git', 'show', f'{reference}:{model_path}'], text=True) if reference else Path(model_path).read_text()
(output / 'HotkeyShortcut.swift').write_text(model)
source = Path('Tests/FluidDictationIntegrationTests/HotkeyShortcutTests.swift').read_text()
names = [
    'testFunctionKeyDisplayNames',
    'testModifiedFunctionKeyDisplayPreservesMatchingAndCoding',
    'testFunctionKeyNamesPreserveLetterLayoutAndModifierNames',
]
methods = []
for name in names:
    marker = '    func ' + name + '('
    assert source.count(marker) == 1, f'Expected one native shortcut test {name}'
    start = source.index(marker)
    end = source.index('\n    }', start) + len('\n    }')
    methods.append(source[start:end])
(output / 'main.swift').write_text(
    'import AppKit\nimport Carbon\nimport Foundation\nimport XCTest\n'
    + 'final class HotkeyShortcutDisplayTests: XCTestCase {\n'
    + '\n'.join(methods) + '\n}\n'
    + 'let suite = HotkeyShortcutDisplayTests.defaultTestSuite\n'
    + 'precondition(suite.testCaseCount == 3, "All native shortcut display tests must be discovered")\n'
    + 'suite.run()\n'
    + 'guard let run = suite.testRun, run.executionCount == 3, run.failureCount == 0 else { exit(1) }\n'
)
PY

hotkey_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
hotkey_libraries="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
xcrun swiftc -swift-version 6 -strict-concurrency=complete \
    -I "$hotkey_libraries" -L "$hotkey_libraries" -lXCTestSwiftSupport \
    -Xlinker -rpath -Xlinker "$hotkey_libraries" \
    -F "$hotkey_frameworks" -Xlinker -rpath -Xlinker "$hotkey_frameworks" \
    -module-cache-path "$hotkey_test_dir/ModuleCache" \
    "$hotkey_test_dir/HotkeyShortcut.swift" "$hotkey_test_dir/main.swift" \
    -o "$hotkey_test_dir/display-tests"
"$hotkey_test_dir/display-tests"
