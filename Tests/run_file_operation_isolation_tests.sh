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
        cp "$task_test_dir/owned-domains.json" "$task_evidence_dir/owned-domains.json"
        cat > "$task_test_dir/cleanup-preferences.js" <<'JS'
ObjC.import('Foundation');
function run(args) {
    const source = $.NSString.stringWithContentsOfFileEncodingError(args[0], $.NSUTF8StringEncoding, null);
    const domains = JSON.parse(ObjC.unwrap(source));
    return JSON.stringify(domains.map(domain => {
        if (!/^synthetic\.file-operation\.[0-9A-F-]{36}$/.test(domain)
            && !/^local\.voice\.unbundled\.private-profile\.[a-f0-9]{64}$/.test(domain)) throw new Error('Unexpected fixture domain');
        const defaults = $.NSUserDefaults.alloc.initWithSuiteName(domain);
        defaults.removePersistentDomainForName(domain);
        if (!defaults.synchronize) throw new Error('Preference cleanup did not synchronize');
        const remaining = ObjC.deepUnwrap(defaults.persistentDomainForName(domain));
        const keys = remaining && typeof remaining === 'object' ? Object.keys(remaining).length : 0;
        if (keys !== 0) throw new Error('Preference cleanup left values');
        return { domain, synchronized: true, remainingKeys: keys };
    }));
}
JS
        osascript -l JavaScript "$task_test_dir/cleanup-preferences.js" "$task_test_dir/owned-domains.json" > "$task_evidence_dir/preferences-api-cleanup.json"
    fi
    python3 - "$task_test_dir/owned-domains.json" "$task_evidence_dir/preferences-cleanup.json" <<'PY'
from pathlib import Path
import json,sys,plistlib,time
manifest=Path(sys.argv[1]); output=Path(sys.argv[2]); rows=[]
if manifest.exists():
    domains=json.loads(manifest.read_text())
    deadline=time.monotonic()+10
    while True:
        pending=[]
        for domain in domains:
            target=Path.home()/"Library"/"Preferences"/(domain+".plist")
            if target.exists():
                assert not target.is_symlink()
                if plistlib.loads(target.read_bytes()): pending.append(domain)
        if not pending: break
        if time.monotonic()>=deadline:
            output.write_text(json.dumps({"pendingDomains":pending,"error":"Preference files have not drained"},indent=2)+"\n")
            raise RuntimeError("Owned preference file cleanup did not drain")
        time.sleep(0.1)
    for domain in domains:
        target=Path.home()/"Library"/"Preferences"/(domain+".plist")
        if target.exists():
            assert not target.is_symlink() and plistlib.loads(target.read_bytes())=={}
            target.unlink()
        rows.append({"domain":domain,"plistAbsent":not target.exists()})
output.write_text(json.dumps(rows,indent=2)+"\n")
PY
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
