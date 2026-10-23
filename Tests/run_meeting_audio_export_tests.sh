#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
# Follow the existing standalone production-value test mechanism. No app, playback,
# inference, recordings or model resources are involved. All file bytes are synthetic.
task_test_dir=$(mktemp -d "$PWD/.build/meeting-audio-export-tests.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT
python3 Tests/Support/write_attribution_standalone_types.py "$task_test_dir/AttributionTypes.swift"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift \
    "$task_test_dir/AttributionTypes.swift" \
    Sources/Fluid/Services/Meeting/MeetingAudioExporter.swift \
    Tests/MeetingAudioExporterTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir/fixtures"
