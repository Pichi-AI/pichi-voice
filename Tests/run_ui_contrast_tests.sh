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
# Preserve the complete actual secondary PrimitiveButtonStyle and real History
# report Button. Replace only the glass renderer, which ImageRenderer cannot draw.
import os, subprocess, hashlib, json
secondary_revision = os.environ.get('PICHI_SECONDARY_GLASS_LEGACY_REVISION')
secondary_source_path = 'Sources/Fluid/Theme/Components/FluidGlassControls.swift'
secondary_source = subprocess.check_output(['git', 'show', f'{secondary_revision}:{secondary_source_path}'], text=True) if secondary_revision else Path(secondary_source_path).read_text()
first = secondary_source.index('struct FluidGlassSecondaryActionStyle:')
secondary_style = secondary_source[first:secondary_source.index('/// Native glass replaces an inherited foreground', first)]
assert secondary_style.count('.buttonStyle(.glass)') == 1
assert 'role: configuration.role' in secondary_style and 'action: configuration.trigger' in secondary_style
reference_style = secondary_style.replace('struct FluidGlassSecondaryActionStyle:', 'struct ProductionSecondaryReferenceStyle:', 1).replace('.buttonStyle(.glass)', '.buttonStyle(.plain)', 1)
history_report = snippet('Sources/Fluid/UI/TranscriptionHistoryView.swift',
    '        Button { self.openFeedbackReport(for: entry) } label: {',
    '        Button { self.copyFinalText(entry) } label: {')
assert history_report.count('.fluidGlassAction()') == 1
with Path(sys.argv[1]).open('a') as output:
    output.write(reference_style)
    output.write('struct ProductionHistoryReportFixture: View {\n'
        ' let action: () -> Void\n private let entry = "Synthetic"\n'
        ' private func openFeedbackReport(for entry: String) { self.action() }\n'
        ' var body: some View {\n' + history_report.replace('.fluidGlassAction()', '.buttonStyle(ProductionSecondaryReferenceStyle(tone: nil))') + '\n }\n}\n')
menu_first = glass.index('private struct FluidGlassMenuActionModifier:')
menu_last = glass.index('\nextension View {\n    func fluidGlassMenuAction()', menu_first)
menu_source = glass[menu_first:menu_last]
assert menu_source.count('.glassEffect(.regular, in: .capsule)') == 1
assert '.buttonStyle(FluidGlassMenuActionStyle(foreground: .primary))' in menu_source
assert '.buttonStyle(FluidGlassMenuActionStyle(foreground: self.theme.palette.primaryText))' in menu_source
menu_reference = menu_source.replace('private struct FluidGlassMenuActionModifier:', 'struct ProductionMenuReferenceModifier:', 1)
menu_reference = menu_reference.replace('@Environment(\\.accessibilityReduceTransparency) private var reduceTransparency', 'let reduceTransparency: Bool', 1)
menu_reference = menu_reference.replace('FluidGlassMenuActionStyle', 'ProductionMenuReferenceStyle')
menu_reference = menu_reference.replace('.glassEffect(.regular, in: .capsule)', '.background(Color.clear)', 1)
export_source = snippet('Sources/Fluid/UI/FileTranscriptionView.swift',
    '                        Menu {\n                            ForEach(ExportFormat.allCases',
    '                        Button(role: .destructive) { self.pendingDeleteEntry = entry } label: {')
assert export_source.count('.fluidGlassMenuAction()') == 1
assert 'ForEach(ExportFormat.allCases, id: \\.self)' in export_source
assert 'self.exportDocument = try TranscriptionDocument(entry: entry, format: format)' in export_source
label_start = export_source.index('                            Label("Export",')
export_label = export_source[label_start:export_source.index('\n                        }', label_start)]
stats_share = snippet('Sources/Fluid/UI/StatsView.swift',
    '            Button { self.showShareSheet = true } label: {',
    '        }\n        .sheet(isPresented: self.$showShareSheet)')
for contract in ['.fluidToolbarIcon()', '.accessibilityLabel("Share my stats")',
                 '.disabled(self.statsStore.snapshot == nil)',
                 '.help(PichiLocalization.text("Make an image of your stats to post or send"))']:
    assert contract in stats_share
with Path(sys.argv[1]).open('a') as output:
    output.write(menu_reference)
    output.write('struct ProductionExportReferenceFixture: View {\n'
        ' let fallback: Bool\n var body: some View {\n'
        '  Button(action: {}) {\n' + export_label + '\n  }\n'
        '  .modifier(ProductionMenuReferenceModifier(reduceTransparency: self.fallback))\n }\n}\n')
    output.write('struct ProductionStatsShareFixture: View {\n'
        ' @State private var showShareSheet = false\n'
        ' private struct Store { let snapshot: Int? = 1 }\n private let statsStore = Store()\n'
        ' var body: some View {\n' + stats_share + '\n }\n}\n')
Path(sys.argv[1]).with_name('SecondaryGlassProductionSource.json').write_text(json.dumps({
    'styleSourceSHA256': hashlib.sha256(secondary_source.encode()).hexdigest(),
    'reportButtonSHA256': hashlib.sha256(history_report.encode()).hexdigest(),
    'exportMenuSHA256': hashlib.sha256(export_source.encode()).hexdigest(),
    'menuStyleSHA256': hashlib.sha256(menu_source.encode()).hexdigest(),
    'statsShareSHA256': hashlib.sha256(stats_share.encode()).hexdigest(),
    'legacySourceRevision': subprocess.check_output(['git', 'rev-parse', secondary_revision], text=True).strip() if secondary_revision else None,
    'adapters': ['native glass renderer replaced by plain ButtonStyle', 'synthetic report action and entry', 'injected material scheme'],
    'nativeMaterialSchemePropagation': 'SKIP',
}, indent=2) + '\n')
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
# Retain actual controls/Charts, axis formatting and shared font roles. Only
# app-owned data/actions are inert; no copied prompt or axis implementation.
import os, subprocess, hashlib, json
ink_revision = os.environ.get('PICHI_NATIVE_INK_LEGACY_REVISION')
ink_sources = {}
def ink_source(path):
    source = subprocess.check_output(['git', 'show', f'{ink_revision}:{path}'], text=True) if ink_revision else Path(path).read_text()
    ink_sources[path] = hashlib.sha256(source.encode()).hexdigest()
    return source
def ink_snippet(path, start, end):
    source = ink_source(path)
    assert source.count(start) == 1, f'Expected one native ink production boundary: {start}'
    first = source.index(start)
    return source[first:source.index(end, first)]
activity_path = 'Sources/Fluid/UI/StatsActivityView.swift'
activity = ink_source(activity_path)
history = ink_snippet('Sources/Fluid/UI/TranscriptionHistoryView.swift',
    '    private var searchBar: some View {', '    // MARK: - Entry List')
files = ink_snippet('Sources/Fluid/UI/FileTranscriptionView.swift',
    '            HStack(spacing: self.theme.metrics.spacing.sm) {\n                Image(systemName: "magnifyingglass")',
    '            Divider()')
def chart_block(source, start, height, offset=0):
    first = source.index(start, offset)
    last = source.index(f'.frame(height: {height})', first) + len(f'.frame(height: {height})')
    return source[first:last]
daily = chart_block(activity, '            Chart(period.days)', 124)
growth = chart_block(activity, '                Chart(period.days)', 150, activity.index('private func growthCard'))
rhythm = chart_block(activity, '                Chart(period.weekdays)', 150)
hours = chart_block(ink_source('Sources/Fluid/UI/StatsHighlightsView.swift'),
    '                Chart(Array(self.snapshot.hourlySessions.enumerated())', 140)
with Path(sys.argv[1]).open('a') as output:
    output.write('\nimport Charts\n')
    output.write('struct ProductionHistorySearchFixture: View {\n'
        ' @Environment(\\.theme) private var theme\n @Binding var searchQuery: String\n'
        ' var body: some View { self.searchBar }\n' + history + '}\n')
    output.write('struct ProductionFilesSearchFixture: View {\n'
        ' @Environment(\\.theme) private var theme\n @Binding var searchQuery: String\n'
        ' var body: some View {\n' + files + '\n }\n}\n')
    for name, code in [('Daily', daily), ('Growth', growth), ('Rhythm', rhythm), ('Hours', hours)]:
        output.write('struct Production' + name + 'ChartFixture: View {\n'
            ' @Environment(\\.theme) private var theme\n @Environment(\\.locale) private var interfaceLocale\n'
            ' let period: StatsActivityPeriod\n'
            ' @State private var hoveredDate: Date?\n @State private var selectedDate: Date?\n'
            ' @State private var hoveredWeekday: String?\n @State private var pinnedWeekday: String?\n'
            ' @State private var hoveredHour: Int?\n @State private var pinnedHour: Int?\n'
            ' private let selected: StatsActivityPeriod.Day? = nil\n'
            ' private struct Snapshot { let hourlySessions = (0..<24).map { $0 % 3 == 0 ? 0 : $0 + 3 } }\n'
            ' private let snapshot = Snapshot()\n'
            ' private func inspectDate(_ x: CGFloat, proxy: ChartProxy, pin: Bool) {}\n'
            ' var body: some View {\n' + code + '\n }\n}\n')

# Extract the complete production participant editor, not a parallel test field.
participant_path = 'Sources/Fluid/UI/MeetingAssignSpeakersSheet.swift'
participant_revision = os.environ.get('PICHI_PARTICIPANT_INPUT_LEGACY_REVISION')
participant_source = subprocess.check_output(['git', 'show', f'{participant_revision}:{participant_path}'], text=True) if participant_revision else Path(participant_path).read_text()
participant_start = '            TextField(\n                speaker.displayName,'
assert participant_source.count(participant_start) == 1
participant_first = participant_source.index(participant_start)
participant_last_marker = '            .disabled(self.isSaving)'
participant_last = participant_source.index(participant_last_marker, participant_first) + len(participant_last_marker)
participant_field = participant_source[participant_first:participant_last]
Path(sys.argv[1]).with_name('ProductionParticipantSheet.swift').write_text(participant_source)
meeting_actions = Path('Sources/Fluid/UI/MeetingWorkspaceComponents.swift').read_text()
Path(sys.argv[1]).with_name('ProductionMeetingActions.swift').write_text(meeting_actions[:meeting_actions.index('enum MeetingDocumentSection:')])
with Path(sys.argv[1]).open('a') as output:
    output.write('struct ProductionParticipantInputFixture: View {\n'
        ' struct Speaker { let id: String; let displayName: String }\n'
        ' @Environment(\\.theme) private var theme\n'
        ' @Binding var drafts: [String: String]\n'
        ' let isSaving: Bool\n'
        ' @FocusState private var focusedField: String?\n'
        ' let speaker = Speaker(id: "synthetic", displayName: "Участник Ёё")\n'
        ' var body: some View {\n' + participant_field + '\n }\n}\n')
Path(sys.argv[1]).with_name('ParticipantInputProductionSource.json').write_text(json.dumps({
    'source': participant_path, 'sourceSHA256': hashlib.sha256(participant_source.encode()).hexdigest(),
    'fieldSHA256': hashlib.sha256(participant_field.encode()).hexdigest(),
    'legacySourceRevision': participant_revision,
    'adapters': ['invented participant ID/name', 'externally observed draft/saving state'],
    'visibleWindowOrPhysicalKeyboard': 'SKIP',
}, indent=2) + '\n')

Path(sys.argv[1]).with_name('NativeInkProductionSource.json').write_text(json.dumps({
    'sourceSHA256': ink_sources,
    'sharedControlSHA256': hashlib.sha256(Path('Sources/Fluid/Theme/Components/FluidEditControls.swift').read_bytes()).hexdigest(),
    'legacySourceRevision': subprocess.check_output(['git', 'rev-parse', ink_revision], text=True).strip() if ink_revision else None,
    'adapters': ['synthetic chart totals and selection', 'inert chart pointer callback'],
    'visibleWindowOrApp': 'SKIP',
}, indent=2) + '\n')
import hashlib, json
Path(sys.argv[1]).with_name('DashboardProductionSource.json').write_text(json.dumps({
    'source': dashboard_file, 'sha256': hashlib.sha256(dashboard.encode()).hexdigest(),
    'excerpts': {name: hashlib.sha256(value.encode()).hexdigest() for name, value in
                 [('quickActions', quick), ('shortcutKey', key), ('DashboardQuickAction', row)]},
    'adapters': ['inert dependencies', 'construction renderer only'],
    'nativeGlassRasterization': 'SKIP', 'physicalInputAndAccessibilityActivation': 'SKIP',
}, indent=2) + '\n')


# Native toolbar labels must reset inherited brand ink at their existing label
# boundary. These excerpts keep the actual label expressions and Button action.
# Material appearance is supplied by the fixture, not claimed as native glass.
import re
toolbar_revision = os.environ.get('PICHI_TOOLBAR_INK_LEGACY_REVISION')
def toolbar_source(path):
    return subprocess.check_output(['git', 'show', f'{toolbar_revision}:{path}'], text=True) if toolbar_revision else Path(path).read_text()
page_layout = toolbar_source('Sources/Fluid/Theme/Components/FluidPageLayout.swift')
page_actions = page_layout[page_layout.index('                    self.actions\n'):]
page_actions = page_actions[:page_actions.index('\n                }')]
assert '.buttonStyle(.automatic)' in page_actions and '.labelStyle(FluidToolbarLabelStyle())' in page_actions
# The actual page-action chain and private label style compile in their own
# source file. A plain inner Button is only the non-native raster adapter.
Path(sys.argv[1]).with_name('ToolbarPageLayout.swift').write_text(page_layout + '\n'
    'struct ProductionToolbarPageFixture: View {\n'
    ' private var actions: some View {\n'
    '  Button(action: {}) { Label("Share", systemImage: "square.and.arrow.up") }.buttonStyle(.plain)\n'
    ' }\n var body: some View {\n' + page_actions + '\n }\n}\n')
content_source = toolbar_source('Sources/Fluid/ContentView.swift')
main_toolbar = content_source[content_source.index('    private func applyMainWindowToolbar'):content_source.index('    private var hasPageToolbarActions:')]
assert '.buttonStyle(.automatic)' in main_toolbar
labels = {}
for name, symbol in [('Sidebar', 'sidebar.left'), ('Issue', 'ladybug.fill')]:
    match = re.search(r'Image\(systemName: "' + re.escape(symbol) + r'"\)\s*\.fluidToolbarIcon\(\)', main_toolbar)
    assert match, 'Expected unchanged native toolbar label'
    labels[name] = match.group()
theme_button = content_source[content_source.index('    private var themePreferenceButton:'):content_source.index('    private func nextThemePreference(')]
match = re.search(r'Image\(systemName: self.settings.themePreference.systemImageName\)\s*\.fluidToolbarIcon\(\)', theme_button)
assert match
labels['Theme'] = match.group()
update = content_source[content_source.index('private struct UpdateAvailableToolbarButton:'):content_source.index('private struct TodayStatsToolbarButton:')]
assert '.disabled(self.updater.isCheckingForUpdates || self.updater.isUpdateInProgress)' in update
assert '.accessibilityLabel("Update available: \\(version)")' in update
first = update.index('                Image(systemName:')
labels['Update'] = update[first:update.index('\n            }', first)]
today = content_source[content_source.index('private struct TodayStatsToolbarButton:'):content_source.index('// MARK: - Card Animation Modifier')]
assert '.accessibilityLabel("Today stats")' in today
first = today.index('        return Button(action: self.action)')
today_button = today[first:today.index('        .help(', first)].replace('        return Button', '        Button', 1)
with Path(sys.argv[1]).open('a') as output:
    for name, label in labels.items():
        output.write('struct ProductionToolbar' + name + 'Fixture: View {\n'
            ' @Environment(\\.theme) private var theme\n'
            ' private struct Preference { let systemImageName = "moon" }\n'
            ' private struct Settings { let themePreference = Preference() }\n'
            ' private let settings = Settings()\n'
            ' var body: some View {\n' + label + '\n }\n}\n')
    output.write('struct ProductionToolbarTodayFixture: View {\n'
        ' let hasActivity: Bool\n let action: () -> Void\n'
        ' private struct Summary { let words = 123 }\n'
        ' private let summary = Summary()\n private let timeSaved = "2 min"\n'
        ' var body: some View {\n' + today_button + '\n }\n}\n')
Path(sys.argv[1]).with_name('ToolbarInkProductionSource.json').write_text(json.dumps({
    'contentSHA256': hashlib.sha256(content_source.encode()).hexdigest(),
    'pageLayoutSHA256': hashlib.sha256(page_layout.encode()).hexdigest(),
    'legacySourceRevision': subprocess.check_output(['git', 'rev-parse', toolbar_revision], text=True).strip() if toolbar_revision else None,
    'adapters': ['synthetic statistics and theme-icon selection', 'reference native material colorScheme', 'plain inner page Button renderer'],
    'nativeToolbarSchemePropagation': 'SKIP', 'nativeGlassRasterization': 'SKIP',
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
    Sources/Fluid/Theme/Components/FluidManagementSheet.swift \
    Sources/Fluid/UI/AISettings/ProviderConnectionFields.swift \
    Sources/Fluid/Theme/Components/FluidSegmentedPicker.swift \
    Sources/Fluid/Theme/Components/FluidDropdown.swift \
    Sources/Fluid/Theme/Components/FluidGlassControls.swift \
    Sources/Fluid/Theme/Components/ThemedCard.swift \
    Sources/Fluid/UI/AISettingsComponents.swift \
    "$task_test_dir/ProductionLabels.swift" \
    Tests/UIContrastTests.swift Tests/FluidSegmentedPickerTests.swift Tests/NativePaletteAppearanceTests.swift \
    Tests/NativeSidebarContrastTests.swift Tests/DashboardShortcutSurfaceTests.swift \
    Sources/Fluid/UI/StatsActivityPeriod.swift Sources/Fluid/UI/StatsChartInteraction.swift \
    Tests/NativeInkTransitionTests.swift Tests/ToolbarInkTests.swift Tests/SecondaryGlassInkTests.swift Tests/ParticipantInputContrastTests.swift \
    "$task_test_dir/ProductionParticipantSheet.swift" "$task_test_dir/ProductionMeetingActions.swift" \
    "$task_test_dir/ToolbarPageLayout.swift" -o "$task_test_dir/tests"
# Keep the existing full-suite executable and its bundle context unchanged.
# The focused caption pass uses the same binary with real compiled resources.
case " $* " in
    *" --overlay-captions-only "*|*" --native-ink-only "*|*" --toolbar-ink-only "*|*" --secondary-glass-ink-only "*|*" --participant-input-only "*|"  ")
        xcrun xcstringstool compile Sources/Fluid/Localization/Localizable.xcstrings \
            --output-directory "$task_test_dir/OverlayCaptionFixture.app/Contents/Resources" --language en --language ru
        cp "$task_test_dir/tests" "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests"
        cp Sources/Fluid/Branding/brand-package.json "$task_test_dir/OverlayCaptionFixture.app/Contents/Resources/brand-package.json"
        ;;
esac
case " $* " in
    *" --overlay-captions-only "*|*" --native-ink-only "*|*" --toolbar-ink-only "*|*" --secondary-glass-ink-only "*|*" --participant-input-only "*)
        "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests" "$task_test_dir" "$@"
        ;;
    "  ")
        "$task_test_dir/tests" "$task_test_dir"
        "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests" "$task_test_dir" --overlay-captions-only
        "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests" "$task_test_dir" --native-ink-only
        "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests" "$task_test_dir" --toolbar-ink-only
        "$task_test_dir/OverlayCaptionFixture.app/Contents/MacOS/tests" "$task_test_dir" --secondary-glass-ink-only
        ;;
    *) "$task_test_dir/tests" "$task_test_dir" "$@" ;;
esac
