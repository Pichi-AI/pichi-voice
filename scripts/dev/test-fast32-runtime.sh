#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_audio_source="${1:?Pass an existing FluidAudio source checkout. No dependencies will be downloaded.}"
test "$(git -C "$pichi_audio_source" rev-parse HEAD)" = eb1e6628998e47022799d305b52c2680d3576801
pichi_build="$pichi_root/.build/fast32-contract"
mkdir -p "$pichi_build"
python3 - "$pichi_audio_source" "$pichi_build" <<'PY'
from pathlib import Path
import sys
source, build = Path(sys.argv[1]), Path(sys.argv[2])
error = (source/'Sources/FluidAudio/Diarizer/Core/DiarizerTypes.swift').read_text()
(build/'DiarizerError.swift').write_text('import Foundation\n'+error[error.index('public enum DiarizerError'):])
runtime = Path('Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronRuntime.swift').read_text()
contracts = runtime[:runtime.index('/// The attempt\'s prepared Parakeet ASR session')]
# Unused surrounding app identity/error types; tested contracts above come from production.
contracts += '\nnonisolated enum MeetingPCMInputError: Error { case unsupportedRuntime }\n'
contracts += 'nonisolated struct MeetingAnalysisEpochID: Sendable {}\n'
errors = Path('Sources/Fluid/Services/Meeting/Backend/MeetingProductionParakeetNemotronRuntime.swift').read_text()
start = errors.index('nonisolated enum MeetingParakeetNemotronRuntimeError')
end = errors.index('/// Buffered providers', start)
(build/'Contracts.swift').write_text(contracts + errors[start:end])
PY
swiftc -swift-version 5 -parse-as-library -emit-module -emit-library -module-name FluidAudio \
    -module-cache-path "$pichi_build/ModuleCache" -emit-module-path "$pichi_build/FluidAudio.swiftmodule" \
    -o "$pichi_build/libFluidAudio.dylib" "$pichi_build/DiarizerError.swift" \
    "$pichi_audio_source/Sources/FluidAudio/Shared/ANEMemoryOptimizer.swift" \
    "$pichi_audio_source/Sources/FluidAudio/Shared/ANEMemoryUtils.swift" \
    "$pichi_audio_source/Sources/FluidAudio/Shared/AppLogger.swift" \
    "$pichi_audio_source/Sources/FluidAudio/Shared/AudioMelSpectrogram.swift"
swiftc -swift-version 5 -parse-as-library -default-isolation MainActor \
    -I "$pichi_build" -L "$pichi_build" -lFluidAudio -Xlinker -rpath -Xlinker "$pichi_build" \
    -module-cache-path "$pichi_build/ModuleCache" "$pichi_build/Contracts.swift" \
    Sources/Fluid/Services/Meeting/Backend/Nemotron3/*.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingFast32NemotronDiarizer.swift \
    Tests/MeetingFast32RuntimeTests.swift -o "$pichi_build/tests"
"$pichi_build/tests"
