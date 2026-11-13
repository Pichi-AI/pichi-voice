#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-apple-intelligence-command.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Compile exactly the production pure core exercised by this probe. The unrelated
# FoundationModels macro host cannot run inside a nested sandbox.
python3 - "$task_test_dir/Core.swift" <<'CORE'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/AppleIntelligenceCommandProvider.swift').read_text()
core = source.split('// MARK: - Pure core\n', 1)[1].split('// MARK: - FoundationModels', 1)[0]
Path(sys.argv[1]).write_text('import Foundation\n' + core)
CORE
xcrun swiftc -parse-as-library \
    "$task_test_dir/Core.swift" \
    Tests/AppleIntelligenceCommandTests.swift \
    -o "$task_test_dir/apple-intelligence-tests"
"$task_test_dir/apple-intelligence-tests"
