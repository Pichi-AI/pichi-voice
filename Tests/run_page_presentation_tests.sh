#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/fluidvoice-page-presentation.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
# Reuse the brand schema without admitting the production disk/defaults store.
sed '/^nonisolated final class BrandPackageStore:/,$d' Sources/Fluid/Branding/BrandPackage.swift > "$task_test_dir/BrandPackageTypes.swift"
# Compile the production dashboard geometry without app/service dependencies.
sed '/^struct DashboardSetupStatus/,$d' Sources/Fluid/UI/DashboardView.swift > "$task_test_dir/DashboardLayout.swift"
# Compile the complete shared theme boundary used by toolbar actions, without
# admitting the adaptive app shell or installed settings into this pure probe.
python3 - "$task_test_dir/ThemeEnvironment.swift" <<'PY_THEME'
from pathlib import Path
import sys
source = Path('Sources/Fluid/Theme/ThemeEnvironment.swift').read_text()
marker = 'struct AdaptiveAppTheme<'
assert source.count(marker) == 1
color_marker = '// MARK: - Color Hex Initializer'
assert source.count(color_marker) == 1
# The real color helpers read only this inert accent fixture, never installed preferences.
fixture = '\nfinal class SettingsStore { static let shared = SettingsStore(); let accentColor: Color = .blue }\n'
Path(sys.argv[1]).write_text(source[:source.index(marker)] + source[source.index(color_marker):] + fixture)
PY_THEME
xcrun swiftc -parse-as-library \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift \
    "$task_test_dir/BrandPackageTypes.swift" \
    Tests/Support/StandaloneBrandPackageStore.swift \
    Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Theme/FluidTypography.swift \
    Sources/Fluid/Theme/AppTheme.swift \
    "$task_test_dir/ThemeEnvironment.swift" \
    Sources/Fluid/Theme/Components/FluidOutlinedButtonStyle.swift \
    Sources/Fluid/UI/AppNavigationState.swift \
    Sources/Fluid/Theme/Components/FluidPageLayout.swift \
    Sources/Fluid/Theme/Components/ToolbarAppearanceTrace.swift Sources/Fluid/Services/FileLogger.swift Sources/Fluid/Services/DebugLogger.swift \
    "$task_test_dir/DashboardLayout.swift" \
    Tests/PagePresentationTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
