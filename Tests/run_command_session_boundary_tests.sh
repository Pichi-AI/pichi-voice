#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-command-session.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT

# Compile the exact production session methods, excluding the model/terminal agent loop.
sed '/^    \/\/\/ Process user voice\/text command/,$d' Sources/Fluid/Services/CommandModeService.swift > "$task_test_dir/CommandModeService.swift"
cat >> "$task_test_dir/CommandModeService.swift" <<'SWIFT'
}

extension CommandModeService {
    func seedTransientStateForTests() {
        currentTurnCount = 7
        currentStep = .completed(false)
        streamingText = "old answer"
        streamingThinkingText = "old reasoning"
        streamingBuffer = ["old", " answer"]
        thinkingBuffer = ["old", " reasoning"]
        lastUIUpdate = 42
        lastThinkingUIUpdate = 43
    }

    var transientStateForTests: TransientState {
        TransientState(
            pendingID: pendingCommand?.id,
            currentTurnCount: currentTurnCount,
            currentStep: currentStep,
            streamingText: streamingText,
            streamingThinkingText: streamingThinkingText,
            streamingBuffer: streamingBuffer,
            thinkingBuffer: thinkingBuffer,
            lastUIUpdate: lastUIUpdate,
            lastThinkingUIUpdate: lastThinkingUIUpdate
        )
    }
}
SWIFT

# Keep the real store, replacing only UserDefaults with the in-memory double in the tests.
cp Sources/Fluid/Persistence/ChatHistoryStore.swift "$task_test_dir/ChatHistoryStore.swift"
cat >> "$task_test_dir/ChatHistoryStore.swift" <<'SWIFT'

extension ChatHistoryStore {
    static func reloadedForTests() -> ChatHistoryStore { ChatHistoryStore() }

    func resetForTests(sessions: [ChatSession], currentChatID: String) {
        self.sessions = sessions
        self.currentChatID = currentChatID
    }
}
SWIFT

python3 -B -S - "$task_test_dir/CommandModeService.swift" <<'PY'
from pathlib import Path
import sys
sys.path.insert(0, 'Tests')
from run_meeting_backup_refresh_tests import declaration
source = Path('Sources/Fluid/Services/CommandModeService.swift').read_text()
with Path(sys.argv[1]).open('a') as output:
    output.write('\nextension CommandModeService {\n'
        + declaration(source, '    func prepareForPrivateProfileTransition()') + '\n}\n')
PY
python3 -S Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift" --synthetic-brand --operation-owner
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileOperationOwner.swift \
    Tests/Support/StandaloneGuestProfileDefaults.swift \
    "$task_test_dir/CommandModeService.swift" \
    Sources/Fluid/Services/AppleIntelligenceCommandProvider.swift \
    "$task_test_dir/ChatHistoryStore.swift" \
    Sources/Fluid/Persistence/PersistedHistory.swift \
    Tests/CommandSessionBoundaryTests.swift \
    -o "$task_test_dir/session-tests"
"$task_test_dir/session-tests"
