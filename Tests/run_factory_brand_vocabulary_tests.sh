#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
brand_vocab_dir=$(mktemp -d /tmp/brand-vocabulary.XXXXXX)
trap 'rm -rf "$brand_vocab_dir"' EXIT HUP INT TERM
# The Intel data-only store excludes the optional ARM FluidAudio integration.
# Apple Silicon uses its installed Rosetta runtime; no model/package downloads occur.
xcrun swiftc -target x86_64-apple-macosx15.0 -default-isolation MainActor -parse-as-library \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Services/ParakeetVocabularyStore.swift Tests/FactoryBrandVocabularyTests.swift \
    -o "$brand_vocab_dir/tests"
"$brand_vocab_dir/tests"
