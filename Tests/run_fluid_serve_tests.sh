#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d /tmp/pichi-fluid-serve.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Compile the production persisted codecs and command, without launching the app.
set -- Sources/Fluid/Services/ModelTemperatureSupport.swift \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    Sources/Fluid/Services/Meeting/PichiMeetingSummaryDocument.swift \
    Sources/Fluid/Services/FluidServe/FluidServeFileBoundary.swift \
    Sources/Fluid/Services/FluidServe/FluidServeSkill.swift \
    Sources/Fluid/Services/FluidServe/FluidServeMeetings.swift \
    Sources/Fluid/Services/FluidServe/FluidServeCommand.swift
xcrun swiftc -module-cache-path "$task_test_dir/ModuleCache" "$@" Sources/FVServe/main.swift -o "$task_test_dir/fv-serve"
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" "$@" Tests/FluidServeGroundedSummaryTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir/fv-serve"
# Reuse production appearance metadata with the existing isolated store support.
python3 - "$task_test_dir/BrandPackageMetadata.swift" <<'PYMETA'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Branding/BrandPackage.swift').read_text()
Path(sys.argv[1]).write_text(source[:source.index('nonisolated final class BrandPackageStore:')])
PYMETA
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" "$@" \
    Sources/Fluid/Branding/AppBrand.swift "$task_test_dir/BrandPackageMetadata.swift" Sources/Fluid/Branding/BrandDistribution.swift \
    Tests/Support/StandaloneBrandPackageStore.swift \
    Sources/Fluid/Services/FluidServe/FluidServeSkillInstaller.swift Tests/FluidServeSkillContainmentTests.swift \
    -o "$task_test_dir/skill-tests"
"$task_test_dir/skill-tests"
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" "$@" Tests/FluidServeContainmentTests.swift -o "$task_test_dir/containment-tests"
"$task_test_dir/containment-tests"
# Permanent deletion by a mutable name cannot prove which inode is removed.
python3 - <<'PYNODELETE'
from pathlib import Path
for name in ['FluidServeFileBoundary.swift', 'FluidServeSkillInstaller.swift']:
    source = Path('Sources/Fluid/Services/FluidServe', name).read_text()
    for operation in ['unlinkat(', 'unlink(', 'removeItem(']:
        assert operation not in source, f"Unsafe permanent cleanup reintroduced in {name}: {operation}"
print('FluidServe no-permanent-cleanup source checks passed')
PYNODELETE
