#!/bin/sh

set -eu

swift build --build-tests

products_dir=$(swift build --show-bin-path)
source_framework="$products_dir/CTranscribe.framework"
staged_frameworks="$products_dir/PackageFrameworks"

if [ ! -d "$source_framework" ]; then
    echo "error: CTranscribe.framework was not produced at $source_framework" >&2
    exit 1
fi

mkdir -p "$staged_frameworks"
rm -rf "$staged_frameworks/CTranscribe.framework"
ditto "$source_framework" "$staged_frameworks/CTranscribe.framework"

swift test --skip-build "$@"
