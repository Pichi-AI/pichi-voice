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
settings = 'Sources/Fluid/UI/SettingsView.swift'
microphone = snippet(settings, '                                        Button {\n                                            self.asr.requestMicAccess()',
                     '                                    } else if self.asr.micStatus == .denied {')
accessibility = snippet(settings, '                                    Button("Open Accessibility Settings") {',
                        '                                }\n\n                                self.instructionsBox(')
backup = snippet(settings, '                Button(action: self.exportBackup) {',
                 '                Button(action: self.importBackup) {')
updates = snippet(settings, '                                Button("Check for Updates") {',
                  '                                Button("Release Notes") {')
for control in [microphone, accessibility, backup, updates]:
    assert control.count('.buttonStyle(AccentButtonStyle(compact: true))') == 1
    assert '.buttonStyle(.borderedProminent)' not in control
# Accessibility environment values are read-only in this SDK. These additional
# fixtures select the EXACT production fallback ButtonStyle directly; this is
# fallback evidence, never a claim that native glass was rasterized.
glass = Path('Sources/Fluid/Theme/Components/FluidGlassControls.swift').read_text()
assert 'content.buttonStyle(AccentButtonStyle(tone: self.tone))' in glass
secondary = glass[glass.index('struct FluidGlassSecondaryActionStyle:'):glass.index('/// Native glass replaces an inherited foreground')]
assert 'content.buttonStyle(FluidGlassSecondaryActionStyle(tone: self.tone))' in glass
assert '.buttonStyle(.glass)' in secondary and '.buttonStyle(.glassProminent)' not in secondary
assert '.tint(.clear)' in secondary, 'Secondary glass must override the inherited accent tint'
assert 'role: configuration.role' in secondary and 'action: configuration.trigger' in secondary
assert 'Button(role: role, action: action)' in glass, 'Native Button must retain role and activation'
foreground_lines = [line.strip() for line in secondary.splitlines() if line.strip().startswith('let foreground = ')]
assert len(foreground_lines) == 1
secondary_foreground = foreground_lines[0].replace('configuration.role', 'self.role')
prominent = glass[glass.index('struct FluidGlassProminentActionStyle:'):glass.index('/// Keeps disabled glass actions')]
assert '@Environment(\\.appearsActive) private var appearsActive' in prominent
assert '.buttonStyle(.glassProminent)' in prominent
assert 'foreground: foreground' in prominent and 'action: configuration.trigger' in prominent
prominent_foreground_lines = [line.strip() for line in prominent.splitlines() if line.strip().startswith('let foreground = ')]
assert len(prominent_foreground_lines) == 1, 'Expected one production prominent foreground decision'
prominent_foreground = prominent_foreground_lines[0]
command_file = 'Sources/Fluid/Views/CommandModeView.swift'
command_glyph = snippet(command_file,
    '                        Image(systemName: self.ownsASRRecording ? "stop.fill" : "arrow.up")',
    '                    }\n                    .fluidGlassAction(prominent: true')
command_style = '.fluidGlassAction(prominent: true, circular: true, tone: self.theme.palette.primaryText)'
assert command_style in Path(command_file).read_text()
config_file = 'Sources/Fluid/UI/AISettingsView+AIConfiguration.swift'
help_action = snippet(config_file,
    '                Button(action: { self.viewModel.showHelp.toggle() })',
    '                .buttonStyle(.plain)') + '                .buttonStyle(.plain)\n'
help_method = snippet(config_file, '    func helpStep(', '    var providerStepContent:')
help_number = help_method[help_method.index('            ZStack {'):help_method.index('            Image(systemName: icon)')]
warning_method = snippet(config_file, '    var apiKeyWarningView:', '    var helpSectionView:')
warning = warning_method[warning_method.index('        HStack(spacing: 10) {'):warning_method.index('\n    }\n')]
words = snippet('Sources/Fluid/UI/StatsShareCard.swift',
    '            Text(self.content.totalWords.formatted())', '            Text("words dictated")')
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
    output.write('struct ProductionCommandGlyphFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    private let ownsASRRecording = false\n'
        '    var body: some View {\n        Button {} label: {\n' + command_glyph + '\n        }\n'
        '        ' + command_style + '\n        .disabled(true)\n    }\n}\n')
    output.write('struct ProductionHelpActionFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    private struct Model { var showHelp = true }; @State private var viewModel = Model()\n'
        '    var body: some View {\n' + help_action + '\n    }\n}\n')
    output.write('struct ProductionHelpNumberFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n    private let number = "3"\n'
        '    var body: some View {\n' + help_number + '\n    }\n}\n')
    output.write('struct ProductionWordMetricFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    private struct Content { let totalWords = 12345 }; private let content = Content()\n'
        '    var body: some View {\n' + words + '\n    }\n}\n')
    output.write('struct ProductionAPIKeyWarningFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    var body: some View {\n' + warning + '\n    }\n}\n')
    output.write('struct CopyToastFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    var body: some View {\n' + toast + '\n    }\n}\n')
    for name, control, dependencies in [
        ('MicrophonePermissionFixture', microphone, 'private struct ASR { func requestMicAccess() {} }; private let asr = ASR()'),
        ('AccessibilityPermissionFixture', accessibility, 'private func openAccessibilitySettings() {}'),
        ('BackupPrimaryActionFixture', backup, 'private func exportBackup() {}'),
        ('UpdatePrimaryActionFixture', updates, 'private struct Updater { let isCheckingForUpdates = false; let isUpdateInProgress = false; func checkForUpdatesManually() {} }; private let updater = Updater()'),
    ]:
        output.write('struct ' + name + ': View {\n    ' + dependencies + '\n'
            '    var body: some View {\n' + control + '\n    }\n}\n')
    output.write('struct ProminentGlassLabelFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    @Environment(\\.appearsActive) private var appearsActive\n'
        '    let tone: Color?\n'
        '    var body: some View {\n        ' + prominent_foreground + '\n'
        '        return FluidGlassProminentActionStyle.pairedLabelButton(role: nil, foreground: foreground, action: {}) {\n'
        '            Label("Prominent appearance", systemImage: "arrow.up.right")\n'
        '        }\n    }\n}\n')
    output.write('struct SecondaryGlassLabelFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    let role: ButtonRole?\n    let tone: Color?\n'
        '    var body: some View {\n        ' + secondary_foreground + '\n'
        '        return FluidGlassProminentActionStyle.pairedLabelButton(role: self.role, foreground: foreground, action: {}) {\n'
        '            Label("Remove file", systemImage: "xmark")\n'
        '        }\n    }\n}\n')
# SwiftUI supplies Configuration, and this quiet ButtonStyle is private.
# Compile the EXACT production quiet style body in an inert View adapter with
# a synthetic pressed configuration; this is source-bound raster evidence,
# not a physical mouse press or native input/activation test.
quiet = snippet('Sources/Fluid/Theme/Components/FluidGlassControls.swift',
                'private struct FluidQuietActionStyle: ButtonStyle {',
                '/// Glass stays outside the menu label;')
quiet = quiet.replace('private struct FluidQuietActionStyle: ButtonStyle {',
    'struct ProductionQuietPressedFixture: View {', 1)
quiet = quiet.replace('    let circular: Bool', '    let circular = false', 1)
quiet = quiet.replace('    let tone: Color?', '    let tone: Color? = nil', 1)
quiet = quiet.replace('    let spacious: Bool', '    let spacious = false', 1)
quiet = quiet.replace('    func makeBody(configuration: Configuration) -> some View {',
    '    struct Configuration { let isPressed = true; let label = Text("Quiet pressed action") }\n'
    '    var body: some View { self.makeBody(configuration: Configuration()) }\n'
    '    @ViewBuilder\n    func makeBody(configuration: Configuration) -> some View {', 1)
with Path(sys.argv[1]).open('a') as output:
    output.write(quiet)
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
    Sources/Fluid/Theme/Components/FluidIconTile.swift \
    Sources/Fluid/Theme/Components/FluidEditControls.swift \
    Sources/Fluid/Theme/Components/FluidSegmentedPicker.swift \
    Sources/Fluid/Theme/Components/FluidDropdown.swift \
    Sources/Fluid/Theme/Components/FluidGlassControls.swift \
    Sources/Fluid/UI/AISettingsComponents.swift \
    "$task_test_dir/ProductionLabels.swift" \
    Tests/UIContrastTests.swift Tests/FluidSegmentedPickerTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests" "$task_test_dir" "$@"
