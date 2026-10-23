#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$PWD/.build"
task_test_dir=$(mktemp -d "${PICHI_HISTORY_PRIVATE_TEST_OUTPUT_DIR:-$PWD/.build/history-private-projection-tests}.XXXXXX")
trap 'python3 -S -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$task_test_dir"' EXIT
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/UI/TranscriptionHistoryView.swift').read_text()
imports = '\n'.join(line for line in source.splitlines() if line.startswith('import ')) + '\n'
start = source.index('// MARK: - Joined history projection lifetime')
end = source.index('// MARK: - History feedback sheet', start)
(Path(sys.argv[1]) / 'HistoryPrivateProjection.swift').write_text(
    imports + source[start:end])
# Typecheck the actual asynchronous native save-panel boundary without presenting it.
export_start = source.index('    private func exportPair(_ entry: TranscriptionHistoryEntry)')
export_end = source.index('    // MARK: - No Selection View', export_start)
with (Path(sys.argv[1]) / 'HistoryPrivateProjection.swift').open('a') as output:
    output.write('@MainActor struct HistoryExportCompileFixture {\n'
        ' let projection: HistoryPrivateProjection\n'
        ' private func hasAudio(_ entry: TranscriptionHistoryEntry) -> Bool { false }\n'
        + source[export_start:export_end] + '}\n')
assert '.task(id: self.audioAvailabilityRequest)' not in source
assert 'DispatchQueue.main.async { proxy.scrollTo(id) }' not in source
assert 'self.projection.isCurrent(ticket), response == .OK, let url = panel.url' in source
assert 'panel.begin { continuation.resume(returning: $0) }' in source
assert 'panel.runModal()' not in source
assert 'TranscriptionFeedbackReportSheet(projection: self.projection)' in source
# Preserve the existing behavior/presentation suite using exact production values.
def declaration(text, marker):
    assert text.count(marker) == 1
    start = text.index(marker)
    end = text.index('{', start) + 1
    depth = 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

for path, markers, name in [
    ('Sources/Fluid/Persistence/TranscriptionHistoryStore.swift',
     ['nonisolated struct TranscriptionHistoryEntry:'], 'HistoryValues.swift'),
    ('Sources/Fluid/Persistence/DictationAudioHistoryStore.swift',
     ['nonisolated struct DictationAudioMetadata:'], 'AudioValues.swift'),
    ('Sources/Fluid/UI/TranscriptionHistoryView.swift',
     ['nonisolated struct HistoryPinRevealRequest:', 'nonisolated enum HistorySelectionRevealPolicy {'],
     'HistoryRevealValues.swift'),
]:
    text = Path(path).read_text()
    (Path(sys.argv[1]) / name).write_text(
        'import Foundation\n' + '\n'.join(declaration(text, marker) for marker in markers) + '\n')
PY
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -enable-upcoming-feature MemberImportVisibility \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/UI/HistoryAudioAvailability.swift \
    "$task_test_dir/HistoryPrivateProjection.swift" Tests/HistoryPrivateProjectionTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
xcrun swiftc -parse-as-library -swift-version 6 \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/HistoryValues.swift" "$task_test_dir/AudioValues.swift" \
    "$task_test_dir/HistoryRevealValues.swift" Sources/Fluid/UI/HistoryAudioAvailability.swift \
    Sources/Fluid/UI/HistoryTextDiff.swift Sources/Fluid/UI/ModelDisplayName.swift \
    Tests/HistoryPresentationTests.swift -o "$task_test_dir/presentation-tests"
"$task_test_dir/presentation-tests"
