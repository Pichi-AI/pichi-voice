#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/speaker-continuity"
mkdir -p "$pichi_build"
# Compile actual persisted models and the actual pure product policy, without initializing
# an application, audio capture or model. Owning declarations are extracted unchanged.
python3 - "$pichi_build/Continuity.swift" <<'PY'
from pathlib import Path
import sys
def section(path, start, end):
    text = Path(path).read_text()
    return text[text.index(start):text.index(end, text.index(start))]
source = 'import Foundation\n'
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingBackendEvidence.swift',
                  'nonisolated struct MeetingAnalysisEpochID:', 'nonisolated struct MeetingAnalysisEpochGenerationKey:')
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingTranscriptAssembler.swift',
                  'nonisolated enum MeetingAssemblyCoverageGapReason:', '/// Everything the assembler needs,')
source += section('Sources/Fluid/Services/Meeting/Backend/MeetingTranscriptAssembler.swift',
                  'nonisolated enum MeetingTranscriptSpeakerContinuity {', '/// Speaker-only reconciliation after whole-recording analysis.')
Path(sys.argv[1]).write_text(source)
PY
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor -O \
    -module-cache-path "$pichi_build/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    "$pichi_build/Continuity.swift" Tests/MeetingSpeakerContinuityTests.swift \
    -o "$pichi_build/tests"
"$pichi_build/tests" "$@"
