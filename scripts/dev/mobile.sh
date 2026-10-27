#!/bin/bash
set -euo pipefail
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_dir"
if [[ "$(git rev-parse --git-dir)" == ".git" ]]; then
    printf 'Mobile builds must run in an isolated worktree.\n' >&2
    exit 1
fi
mode="${1:-build}"
build_dir="$repo_dir/.build/mobile"
mkdir -p "$build_dir"
# Xcode's simulator signing embeds the app-scoped Keychain entitlement. Unsigned
# compilation can be requested explicitly, but cannot exercise kiosk access.
args=(-project Fluid.xcodeproj -scheme PichiVoiceMobile -configuration Debug -derivedDataPath "$build_dir/DerivedData" -clonedSourcePackagesDirPath "$build_dir/SourcePackages" -sdk iphonesimulator -destination "${PICHI_MOBILE_DESTINATION:-generic/platform=iOS Simulator}" "CODE_SIGNING_ALLOWED=${PICHI_MOBILE_CODE_SIGNING_ALLOWED:-YES}")
case "$mode" in
    build) xcodebuild "${args[@]}" build ;;
    build-for-testing) xcodebuild "${args[@]}" build-for-testing ;;
    test) xcodebuild "${args[@]}" test ;;
    *) printf 'Usage: bash scripts/dev/mobile.sh [build|build-for-testing|test]\n' >&2; exit 2 ;;
esac
