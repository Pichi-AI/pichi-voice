#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="$task_repo_dir/.build/command-ui-localization-tests"
task_bundle_dir="$task_test_dir/CommandUIFixture.app"
mkdir -p "$task_bundle_dir/Contents/MacOS" "$task_bundle_dir/Contents/Resources"

# Compile the actual Apple catalog and production UI. The application service,
# history persistence and clipboard are inert doubles; no installed app state,
# real pasteboard, model, microphone or network is accessed.
python3 -S - "$task_test_dir" <<'PY'
from pathlib import Path
import plistlib
import sys

output = Path(sys.argv[1])

def unique(source, marker):
    assert source.count(marker) == 1, f"Expected exactly one {marker!r}"
    return source.index(marker)

source = Path('Sources/Fluid/Services/CommandModeService.swift').read_text()
start = unique(source, '    struct Message: Identifiable, Equatable {')
end = unique(source, '    struct PendingCommand {')
(output / 'CommandMessageModel.swift').write_text('import Foundation\nenum CommandModeService {\n' + source[start:end] + '}\n')

source = Path('Sources/Fluid/Persistence/ChatHistoryStore.swift').read_text()
end = unique(source, '// MARK: - Chat History Store')
(output / 'ChatModels.swift').write_text(source[:end])

# Run the production row projection against a fixed clock. Only the clock read
# and access levels change; grouping, titles, previews and formatter stay exact.
source = Path('Sources/Fluid/Views/CommandSessionSidebar.swift').read_text()
row_start = unique(source, '    private struct SessionRow: Identifiable, Equatable {')
row_end = unique(source, '    private enum SessionScope: String, CaseIterable {')
method_start = unique(source, '    private func refreshRows(from sessions: [ChatSession]) {')
method = source[method_start:]
assert method.endswith('    }\n}\n')
method = method[:-2]
assert method.count('let now = Date()') == 1
method = method.replace('private func refreshRows(from sessions: [ChatSession])',
                        'func refreshRows(from sessions: [ChatSession], reference: Date)')
method = method.replace('let now = Date()', 'let now = reference')
models = source[row_start:row_end].replace('private struct', 'struct').replace('private enum', 'enum')
(output / 'CommandSessionProjection.swift').write_text(
    'import Foundation\nfinal class CommandSessionProjection {\n'
    '    var interfaceLocale: Locale\n    var rows: [SessionRow] = []\n'
    '    init(locale: Locale) { self.interfaceLocale = locale }\n'
    + models + method + '}\n')

# Preserve the real theme environment and color helpers while excluding only
# AdaptiveAppTheme, whose settings/screen orchestration is outside this fixture.
source = Path('Sources/Fluid/Theme/ThemeEnvironment.swift').read_text()
start = unique(source, 'struct AdaptiveAppTheme<Content: View>: View {')
end = unique(source, '// MARK: - Color Hex Initializer')
(output / 'ThemeEnvironment.swift').write_text(source[:start] + source[end:])

source = Path('Sources/Fluid/Branding/BrandPackage.swift').read_text()
end = unique(source, '/// One write commits the entire validated package, so a failed import cannot partly change appearance.')
(output / 'BrandPackage.swift').write_text(source[:end])

# Observe the real value passed to SwiftUI help/accessibility. Offscreen
# NSHostingView does not expose an AX tree on every macOS release. The probe
# returns the exact value unchanged and never substitutes localization behavior.
source = Path('Sources/Fluid/Views/CommandMarkdownContent.swift').read_text()
label = 'let localizedLabel = PichiLocalization.text(self.copied ? "Copied" : self.label, locale: self.interfaceLocale)'
unique(source, label)
unique(source, '.help(localizedLabel)')
unique(source, '.accessibilityLabel(localizedLabel)')
source = source.replace(label, 'let localizedLabel = CommandCopyLabelProbe.record(\n'
                       '            PichiLocalization.text(self.copied ? "Copied" : self.label, locale: self.interfaceLocale),\n'
                       '            key: self.label, copied: self.copied, locale: self.interfaceLocale)')
(output / 'CommandMarkdownContent.swift').write_text(source)

info = {'CFBundleIdentifier': 'ai.pichi.command-ui.fixture',
        'CFBundleExecutable': 'tests', 'CFBundlePackageType': 'APPL',
        'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'ru'],
        'LSUIElement': True}
(output / 'CommandUIFixture.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY

xcrun xcstringstool compile Sources/Fluid/Localization/Localizable.xcstrings \
    --output-directory "$task_bundle_dir/Contents/Resources" --language en --language ru
xcrun swiftc -default-isolation MainActor -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/CommandMessageModel.swift" "$task_test_dir/ChatModels.swift" \
    "$task_test_dir/CommandSessionProjection.swift" "$task_test_dir/ThemeEnvironment.swift" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift "$task_test_dir/BrandPackage.swift" \
    Sources/Fluid/Branding/BrandDistribution.swift Tests/Support/StandaloneBrandPackageStore.swift \
    Sources/Fluid/Theme/FluidTypography.swift Sources/Fluid/Theme/AppTheme.swift \
    Sources/Fluid/Theme/NativeButtonStyles.swift \
    Sources/Fluid/Theme/Components/FluidOutlinedButtonStyle.swift \
    Sources/Fluid/Theme/Components/FluidGlassControls.swift \
    Sources/Fluid/Theme/Components/FluidDropdown.swift Sources/Fluid/Theme/Components/EditableTitle.swift \
    "$task_test_dir/CommandMarkdownContent.swift" Sources/Fluid/Views/CommandMessageView.swift \
    Sources/Fluid/Views/CommandSessionSidebar.swift Tests/CommandUILocalizationTests.swift \
    -o "$task_bundle_dir/Contents/MacOS/tests"
"$task_bundle_dir/Contents/MacOS/tests" "$task_test_dir" "$(git rev-parse --short=8 HEAD)"
