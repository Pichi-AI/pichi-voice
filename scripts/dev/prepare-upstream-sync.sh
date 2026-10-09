#!/usr/bin/env bash
set -euo pipefail

pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
git fetch origin main
git fetch upstream main --tags
if git merge-base --is-ancestor upstream/main origin/main; then
    printf '%s\n' 'origin/main already contains the current FluidVoice main.'
    exit 0
fi
pichi_directory="$(bash scripts/dev/new-worktree.sh upstream-sync)"
if ! git -C "$pichi_directory" merge --no-ff --no-commit upstream/main; then
    printf 'Resolve merge conflicts in %s. main was not changed.\n' "$pichi_directory" >&2
    exit 1
fi
printf 'Review and test the pending merge in %s, then commit, push its branch, and open a PR.\n' "$pichi_directory"
