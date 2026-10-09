#!/usr/bin/env bash
set -euo pipefail

pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
if [[ "${1:-}" != "--allow-primary" ]]; then
    bash scripts/dev/assert-worktree.sh
fi
if ! git remote get-url upstream >/dev/null 2>&1; then
    git remote add upstream https://github.com/altic-dev/FluidVoice.git
fi
pichi_upstream_url="$(git remote get-url upstream)"
if [[ "$pichi_upstream_url" != "https://github.com/altic-dev/FluidVoice.git" ]]; then
    printf 'Review the unexpected upstream URL before setup: %s\n' "$pichi_upstream_url" >&2
    exit 1
fi
git config --replace-all remote.upstream.fetch '+refs/heads/main:refs/remotes/upstream/main'
git config remote.upstream.pushurl DISABLED
git config remote.pushDefault origin
git config push.default simple
bash scripts/dev/check.sh
if [[ "$(uname -s)" == "Darwin" ]]; then
    xcodebuild -version
    printf '%s\n' 'Swift packages resolve during the first macOS build in this worktree.'
else
    printf '%s\n' 'Portable environment is ready. Full app build and audio tests require macOS and Xcode.'
fi
