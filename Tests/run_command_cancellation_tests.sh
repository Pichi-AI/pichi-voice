#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
if [ ! -d "$task_developer_dir/Platforms/MacOSX.platform" ]; then
    echo "Select a full Xcode with DEVELOPER_DIR before running these tests." >&2
    exit 1
fi
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-command-cancellation.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
task_test_bundle="$task_test_dir/CommandCancellationFixture.app"
mkdir -p "$task_test_bundle/Contents/MacOS" "$task_test_bundle/Contents/Resources"
python3 -S - "$task_test_bundle/Contents/Info.plist" <<'PY'
from pathlib import Path
import plistlib
import sys
Path(sys.argv[1]).write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'ai.pichi.command-cancellation.fixture',
    'CFBundleExecutable': 'tests', 'CFBundlePackageType': 'APPL',
    'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'ru'],
}))
PY
xcrun xcstringstool compile Sources/Fluid/Localization/Localizable.xcstrings \
    --output-directory "$task_test_bundle/Contents/Resources" --language en --language ru
# Reuse the brand schema without admitting the production disk/defaults store.
sed '/^nonisolated final class BrandPackageStore:/,$d' Sources/Fluid/Branding/BrandPackage.swift > "$task_test_dir/BrandPackageTypes.swift"
# Relaunch uses the real store initializer and persisted bytes, without saving or switching chats.
cp Sources/Fluid/Persistence/ChatHistoryStore.swift "$task_test_dir/ChatHistoryStore.swift"
cat >> "$task_test_dir/ChatHistoryStore.swift" <<'SWIFT'

extension ChatHistoryStore {
    func reloadFromPersistenceForTests() {
        let restored = ChatHistoryStore(defaults: self.defaults)
        self.sessions = restored.sessions
        self.currentChatID = restored.currentChatID
    }
}
SWIFT
# Include the actual voice continuation and notch submit methods to cover their await boundaries.
python3 - "$task_test_dir/CommandUI.swift" <<'PYCODE'
from pathlib import Path
import sys
voice = Path('Sources/Fluid/ContentView.swift').read_text()
a = voice.index('    private func processCommandWithVoice(')
b = voice.index('    /// Capture app context', a)
notch = Path('Sources/Fluid/Views/NotchContentViews.swift').read_text()
c = notch.index('    private func submitFollowUp()')
d = notch.index('\n}\n', c)
Path(sys.argv[1]).write_text('import Foundation\n@MainActor extension VoiceCommandOwner {\n' + voice[a:b].replace('private func', 'func', 1) + '}\n@MainActor extension NotchInputOwner {\n' + notch[c:d].replace('private func', 'func', 1) + '\n}\n')
PYCODE
# The actual result value parser must also preserve provider/tool-owned metadata.
{ echo 'import Foundation'; sed -n '/^struct CommandToolOutput:/,$p' Sources/Fluid/Views/CommandMessageView.swift; } > "$task_test_dir/CommandToolOutput.swift"
# Compile the entire production agent, including streaming callbacks and recursive turns.
# Only its model, terminal, UI, and UserDefaults dependencies are test doubles.
python3 Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift"
xcrun swiftc -parse-as-library \
    "$task_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift \
    Tests/Support/StandaloneGuestProfileDefaults.swift \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift \
    "$task_test_dir/BrandPackageTypes.swift" \
    Tests/Support/StandaloneBrandPackageStore.swift \
    Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Services/CommandModeService.swift \
    "$task_test_dir/ChatHistoryStore.swift" \
    Sources/Fluid/Persistence/PersistedHistory.swift \
    Tests/CommandCancellationTests.swift \
    "$task_test_dir/CommandUI.swift" \
    "$task_test_dir/CommandToolOutput.swift" \
    -o "$task_test_bundle/Contents/MacOS/tests"
"$task_test_bundle/Contents/MacOS/tests"
