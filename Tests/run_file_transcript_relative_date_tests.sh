#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="$task_repo_dir/.build/file-relative-date-tests"
mkdir -p "$task_test_dir"

# Observe calls in the real formatter without replacing its behavior. Existing
# standalone store dependencies keep all persistence in memory.
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import sys

output = Path(sys.argv[1])
support = Path('Tests/FileTranscriptRenameTests.swift').read_text().split('@main @MainActor struct FileTranscriptRenameTests {')[0]
write = 'func set(_ value: Any?, forKey key: String) { self.values[key] = value }'
assert support.count(write) == 1
support = support.replace(write, 'func set(_ value: Any?, forKey key: String) { self.values[key] = value; RelativeDateTimeProbe.shared.recordWrite() }')
(output / 'StandaloneSupport.swift').write_text(support)

source = Path('Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift').read_text()
result = 'return formatter.localizedString(for: self.timestamp, relativeTo: reference)'
assert source.count(result) == 1
source = source.replace(result, 'let value = formatter.localizedString(for: self.timestamp, relativeTo: reference)\n'
                       '        RelativeDateTimeProbe.shared.record(locale: locale, reference: reference, value: value)\n'
                       '        return value')
(output / 'FileTranscriptionHistoryStore.swift').write_text(source)

environment = Path('Sources/Fluid/Theme/Components/FluidPageLayout.swift').read_text()
boundary = 'private struct FluidPageActions<Actions: View>: ViewModifier {'
assert environment.count(boundary) == 1
(output / 'PageVisibilityEnvironment.swift').write_text(environment[:environment.index(boundary)])
PY

xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/StandaloneSupport.swift" \
    "$task_test_dir/FileTranscriptionHistoryStore.swift" \
    "$task_test_dir/PageVisibilityEnvironment.swift" \
    Sources/Fluid/Persistence/PersistedHistory.swift \
    Sources/Fluid/UI/FileTranscriptRelativeDateLabel.swift \
    Tests/FileTranscriptRelativeDateTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir"
