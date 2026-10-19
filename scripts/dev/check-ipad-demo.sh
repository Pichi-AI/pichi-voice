#!/usr/bin/env bash
# Read-only recipient preflight. Never builds, provisions, installs or launches.
set -euo pipefail

usage() {
    printf '%s\n' \
        'Usage: bash check-ipad-demo.sh --check --revision FULL_ORIGINAL_SHA [--source-dir DIR]' \
        'Verify the delivered archive SHA-256 separately before using its original revision.'
}
fail() { printf 'STOP: %s\n' "$*" >&2; exit 1; }
pichi_source="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
pichi_revision=''
pichi_check=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) pichi_check=1; shift ;;
        --revision|--source-dir)
            [[ $# -ge 2 && -n "$2" ]] || { usage >&2; exit 2; }
            if [[ "$1" == --revision ]]; then pichi_revision="$2"; else pichi_source="$2"; fi
            shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) usage >&2; exit 2 ;;
    esac
done
[[ "$pichi_check" == 1 ]] || { usage >&2; exit 2; }
[[ "$pichi_revision" =~ ^[0-9a-fA-F]{40}$ ]] || fail 'Supply the full original SHA from the verified delivery manifest.'
[[ -f "$pichi_source/Fluid.xcodeproj/project.pbxproj" && -f "$pichi_source/Sources/Mobile/Info.plist" ]] || fail 'Source directory does not contain the mobile project.'
[[ "$(uname -s)" == Darwin ]] || fail 'A Mac with full Xcode is required.'

printf 'Delivered original revision (caller supplied): %s\n' "$pichi_revision"
printf 'Sources: %s\n' "$(cd "$pichi_source" && pwd)"
printf 'Host: %s, macOS %s\n' "$(uname -m)" "$(sw_vers -productVersion)"
case "$(uname -m)" in
    arm64) printf '%s\n' 'Apple Silicon host. This check does not establish that this toolchain builds the project.' ;;
    x86_64) printf '%s\n' 'Intel or Rosetta host. This recipient build route has not been verified on Intel. Do not infer support from this check.' ;;
    *) fail 'Unrecognized Mac architecture; verify the toolchain manually.' ;;
esac

command -v xcode-select >/dev/null || fail 'Install full Xcode, launch it and finish component setup.'
pichi_developer="$(xcode-select -p)" || fail 'Select full Xcode in Xcode Settings > Locations.'
[[ "$pichi_developer" == */Contents/Developer && -d "$pichi_developer/Platforms/iPhoneOS.platform" ]] || fail 'Active developer directory must be full Xcode with the iOS platform, not Command Line Tools.'
command -v xcodebuild >/dev/null || fail 'xcodebuild is unavailable.'
xcodebuild -version || fail 'Launch Xcode and finish its first-run setup.'
pichi_sdk="$(xcodebuild -sdk iphoneos -version SDKVersion)" || fail 'Install the iOS platform in Xcode Settings > Components.'
[[ "$pichi_sdk" =~ ^[0-9]+([.][0-9]+)*$ ]] || fail 'Cannot read the installed iPhoneOS SDK version.'
[[ "${pichi_sdk%%.*}" -ge 17 ]] || fail 'The project requires an iPhoneOS SDK supporting iOS 17 or newer.'
printf 'Installed iPhoneOS SDK: %s\n' "$pichi_sdk"
for pichi_tool in git python3 codesign security xcrun; do
    command -v "$pichi_tool" >/dev/null || fail "Missing prerequisite: $pichi_tool"
done
printf '\n%s\n' \
    'Local prerequisites found. This is not a successful build or device compatibility check.' \
    'Next: follow docs/development/ipad-demo-install-via-mac.md in Xcode.' \
    'Use your own Personal Team and unique bundle ID, keep both for later updates.' \
    'Set PICHI_SOURCE_REVISION to the original revision above, even after a local archive import.' \
    'Build Release, disable Debug executable and keep DerivedData/package checkouts inside the worktree.' \
    'Before replacing an existing app: export current meetings, settings and your voice profile; stop recording and processing.' \
    'Verify the signed app revision, team, bundle ID, profile expiry and exact device membership before installing.' \
    'Never uninstall the app, reset its container or delete data to resolve a signing problem.' \
    'Apple Account sign-in, device pairing, iPadOS compatibility and provisioning remain to be checked in Xcode.'
