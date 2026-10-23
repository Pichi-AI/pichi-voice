#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pichi-search-profile.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
python3 Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift" --synthetic-brand
# Keep the complete service and its async paths. Only the external index module import
# is removed; inert index/store/settings types are supplied by the fixture.
sed '/^import ZeppelinEmbed$/d' Sources/Fluid/Services/AppSearch/AppSearchService.swift > "$task_test_dir/AppSearchService.swift"
xcrun swiftc -default-isolation MainActor -parse-as-library \
    -module-cache-path "$task_test_dir/ModuleCache" "$task_test_dir/ProfileTypes.swift" \
    Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Services/AppSearch/AppSearchSnippet.swift \
    "$task_test_dir/AppSearchService.swift" Tests/AppSearchPrivateProfileTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
