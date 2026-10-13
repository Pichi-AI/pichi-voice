#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d /tmp/pichi-fluid-serve.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Compile the production persisted codecs and command, without launching the app.
set -- Sources/Fluid/Services/ModelTemperatureSupport.swift \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    Sources/Fluid/Services/Meeting/PichiMeetingSummaryDocument.swift \
    Sources/Fluid/Services/FluidServe/FluidServeSkill.swift \
    Sources/Fluid/Services/FluidServe/FluidServeMeetings.swift \
    Sources/Fluid/Services/FluidServe/FluidServeCommand.swift
xcrun swiftc -module-cache-path "$task_test_dir/ModuleCache" "$@" Sources/FVServe/main.swift -o "$task_test_dir/fv-serve"
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" "$@" Tests/FluidServeGroundedSummaryTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir/fv-serve"
