#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
brand_vocab_dir=$(mktemp -d /tmp/brand-vocabulary.XXXXXX)
trap 'rm -rf "$brand_vocab_dir"' EXIT HUP INT TERM
python3 -S - "$brand_vocab_dir/CaptureEvidenceFile.swift" <<'PYTHON'
from pathlib import Path
import sys
source = Path("Sources/Fluid/Services/DictionaryNegativeExamples.swift").read_text()
start = source.index("nonisolated final class DictionaryCaptureEvidenceFile")
end = source.index("\nnonisolated struct DictionaryAcousticEvidence", start)
Path(sys.argv[1]).write_text("import Foundation\nimport Darwin\n" + source[start:end])
PYTHON
# The Intel data-only store excludes the optional ARM FluidAudio integration.
# Apple Silicon uses its installed Rosetta runtime; no model/package downloads occur.
xcrun swiftc -target x86_64-apple-macosx15.0 -default-isolation MainActor -parse-as-library \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/AccountDomain.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift \
    "$brand_vocab_dir/CaptureEvidenceFile.swift" Sources/Fluid/Services/ParakeetVocabularyStore.swift Tests/FactoryBrandVocabularyTests.swift \
    -o "$brand_vocab_dir/tests"
"$brand_vocab_dir/tests"
