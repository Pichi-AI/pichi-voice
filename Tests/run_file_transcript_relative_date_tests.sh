#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="$task_repo_dir/.build/file-relative-date-tests"
mkdir -p "$task_test_dir"

# Observe calls in the real formatter without replacing its behavior. Existing
# standalone store dependencies keep all persistence in memory.
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
support = Path('Tests/FileTranscriptRenameTests.swift').read_text().split('@main @MainActor struct FileTranscriptRenameTests {')[0]
write = 'override func set(_ value: Any?, forKey key: String) { self.lock.withLock { self.values[key] = value } }'
assert support.count(write) == 1
support = support.replace(write, 'override func set(_ value: Any?, forKey key: String) { self.lock.withLock { self.values[key] = value }; RelativeDateTimeProbe.shared.recordWrite() }')
(output / 'StandaloneSupport.swift').write_text(support)

# Compile the same actual profile/defaults dependencies as the rename probe.
account = Path('Sources/Fluid/Account/AccountDomain.swift').read_text()
def declaration(marker):
    assert account.count(marker) == 1, f'Ambiguous production declaration: {marker}'
    start = account.index(marker)
    end = account.index('{', start) + 1
    depth = 1
    while depth:
        depth += (account[end] == '{') - (account[end] == '}')
        end += 1
    return account[start:end]
(output / 'AccountValues.swift').write_text('import Foundation\n' + '\n'.join(declaration(marker) for marker in (
    'nonisolated struct AccountIdentity:', 'nonisolated struct AccountContext:',
    'nonisolated enum AccountError:',
)) + '\n')

source = Path('Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift').read_text()
result = 'return formatter.localizedString(for: self.timestamp, relativeTo: reference)'
assert source.count(result) == 1
source = source.replace(result, 'let value = formatter.localizedString(for: self.timestamp, relativeTo: reference)\n'
                       '        RelativeDateTimeProbe.shared.record(locale: locale, reference: reference, value: value)\n'
                       '        return value')
(output / 'FileTranscriptionHistoryStore.swift').write_text(source)

environment = Path('Sources/Fluid/Theme/Components/FluidPageLayout.swift').read_text()
boundary = 'private struct FluidPageActions<Actions: View>: ViewModifier {'
assert environment.count(boundary) == 1
(output / 'PageVisibilityEnvironment.swift').write_text(environment[:environment.index(boundary)])
PY

xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/AccountValues.swift" \
    Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Tests/Support/StandaloneFileHistoryProfile.swift \
    "$task_test_dir/StandaloneSupport.swift" \
    "$task_test_dir/FileTranscriptionHistoryStore.swift" \
    "$task_test_dir/PageVisibilityEnvironment.swift" \
    Sources/Fluid/Persistence/PersistedHistory.swift \
    Sources/Fluid/UI/FileTranscriptRelativeDateLabel.swift \
    Tests/FileTranscriptRelativeDateTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir"
