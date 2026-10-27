#!/usr/bin/env bash
set -euo pipefail

pichi_source_root="$(cd "$(dirname "$0")/.." && pwd)"
pichi_test_root="$(mktemp -d "${TMPDIR:-/tmp}/pichi-upstream-sync.XXXXXX")"
trap 'rm -rf "$pichi_test_root"' EXIT

# All remotes and histories are synthetic, local and independent of user Git settings.
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME='Upstream sync test' GIT_AUTHOR_EMAIL='sync-test@example.invalid'
export GIT_COMMITTER_NAME="$GIT_AUTHOR_NAME" GIT_COMMITTER_EMAIL="$GIT_AUTHOR_EMAIL"

pichi_fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

pichi_assert_equal() {
    [[ "$1" == "$2" ]] || pichi_fail "$3: expected $2, got $1"
}

pichi_fixture() {
    pichi_case="$pichi_test_root/$1"
    pichi_upstream="$pichi_case/upstream"
    pichi_downstream="$pichi_case/downstream"
    mkdir -p "$pichi_upstream/scripts/dev"
    cp "$pichi_source_root/scripts/dev/prepare-upstream-sync.sh" "$pichi_upstream/scripts/dev/"
    cp "$pichi_source_root/scripts/dev/new-worktree.sh" "$pichi_upstream/scripts/dev/"
    cp "$pichi_source_root/scripts/dev/verify-published-upstream-release.py" "$pichi_upstream/scripts/dev/"
    git -C "$pichi_upstream" init -q -b main
    printf 'baseline\n' > "$pichi_upstream/shared.txt"
    git -C "$pichi_upstream" add .
    git -C "$pichi_upstream" commit -qm baseline
    pichi_common_sha="$(git -C "$pichi_upstream" rev-parse HEAD)"
    git clone -q --bare "$pichi_upstream" "$pichi_case/origin.git"
    git clone -q "$pichi_case/origin.git" "$pichi_downstream"
    git -C "$pichi_downstream" remote add upstream "$pichi_upstream"
    git -C "$pichi_downstream" config remote.upstream.fetch '+refs/heads/main:refs/remotes/upstream/main'
    git -C "$pichi_downstream" config remote.upstream.pushurl DISABLED
    printf 'downstream feature\n' > "$pichi_downstream/downstream.txt"
    if [[ "$1" == conflict ]]; then
        printf 'downstream\n' > "$pichi_downstream/shared.txt"
    fi
    git -C "$pichi_downstream" add .
    git -C "$pichi_downstream" commit -qm downstream
    git -C "$pichi_downstream" push -q origin main
    pichi_downstream_sha="$(git -C "$pichi_downstream" rev-parse HEAD)"
    printf 'released feature\n' > "$pichi_upstream/release.txt"
    if [[ "$1" == conflict ]]; then
        printf 'upstream\n' > "$pichi_upstream/shared.txt"
    fi
    git -C "$pichi_upstream" add .
    git -C "$pichi_upstream" commit -qm release
    git -C "$pichi_upstream" tag v1.6.11
    pichi_release_sha="$(git -C "$pichi_upstream" rev-parse HEAD)"
    printf 'later unreleased feature\n' > "$pichi_upstream/unreleased.txt"
    git -C "$pichi_upstream" add .
    git -C "$pichi_upstream" commit -qm unreleased
    pichi_upstream_main_sha="$(git -C "$pichi_upstream" rev-parse HEAD)"
}

pichi_sync() {
    if pichi_output="$(cd "$pichi_downstream" && PICHI_VOICE_WORKTREE_ROOT="$pichi_case/worktrees" \
        bash scripts/dev/prepare-upstream-sync.sh "$@" 2>&1)"; then
        pichi_status=0
    else
        pichi_status=$?
    fi
    pichi_directory="$(printf '%s\n' "$pichi_output" | sed -n 's/^Sync worktree: //p')"
}

pichi_worktree_count() {
    git -C "$pichi_downstream" worktree list --porcelain | awk '/^worktree / { count++ } END { print count }'
}

pichi_fixture clean
pichi_sync v1.6.11
pichi_assert_equal "$pichi_status" 0 'pinned release merge'
pichi_assert_equal "$(git -C "$pichi_directory" rev-parse MERGE_HEAD)" "$pichi_release_sha" 'release target'
pichi_assert_equal "$(git -C "$pichi_directory" rev-parse HEAD)" "$pichi_downstream_sha" 'frozen downstream baseline'
[[ -f "$pichi_directory/downstream.txt" && -f "$pichi_directory/release.txt" ]] || pichi_fail 'merge dropped a feature'
[[ ! -e "$pichi_directory/unreleased.txt" ]] || pichi_fail 'release sync imported unreleased main'
[[ "$pichi_output" == *"Downstream baseline (origin/main): $pichi_downstream_sha"* && \
    "$pichi_output" == *"Upstream target (v1.6.11): $pichi_release_sha"* && \
    "$pichi_output" == *"Common ancestor: $pichi_common_sha"* ]] || pichi_fail 'missing baseline report'
pichi_assert_equal "$(git -C "$pichi_downstream" rev-parse main)" "$pichi_downstream_sha" 'primary main after release sync'

pichi_sync
pichi_assert_equal "$pichi_status" 0 'default upstream/main merge'
pichi_assert_equal "$(git -C "$pichi_directory" rev-parse MERGE_HEAD)" "$pichi_upstream_main_sha" 'default target'
[[ -f "$pichi_directory/unreleased.txt" ]] || pichi_fail 'default sync omitted upstream main'

pichi_before="$(pichi_worktree_count)"
pichi_sync missing-release
[[ "$pichi_status" -ne 0 && "$pichi_output" == *'Cannot resolve upstream ref'* ]] || pichi_fail 'missing ref accepted'
pichi_assert_equal "$(pichi_worktree_count)" "$pichi_before" 'worktree count after missing ref'

# An unverified tag present on upstream but outside main must not be imported.
git -C "$pichi_upstream" checkout -q --orphan foreign
git -C "$pichi_upstream" rm -qrf .
printf 'unrelated history\n' > "$pichi_upstream/foreign.txt"
git -C "$pichi_upstream" add .
git -C "$pichi_upstream" commit -qm foreign
git -C "$pichi_upstream" tag foreign-release
git -C "$pichi_upstream" checkout -q main
pichi_sync foreign-release
[[ "$pichi_status" -ne 0 && "$pichi_output" == *'outside fetched upstream/main history'* ]] || pichi_fail 'foreign ref accepted'
pichi_assert_equal "$(pichi_worktree_count)" "$pichi_before" 'worktree count after foreign ref'

# A frozen base must remain selected even if origin/main advances before creation.
printf 'later downstream feature\n' > "$pichi_downstream/later.txt"
git -C "$pichi_downstream" add .
git -C "$pichi_downstream" commit -qm later-downstream
git -C "$pichi_downstream" push -q origin main
pichi_base_directory="$(cd "$pichi_downstream" && PICHI_VOICE_WORKTREE_ROOT="$pichi_case/worktrees" \
    bash scripts/dev/new-worktree.sh frozen-base "$pichi_downstream_sha" 2> "$pichi_case/frozen-base.log")"
pichi_assert_equal "$(git -C "$pichi_base_directory" rev-parse HEAD)" "$pichi_downstream_sha" 'explicit worktree base'
[[ ! -e "$pichi_base_directory/later.txt" ]] || pichi_fail 'frozen worktree imported later origin main'

git -C "$pichi_downstream" merge -q --no-ff -m 'already imported release' "$pichi_release_sha"
git -C "$pichi_downstream" push -q origin main
pichi_before="$(pichi_worktree_count)"
pichi_sync v1.6.11
pichi_assert_equal "$pichi_status" 0 'already imported release'
[[ "$pichi_output" == *'already contains the selected FluidVoice target'* ]] || pichi_fail 'missing no-update report'
pichi_assert_equal "$(pichi_worktree_count)" "$pichi_before" 'worktree count after no update'

pichi_fixture conflict
pichi_sync v1.6.11
[[ "$pichi_status" -ne 0 ]] || pichi_fail 'conflict sync succeeded'
[[ "$pichi_output" == *$'Conflicted paths:\nshared.txt'* && \
    "$pichi_output" == *"Resolve merge conflicts in $pichi_directory"* ]] || pichi_fail 'missing conflict path/location report'
pichi_assert_equal "$(git -C "$pichi_directory" rev-parse MERGE_HEAD)" "$pichi_release_sha" 'conflicted release target'
pichi_assert_equal "$(git -C "$pichi_directory" diff --name-only --diff-filter=U)" shared.txt 'unresolved conflict left for review'
pichi_assert_equal "$(git -C "$pichi_downstream" rev-parse main)" "$pichi_downstream_sha" 'primary main after conflict'
pichi_assert_equal "$(git -C "$pichi_downstream" ls-remote origin refs/heads/main | awk '{ print $1 }')" \
    "$pichi_downstream_sha" 'origin main after conflict'

printf '%s\n' 'Upstream sync tests passed: pinned release, default main, frozen base, no update, invalid refs and preserved conflicts.'
python3 -B -S "$pichi_source_root/Tests/test_published_upstream_release.py"
