#!/usr/bin/env bash
set -euo pipefail

pichi_slug="${1:-}"
if [[ $# -gt 2 || ! "$pichi_slug" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    printf '%s\n' 'Usage: bash scripts/dev/new-worktree.sh <lowercase-task-slug> [base-ref]' >&2
    exit 1
fi
if [[ $# -eq 2 ]]; then
    pichi_base="$(git rev-parse --verify --end-of-options "${2}^{commit}")"
else
    git fetch origin main >&2
    pichi_base="$(git rev-parse --verify 'refs/remotes/origin/main^{commit}')"
fi
pichi_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
pichi_primary="$(dirname "$pichi_common_dir")"
pichi_worktree_root="${PICHI_VOICE_WORKTREE_ROOT:-${pichi_primary}-worktrees}"
pichi_suffix="$(python3 -c 'import uuid; print(uuid.uuid4().hex[:10])')"
pichi_branch="codex/${pichi_slug}-${pichi_suffix}"
pichi_directory="${pichi_worktree_root}/${pichi_slug}-${pichi_suffix}"
git worktree add -b "$pichi_branch" "$pichi_directory" "$pichi_base" >&2
printf 'Created branch %s\n' "$pichi_branch" >&2
printf '%s\n' "$pichi_directory"
