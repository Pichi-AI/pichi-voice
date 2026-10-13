#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="${PICHI_UI_CONTRAST_OUTPUT_DIR:-$task_repo_dir/.build/ui-contrast-tests}"
mkdir -p "$task_test_dir"

# Render the actual inline labels without starting the application or its services.
# Fail closed if the production boundaries change instead of testing a copied label.
python3 -S - "$task_test_dir/ProductionLabels.swift" <<'PY'
from pathlib import Path
import sys

def snippet(file, start, end):
    text = Path(file).read_text()
    assert text.count(start) == 1, f"Expected one production label: {start}"
    first = text.index(start)
    return text[first:text.index(end, first)]

delete = snippet('Sources/Fluid/UI/FileTranscriptionView.swift',
                 '                        Button(role: .destructive) { self.pendingDeleteEntry = entry } label: {',
                 '                        Spacer(minLength: 0)')
badge = snippet('Sources/Fluid/UI/AISettingsView+SpeechRecognition.swift',
                '                        Text("Active")', '                    } else {')
choose = snippet('Sources/Fluid/UI/FileTranscriptionView.swift',
                 '                    Button { self.showingFilePicker = true } label: {',
                 '                }\n                .frame(maxWidth: .infinity)')
copy = snippet('Sources/Fluid/UI/FileTranscriptionView.swift',
               '                        Button { self.copyToClipboard(entry.text) } label: {',
               '                        Menu {')
explore = snippet('Sources/Fluid/UI/ReleaseHighlightsView.swift',
                  '                Button(PichiLocalization.text(feature.action), systemImage: "arrow.up.right")',
                  '            }\n            .padding(.top, 18)')
toast = snippet('Sources/Fluid/UI/FileTranscriptionView.swift',
                '                Text("Copied!")', '                    .padding()\n')
# Accessibility environment values are read-only in this SDK. These additional
# fixtures select the EXACT production fallback ButtonStyle directly; this is
# fallback evidence, never a claim that native glass was rasterized.
glass = Path('Sources/Fluid/Theme/Components/FluidGlassControls.swift').read_text()
assert 'content.buttonStyle(AccentButtonStyle(tone: self.tone))' in glass
def fallback(control):
    assert control.count('.fluidGlassAction(prominent: true)') == 1
    return control.replace('.fluidGlassAction(prominent: true)', '.buttonStyle(AccentButtonStyle())')
choose, copy, explore = map(fallback, [choose, copy, explore])
Path(sys.argv[1]).write_text('import SwiftUI\n'
    'struct DeleteRoleFixture: View {\n'
    '    @Environment(\\.theme) private var theme\n'
    '    let entry = "synthetic"\n'
    '    @State private var pendingDeleteEntry: String?\n'
    '    var body: some View {\n' + delete + '\n    }\n}\n'
    'struct ActiveBadgeFixture: View {\n'
    '    @Environment(\\.theme) private var theme\n'
    '    var body: some View {\n' + badge + '\n    }\n}\n'
    'struct ChooseFileActionFixture: View {\n'
    '    @State private var showingFilePicker = false\n'
    '    var body: some View {\n' + choose + '\n    }\n}\n'
    'struct CopyTranscriptActionFixture: View {\n'
    '    private struct Entry { let text = "synthetic" }\n'
    '    private let entry = Entry()\n'
    '    private func copyToClipboard(_ text: String) {}\n'
    '    var body: some View {\n' + copy + '\n    }\n}\n'
    'struct ExploreReleaseActionFixture: View {\n'
    '    private struct Feature { let action = "Explore AI providers"; let destination = 0 }\n'
    '    private let feature = Feature()\n'
    '    private let canExplore = true\n'
    '    private func onClose(_ destination: Int) {}\n'
    '    var body: some View {\n' + explore + '\n    }\n}\n')
with Path(sys.argv[1]).open('a') as output:
    output.write('struct CopyToastFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    var body: some View {\n' + toast + '\n    }\n}\n')
PY

xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift \
    Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Theme/FluidTypography.swift \
    Sources/Fluid/Theme/AppTheme.swift \
    Sources/Fluid/Theme/ThemeEnvironment.swift \
    Sources/Fluid/Theme/NativeButtonStyles.swift \
    Sources/Fluid/Theme/Components/FluidOutlinedButtonStyle.swift \
    Sources/Fluid/Theme/Components/FluidDropdown.swift \
    Sources/Fluid/Theme/Components/FluidGlassControls.swift \
    Sources/Fluid/UI/AISettingsComponents.swift \
    "$task_test_dir/ProductionLabels.swift" \
    Tests/UIContrastTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir"
