#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir="${PICHI_STATS_TEST_OUTPUT_DIR:-$PWD/.build/stats-snapshot-tests}"
mkdir -p "$task_test_dir/StatsCatalog.bundle"
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import plistlib
import sys
out = Path(sys.argv[1])
# Exact production presentation boundaries must consume the tested contracts.
heatmap = Path('Sources/Fluid/UI/StatsHeatmapView.swift').read_text()
assert 'Text(row.isMultiple(of: 2) ? self.weekdayLabels[row] : "")' in heatmap
assert 'Calendar.current' not in heatmap
hero = Path('Sources/Fluid/UI/StatsTodayHero.swift').read_text()
share = Path('Sources/Fluid/UI/StatsShareCard.swift').read_text()
assert 'Text(PichiLocalization.formattedStreakUnit(days: self.streak))' in hero
assert 'PichiLocalization.formattedStreakUnit(days: self.content.currentStreak)' in share
# Use real value types, never production disk/defaults history/audio stores.
for source, marker, name in [
    ('Sources/Fluid/Persistence/TranscriptionHistoryStore.swift', '\n@MainActor final class DictationHistoryWriteAdmission {', 'HistoryValue.swift'),
    ('Sources/Fluid/Persistence/DictationAudioHistoryStore.swift', '\nnonisolated final class DictationAudioSaveAdmission:', 'AudioValue.swift'),
    ('Sources/Fluid/Branding/BrandPackage.swift', 'nonisolated final class BrandPackageStore:', 'BrandPackageTypes.swift'),
]:
    text = Path(source).read_text()
    assert text.count(marker) == 1, source
    (out / name).write_text(text.split(marker)[0])
(out / 'SettingsFixture.swift').write_text(Path('Tests/UIContrastTests.swift').read_text().split('@main')[0])
theme = Path('Sources/Fluid/Theme/ThemeEnvironment.swift').read_text()
start = theme.index('struct AdaptiveAppTheme<Content: View>: View {')
end = theme.index('// MARK: - Color Hex Initializer')
(out / 'ThemeEnvironment.swift').write_text(theme[:start] + theme[end:])
bundle = out / 'StatsCatalog.bundle'
(bundle / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.voice.stats-catalog.fixture', 'CFBundleDevelopmentRegion': 'en'}))
empty = out / 'EmptyCatalog.bundle'
empty.mkdir(exist_ok=True)
(empty / 'Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier': 'local.voice.empty-stats-catalog.fixture', 'CFBundleDevelopmentRegion': 'en'}))
# Installed partial translation: this key is deliberately absent, so the real
# production lookup must fall back using the source language's plural rules.
partial = bundle / 'fr.lproj'
partial.mkdir(exist_ok=True)
(partial / 'Localizable.strings').write_bytes(plistlib.dumps({'Settings': 'Paramètres'}, fmt=plistlib.FMT_XML))
PY
xcrun xcstringstool compile Sources/Fluid/Localization/Localizable.xcstrings --output-directory "$task_test_dir/StatsCatalog.bundle"
python3 Tests/Support/write_private_profile_standalone_types.py "$task_test_dir/ProfileTypes.swift"
xcrun swiftc -O -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/ProfileTypes.swift" Sources/Fluid/Account/PrivateProfileStorage.swift \
    Sources/Fluid/Account/PrivateProfileDefaults.swift \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift "$task_test_dir/BrandPackageTypes.swift" \
    Tests/Support/StandaloneBrandPackageStore.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Theme/FluidTypography.swift Sources/Fluid/Theme/AppTheme.swift \
    "$task_test_dir/ThemeEnvironment.swift" Sources/Fluid/Theme/NativeButtonStyles.swift \
    Sources/Fluid/Theme/Components/FluidOutlinedButtonStyle.swift Sources/Fluid/Theme/Components/FluidDropdown.swift \
    Sources/Fluid/Services/DictionaryAcousticEvidence.swift Sources/Fluid/Services/DictionaryHistoryReplacement.swift \
    Sources/Fluid/Services/DictionaryCorrectionEditPolicy.swift \
    "$task_test_dir/SettingsFixture.swift" "$task_test_dir/HistoryValue.swift" "$task_test_dir/AudioValue.swift" \
    Tests/StatsSnapshotStoreFixtures.swift Sources/Fluid/UI/StatsSnapshot.swift \
    Sources/Fluid/UI/StatsActivityPeriod.swift Sources/Fluid/UI/StatsHeatmapView.swift Sources/Fluid/UI/StatsSnapshotStore.swift \
    Tests/StatsSnapshotTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir/StatsCatalog.bundle"
