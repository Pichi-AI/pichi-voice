#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/publication-consent-tests"
mkdir -p "$task_test_dir"
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/AccountDomain.swift Sources/Fluid/Account/AccountPKCE.swift \
    Sources/Fluid/Account/AccountLegacyTransport.swift Sources/Fluid/Account/AccountSessionService.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationConsentStore.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationWire.swift \
    Sources/Fluid/Services/CloudPublication/PichiProtectedPublicationPayload.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationRetryPolicy.swift \
    Sources/Fluid/Services/CloudPublication/PichiPublicationHTTPClient.swift \
    Tests/PichiPublicationConsentTests.swift Tests/PichiPublicationWireTests.swift \
    Tests/PichiPublicationAssessmentOptionsTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir/fixtures-$(uuidgen)" "$PWD/Tests/Fixtures/PichiAccountSyncV1"
