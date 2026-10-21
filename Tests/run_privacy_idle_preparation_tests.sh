#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/privacy-idle-preparation-tests"
mkdir -p "$task_test_dir"
# Compile the actual preparation/lifecycle owners with their actual error declarations.
# No ONNX binding, native app, audio API, model artifact or network request is needed.
python3 - "$task_test_dir/PreparationOwners.swift" "$task_test_dir/ActualMobileLifecycle.swift" <<'PY'
from pathlib import Path
import sys
service = Path('Sources/Fluid/Services/Privacy/PichiTranscriptPrivacyService.swift').read_text()
descriptor = Path('Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIIModelDescriptor.swift').read_text()
errors = descriptor[descriptor.index('public enum TextPrivacyError:'):descriptor.index('public struct PIIModelArtifact:')]
resource_error = next(line for line in service.splitlines() if line.startswith('enum TextPrivacyResourceError:'))
owners = service[service.index('/// Owns the shared privacy loader'):]
Path(sys.argv[1]).write_text('import Foundation\n' + errors + resource_error + '\n' + owners)
app = Path('Sources/Mobile/MobileApp.swift').read_text()
methods = app[app.index('    func signalUIReady()'):app.index('    func didReceiveMemoryWarning()')]
view = app[app.index('struct PichiVoiceMobileApp: App'):]
task = view[view.index('            }.task {'):view.index('            .onChange(of: scenePhase')]
operations = '\n'.join(line.strip().replace('scenePhase == .active', 'capturedSceneActive')
                       for line in task.splitlines() if 'await services.' in line)
initial = '.onChange(of: scenePhase, initial: true)' in view
Path(sys.argv[2]).write_text('import Foundation\nextension IdleSceneHostProbe {\n' + methods + '\n}\n'
    + '@MainActor func runInitialMobileTask(services: IdleSceneHostProbe, capturedSceneActive: Bool) async {\n'
    + operations + '\n}\nlet mobileSceneUsesInitialCallback = ' + str(initial).lower() + '\n')
PY
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/PreparationOwners.swift" Tests/PrivacyIdlePreparationTests.swift \
    "$task_test_dir/ActualMobileLifecycle.swift" \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
