#!/bin/sh
set -eu
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
case "$task_developer_dir" in
    */Xcode*.app/Contents/Developer) ;;
    *) echo "Set DEVELOPER_DIR to an installed full Xcode." >&2; exit 1 ;;
esac
export DEVELOPER_DIR="$task_developer_dir"
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
task_test_dir=$(mktemp -d /tmp/fluidvoice-dictionary-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Reuse the brand schema without admitting the production disk/defaults store.
sed '/^nonisolated final class BrandPackageStore:/,$d' "$task_repo_dir/Sources/Fluid/Branding/BrandPackage.swift" > "$task_test_dir/BrandPackageTypes.swift"
xcrun swiftc -D DICTIONARY_EXPERIMENT_STANDALONE -O -parse-as-library \
    "$task_repo_dir/Sources/Fluid/Localization/PichiLocalization.swift" \
    "$task_repo_dir/Sources/Fluid/Branding/AppBrand.swift" \
    "$task_test_dir/BrandPackageTypes.swift" \
    "$task_repo_dir/Tests/Support/StandaloneBrandPackageStore.swift" \
    "$task_repo_dir/Sources/Fluid/Branding/BrandDistribution.swift" \
    "$task_repo_dir/Sources/Fluid/Account/AccountDomain.swift" \
    "$task_repo_dir/Sources/Fluid/Account/PrivateProfileStorage.swift" \
    "$task_repo_dir/Sources/Fluid/Account/PrivateProfileDefaults.swift" \
    "$task_repo_dir/Sources/Fluid/Services/ParakeetSpeechModelCatalog.swift" \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift" \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryExperimentalMatcher.swift" \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryNegativeExamples.swift" \
    "$task_repo_dir/Sources/Fluid/Services/DictionaryLearningEvidence.swift" \
    "$task_repo_dir/Tests/Standalone/DictionaryMatcherExperimentTests.swift" \
    -o "$task_test_dir/tests"
PICHI_DICTIONARY_TEST_PROFILE_MANIFEST="$task_test_dir/domains.json" "$task_test_dir/tests" "$@"
python3 -S "$task_repo_dir/Tests/Support/remove_empty_synthetic_preferences.py" "$task_test_dir/domains.json"
