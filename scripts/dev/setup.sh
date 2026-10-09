#!/usr/bin/env bash
set -euo pipefail

pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
if [[ "${1:-}" != "--allow-primary" ]]; then
    bash scripts/dev/assert-worktree.sh
fi
bash scripts/dev/check.sh
if [[ "$(uname -s)" == "Darwin" ]]; then
    xcodebuild -version
    printf '%s\n' 'Swift packages resolve during the first macOS build in this worktree.'
else
    printf '%s\n' 'Portable environment is ready. Full app build and audio tests require macOS and Xcode.'
fi
