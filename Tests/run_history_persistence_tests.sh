#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-history-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Reuse the brand schema without admitting the production disk/defaults store.
sed '/^nonisolated final class BrandPackageStore:/,$d' Sources/Fluid/Branding/BrandPackage.swift > "$task_test_dir/BrandPackageTypes.swift"
# Compile the production record and history mapping without pulling in the
# unrelated file-transcript/chat stores and their app dependencies.
sed '/^extension FileTranscriptionEntry/,$d' \
    Sources/Fluid/Persistence/Search/SearchIndexRecord.swift > "$task_test_dir/HistorySearchRecord.swift"
xcrun swiftc -O -parse-as-library \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift \
    "$task_test_dir/BrandPackageTypes.swift" \
    Tests/Support/StandaloneBrandPackageStore.swift \
    Sources/Fluid/Branding/BrandDistribution.swift \
    "$task_test_dir/HistorySearchRecord.swift" \
    Sources/Fluid/Persistence/TranscriptionHistoryDatabase.swift \
    Sources/Fluid/Persistence/TranscriptionHistoryStore.swift \
    Tests/HistoryPersistenceBoundaryTests.swift \
    -lsqlite3 -o "$task_test_dir/history-tests"
"$task_test_dir/history-tests"
