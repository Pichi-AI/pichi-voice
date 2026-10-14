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
# Keep the two native sidebar labels bound to the real common helper, their
# different icon constructors and the production hover/selected surface.
content = Path('Sources/Fluid/ContentView.swift').read_text()
assert content.count('private func sidebarLabel<Icon: View>') == 1
helper = snippet('Sources/Fluid/ContentView.swift',
    '    private func sidebarLabel<Icon: View>', '    private func sidebarNavigationLink(')
main = snippet('Sources/Fluid/ContentView.swift',
    '    private func sidebarNavigationLink(', '    private var themePreferenceButton:')
settings = snippet('Sources/Fluid/ContentView.swift',
    '                    NavigationLink(value: section) {', '                }\n            }\n            .listStyle(.sidebar)')
assert 'self.sidebarLabel(section.title, isSelected: isSelected)' in settings
assert 'self.sidebarLabel(item.title, isSelected: isSelected)' in main
assert 'Color.primary' not in helper and 'Color.secondary' not in helper
cache = snippet('Sources/Fluid/ContentView.swift',
    '@MainActor\nprivate enum SidebarSymbolCache {', 'private struct SidebarChromeButtonStyle:')
hover = snippet('Sources/Fluid/ContentView.swift',
    'extension View {\n    func sidebarOptionHover(', 'private struct AccessibilitySettingsFloatingGuideView:')
with Path(sys.argv[1]).open('a') as output:
    output.write(cache + '\n' + hover)
    output.write('struct ProductionSidebarFixture: View {\n'
        ' @ObservedObject var state: NativeSidebarContrastTests.State\n'
        ' @Environment(\\.theme) private var theme\n'
        ' let family: NativeSidebarContrastTests.Family\n'
        ' private var selectedSidebarItem: SidebarItem? { self.state.selection }\n'
        ' private var accessibilityReduceMotion: Bool { true }\n'
        ' var body: some View {\n'
        '  List(selection: self.$state.selection) {\n'
        '   ForEach(self.state.items) { section in\n'
        '    let isSelected = self.state.selection == section\n'
        '    if self.family == .main { self.sidebarNavigationLink(section, systemImage: section.systemImage) }\n'
        '    else {\n' + settings + '\n    }\n'
        '   }\n  }.listStyle(.sidebar).accentColor(self.theme.palette.accent)\n'
        ' }\n' + helper + '\n' + main + '\n}\n')
    chrome = snippet('Sources/Fluid/ContentView.swift',
        'private struct SidebarChromeButtonStyle: ButtonStyle {', 'extension View {\n    func sidebarOptionHover(')
    chrome = chrome.replace('private struct SidebarChromeButtonStyle: ButtonStyle {',
        'struct ProductionSidebarChromeFixture: View {', 1)
    chrome = chrome.replace('    let reduceMotion: Bool', '    let reduceMotion = true', 1)
    chrome = chrome.replace('    func makeBody(configuration: Configuration) -> some View {',
        '    let isPressed: Bool\n'
        '    struct Configuration { let isPressed: Bool; var label: some View { Text("Marginal sidebar").frame(width: 160, height: 44) } }\n'
        '    var body: some View { self.makeBody(configuration: Configuration(isPressed: self.isPressed)) }\n'
        '    @ViewBuilder\n    func makeBody(configuration: Configuration) -> some View {', 1)
    output.write(chrome)
    hover_fixture = hover[hover.index('private struct SidebarOptionHoverModifier:'):]
    hover_fixture = hover_fixture.replace('private struct SidebarOptionHoverModifier: ViewModifier {',
        'struct ProductionSidebarHoveredFixture: View {', 1)
    hover_fixture = hover_fixture.replace('    let isSelected: Bool', '    let isSelected = false', 1)
    hover_fixture = hover_fixture.replace('    let reduceMotion: Bool', '    let reduceMotion = true', 1)
    hover_fixture = hover_fixture.replace('    @State private var isHovered = false', '    @State private var isHovered = true', 1)
    hover_fixture = hover_fixture.replace('    func body(content: Content) -> some View {',
        '    var body: some View {\n        let content = Text("Marginal hovered row").frame(width: 160, height: 44)', 1)
    hover_fixture = hover_fixture.replace('        content\n            .frame(', '        return content\n            .frame(', 1)
    output.write(hover_fixture)

# Compile the complete Dashboard section, not a copied keycap. Dependencies are
# process-local synthetic state; production actions and Button labels stay intact.
dashboard_file = 'Sources/Fluid/UI/DashboardView.swift'
dashboard = Path(dashboard_file).read_text()
quick = snippet(dashboard_file, '    private func quickActions(horizontal: Bool)',
                '    private var intelligenceInvitation:')
key = snippet(dashboard_file, '    @ViewBuilder\n    private var shortcutKey:',
              '\n}\n\nprivate struct DashboardRecentRow:')
row = snippet(dashboard_file, 'private struct DashboardQuickAction: View {',
              'private struct DashboardSetupCard:')
assert quick.count('ThemedCard(style: .standard, padding: 20)') == 1
assert 'AnyLayout(HStackLayout' in quick and 'AnyLayout(VStackLayout' in quick
assert quick.count('.disabled(self.busy)') == 3
assert quick.count('Button(action: self.openShortcutSettings)') == 1
assert quick.count('.fluidOutlinedButton()') == 1
assert 'self.selectedSidebarItem = .customDictionary' in quick
assert 'self.selectedSidebarItem = .cleanupStyles' in quick
for required in ['Button(action: self.openShortcutSettings)',
                 'self.settings.primaryDictationShortcuts.first?.displayString',
                 '.font(.fluidSystem(size: 25, weight: .medium))',
                 '.lineLimit(2).minimumScaleFactor(0.5)',
                 '.buttonStyle(FluidOutlinedButtonStyle(height: 64, fillsWidth: true))',
                 '.frame(width: 126, height: 64)', '.help(', '.accessibilityLabel(']:
    assert key.count(required) == 1, f'Dashboard keycap contract changed: {required}'
for forbidden in ['.glassEffect', '.fluidGlassAction', '.material', '.opacity(', 'Color.primary']:
    assert forbidden not in key, f'Dashboard keycap cannot replace its validated surface: {forbidden}'
row_style = '.buttonStyle(FluidOutlinedButtonStyle(fillsWidth: true))'
assert row.count('Button(action: self.action)') == 1 and row.count(row_style) == 1
assert '.padding(.horizontal' not in row, 'Shared style owns the existing 12-point horizontal padding'
assert '.padding(.vertical, 16)' in row
for forbidden in ['.buttonStyle(.plain)', '.opacity(', '.background(', '.onHover', '@State']:
    assert forbidden not in row, f'Dashboard row must use the shared surface and lifecycle: {forbidden}'
outlined = Path('Sources/Fluid/Theme/Components/FluidOutlinedButtonStyle.swift').read_text()
assert '.padding(.horizontal, 12)' in outlined
assert 'shape.fill(self.theme.palette.elevatedCardBackground)' in outlined
assert 'let highlighted = self.isEnabled && self.isHovered' in outlined
assert 'let pressed = self.isEnabled && self.configuration.isPressed' in outlined
dependencies = '''
    @ObservedObject var state: DashboardShortcutSurfaceTests.State
    @Environment(\\.theme) private var theme
    let horizontal: Bool
    private var settings: DashboardShortcutSurfaceTests.Settings { self.state.settings }
    private var busy: Bool { self.state.busy }
    private var shortcut: String { self.state.settings.primaryDictationShortcutDisplayString }
    private var selectedSidebarItem: DashboardShortcutSurfaceTests.Destination? {
        get { self.state.destination }
        nonmutating set { self.state.destination = newValue }
    }
    private func openShortcutSettings() { self.state.shortcutActivations += 1 }
'''
with Path(sys.argv[1]).open('a') as output:
    output.write('struct ProductionDashboardShortcutsFixture: View {\n' + dependencies +
        '    var body: some View { self.quickActions(horizontal: self.horizontal) }\n' + quick + key + '\n}\n' + row)
    output.write('struct ProductionDashboardKeyFixture: View {\n' + dependencies +
        '    var body: some View { self.shortcutKey.disabled(self.busy) }\n' + key + '\n}\n')
    # The shared style paints its opaque surface in every state. Pointer hover
    # and pressed outlines remain native E2E checks; no hover state is invented.
    output.write(row.replace('private struct DashboardQuickAction:', 'struct ProductionDashboardRowFixture:', 1))
    # Configuration is made by real production Buttons. These adapters replace
    # ONLY the renderer to observe nil role, enabled environment and trigger.
    inspected_row = row.replace('private struct DashboardQuickAction:', 'private struct ProductionDashboardInspectedAction:', 1)
    inspected_row = inspected_row.replace('    var body: some View {',
        '    @Environment(\\.dashboardObservations) private var observations\n    var body: some View {', 1)
    inspected_row = inspected_row.replace(row_style,
        '.buttonStyle(DashboardShortcutSurfaceTests.InspectionStyle(observations: self.observations!, identity: self.title))', 1)
    inspected_quick = quick.replace('DashboardQuickAction(', 'ProductionDashboardInspectedAction(')
    inspected_quick = inspected_quick.replace('.fluidOutlinedButton()',
        '.buttonStyle(DashboardShortcutSurfaceTests.InspectionStyle(observations: self.state.observations, identity: "change"))', 1)
    inspected_key = key.replace('.buttonStyle(FluidOutlinedButtonStyle(height: 64, fillsWidth: true))',
        '.buttonStyle(DashboardShortcutSurfaceTests.InspectionStyle(observations: self.state.observations, identity: "key"))', 1)
    output.write(inspected_row)
    output.write('struct ProductionDashboardConstructionFixture: View {\n' + dependencies +
        '    var body: some View { self.quickActions(horizontal: self.horizontal).environment(\\.dashboardObservations, self.state.observations) }\n' +
        inspected_quick + inspected_key + '\n}\n')
import hashlib, json
Path(sys.argv[1]).with_name('DashboardProductionSource.json').write_text(json.dumps({
    'source': dashboard_file, 'sha256': hashlib.sha256(dashboard.encode()).hexdigest(),
    'excerpts': {name: hashlib.sha256(value.encode()).hexdigest() for name, value in
                 [('quickActions', quick), ('shortcutKey', key), ('DashboardQuickAction', row)]},
    'adapters': ['inert dependencies', 'construction renderer only'],
    'nativeGlassRasterization': 'SKIP', 'physicalInputAndAccessibilityActivation': 'SKIP',
}, indent=2) + '\n')

# The four actual slider captions keep their complete production localization,
# shared caption font and layout chain. Global brand font defaults stay intact.
import re, subprocess, plistlib, os
settings_path = 'Sources/Fluid/UI/SettingsView.swift'
settings_source = Path(settings_path).read_text()
# Historical negative controls are opt-in. A normal shallow checkout only needs
# its actual current source, never an older Git object to run the regression.
old_revision = os.environ.get('PICHI_OVERLAY_CAPTION_LEGACY_REVISION')
old_source = subprocess.check_output(['git', 'show', f'{old_revision}:{settings_path}'], text=True) if old_revision else None
first = '                            .settingsSearchTarget(.overlaySensitivity)\n'
last = '                            .settingsSearchTarget(.transcriptionPreviewLength)\n'
def caption_block(text):
    assert text.count(first) == text.count(last) == 1
    return text[text.index(first) + len(first):text.index(last)]
pattern = re.compile(r'Text\((PichiLocalization\.text\("scale.more", defaultValue: "More"\)|"Less")\)\n(?:\s+\.[^\n]+\n)+')
current_block = caption_block(settings_source)
legacy_block = caption_block(old_source) if old_source else None
current_caps = list(pattern.finditer(current_block))
legacy_caps = list(pattern.finditer(legacy_block)) if legacy_block else []
assert len(current_caps) == 4, 'Expected four actual Overlay slider boundary captions'
if old_source:
    assert len(legacy_caps) == 4, 'Expected four actual historical caption expressions'
    assert pattern.sub('CAPTION\n', current_block) == pattern.sub('CAPTION\n', legacy_block), 'Slider bindings/ranges/numeric monospaced readout must remain unchanged'
expected_keys = ['scale.more', 'Less', 'Less', 'scale.more']
for current in current_caps:
    assert current.group().count('.font(.fluidSystem(.caption))') == 1
    assert current.group().count('.foregroundStyle(self.settingsSecondaryText)') == 1
    assert current.group().count('.lineLimit(1)') == 1
    assert current.group().count('.fixedSize(horizontal: true, vertical: false)') == 1
    assert current.group().count('.frame(minWidth: 36, alignment:') == 1
for current, legacy in zip(current_caps, legacy_caps):
    assert current.group(1) == legacy.group(1)
    assert legacy.group().count('.font(.fluidSystem(.caption))') == 1
    assert legacy.group().count('.foregroundStyle(self.settingsSecondaryText)') == 1
    assert legacy.group().count('.frame(width: 36, alignment:') == 1
helper = snippet(settings_path, '    var settingsSecondaryText: Color {', '    var settingsTertiaryText: Color {')
catalog_path = Path('Sources/Fluid/Localization/Localizable.xcstrings')
catalog = json.loads(catalog_path.read_text())
expected = {language: [catalog['strings'][key]['localizations'][language]['stringUnit']['value'] for key in expected_keys] for language in ['en', 'ru']}
expected_swift = '[' + ', '.join(json.dumps(language) + ': [' + ', '.join(json.dumps(value, ensure_ascii=False) for value in values) + ']' for language, values in expected.items()) + ']'
with Path(sys.argv[1]).open('a') as output:
    output.write('struct ProductionOverlayCaptionFixture: View {\n'
        '    @Environment(\\.theme) private var theme\n'
        '    let index: Int\n    let legacy: Bool\n'
        '    @ViewBuilder var body: some View {\n        if self.legacy {\n            switch self.index {\n')
    for legacy, matches in [(True, legacy_caps), (False, current_caps)]:
        if not legacy: output.write('        } else {\n            switch self.index {\n')
        for index, match in enumerate(matches):
            output.write(f'            case {index}:\n' + match.group())
        output.write('            default: EmptyView()\n            }\n')
    output.write('        }\n    }\n' + helper + '}\n')
    output.write('enum ProductionOverlayCaptionMetadata {\n'
        '    static let legacyAvailable = ' + str(bool(old_source)).lower() + '\n'
        '    static let expected: [String: [String]] = ' + expected_swift + '\n}\n')
Path(sys.argv[1]).with_name('OverlayCaptionProductionSource.json').write_text(json.dumps({
    'source': settings_path, 'sha256': hashlib.sha256(settings_source.encode()).hexdigest(),
    'captionSHA256': [hashlib.sha256(match.group().encode()).hexdigest() for match in current_caps],
    'legacySourceRevision': subprocess.check_output(['git', 'rev-parse', old_revision], text=True).strip() if old_revision else None,
    'legacyCaptionSHA256': [hashlib.sha256(match.group().encode()).hexdigest() for match in legacy_caps],
    'catalogSHA256': hashlib.sha256(catalog_path.read_bytes()).hexdigest(),
    'sliderContractSHA256': hashlib.sha256(pattern.sub('CAPTION\n', current_block).encode()).hexdigest(),
    'adapters': [], 'fontDesignCoverage': 'Actual global caption font only; other global brand fonts require native retest',
    'native800PointViewport': 'SKIP',
}, indent=2) + '\n')
bundle = Path(sys.argv[1]).parent / 'OverlayCaptionFixture.app/Contents'
(bundle / 'MacOS').mkdir(parents=True, exist_ok=True)
(bundle / 'Resources').mkdir(exist_ok=True)
(bundle / 'Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'ai.pichi.overlay-caption.fixture', 'CFBundleExecutable': 'tests',
    'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en',
    'CFBundleLocalizations': ['en', 'ru'], 'LSUIElement': True,
}))
PY

xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift \
    Sources/Fluid/Branding/BrandPackage.swift \
    Sources/Fluid/Branding/BrandDistribution.swift \
    Sources/Fluid/Branding/BrandAppearanceController.swift \
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
    Sources/Fluid/Theme/Components/ThemedCard.swift \
    Sources/Fluid/UI/AISettingsComponents.swift \
    "$task_test_dir/ProductionLabels.swift" \
    Tests/UIContrastTests.swift Tests/FluidSegmentedPickerTests.swift Tests/NativePaletteAppearanceTests.swift \
    Tests/NativeSidebarContrastTests.swift Tests/DashboardShortcutSurfaceTests.swift -o "$task_test_dir/tests"
# Keep the existing full-suite executable and its bundle context unchanged.
# The focused caption pass uses the same binary with real compiled resources.
case " $* " in
    *" --overlay-captions-only "*|"  ")
        xcrun xcstringstool compile Sources/Fluid/Localization/Localizable.xcstrings \
            --output-directory "$task_test_dir/OverlayCaptionFixture.app/Contents/Resources" --language en --language ru
        cp "$task_test_dir/tests" "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests"
        cp Sources/Fluid/Branding/brand-package.json "$task_test_dir/OverlayCaptionFixture.app/Contents/Resources/brand-package.json"
        ;;
esac
case " $* " in
    *" --overlay-captions-only "*)
        "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests" "$task_test_dir" "$@"
        ;;
    "  ")
        "$task_test_dir/tests" "$task_test_dir"
        "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests" "$task_test_dir" --overlay-captions-only
        ;;
    *) "$task_test_dir/tests" "$task_test_dir" "$@" ;;
esac
