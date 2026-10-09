#!/usr/bin/env bash
set -euo pipefail

pichi_git_dir="$(git rev-parse --absolute-git-dir)"
pichi_common_dir="$(git rev-parse --path-format=absolute --git-common-dir)"
if [[ "$pichi_git_dir" == "$pichi_common_dir" ]]; then
    printf '%s\n' 'Use a separate worktree before running this command.' >&2
    printf '%s\n' 'In Codex, select Worktree. Or run: bash scripts/dev/new-worktree.sh <task-slug>' >&2
    exit 1
fi
