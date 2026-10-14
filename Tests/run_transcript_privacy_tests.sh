#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_build_dir="$PWD/.build/pii-swiftpm"
swift test --jobs 2 --package-path Vendor/PichiGigaAM --scratch-path "$task_build_dir" --filter PichiTextPrivacyTests
task_test_dir="$PWD/.build/pii-resource-harness"
mkdir -p "$task_test_dir"
# Compile the owning downloader unchanged without its unrelated FluidAudio
# extensions. This harness uses injected transport; it never downloads models.
python3 - "$task_test_dir/ProgressiveFileDownloader.swift" <<'PY'
import sys
from pathlib import Path
source = Path('Sources/Fluid/Networking/ModelDownloader.swift').read_text()
start = source.index('final nonisolated class ProgressiveFileDownloader')
end = source.index('#if arch(arm64)', start)
Path(sys.argv[1]).write_text('import Foundation\n' + source[start:end])
PY
task_products="$task_build_dir/out/Products/Debug"
task_frameworks="$task_build_dir/artifacts/onnxruntime-swift-package-manager/onnxruntime/onnxruntime.xcframework/macos-arm64_x86_64"
xcrun swiftc -parse-as-library -swift-version 5 -default-isolation MainActor \
    -I "$task_products" -L "$task_products" -lPichiTextPrivacy \
    -F "$task_frameworks" -framework onnxruntime -lc++ \
    -Xcc "-fmodule-map-file=$task_build_dir/out/Intermediates.noindex/GeneratedModuleMaps/OnnxRuntimeBindings.modulemap" \
    -Xcc "-I$task_build_dir/checkouts/onnxruntime-swift-package-manager/objectivec/include" \
    -Xcc "-I$task_products/include" \
    -Xlinker -rpath -Xlinker "$task_frameworks" \
    Sources/Fluid/Services/Privacy/TranscriptTextRedacting.swift \
    Sources/Fluid/Services/Privacy/PichiTranscriptPrivacyService.swift \
    "$task_test_dir/ProgressiveFileDownloader.swift" \
    Tests/TranscriptPrivacyResourceTests.swift \
    -o "$task_test_dir/privacy-resource-tests"
"$task_test_dir/privacy-resource-tests"
