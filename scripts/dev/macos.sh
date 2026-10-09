#!/usr/bin/env bash
set -euo pipefail

pichi_action="${1:-}"
if [[ "$pichi_action" != "build" && "$pichi_action" != "test" ]]; then
    printf '%s\n' 'Usage: bash scripts/dev/macos.sh build|test' >&2
    exit 1
fi
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
if [[ "$(uname -s)" != "Darwin" ]]; then
    printf '%s\n' 'This command requires macOS and full Xcode.' >&2
    exit 1
fi
pichi_args=(
    -project Fluid.xcodeproj
    -scheme Fluid
    -destination 'platform=macOS,arch=arm64'
    -derivedDataPath "$pichi_root/.build/Xcode"
    -clonedSourcePackagesDirPath "$pichi_root/.build/SourcePackages"
    CODE_SIGN_IDENTITY=
    CODE_SIGNING_REQUIRED=NO
    CODE_SIGNING_ALLOWED=NO
)
if [[ "$pichi_action" == "test" ]]; then
    pichi_args+=(
        -skip-testing:FluidDictationIntegrationTests/DictationE2ETests/testDictationEndToEnd_whisperTiny_transcribesFixture
    )
fi
exec xcodebuild "${pichi_args[@]}" "$pichi_action"
