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
# Exercise the shared production elapsed formatter without constructing the export/store graph.
python3 - "$task_test_dir/ElapsedFormatter.swift" <<'PYEND'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift').read_text()
formatter = source[source.index('    static func timestampText('):source.index('\n}\n\nprivate struct ExportedSpeaker')]
Path(sys.argv[1]).write_text('import Foundation\nnonisolated enum MeetingTranscriptExporter {\n' + formatter + '\n}\n')
PYEND
# Production scalar PCM tee and projection; no app host, models or microphone.
python3 Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift" --synthetic-brand
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ActivityDetector.swift" \
    "$task_test_dir/ElapsedFormatter.swift" \
    "$task_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Services/Meeting/MeetingTimelineTrace.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingPCMFormatContract.swift \
    Sources/Fluid/Services/Meeting/Platform/MeetingCapturePCMTransport.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift \
    Tests/MeetingPendingSpeechProjectionTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
