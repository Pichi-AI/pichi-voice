#!/usr/bin/env bash
set -euo pipefail

if [[ $# -gt 1 || "${1:-}" == -* ]]; then
    printf '%s\n' 'Usage: bash scripts/dev/prepare-upstream-sync.sh [upstream-ref]' >&2
    exit 1
fi
pichi_upstream_ref="${1:-upstream/main}"
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
git fetch origin main
git fetch upstream main --tags
pichi_downstream_sha="$(git rev-parse --verify 'refs/remotes/origin/main^{commit}')"
pichi_upstream_main_sha="$(git rev-parse --verify 'refs/remotes/upstream/main^{commit}')"
if ! pichi_upstream_sha="$(git rev-parse --verify --end-of-options "${pichi_upstream_ref}^{commit}")"; then
    printf 'Cannot resolve upstream ref: %s\n' "$pichi_upstream_ref" >&2
    exit 1
fi
if ! git merge-base --is-ancestor "$pichi_upstream_sha" "$pichi_upstream_main_sha"; then
    if ! python3 -S scripts/dev/verify-published-upstream-release.py "$pichi_upstream_ref" "$pichi_upstream_sha"; then
        printf 'Ref %s (%s) is outside fetched upstream/main history (%s) and was not verified as a published macOS release. No worktree created.\n' \
            "$pichi_upstream_ref" "$pichi_upstream_sha" "$pichi_upstream_main_sha" >&2
        exit 1
    fi
fi
if ! pichi_merge_base="$(git merge-base "$pichi_downstream_sha" "$pichi_upstream_sha")"; then
    printf '%s\n' 'origin/main and the selected upstream ref have no common ancestry. No worktree created.' >&2
    exit 1
fi
printf 'Downstream baseline (origin/main): %s\nUpstream target (%s): %s\nFetched upstream/main: %s\nCommon ancestor: %s\n' \
    "$pichi_downstream_sha" "$pichi_upstream_ref" "$pichi_upstream_sha" "$pichi_upstream_main_sha" "$pichi_merge_base"
if git merge-base --is-ancestor "$pichi_upstream_sha" "$pichi_downstream_sha"; then
    printf 'origin/main already contains the selected FluidVoice target (%s).\n' "$pichi_upstream_sha"
    exit 0
fi
pichi_directory="$(bash scripts/dev/new-worktree.sh upstream-sync "$pichi_downstream_sha")"
printf 'Sync worktree: %s\n' "$pichi_directory"
if git -C "$pichi_directory" merge --no-ff --no-commit "$pichi_upstream_sha"; then
    printf 'Review and test the pending merge in %s, then commit, push its branch, and open a PR.\n' "$pichi_directory"
else
    pichi_status=$?
    pichi_conflicts="$(git -C "$pichi_directory" diff --name-only --diff-filter=U)"
    if [[ -n "$pichi_conflicts" ]]; then
        printf 'Conflicted paths:\n%s\nResolve merge conflicts in %s. main was not changed.\n' \
            "$pichi_conflicts" "$pichi_directory" >&2
    else
        printf 'Merge stopped with exit status %s in %s. Inspect the Git error above. main was not changed.\n' \
            "$pichi_status" "$pichi_directory" >&2
    fi
    exit "$pichi_status"
fi
