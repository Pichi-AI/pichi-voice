#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/mobile-account-tests"
mkdir -p "$task_test_dir"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/Account*.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Mobile/MobileAccount.swift Sources/Mobile/MobilePresentationDocument.swift \
    Tests/MobileAccountInteractionTests.swift Tests/MobilePrivatePublicationTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
