#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/runtime-voice-verification"
mkdir -p "$pichi_build"
python3 - "$pichi_build/ActualVoiceAdmission.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/Meeting/Backend/MeetingProductionParakeetNemotronRuntime.swift').read_text()
start = source.index('    func speakerVoiceProfiles(samples:')
end = source.index('    func withNemotronDiarization(', start)
context = '''
import Foundation
final nonisolated class VoiceVerificationProbe: Sendable {
    private let ownerVoiceVerificationEnabled: Bool
    private let voiceModelDirectory = URL(fileURLWithPath: "/nonexistent-synthetic-voice-model")
    private let usesDefaultVoiceModelDirectory = false
    init(verificationEnabled: Bool) { self.ownerVoiceVerificationEnabled = verificationEnabled }
'''
voice = Path('Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerVoiceModelArtifacts.swift').read_text()
extension_start = voice.index('extension MeetingNemotronModelProfile {')
Path(sys.argv[1]).write_text(context + source[start:end] + '\n}\n' + voice[extension_start:])
PY
swiftc -swift-version 6 -parse-as-library -default-isolation MainActor \
    -module-cache-path "$pichi_build/ModuleCache" \
    Sources/Fluid/Services/Meeting/Backend/MeetingNemotronModelLocator.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingModelInstaller.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingNemotronCompiledModelOwner.swift \
    "$pichi_build/ActualVoiceAdmission.swift" Tests/MeetingRuntimeVoiceVerificationContractTests.swift \
    -o "$pichi_build/tests"
"$pichi_build/tests"
