#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_dir="$task_repo_dir/.build/settings-owned-copy-tests"
task_bundle="$task_dir/SettingsCopyFixture.app"
mkdir -p "$task_bundle/Contents/MacOS" "$task_bundle/Contents/Resources"

# Compile actual owned copy expressions and catalog without creating any UI,
# asking for permissions, enumerating hardware or reading installed preferences.
python3 -S - "$task_dir" "${1:-}" <<'PY'
from pathlib import Path
import plistlib
import subprocess
import sys

output, reference = Path(sys.argv[1]), sys.argv[2]
def read(path):
    return subprocess.check_output(['git', 'show', f'{reference}:{path}'], text=True) if reference else Path(path).read_text()
def unique(source, marker):
    assert source.count(marker) == 1, f'Expected one owned copy boundary: {marker}'
    return source.index(marker)
source = read('Sources/Fluid/UI/SettingsView.swift')
current = Path('Sources/Fluid/UI/SettingsView.swift').read_text()
renderer = 'Text((try? AttributedString(markdown: step)) ?? AttributedString(step))'
unique(current, renderer)
render_expression = renderer[len('Text('):-1]
start = unique(source, 'steps: self.asr.micStatus == .notDetermined') + len('steps: ')
microphone = source[start:source.index('\n                                )', start)].strip().rstrip(',')
start = unique(source, 'title: "Follow these steps to enable Accessibility:"')
start = source.index('steps: ', start) + len('steps: ')
end = source.index('\n                                    ],', start) + len('\n                                    ]')
accessibility = source[start:end].strip()
marker = '    private static func outputDeviceDisplayName('
if marker in source:
    start = unique(source, marker)
    device = source[start:source.index('\n    }', start) + len('\n    }')].replace('private static', 'static', 1)
else:
    # Historical origin for before/fix proof, retaining its exact ternary.
    start = unique(source, 'Text(isSystemDefault ? ') + len('Text(')
    expression = source[start:source.index(').tag(dev.uid)', start)].replace('dev.name', 'name')
    device = 'static func outputDeviceDisplayName(_ name: String, isSystemDefault: Bool) -> String { ' + expression + ' }'
fixture = ('import Foundation\nstruct SettingsCopyFixture {\n'
           'enum MicStatus { case notDetermined, denied }\n'
           'struct ASR { var micStatus: MicStatus }\n'
           'var asr: ASR\nvar appDisplayName: String\n'
           'func microphoneSteps() -> [String] { ' + microphone + ' }\n'
           'func accessibilitySteps() -> [String] { ' + accessibility + ' }\n'
           + device + '\nstatic func renderInstruction(_ step: String) -> AttributedString { '
           + render_expression + ' }\n}\n')
(output / 'SettingsCopyFixture.swift').write_text(fixture)

settings = read('Sources/Fluid/Persistence/SettingsStore.swift')
def enum_declaration(marker):
    start = unique(settings, marker)
    brace = settings.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (settings[end] == '{') - (settings[end] == '}')
        end += 1
    return settings[start:end]
(output / 'OverlayMetadata.swift').write_text('enum SettingsStore {\n' + enum_declaration('    enum OverlaySize:')
    + '\n' + enum_declaration('    enum OverlayPosition:') + '\n}\n')

package = Path('Sources/Fluid/Branding/BrandPackage.swift').read_text()
marker = 'nonisolated final class BrandPackageStore:'
unique(package, marker)
(output / 'BrandPackageTypes.swift').write_text(package[:package.index(marker)])
(output / 'Localizable.xcstrings').write_text(read('Sources/Fluid/Localization/Localizable.xcstrings'))
(output / 'SettingsCopyFixture.app/Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'ai.pichi.settings-copy.fixture', 'CFBundleExecutable': 'tests',
    'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'ru'],
}))
PY

xcrun xcstringstool compile "$task_dir/Localizable.xcstrings" \
    --output-directory "$task_bundle/Contents/Resources" --language en --language ru
xcrun swiftc -parse-as-library -module-cache-path "$task_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandDistribution.swift "$task_dir/BrandPackageTypes.swift" \
    "$task_dir/SettingsCopyFixture.swift" "$task_dir/OverlayMetadata.swift" \
    Tests/SettingsOwnedCopyTests.swift -o "$task_bundle/Contents/MacOS/tests"
"$task_bundle/Contents/MacOS/tests"
