#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="$task_repo_dir/.build/typography-tests"
mkdir -p "$task_test_dir"
xcrun swiftc -parse-as-library \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift \
    Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Theme/FluidTypography.swift \
    Tests/FluidTypographyTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests" "$@"
