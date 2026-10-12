#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
brand_menu_dir=$(mktemp -d /tmp/brand-native-menu.XXXXXX)
trap 'rm -rf "$brand_menu_dir"' EXIT HUP INT TERM
xcrun swiftc -default-isolation MainActor -parse-as-library \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Branding/BrandAppearanceController.swift Tests/BrandOwnedNativeMenuTests.swift \
    -o "$brand_menu_dir/tests"
"$brand_menu_dir/tests"
