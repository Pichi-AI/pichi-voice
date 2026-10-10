#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
text_catalog_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$text_catalog_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$text_catalog_developer_dir"
mkdir -p .build
text_catalog_test_dir=$(mktemp -d .build/text-model-catalog-tests.XXXXXX)
trap 'rm -rf "$text_catalog_test_dir"' EXIT
sed '/^    \/\/ MARK: - Fetch Models from API/,$d' Sources/Fluid/Services/ModelRepository.swift > "$text_catalog_test_dir/ModelRepository.swift"
echo '}' >> "$text_catalog_test_dir/ModelRepository.swift"
xcrun swiftc -parse-as-library \
    "$text_catalog_test_dir/ModelRepository.swift" \
    Sources/Fluid/Services/LocalTextModelCatalog.swift \
    Tests/LocalTextModelCatalogTests.swift \
    -o "$text_catalog_test_dir/catalog-tests"
"$text_catalog_test_dir/catalog-tests"
