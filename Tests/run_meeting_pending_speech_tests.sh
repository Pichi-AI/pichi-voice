#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="$task_repo_dir/.build/meeting-pending-speech-tests"
mkdir -p "$task_test_dir"
# Production scalar PCM tee and projection; no app host, models or microphone.
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Services/Meeting/Backend/MeetingPCMFormatContract.swift \
    Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift \
    Tests/MeetingPendingSpeechProjectionTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
