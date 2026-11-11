#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
bash scripts/dev/assert-worktree.sh
mkdir -p .build
pichi_echo_test_dir="$(mktemp -d "$PWD/.build/streaming-echo.XXXXXX")"
trap 'rm -rf "$pichi_echo_test_dir"' EXIT HUP INT TERM
python3 -S - "$pichi_echo_test_dir" <<'PY'
from pathlib import Path
import sys
root = Path(sys.argv[1])
def declaration(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end] + '\n'
meeting = Path('Sources/Fluid/Services/Meeting')
values = 'import Foundation\n'
values += 'typealias MeetingAudioTrackID = UUID\ntypealias MeetingTranscriptSegmentID = UUID\n'
values += (meeting / 'Backend/MeetingCanonicalEvidenceTypes.swift').read_text()
manifest = (meeting / 'Backend/MeetingAnalysisManifest.swift').read_text()
values += declaration(manifest, 'nonisolated enum MeetingAnalysisManifestSchema')
values += declaration(manifest, 'nonisolated struct MeetingAnalysisInterval:')
assembler = (meeting / 'Backend/MeetingTranscriptAssembler.swift').read_text()
values += declaration(assembler, 'nonisolated enum MeetingSpeakerActivityCoverage {')
values += declaration(assembler, 'nonisolated enum MeetingWordBoundaryRecovery {')
values += declaration(assembler, 'nonisolated enum MeetingUnitEchoVerdict:')
values += declaration((meeting / 'MeetingStreamingPCMController.swift').read_text(), 'nonisolated struct MeetingStreamingPCMObservation:')
provider = (meeting / 'Backend/MeetingUnitEchoVerdictProvider.swift').read_text()
values += declaration(provider, 'nonisolated struct MeetingPositionedEchoUnit:')
values += declaration(provider, 'nonisolated enum MeetingPositionedEchoScoring {')
# Only the application record shell is inert. The production raw-evidence owner, observation,
# anonymous token/native unit values, native activity/boundary rules and echo scorer are actual.
values += '''
nonisolated enum MeetingAudioTrackKind: Sendable { case microphone, applicationAudio }
nonisolated struct MeetingAudioTrack: Sendable { let id: UUID; let kind: MeetingAudioTrackKind }
nonisolated struct MeetingTranscriptNativeTiming: Sendable { let start: Double; let end: Double }
nonisolated struct MeetingTranscriptSegment: Sendable {
    let id: UUID
    let sourceTrackID: UUID
    let text: String
    let nativeTiming: MeetingTranscriptNativeTiming?
    let nativePrecision: MeetingTextUnitPrecision?
    let nativeSpeakerAssignment: MeetingBackendSpeakerAssignment?
    var isLikelyEcho: Bool? = nil
}
nonisolated struct MeetingPCMTranscriptBatch: Sendable {
    struct EchoRevision: Sendable { let segmentID: UUID; let isLikelyEcho: Bool }
    var segments: [MeetingTranscriptSegment]
    var echoRevisions: [EchoRevision] = []
}
'''
root.joinpath('ActualEchoContracts.swift').write_text(values)
PY
xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -module-cache-path "$pichi_echo_test_dir/ModuleCache" \
    "$pichi_echo_test_dir/ActualEchoContracts.swift" \
    Sources/Fluid/Services/Meeting/MeetingEchoDetector.swift \
    Sources/Fluid/Services/Meeting/MeetingStreamingEchoAdmission.swift \
    Tests/MeetingStreamingEchoAdmissionTests.swift -o "$pichi_echo_test_dir/tests"
"$pichi_echo_test_dir/tests"
