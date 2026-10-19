#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="$task_repo_dir/.build/meeting-pending-speech-tests"
mkdir -p "$task_test_dir"
# Compile the actual detector, excluding its unrelated playback diagnostic policy.
python3 - "$task_test_dir/ActivityDetector.swift" <<'PYEND'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingSpeechActivityDetector.swift').read_text()
Path(sys.argv[1]).write_text(source[:source.index('/// Offline B2 diagnostic combination.')])
PYEND
# Production scalar PCM tee and projection; no app host, models or microphone.
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ActivityDetector.swift" \
    Sources/Fluid/Services/Meeting/Backend/MeetingPCMFormatContract.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift \
    Tests/MeetingPendingSpeechProjectionTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
