#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="$PWD/.build/private-profile-stores-tests"
mkdir -p "$task_test_dir"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# Extract only the policy class. The unrelated Accessibility observer is owned by composition.
sed '/^final class AutomaticDictionaryCorrectionTracker/,$d' \
    Sources/Fluid/Services/AutomaticDictionaryCorrectionTracker.swift | sed '$ { /^@MainActor$/d; }' > "$task_test_dir/CorrectionPolicy.swift"
xcrun swiftc -target x86_64-apple-macosx15.0 -parse-as-library -swift-version 5 \
    -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Account/AccountDomain.swift Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Sources/Fluid/Persistence/DictationAudioHistoryStore.swift \
    Sources/Fluid/Services/DictionaryHistoryReplacement.swift \
    Sources/Fluid/Persistence/TranscriptionHistoryDatabase.swift Sources/Fluid/Persistence/TranscriptionHistoryStore.swift \
    Sources/Fluid/Persistence/ChatHistoryStore.swift Sources/Fluid/Persistence/FileTranscriptionHistoryStore.swift \
    Sources/Fluid/Persistence/PersistedHistory.swift Sources/Fluid/Services/ParakeetVocabularyStore.swift \
    Sources/Fluid/Services/PronunciationDictionaryStore.swift Sources/Fluid/Services/DictionaryAudioInspection.swift \
    Sources/Fluid/Services/DictionaryAcousticEvidence.swift \
    Sources/Fluid/Services/DictionaryLearningEvidence.swift Sources/Fluid/Services/DictionaryNegativeExamples.swift \
    Sources/Fluid/Services/DictionaryExperimentalMatcher.swift Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingOwnerVoiceProfile.swift Sources/Fluid/Services/TranscriptionExecutor.swift \
    "$task_test_dir/CorrectionPolicy.swift" Tests/Support/PrivateProfileStoresSupport.swift \
    Tests/PrivateProfileStoresTests.swift -lsqlite3 -o "$task_test_dir/tests"
"$task_test_dir/tests"
