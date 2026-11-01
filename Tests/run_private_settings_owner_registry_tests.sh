#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_root="$task_repo_dir/.build/private-settings-owner-registry-tests"
mkdir -p "$task_test_root"
task_test_dir=$(mktemp -d "$task_test_root/run.XXXXXX")
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM

# Compile the real registry, registration, operation and join declarations with
# inert surrounding settings dependencies. No user defaults, credentials or model work.
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import sys

out = Path(sys.argv[1])
def declaration(source, marker):
    assert source.count(marker) == 1, marker
    start = source.index(marker)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]

def line(source, marker):
    matches = [value for value in source.splitlines() if marker in value]
    assert len(matches) == 1, marker
    return matches[0]

sources = []
for name, filename, slot, join, operation, before, after in [
    ('AIEnhancementSettingsViewModel', 'AIEnhancementSettingsViewModel.swift', 'privateRequests', 'joinPrivateProfileRequests', 'privateProfileRequest<Value: Sendable>', '        self.selectedProviderID = settings.selectedProviderID\n', '        self.profileTransitionCancellable ='),
    ('PrivateAISettingsController', 'PrivateAISettingsController.swift', 'privateTasks', 'joinPrivateProfileTasks', 'startProfileTask(', '        self.session = PrivateAISettingsSession(selectedModelID: PrivateAIIntegrationService.configuredModelID)\n', '        self.profileObserver ='),
]:
    source = Path('Sources/Fluid/UI/AISettings', filename).read_text()
    registration = source.split(before, 1)[1].split(after, 1)[0]
    parts = [declaration(source, '    private final class WeakOwner {'),
             line(source, 'private static var profileOwners:'), line(source, 'private var ' + slot + ':'),
             declaration(source, '    static func ' + join + '('),
             declaration(source, '    private func ' + operation)]
    if name == 'AIEnhancementSettingsViewModel':
        properties = 'var profileIsCurrent = true'
        initializer = 'init() {\n' + registration + '\n}'
        shim = '''func run(_ operation: @escaping @MainActor @Sendable () async throws -> Int) async throws -> Int {
            try await self.privateProfileRequest(operation)
        }'''
    else:
        properties = 'let viewModel: AIEnhancementSettingsViewModel'
        initializer = 'init(viewModel: AIEnhancementSettingsViewModel) { self.viewModel = viewModel\n' + registration + '\n}'
        shim = '''func run(_ operation: @escaping @MainActor () async -> Void) { self.startProfileTask(operation) }'''
    # This test-only observer reads production storage; it does not replace cleanup logic.
    sources.append('@MainActor final class ' + name + ' {\n' + properties + '\n' + '\n'.join(parts) + '\n' + initializer + '\n' + shim + '\nstatic var retainedRegistrationCount: Int { self.profileOwners.count }\n}\n')
(out / 'ProductionRegistryBoundary.swift').write_text('import Foundation\n' + '\n'.join(sources))
PY

xcrun swiftc -parse-as-library -swift-version 5 -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ProductionRegistryBoundary.swift" Tests/PrivateSettingsOwnerRegistryTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
