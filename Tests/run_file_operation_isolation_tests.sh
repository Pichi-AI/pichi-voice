#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/file-operation-isolation-tests"
mkdir -p "$task_test_dir"
task_evidence_base="$PWD/private_assets/test-artifacts/file-operation-isolation"
mkdir -p "$task_evidence_base"
task_evidence_dir=$(mktemp -d "$task_evidence_base/run.XXXXXX")
echo "Evidence: $task_evidence_dir"
cleanup() {
    if [ -f "$task_test_dir/owned-domains.json" ]; then
        python3 -S Tests/Support/cleanup_file_operation_preferences.py \
            --manifest "$task_test_dir/owned-domains.json" \
            --evidence "$task_evidence_dir/preferences-cleanup"
    fi
    rm -rf "$task_test_dir"
}
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
# The provider's optional enrollment capability carries this production value.
# Keep its declaration current without loading the unrelated dictionary pipeline.
python3 -S - "$task_test_dir/DictionaryLearningAudioEvidence.swift" <<'PY'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Services/DictionaryLearningEvidence.swift').read_text()
marker = 'nonisolated struct DictionaryLearningAudioEvidence:'
assert source.count(marker) == 1, 'Expected one production audio-evidence declaration'
start = source.index(marker)
end = source.index('{', start) + 1
depth = 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
# The evidence carries DictionaryLearningFeatureFrames (a93663b2), which wraps the real
# DictionaryAudioInspection.Frames compiled below from its production file.
frames_marker = 'nonisolated struct DictionaryLearningFeatureFrames:'
assert source.count(frames_marker) == 1, 'Expected one production feature-frames declaration'
frames_start = source.index(frames_marker)
frames_end = source.index('\n}\n', frames_start) + 3
# DictionaryAudioInspection throws this exact production error; the playground actor is excluded.
playground = Path('Sources/Fluid/Services/DictionaryMatchPlayground.swift').read_text()
error_marker = 'enum DictionaryMatchPlaygroundError: LocalizedError {'
assert playground.count(error_marker) == 1, 'Expected one production playground error declaration'
error_start = playground.index(error_marker)
error_end = playground.index('\n}\n', error_start) + 3
Path(sys.argv[1]).write_text('import Foundation\n' + playground[error_start:error_end] + '\n' + source[frames_start:frames_end] + '\n' + source[start:end] + '\n')
PY
xcrun swiftc -target x86_64-apple-macosx15.0 -parse-as-library -swift-version 5 \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/DictionaryLearningAudioEvidence.swift" \
    Sources/Fluid/Services/DictionaryAudioInspection.swift \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/AccountDomain.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift Sources/Fluid/Account/PrivateProfileOperationOwner.swift \
    Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift Sources/Fluid/Persistence/PersistedHistory.swift \
    Sources/Fluid/Services/TranscriptionProvider.swift Sources/Fluid/Services/ASRActivityLease.swift \
    Sources/Fluid/Services/FileTranscriptionService.swift Tests/Support/FileOperationIsolationSupport.swift \
    Tests/FileOperationIsolationTests.swift -o "$task_test_dir/tests" > "$task_evidence_dir/compile.log" 2>&1 || {
        cat "$task_evidence_dir/compile.log"; exit 1;
    }
"$task_test_dir/tests" "$task_test_dir/fixtures" "$task_test_dir/owned-domains.json" > "$task_evidence_dir/run.log" 2>&1 || {
    cat "$task_evidence_dir/run.log"; exit 1;
}
cat "$task_evidence_dir/run.log"
