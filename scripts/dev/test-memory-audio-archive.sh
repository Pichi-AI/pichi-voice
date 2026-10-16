#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/memory-audio-archive"
mkdir -p "$pichi_build"
swiftc -O -swift-version 6 -parse-as-library -module-cache-path "$pichi_build/ModuleCache" \
    Sources/Fluid/Services/Meeting/Platform/MeetingMemoryAudioArchive.swift \
    Tests/MeetingMemoryAudioArchiveTests.swift -o "$pichi_build/tests"
"$pichi_build/tests" "$@"
