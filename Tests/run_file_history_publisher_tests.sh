#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_root="$task_repo_dir/.build/file-history-publisher-tests"
mkdir -p "$task_test_root"
task_test_dir=$(mktemp -d "$task_test_root/run.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM

python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
support = Path('Tests/FileTranscriptRenameTests.swift').read_text().split('@main @MainActor struct FileTranscriptRenameTests {')[0]
(output / 'StandaloneSupport.swift').write_text(support)
account = Path('Sources/Fluid/Account/AccountDomain.swift').read_text()
def declaration(marker):
    assert account.count(marker) == 1
    start = account.index(marker)
    end = account.index('{', start) + 1
    depth = 1
    while depth:
        depth += (account[end] == '{') - (account[end] == '}')
        end += 1
    return account[start:end]
(output / 'AccountValues.swift').write_text('import Foundation\n' + '\n'.join(declaration(marker) for marker in (
    'nonisolated struct AccountIdentity:', 'nonisolated struct AccountContext:', 'nonisolated enum AccountError:',
)) + '\n')
PY

xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/AccountValues.swift" \
    Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Tests/Support/StandaloneFileHistoryProfile.swift "$task_test_dir/StandaloneSupport.swift" \
    Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift Sources/Fluid/Persistence/PersistedHistory.swift \
    Tests/FileHistoryPublisherTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
