#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
mkdir -p .build/overlay-caption-tests
task_test_dir=$(mktemp -d "$PWD/.build/overlay-caption-tests/run.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# Keep production package metadata and typography, without reading an installed brand store.
sed '/^nonisolated final class BrandPackageStore:/,$d' Sources/Fluid/Branding/BrandPackage.swift > "$task_test_dir/BrandPackageTypes.swift"
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    "$task_test_dir/BrandPackageTypes.swift" Tests/Support/StandaloneBrandPackageStore.swift \
    Sources/Fluid/Branding/BrandDistribution.swift Sources/Fluid/Theme/FluidTypography.swift \
    Sources/Fluid/UI/OverlayCaptionView.swift Tests/OverlayCaptionTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
