#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/meeting-asr-prepared-provider-tests"
mkdir -p "$task_test_dir"
# Compile the actual owner, scope, immutable configuration and additive service contract.
# The portable harness supplies inert neighboring contracts. No weights, network, capture,
# native app build, activity lease acquisition or model inference runs in this test.
if ! xcrun swiftc -parse-as-library -swift-version 5 -strict-concurrency=targeted -default-isolation MainActor -D DEBUG \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Services/ASRActivityLease.swift \
    Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift \
    Sources/Fluid/Services/Meeting/MeetingASRPreparationOwner.swift \
    Sources/Fluid/Services/Meeting/MeetingASRPreparedScope.swift \
    Sources/Fluid/Services/Meeting/MeetingASRServiceContract.swift \
    Tests/MeetingASRPreparedProviderTests.swift -o "$task_test_dir/tests" \
    2>"$task_test_dir/compiler.log"; then
    cat "$task_test_dir/compiler.log"
    exit 1
fi
if [[ -s "$task_test_dir/compiler.log" ]]; then
    echo "Compiler diagnostics saved: $task_test_dir/compiler.log"
fi
"$task_test_dir/tests"
