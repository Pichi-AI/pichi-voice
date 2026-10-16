#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/pcm-preview-contract"
mkdir -p "$pichi_build"
swiftc -swift-version 6 -parse-as-library -module-cache-path "$pichi_build/ModuleCache" \
    Sources/Fluid/Services/Meeting/Backend/MeetingParakeetNemotronRuntime.swift \
    Tests/MeetingPCMPreviewContractTests.swift -o "$pichi_build/tests"
"$pichi_build/tests"
