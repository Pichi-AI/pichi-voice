#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="$task_repo_dir/.build/meeting-capture-activity-tests"
mkdir -p "$task_test_dir"
python3 - "$task_test_dir/ActivityDetector.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingSpeechActivityDetector.swift').read_text()
Path(sys.argv[1]).write_text(source[:source.index('/// Offline B2 diagnostic combination.')])
PY
python3 Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift" --synthetic-brand
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ActivityDetector.swift" \
    "$task_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Services/Meeting/MeetingTimelineTrace.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingPCMFormatContract.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift \
    Tests/MeetingCaptureSpeechActivityTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
