#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
logo_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pichi-brand-logo.XXXXXX")
trap 'rm -rf "$logo_test_dir"' EXIT HUP INT TERM
python3 Tests/Support/write_private_profile_standalone_types.py "$logo_test_dir/ProfileTypes.swift"
xcrun swiftc -default-isolation MainActor -parse-as-library \
    -module-cache-path "$logo_test_dir/ModuleCache" -D FLUID_ASR_BASELINE \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    "$logo_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Services/FileLogger.swift Sources/Fluid/Services/DebugLogger.swift Sources/Fluid/Branding/PichiBrandMark.swift \
    Sources/Fluid/Theme/Components/FluidVoiceBrandIcon.swift Tests/BrandLogoRenderingTests.swift \
    -o "$logo_test_dir/tests"
"$logo_test_dir/tests"
