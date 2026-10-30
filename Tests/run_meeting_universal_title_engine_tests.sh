#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/meeting-universal-title-tests"
mkdir -p "$task_test_dir"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -O \
    -module-cache-path "$task_test_dir/module-cache" \
    Sources/Fluid/Services/Meeting/MeetingUniversalTitleEngine.swift \
    Tests/MeetingUniversalTitleEngineTests.swift \
    -o "$task_test_dir/title-engine-tests"
"$task_test_dir/title-engine-tests" "$@"
