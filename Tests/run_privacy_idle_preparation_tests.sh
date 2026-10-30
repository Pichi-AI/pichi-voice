#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/privacy-idle-preparation-tests"
mkdir -p "$task_test_dir"
# Compile the actual preparation/lifecycle owners with their actual error declarations.
# No ONNX binding, native app, audio API, model artifact or network request is needed.
python3 -B -S - "$task_test_dir/PreparationOwners.swift" "$task_test_dir/ActualMobileLifecycle.swift" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'Tests')
from run_meeting_backup_refresh_tests import declaration
service = Path('Sources/Fluid/Services/Privacy/PichiTranscriptPrivacyService.swift').read_text()
descriptor = Path('Vendor/PichiGigaAM/Sources/PichiTextPrivacy/PIIModelDescriptor.swift').read_text()
errors = descriptor[descriptor.index('public enum TextPrivacyError:'):descriptor.index('public struct PIIModelArtifact:')]
resource_error = next(line for line in service.splitlines() if line.startswith('enum TextPrivacyResourceError:'))
owners = service[service.index('/// Owns the shared privacy loader'):]
Path(sys.argv[1]).write_text('import Foundation\n' + errors + resource_error + '\n' + owners)
app = Path('Sources/Mobile/MobileApp.swift').read_text()
methods = '\n'.join(declaration(app, marker) for marker in (
    '    func signalUIReady()', '    private func restoreInitialLocalStateIfReady()',
    '    func setSceneActive(', '    private func updateIdlePreparation()'))
view = app[app.index('struct PichiVoiceMobileApp: App'):]
task = view[view.index('            }.task {'):view.index('            .onChange(of: scenePhase')]
# Exercise the ordinary startup task. Debug review compositions have their own
# lifecycles and must not be flattened into this production path.
operations = []
debug_depth = 0
for line in task.splitlines():
    stripped = line.strip()
    if stripped.startswith('#if '):
        assert debug_depth or stripped.startswith('#if DEBUG'), stripped
        debug_depth += 1
    elif stripped == '#endif':
        debug_depth -= 1
        assert debug_depth >= 0
    elif stripped.startswith(('#else', '#elseif')):
        raise AssertionError('Review changed startup conditional before projecting its ordinary path')
    elif debug_depth == 0 and 'await services.' in line:
        operations.append(stripped.replace('scenePhase == .active', 'capturedSceneActive'))
assert debug_depth == 0 and operations
operations = '\n'.join(operations)
initial = '.onChange(of: scenePhase, initial: true)' in view
Path(sys.argv[2]).write_text('import Foundation\nextension IdleSceneHostProbe {\n' + methods + '\n}\n'
    + '@MainActor func runInitialMobileTask(services: IdleSceneHostProbe, capturedSceneActive: Bool) async {\n'
    + operations + '\n}\nlet mobileSceneUsesInitialCallback = ' + str(initial).lower() + '\n')
PY
python3 -B -S Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift" --synthetic-brand
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/PreparationOwners.swift" Tests/PrivacyIdlePreparationTests.swift \
    "$task_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift \
    "$task_test_dir/ActualMobileLifecycle.swift" \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
