#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/../.."
bash scripts/dev/assert-worktree.sh
mkdir -p .build
task_test_dir="$(mktemp -d "$PWD/.build/meeting-microphone-privacy.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# The gate validates measured capture-clock packets against a recording clock context (120).
python3 Tests/Support/write_capture_clock_standalone_types.py "$task_test_dir/CaptureClockTypes.swift" --with-recording-clocks
xcrun swiftc -swift-version 6 -O -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/CaptureClockTypes.swift" Sources/Fluid/Services/Meeting/MeetingPCMSourceTimeline.swift \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingPCMFormatContract.swift \
    Sources/Fluid/Services/Meeting/Mute/MeetingMicrophonePrivacyGate.swift \
    Tests/MeetingMicrophonePrivacyGateTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
