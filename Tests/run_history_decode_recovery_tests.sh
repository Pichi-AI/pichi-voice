#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Set DEVELOPER_DIR to a full Xcode before running tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-history-decode.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# Compile the real profile/defaults dependencies used by both stores. Only the
# installation namespace and the explicitly injected persistence remain synthetic.
python3 Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift" --synthetic-brand
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ProfileTypes.swift" \
    Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Sources/Fluid/Persistence/ChatHistoryStore.swift \
    Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift \
    Sources/Fluid/Persistence/PersistedHistory.swift \
    Tests/HistoryDecodeRecoveryTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
