#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
pichi_test_dir=$(mktemp -d /tmp/pichi-brand-profile.XXXXXX)
trap 'rm -rf "$pichi_test_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library -D FLUID_ASR_BASELINE Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift Sources/Fluid/Services/FileLogger.swift Tests/BrandProfileTests.swift -o "$pichi_test_dir/tests"
"$pichi_test_dir/tests"
