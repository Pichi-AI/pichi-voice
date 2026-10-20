#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
reading_build="$PWD/.build/meeting-reading-trace-tests"
mkdir -p "$reading_build"
reading_case="$(mktemp -d "$reading_build/case.XXXXXX")"
python3 Tests/Support/write_attribution_standalone_types.py "$reading_case/AttributionTypes.swift"
python3 - "$reading_case/TimelineTrace.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingTimelineTrace.swift').read_text()
# Actual production sink and guards; isolate only its default directory for this synthetic test.
source = source.replace('enabled ? MeetingTimelineTrace() : nil',
    'enabled ? MeetingTimelineTrace(directory: URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)) : nil')
Path(sys.argv[1]).write_text(source)
PY
xcrun swiftc -swift-version 5 -default-isolation MainActor -parse-as-library -O \
    -module-cache-path "$reading_build/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/MeetingProcessingConfiguration.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    "$reading_case/TimelineTrace.swift" "$reading_case/AttributionTypes.swift" \
    Tests/MeetingReadingProjectionTraceTests.swift -o "$reading_build/tests"
reading_target="$(uuidgen)"
env -u PICHI_MEETING_TIMELINE_PROFILE -u PICHI_MEETING_READING_TARGET_WORD_ID \
    "$reading_build/tests" "$reading_case/disabled" "$reading_target"
env PICHI_MEETING_TIMELINE_PROFILE=1 PICHI_MEETING_READING_TARGET_WORD_ID="$reading_target" \
    "$reading_build/tests" "$reading_case/enabled" "$reading_target"
