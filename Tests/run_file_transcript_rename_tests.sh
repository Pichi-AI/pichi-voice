#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Set DEVELOPER_DIR to a full Xcode before running tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-file-rename.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
python3 -S - "$task_test_dir/AccountValues.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Account/AccountDomain.swift').read_text()
def declaration(marker):
    assert source.count(marker) == 1
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]
# The actual profile sources need these values, not distribution/browser/transport APIs.
Path(sys.argv[1]).write_text('import Foundation\n' + '\n'.join(declaration(marker) for marker in (
    'nonisolated struct AccountIdentity:', 'nonisolated struct AccountContext:',
    'nonisolated enum AccountError:',
)) + '\n')
PY
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/AccountValues.swift" Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift Sources/Fluid/Persistence/PersistedHistory.swift \
    Tests/Support/StandaloneFileHistoryProfile.swift Tests/FileTranscriptRenameTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
