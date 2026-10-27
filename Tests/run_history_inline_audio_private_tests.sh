#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
mkdir -p "$PWD/.build"
task_test_dir=$(mktemp -d "${PICHI_HISTORY_INLINE_AUDIO_TEST_OUTPUT_DIR:-$PWD/.build/history-inline-audio-private-tests}.XXXXXX")
trap 'python3 -S -c "import shutil,sys; shutil.rmtree(sys.argv[1])" "$task_test_dir"' EXIT
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/UI/HistoryInlineAudioView.swift').read_text()
start = source.index('// MARK: - Joined inline playback lifetime')
owner = source[start:]
out = Path(sys.argv[1])
(out / 'ProductionAVOwner.swift').write_text('import AVFoundation\nimport Combine\nimport Foundation\n' + owner)
(out / 'SyntheticAVOwner.swift').write_text('import Combine\nimport Foundation\n' + owner)
assert 'DictationAudioHistoryStore.shared' not in owner
assert 'await lookup.value' in owner and 'lookup.cancel()' in owner
assert owner.count('await deadline?.value') == 2
assert 'self.player?.currentItem?.cancelPendingSeeks()' in owner
assert 'self.player?.replaceCurrentItem(with: nil)' in owner
assert 'for task in Array(self.tasks.values) { await task.value }' in owner
assert 'Task { @MainActor in\n                        guard let player' not in source
PY
# Compile the exact owner against real AVFoundation signatures without running it.
xcrun swiftc -typecheck -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Tests/HistoryInlineAudioPlaybackFixtures.swift "$task_test_dir/ProductionAVOwner.swift"
# Run that same owner against synthetic AV contracts without touching audio hardware.
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Tests/HistoryInlineAudioPlaybackFixtures.swift "$task_test_dir/SyntheticAVOwner.swift" \
    Tests/HistoryInlineAudioPlaybackTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
