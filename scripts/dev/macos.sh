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
pichi_arch="$(uname -m)"
case "$pichi_arch" in
    arm64|x86_64) ;;
    *) printf 'Unsupported macOS architecture: %s\n' "$pichi_arch" >&2; exit 1 ;;
esac
pichi_destination="platform=macOS,arch=$pichi_arch"
pichi_test_args=(
    -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture
)
pichi_args=(
    -project Fluid.xcodeproj
    -scheme Fluid
    -destination "$pichi_destination"
    -derivedDataPath "$pichi_root/.build/Xcode"
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
    touch "$pichi_run/build-start"
    # Debug is required for the existing test-host launch and language overrides.
    pichi_build_status=0
    xcodebuild "${pichi_args[@]}" -configuration Debug \
        -resultBundlePath "$pichi_run/build.xcresult" build-for-testing \
        2>&1 | tee "$pichi_run/build.log" || pichi_build_status=$?
    if [[ "$pichi_build_status" -ne 0 ]]; then
        printf 'Build failed (exit %s); tests were not run.\n' "$pichi_build_status" \
            | tee "$pichi_run/summary.txt"
        exit "$pichi_build_status"
    fi
    pichi_xctestrun="$(python3 -S scripts/dev/macos-regression.py configure \
        "$pichi_root/.build/Xcode/Build/Products" "$pichi_run/build-start" "$pichi_run_id")"
    pichi_test_status=0
    xcodebuild -xctestrun "$pichi_xctestrun" -destination "$pichi_destination" \
        -resultBundlePath "$pichi_run/tests.xcresult" -parallel-testing-enabled NO \
        "${pichi_test_args[@]}" test-without-building 2>&1 | tee "$pichi_run/test.log" \
        || pichi_test_status=$?
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
