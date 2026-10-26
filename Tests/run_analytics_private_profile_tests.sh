#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d "${TMPDIR:-/tmp}/pichi-analytics-profile.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
python3 Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift" --synthetic-brand
# The real actor is file-private. Append tests to its unchanged source; only transport and
# unrelated SettingsStore are inert doubles. Real SQLite/profile/defaults declarations compile.
cat Sources/Fluid/Analytics/AnalyticsService.swift Tests/AnalyticsPrivateProfileTests.swift > "$task_test_dir/AnalyticsServiceAndTests.swift"
xcrun swiftc -default-isolation MainActor -parse-as-library \
    -module-cache-path "$task_test_dir/ModuleCache" "$task_test_dir/ProfileTypes.swift" \
    Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Sources/Fluid/Analytics/AnalyticsConfig.swift Sources/Fluid/Analytics/AnalyticsEvent.swift \
    Sources/Fluid/Analytics/AnalyticsSystemConfiguration.swift Sources/Fluid/Analytics/AnalyticsDatabase.swift \
    Sources/Fluid/Analytics/AnalyticsIdentityStore.swift "$task_test_dir/AnalyticsServiceAndTests.swift" \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
