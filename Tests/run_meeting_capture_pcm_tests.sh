#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
task_test_dir="$(mktemp -d "$PWD/.build/pichi-capture-pcm.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# The pipeline/metadata stubs isolate the transport from engine installation and application
# composition. Actual PCM converter, format contract, sample copier and consumer are compiled.
# Combined iOS/app tests separately verify real canonical batch/store integration.
python3 -S - "$task_test_dir" <<'PY'
import pathlib, sys
sys.dont_write_bytecode = True
sys.path.insert(0, str(pathlib.Path('Tests').resolve()))
from run_meeting_backup_refresh_tests import declaration

root = pathlib.Path(sys.argv[1])
contract = pathlib.Path('Sources/Fluid/Services/Meeting/MeetingCaptureControlling.swift').read_text()
models = pathlib.Path('Sources/Fluid/Services/Meeting/MeetingModels.swift').read_text()
evidence = pathlib.Path('Sources/Fluid/Services/Meeting/Backend/MeetingCanonicalEvidenceTypes.swift').read_text()
# The streaming observation carries real epoch-scoped owner tokens. Keep their
# production value declarations even though this transport probe supplies no owners.
speaker_contract = next(line for line in models.splitlines() if line.startswith('typealias MeetingAudioTrackID =')) + '\n'
speaker_contract += '\n'.join(declaration(evidence, marker) for marker in (
    'nonisolated struct MeetingAnalysisEpochID:',
    'nonisolated struct MeetingBackendSpeakerToken:',
))
memory_contract = declaration(contract, 'nonisolated protocol MeetingMemoryAudioConsuming:') + '\n' + declaration(contract, 'extension MeetingMemoryAudioConsuming {')
root.joinpath('Contracts.swift').write_text('import Foundation\nimport CoreMedia\n' + speaker_contract + '\n' + memory_contract + '\n'
    + 'class MeetingProcessingPipeline {}\n'
    + 'final class DebugLogger: Sendable { static let shared = DebugLogger(); func info(_ message: String, source: String) {} }\n'
    + 'struct MeetingPCMTranscriptBatch: Sendable { var segments: [String]; var speakers: [String]; var isComplete: Bool = true; var speakerRevisions: [String] = []; var protectedSourceThroughSample: Int? = nil }\n'
    + 'enum MeetingAudioTrackKind: Sendable { case microphone, applicationAudio }\n'
    + 'enum MeetingCaptureEvent: Sendable { enum Kind: Sendable { case writerBackpressure, captureStoppedUnexpectedly }; case interrupted(kind: Kind, trackID: UUID?, detail: String) }\n'
    + 'struct MeetingBackendSpeakerActivity: Sendable {}\n'
    + 'final class MeetingMemoryAudioArchive: @unchecked Sendable { private let lock = NSLock(); private var count = 0; var totalSampleCount: Int { lock.withLock { count } }; func append(_ samples: UnsafeBufferPointer<Float>) throws { lock.withLock { count += samples.count } }; func seal() throws {} }\n')
source = pathlib.Path('Sources/Fluid/Services/Meeting/LiveTranscription/MeetingLiveModels.swift').read_text()
# Compile the complete production copier, without unrelated declarations appended later.
sample_copy = declaration(source, 'nonisolated enum MeetingLiveSampleCopy {')
root.joinpath('SampleCopy.swift').write_text('import AVFoundation\nimport CoreMedia\nimport Foundation\n' + sample_copy + '\n')
# Compile the actual desktop callback and failure methods with inert callback metadata and
# controlled sinks. Their implementation is not re-created in the regression fixture.
engine = pathlib.Path('Sources/Fluid/Services/Meeting/MeetingCaptureEngine.swift').read_text()
inroom = declaration(engine, 'private final nonisolated class InRoomMicrophoneCaptureRuntime:')
callbacks = '\n'.join(declaration(inroom, marker) for marker in [
    'func captureOutput(', 'private func failTranscription(', 'private func enqueueForTranscription('])
probe = pathlib.Path('Tests/Support/MeetingMacCaptureTeeProbe.swift').read_text()
root.joinpath('MacCaptureTee.swift').write_text(probe.replace('// PRODUCTION_CALLBACKS', callbacks) + '\n' + declaration(engine, 'final nonisolated class MeetingMultiTrackCaptureTee:'))
ios = pathlib.Path('Sources/Fluid/Services/Meeting/Platform/IOSMeetingCaptureEngine.swift').read_text()
stop_probe = pathlib.Path('Tests/Support/MeetingCaptureStopProbe.swift').read_text()
stop_probe = stop_probe.replace('// PRODUCTION_CAPTURE_ERROR', declaration(contract, 'nonisolated enum MeetingCaptureError:'))
stop_probe = stop_probe.replace('// PRODUCTION_IOS_STOP', declaration(ios, 'func stop(sessionID:'))
stop_probe = stop_probe.replace('// PRODUCTION_DESKTOP_STOP', declaration(engine, 'func stop(sessionID:'))
coordinator = pathlib.Path('Sources/Fluid/Services/Meeting/MeetingSessionCoordinator.swift').read_text()
stop_probe = stop_probe.replace('// PRODUCTION_STOP_TIMER', declaration(coordinator, 'var elapsedTime:'))
stop_probe = stop_probe.replace('// PRODUCTION_PRESERVE_HANDOFF', declaration(coordinator, 'private func preserveCaptureStopHandoff('))
stop_probe = stop_probe.replace('// PRODUCTION_TAKE_HANDOFF', declaration(coordinator, 'private func takeCaptureStopHandoff('))
stop_probe = stop_probe.replace('// PRODUCTION_DISCARDED_CAPTURE_COMPLETENESS', declaration(coordinator, 'private static func markDiscardedMemoryCaptureIncomplete('))
event_body = declaration(coordinator, 'private func handleCaptureEvent(')
assert 'Self.markDiscardedMemoryCaptureIncomplete(&session, event: kind)' in event_body
assert coordinator.count('Self.markDiscardedMemoryCaptureIncomplete(') == 1, 'Only fresh admitted capture events classify new loss'
merge_body = declaration(coordinator, 'private func mergeLatestMemoryCheckpoint(')
assert 'let wasIncomplete = session.transcriptIsComplete == false' in merge_body
assert 'if wasIncomplete { session.transcriptIsComplete = false }' in merge_body
process_body = declaration(coordinator, 'private func process(')
assert 'session.transcriptIsComplete == false' in process_body and 'result.isComplete && !discardedMemoryPCM' in process_body
stop_body = declaration(coordinator, 'private func performStopAndTranscribe(')
assert stop_body.index('guard self.operationGeneration == generation') < stop_body.index('self.state = .stopping')
assert 'if self.captureStopHandoff?.sessionID != session.id || self.captureStopHandoff?.generation != generation' in stop_body
start_body = declaration(coordinator, 'private func performStartRecording(')
retry_body = declaration(coordinator, 'private func beginProcessingRetry(')
assert 'self.captureStopHandoff = nil' in start_body and 'self.captureStopHandoff = nil' in retry_body
assert 'self.stopRequestedAt = (session.id, Date())' in coordinator
mobile_ui = pathlib.Path('Sources/Mobile/MobileMeetingRoot.swift').read_text()
assert 'Text(MeetingTranscriptExporter.timestampText(coordinator.elapsedTime))' in mobile_ui
root.joinpath('CaptureStop.swift').write_text(stop_probe)
PY
xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingPCMFormatContract.swift \
    Sources/Fluid/Services/Meeting/MeetingMicrophonePCMNormalizer.swift \
    Sources/Fluid/Services/Meeting/Platform/MeetingCapturePCMTransport.swift \
    Sources/Fluid/Services/Meeting/MeetingProcessingPipeline+MemoryAudio.swift \
    Sources/Fluid/Services/Meeting/MeetingStreamingPCMController.swift \
    "$task_test_dir/Contracts.swift" "$task_test_dir/SampleCopy.swift" "$task_test_dir/MacCaptureTee.swift" "$task_test_dir/CaptureStop.swift" \
    Tests/MeetingMultiTrackCaptureTeeTests.swift Tests/MeetingCapturePCMTransportTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
