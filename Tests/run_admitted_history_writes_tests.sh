#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/admitted-history-writes-tests"
mkdir -p "$task_test_dir"
task_evidence_base="$PWD/private_assets/test-artifacts/admitted-history-writes"
mkdir -p "$task_evidence_base"
task_evidence_dir=$(mktemp -d "$task_evidence_base/run.XXXXXX")
echo "Evidence: $task_evidence_dir"
cleanup() {
    python3 - "$task_test_dir/owned-domains.json" "$task_evidence_dir/preferences-cleanup.json" <<'PY_CLEANUP'
from pathlib import Path
import json,sys,plistlib
manifest=Path(sys.argv[1]); output=Path(sys.argv[2]); rows=[]
if manifest.exists():
    for domain in json.loads(manifest.read_text()):
        assert domain.startswith("synthetic.admitted-history.")
        target=Path.home()/"Library"/"Preferences"/(domain+".plist")
        if target.exists():
            assert not target.is_symlink() and plistlib.loads(target.read_bytes())=={}
            target.unlink()
        rows.append({"domain":domain,"plistAbsent":not target.exists()})
output.write_text(json.dumps(rows,indent=2)+"\n")
PY_CLEANUP
    rm -rf "$task_test_dir"
}
trap cleanup EXIT HUP INT TERM
# Extract only the policy class. The unrelated Accessibility observer is owned by composition.
sed '/^final class AutomaticDictionaryCorrectionTracker/,$d' \
    Sources/Fluid/Services/AutomaticDictionaryCorrectionTracker.swift | sed '$ { /^@MainActor$/d; }' > "$task_test_dir/CorrectionPolicy.swift"
xcrun swiftc -target x86_64-apple-macosx15.0 -parse-as-library -swift-version 5 \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/AccountDomain.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Sources/Fluid/Account/PrivateDictationCaptureOutput.swift \
    Sources/Fluid/Account/PrivateDirectDictationCapture.swift \
    Sources/Fluid/Persistence/DictationAudioHistoryStore.swift \
    Sources/Fluid/Persistence/TranscriptionHistoryDatabase.swift Sources/Fluid/Persistence/TranscriptionHistoryStore.swift \
    Sources/Fluid/Persistence/ChatHistoryStore.swift Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift \
    Sources/Fluid/Persistence/PersistedHistory.swift Sources/Fluid/Services/ParakeetVocabularyStore.swift \
    Sources/Fluid/Services/PronunciationDictionaryStore.swift Sources/Fluid/Services/DictionaryAudioInspection.swift \
    Sources/Fluid/Services/DictionaryLearningEvidence.swift Sources/Fluid/Services/DictionaryNegativeExamples.swift \
    Sources/Fluid/Services/DictionaryExperimentalMatcher.swift Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingOwnerVoiceProfile.swift Sources/Fluid/Services/TranscriptionExecutor.swift \
    "$task_test_dir/CorrectionPolicy.swift" Tests/Support/PrivateProfileStoresSupport.swift \
    Tests/AdmittedHistoryWritesTests.swift Tests/PrivateDictationCaptureOutputTests.swift \
    Tests/Support/PrivateDirectCaptureSupport.swift Tests/PrivateDirectCaptureTests.swift -lsqlite3 -o "$task_test_dir/tests" > "$task_evidence_dir/compile.log" 2>&1 || {
        cat "$task_evidence_dir/compile.log"; exit 1;
    }
"$task_test_dir/tests" "$task_test_dir/fixtures" "$task_test_dir/owned-domains.json" > "$task_evidence_dir/run.log" 2>&1 || {
    cat "$task_evidence_dir/run.log"; exit 1;
}
cat "$task_evidence_dir/run.log"
