#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/privacy-idle-preparation-tests"
mkdir -p "$task_test_dir"
# Compile the actual preparation/lifecycle owners with their actual error declarations.
# No ONNX binding, native app, audio API, model artifact or network request is needed.
python3 - "$task_test_dir/PreparationOwners.swift" <<'PY'
from pathlib import Path
import sys
service = Path('Sources/Fluid/Services/Privacy/PichiTranscriptPrivacyService.swift').read_text()
descriptor = Path('Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIIModelDescriptor.swift').read_text()
errors = descriptor[descriptor.index('public enum TextPrivacyError:'):descriptor.index('public struct PIIModelArtifact:')]
resource_error = next(line for line in service.splitlines() if line.startswith('enum TextPrivacyResourceError:'))
owners = service[service.index('/// Owns the shared privacy loader'):]
Path(sys.argv[1]).write_text('import Foundation\n' + errors + resource_error + '\n' + owners)
PY
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/PreparationOwners.swift" Tests/PrivacyIdlePreparationTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
