#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pichi-profile-logging.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
python3 Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift" --synthetic-brand
xcrun swiftc -default-isolation MainActor -parse-as-library \
    -module-cache-path "$task_test_dir/ModuleCache" "$task_test_dir/ProfileTypes.swift" \
    Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Services/FileLogger.swift \
    Sources/Fluid/Services/DebugLogger.swift Tests/PrivateProfileLoggingTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
