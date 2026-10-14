#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-highlights.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Reuse the brand schema without admitting the production disk/defaults store.
sed '/^nonisolated final class BrandPackageStore:/,$d' Sources/Fluid/Branding/BrandPackage.swift > "$task_test_dir/BrandPackageTypes.swift"
xcrun swiftc -parse-as-library \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift \
    "$task_test_dir/BrandPackageTypes.swift" \
    Tests/Support/StandaloneBrandPackageStore.swift \
    Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/UI/ReleaseHighlightsPolicy.swift \
    Sources/Fluid/UI/ReleaseHighlightsContent.swift \
    Tests/ReleaseHighlightsPolicyTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
