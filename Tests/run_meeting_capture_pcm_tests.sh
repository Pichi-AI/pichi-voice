#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
task_test_dir="$(mktemp -d "$PWD/.build/pichi-capture-pcm.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# The pipeline/metadata stubs isolate the transport from engine installation and application
# composition. Actual PCM converter, format contract, sample copier and consumer are compiled.
# Combined iOS/app tests separately verify real canonical batch/store integration.
python3 - "$task_test_dir" <<'PY'
import pathlib, sys
root = pathlib.Path(sys.argv[1])
contract = pathlib.Path('Sources/Fluid/Services/Meeting/MeetingCaptureControlling.swift').read_text()
start = contract.index('nonisolated protocol MeetingMemoryAudioConsuming:')
root.joinpath('Contracts.swift').write_text('import Foundation\nimport CoreMedia\n' + contract[start:] + '\n'
    + 'class MeetingProcessingPipeline {}\n'
    + 'struct MeetingPCMTranscriptBatch: Sendable { var segments: [String]; var speakers: [String] }\n')
source = pathlib.Path('Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift').read_text()
start = source.index('nonisolated enum MeetingLiveSampleCopy {')
root.joinpath('SampleCopy.swift').write_text('import AVFoundation\nimport CoreMedia\nimport Foundation\n' + source[start:])
PY
xcrun swiftc -parse-as-library -swift-version 6 \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingPCMFormatContract.swift \
    Sources/Fluid/Services/Meeting/Platform/MeetingCapturePCMTransport.swift \
    Sources/Fluid/Services/Meeting/MeetingProcessingPipeline+MemoryAudio.swift \
    "$task_test_dir/Contracts.swift" "$task_test_dir/SampleCopy.swift" \
    Tests/MeetingCapturePCMTransportTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
