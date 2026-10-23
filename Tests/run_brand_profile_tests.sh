#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
pichi_test_dir=$(mktemp -d /tmp/pichi-brand-profile.XXXXXX)
trap 'rm -rf "$pichi_test_dir"' EXIT HUP INT TERM
# Compile the production path and staging declarations without the catalog's
# unrelated network, model and Combine dependencies. Native XCTest also calls
# defaultCacheURL on the complete production catalog.
python3 -S - "$pichi_test_dir" "${PICHI_MODEL_FEED_CATALOG_SOURCE:-Sources/Fluid/Services/CompactSpeechModelReleaseCatalog.swift}" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path(sys.argv[2]).read_text()
start = source.index('    private nonisolated static var usesStaging: Bool {')
end = source.index('    private nonisolated static func fixedURL(', start)
declarations = source[start:end]
assert declarations.count('static func defaultCacheURL()') == 1
# The historical declaration was private; exposing it only in the projection
# lets this same regression fail against the old shared Release path.
declarations = declarations.replace('private nonisolated static func defaultCacheURL()',
                                    'nonisolated static func defaultCacheURL()')
(out / 'ModelFeedCacheProjection.swift').write_text(
    'import Foundation\nnonisolated enum CompactSpeechModelReleaseCatalog {\n'
    + declarations + '\n}\n')
PY
python3 Tests/Support/write_private_profile_standalone_types.py "$pichi_test_dir/ProfileTypes.swift"
xcrun swiftc -parse-as-library -module-cache-path "$pichi_test_dir/ModuleCache" -D FLUID_ASR_BASELINE Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift "$pichi_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Services/FileLogger.swift Sources/Fluid/Services/DebugLogger.swift "$pichi_test_dir/ModelFeedCacheProjection.swift" Tests/BrandProfileTests.swift -o "$pichi_test_dir/tests"
"$pichi_test_dir/tests"
xcrun swiftc -parse-as-library -module-cache-path "$pichi_test_dir/ModuleCache" -D DEBUG -D FLUID_ASR_BASELINE Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift "$pichi_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift Sources/Fluid/Services/FileLogger.swift Sources/Fluid/Services/DebugLogger.swift "$pichi_test_dir/ModelFeedCacheProjection.swift" Tests/BrandProfileTests.swift -o "$pichi_test_dir/debug-tests"
# CLI probes inside real, isolated bundle layouts exercise Bundle.main identity.
# They only compute URLs: no model feed fetch, app launch or user-state writes.
python3 -S - "$pichi_test_dir" <<'PY'
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
root = Path(sys.argv[1])
cases = [
    ('release-a', 'tests', 'org.example.voice-feed.release-a', [], 'speech-model-feed.json'),
    ('release-b', 'tests', 'org.example.voice-feed.release-b', [], 'speech-model-feed.json'),
    ('release-staging-ignored', 'tests', 'org.example.voice-feed.release-b', ['--fv-model-feed=staging'], 'speech-model-feed.json'),
    ('debug', 'debug-tests', 'org.example.voice-feed.debug', [], 'speech-model-feed.json'),
    ('debug-staging', 'debug-tests', 'org.example.voice-feed.debug', ['--fv-model-feed=staging'], 'speech-model-feed-staging.json'),
    ('missing', 'tests', None, [], 'speech-model-feed.json'),
    ('invalid', 'tests', '../FluidVoice', [], 'speech-model-feed.json'),
]
for name, binary, identity, arguments, filename in cases:
    contents = root / (name + '.app') / 'Contents'
    executable = contents / 'MacOS' / 'probe'
    executable.parent.mkdir(parents=True)
    shutil.copy2(root / binary, executable)
    info = {'CFBundleExecutable': 'probe', 'CFBundlePackageType': 'APPL'}
    if identity is not None:
        info['CFBundleIdentifier'] = identity
    (contents / 'Info.plist').write_bytes(plistlib.dumps(info))
    expected = identity if identity not in (None, '../FluidVoice') else 'local.voice.unbundled'
    subprocess.run([str(executable), '--model-feed-cache-only', expected, filename, *arguments], check=True)
print('Seven real-bundle model feed cache Release/Debug/staging/invalid-identity probes passed')
PY
