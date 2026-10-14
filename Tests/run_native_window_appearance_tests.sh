#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="${PICHI_NATIVE_WINDOW_OUTPUT_DIR:-$task_repo_dir/.build/native-window-appearance-tests}"
task_theme_source="${PICHI_NATIVE_WINDOW_THEME_SOURCE:-$task_repo_dir/Sources/Fluid/Theme/ThemeEnvironment.swift}"
mkdir -p "$task_test_dir"

# Replace only the installed package getter with synthetic process-local data.
# The production theme, appearance observer and NSHostingController are intact.
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import sys
out = Path(sys.argv[1])
source = Path('Sources/Fluid/Branding/AppBrand.swift').read_text()
getter = 'static var package: BrandPackage { BrandPackageStore.shared.current() }'
assert source.count(getter) == 1
(out / 'AppBrand.swift').write_text(source.replace(getter,
    'static var package: BrandPackage { NativeWindowAppearanceTests.package }'))
mark = Path('Sources/Fluid/Branding/PichiBrandMark.swift').read_text()
selector = 'let variant = self.theme.variant ?? self.colorScheme'
assert mark.count(selector) == 1
(out / 'LogoVariantProbe.swift').write_text('import SwiftUI\n'
    'struct LogoVariantProbe: View {\n'
    ' @Environment(\\.theme) private var theme\n'
    ' @Environment(\\.colorScheme) private var colorScheme\n'
    ' var body: some View {\n  ' + selector + '\n'
    '  NativeWindowAppearanceTests.logoVariants.append(variant)\n'
    '  return Color.clear.frame(width: 1, height: 1)\n }\n}\n')
PY
xcrun swiftc -default-isolation MainActor -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift "$task_test_dir/AppBrand.swift" \
    Sources/Fluid/Branding/BrandPackage.swift Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Branding/BrandAppearanceController.swift \
    Sources/Fluid/Theme/FluidTypography.swift Sources/Fluid/Theme/AppTheme.swift \
    "$task_theme_source" Sources/Fluid/Theme/NativeButtonStyles.swift \
    Sources/Fluid/Theme/Components/FluidOutlinedButtonStyle.swift \
    Sources/Fluid/Theme/Components/FluidDropdown.swift \
    "$task_test_dir/LogoVariantProbe.swift" Tests/NativeWindowAppearanceTests.swift \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
