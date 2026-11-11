#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p "$PWD/.build"
task_test_dir=$(mktemp -d "$PWD/.build/admitted-pronunciation-read-tests.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
xcrun swiftc -target x86_64-apple-macosx15.0 -parse-as-library -swift-version "${PICHI_TEST_SWIFT_VERSION:-5}" \
    -D DICTIONARY_CORRECTION_REAL_CANDIDATE \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/AccountDomain.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Sources/Fluid/Services/PronunciationDictionaryStore.swift Sources/Fluid/Services/DictionaryAudioInspection.swift \
    Sources/Fluid/Services/DictionaryAcousticEvidence.swift \
    Sources/Fluid/Services/DictionaryLearningEvidence.swift Sources/Fluid/Services/DictionaryNegativeExamples.swift \
    Sources/Fluid/Services/DictionaryExperimentalMatcher.swift Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift \
    Sources/Fluid/Services/AutomaticDictionaryCorrectionDetector.swift \
    Tests/Support/PrivateProfileStoresSupport.swift \
    Tests/AdmittedPronunciationReadTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$@"
