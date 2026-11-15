#!/usr/bin/env bash
set -euo pipefail

pichi_action="${1:-}"
if [[ "$pichi_action" != "build" && "$pichi_action" != "test" && "$pichi_action" != "regression" ]]; then
    printf '%s\n' 'Usage: bash scripts/dev/macos.sh build|test|regression [-only-testing:target/class/test ...]' >&2
    exit 1
fi
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'This command requires macOS and full Xcode.' >&2
    exit 1
fi
pichi_destination='platform=macOS,arch=arm64'
pichi_test_args=(
    -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture
)
# A separate directory keeps the regression identity from replacing the product of macos.sh build.
pichi_derived_data="$pichi_root/.build/Xcode"
if [[ "$pichi_action" == "regression" ]]; then
    pichi_derived_data="$pichi_root/.build/XcodeRegression"
fi
pichi_args=(
    -project Fluid.xcodeproj
    -scheme Fluid
    -destination "$pichi_destination"
    -derivedDataPath "$pichi_derived_data"
    -clonedSourcePackagesDirPath "$pichi_root/.build/SourcePackages"
    CODE_SIGN_IDENTITY=
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
)
if [[ "$pichi_action" == "test" ]]; then
    pichi_args+=("${pichi_test_args[@]}")
fi
if [[ "$pichi_action" == "regression" ]]; then
    shift
    for pichi_selector in "$@"; do
        case "$pichi_selector" in
            -only-testing:*|-skip-testing:*) pichi_test_args+=("$pichi_selector") ;;
            *) printf 'Unsupported regression argument: %s\n' "$pichi_selector" >&2; exit 1 ;;
        esac
    done
    pichi_revision="$(git rev-parse HEAD)"
    pichi_run_id="$(date -u +%Y%m%dT%H%M%SZ)-${pichi_revision:0:8}-$$"
    pichi_run="$pichi_root/.build/regression/$pichi_run_id"
    mkdir -p "$pichi_run"
    printf 'Revision: %s\n' "$pichi_revision" > "$pichi_run/run.txt"
    if [[ -n "$(git status --porcelain)" ]]; then
        printf '%s\n' 'Working tree: dirty' >> "$pichi_run/run.txt"
    else
        printf '%s\n' 'Working tree: clean' >> "$pichi_run/run.txt"
    fi
    printf 'Regression artifacts: %s\n' "$pichi_run"
    case "$pichi_root" in
        "$HOME"/Documents/*)
            printf '%s\n' 'Warning: this worktree is under ~/Documents. macOS can block the test host in open() here.' \
                'If the host hangs, use a worktree outside ~/Documents.' >&2
            ;;
    esac
    touch "$pichi_run/build-start"
    # Debug is required for the existing test-host launch and language overrides.
    pichi_build_status=0
    # Tests write settings and caches under their bundle identity. Keep them away from manual Debug builds.
    xcodebuild "${pichi_args[@]}" -configuration Debug PICHI_BUNDLE_IDENTIFIER=ai.pichi.voice.regression \
        -resultBundlePath "$pichi_run/build.xcresult" build-for-testing \
        2>&1 | tee "$pichi_run/build.log" || pichi_build_status=$?
    if [[ "$pichi_build_status" -ne 0 ]]; then
        printf 'Build failed (exit %s); tests were not run.\n' "$pichi_build_status" \
            | tee "$pichi_run/summary.txt"
        exit "$pichi_build_status"
    fi
    # Each run gets its own home, so Application Support, Caches and model folders start empty and nothing a
    # run downloads or writes reaches the shared regression identity. PICHI_REGRESSION_SHARED_HOME=1 keeps
    # the shared identity for a deliberate real-model replay.
    pichi_test_home=""
    pichi_home_args=()
    if [[ "${PICHI_REGRESSION_SHARED_HOME:-}" != "1" ]]; then
        pichi_test_home="$pichi_run/home"
        pichi_home_args=(--home "$pichi_test_home")
    fi
    pichi_xctestrun="$(python3 -S scripts/dev/macos-regression.py configure \
        "$pichi_derived_data/Build/Products" "$pichi_run/build-start" "$pichi_run_id" ${pichi_home_args[@]+"${pichi_home_args[@]}"})"
    # Every worktree tests under the same identity, so its preferences and Keychain items are shared
    # (Application Support is per run, see above). Builds stay parallel; test runs take turns through one lock.
    pichi_lock="${PICHI_REGRESSION_LOCK:-$HOME/Library/Caches/pichi-voice-regression.lock}"
    pichi_lock_waited=0
    while ! mkdir "$pichi_lock" 2>/dev/null; do
        pichi_lock_owner="$(cat "$pichi_lock/pid" 2>/dev/null || true)"
        # A holder that ended, or one that never wrote its pid within a minute, left the lock behind.
        if { [[ -n "$pichi_lock_owner" ]] && ! kill -0 "$pichi_lock_owner" 2>/dev/null \
                && [[ "$(cat "$pichi_lock/pid" 2>/dev/null || true)" == "$pichi_lock_owner" ]]; } \
            || { [[ -z "$pichi_lock_owner" ]] && [[ -n "$(find "$pichi_lock" -maxdepth 0 -mmin +1 2>/dev/null)" ]]; }; then
            printf 'Removing a stale regression lock of process %s.\n' "${pichi_lock_owner:-unknown}" >&2
            rm -rf "$pichi_lock"
            continue
        fi
        if (( pichi_lock_waited % 60 == 0 )); then
            printf 'Waiting for the tests of %s (pid %s) to finish.\n' \
                "$(cat "$pichi_lock/root" 2>/dev/null || printf 'another worktree')" "${pichi_lock_owner:-unknown}" >&2
        fi
        sleep 2
        pichi_lock_waited=$((pichi_lock_waited + 2))
    done
    printf '%s\n' "$$" > "$pichi_lock/pid"
    printf '%s\n' "$pichi_root" > "$pichi_lock/root"
    # The home belongs to this run alone: it is removed with the lock, also after an interruption.
    trap 'rm -rf "$pichi_lock" ${pichi_test_home:+"$pichi_test_home"}' EXIT
    if [[ -n "$pichi_test_home" ]]; then
        mkdir -p "$pichi_test_home/Library/Application Support" "$pichi_test_home/Library/Caches"
    fi
    printf 'Regression lock taken after %s s of waiting.\n' "$pichi_lock_waited" >> "$pichi_run/run.txt"
    pichi_test_status=0
    xcodebuild -xctestrun "$pichi_xctestrun" -destination "$pichi_destination" \
        -derivedDataPath "$pichi_derived_data" \
        -resultBundlePath "$pichi_run/tests.xcresult" -parallel-testing-enabled NO \
        "${pichi_test_args[@]}" test-without-building 2>&1 | tee "$pichi_run/test.log" \
        || pichi_test_status=$?
    rm -rf "$pichi_lock"
    if [[ -n "$pichi_test_home" ]]; then
        printf 'Test home held %s before removal.\n' "$(du -sh "$pichi_test_home" 2>/dev/null | cut -f1)" >> "$pichi_run/run.txt"
        rm -rf "$pichi_test_home"
    fi
    trap - EXIT
    # Extract the actual report even when xcodebuild failed. Missing results fail closed.
    pichi_summary_status=0
    xcrun xcresulttool get test-results summary --path "$pichi_run/tests.xcresult" \
        --compact > "$pichi_run/summary.json" 2> "$pichi_run/summary-error.log" \
        || pichi_summary_status=$?
    if [[ "$pichi_summary_status" -eq 0 ]]; then
        python3 -S scripts/dev/macos-regression.py summarize "$pichi_run/summary.json" \
            "$pichi_test_status" 2>&1 | tee "$pichi_run/summary.txt" || pichi_summary_status=$?
    else
        cat "$pichi_run/summary-error.log" >&2
        printf 'Test report unavailable; xcodebuild exit: %s.\n' "$pichi_test_status" \
            | tee "$pichi_run/summary.txt"
    fi
    if [[ "$pichi_test_status" -ne 0 ]]; then
        exit "$pichi_test_status"
    fi
    exit "$pichi_summary_status"
fi
exec xcodebuild "${pichi_args[@]}" "$pichi_action"
