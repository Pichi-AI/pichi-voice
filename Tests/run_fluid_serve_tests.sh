#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d /tmp/pichi-fluid-serve.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Compile the production persisted codecs and command, without launching the app.
python3 Tests/Support/write_attribution_standalone_types.py "$task_test_dir/AttributionTypes.swift" --fingerprint
# The temperature-key fixture injects an ordinary synthetic UserDefaults suite.
# Profile selection is outside this read-only helper probe and must never run here.
cat > "$task_test_dir/ProfileDefaultsSupport.swift" <<'SWIFT'
import Foundation
nonisolated struct PrivateProfileSnapshot {}
nonisolated final class PrivateProfileDefaults: UserDefaults, @unchecked Sendable {
    static var shared: UserDefaults { preconditionFailure("Unexpected shared profile preferences") }
    var selectedProfile: PrivateProfileSnapshot { preconditionFailure("Unexpected profile selection") }
    static func bound(to profile: PrivateProfileSnapshot) -> UserDefaults {
        preconditionFailure("Unexpected profile preferences binding")
    }
}
SWIFT
set -- "$task_test_dir/ProfileDefaultsSupport.swift" Sources/Fluid/Services/ModelTemperatureSupport.swift \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Services/Meeting/MeetingAudioAsset.swift \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Sources/Fluid/Services/Meeting/MeetingModels.swift \
    Sources/Fluid/Services/Meeting/MeetingSpeakerPresentation.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingSpeakerAttribution.swift \
    Sources/Fluid/Services/Meeting/Backend/MeetingReadingSpeakerResolver.swift \
    "$task_test_dir/AttributionTypes.swift" \
    Sources/Fluid/Services/Meeting/MeetingTranscriptExporter.swift \
    Sources/Fluid/Services/Meeting/MeetingSummaryInput.swift \
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
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" "$@" Tests/FluidServeProfileBoundaryTests.swift -o "$task_test_dir/profile-tests"
"$task_test_dir/profile-tests"
# Permanent deletion by a mutable name cannot prove which inode is removed.
python3 - <<'PYNODELETE'
from pathlib import Path
for name in ['FluidServeFileBoundary.swift', 'FluidServeSkillInstaller.swift']:
    source = Path('Sources/Fluid/Services/FluidServe', name).read_text()
    for operation in ['unlinkat(', 'unlink(', 'removeItem(']:
        assert operation not in source, f"Unsafe permanent cleanup reintroduced in {name}: {operation}"
print('FluidServe no-permanent-cleanup source checks passed')
PYNODELETE
