#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash scripts/dev/assert-worktree.sh
mkdir -p .build
task_test_dir="$(mktemp -d "$PWD/.build/meeting-microphone-privacy.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
xcrun swiftc -swift-version 6 -O -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Services/Meeting/Mute/MeetingMicrophonePrivacyGate.swift \
    Tests/MeetingMicrophonePrivacyGateTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
