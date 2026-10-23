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
xcrun swiftc -target x86_64-apple-macosx15.0 -parse-as-library -swift-version 5 \
    -module-cache-path "$task_test_dir/ModuleCache" \
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
