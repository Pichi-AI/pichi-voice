#!/usr/bin/env bash
set -euo pipefail

pichi_slug="${1:-}"
if [[ ! "$pichi_slug" =~ ^[a-z0-9][a-z0-9-]{0,63}$ ]]; then
    printf '%s\n' 'Usage: bash scripts/dev/new-worktree.sh <lowercase-task-slug>' >&2
    exit 1
fi
pichi_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
pichi_primary="$(dirname "$pichi_common_dir")"
pichi_worktree_root="${PICHI_VOICE_WORKTREE_ROOT:-${pichi_primary}-worktrees}"
pichi_suffix="$(python3 -c 'import uuid; print(uuid.uuid4().hex[:10])')"
pichi_branch="codex/${pichi_slug}-${pichi_suffix}"
pichi_directory="${pichi_worktree_root}/${pichi_slug}-${pichi_suffix}"
git fetch origin main >&2
git worktree add -b "$pichi_branch" "$pichi_directory" origin/main >&2
printf 'Created branch %s\n' "$pichi_branch" >&2
printf '%s\n' "$pichi_directory"
