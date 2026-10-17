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
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path('Tests').resolve()))
from run_meeting_backup_refresh_tests import declaration

root = pathlib.Path(sys.argv[1])
contract = pathlib.Path('Sources/Fluid/Services/Meeting/MeetingCaptureControlling.swift').read_text()
start = contract.index('nonisolated protocol MeetingMemoryAudioConsuming:')
root.joinpath('Contracts.swift').write_text('import Foundation\nimport CoreMedia\n' + contract[start:] + '\n'
    + 'class MeetingProcessingPipeline {}\n'
    + 'final class DebugLogger: Sendable { static let shared = DebugLogger(); func info(_ message: String, source: String) {} }\n'
    + 'struct MeetingPCMTranscriptBatch: Sendable { var segments: [String]; var speakers: [String]; var isComplete: Bool = true; var speakerRevisions: [String] = [] }\n'
    + 'final class MeetingMemoryAudioArchive: @unchecked Sendable { private let lock = NSLock(); private var count = 0; var totalSampleCount: Int { lock.withLock { count } }; func append(_ samples: UnsafeBufferPointer<Float>) throws { lock.withLock { count += samples.count } }; func seal() throws {} }\n')
source = pathlib.Path('Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift').read_text()
# Compile the complete production copier, without unrelated declarations appended later.
sample_copy = declaration(source, 'nonisolated enum MeetingLiveSampleCopy {')
root.joinpath('SampleCopy.swift').write_text('import AVFoundation\nimport CoreMedia\nimport Foundation\n' + sample_copy + '\n')
PY
xcrun swiftc -parse-as-library -swift-version 6 \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingPCMFormatContract.swift \
    Sources/Fluid/Services/Meeting/Platform/MeetingCapturePCMTransport.swift \
    Sources/Fluid/Services/Meeting/MeetingProcessingPipeline+MemoryAudio.swift \
    "$task_test_dir/Contracts.swift" "$task_test_dir/SampleCopy.swift" \
    Tests/MeetingCapturePCMTransportTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
