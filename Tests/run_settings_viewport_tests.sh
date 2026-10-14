#!/bin/sh
set -eu
task_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$task_repo_dir"
task_test_dir="${PICHI_SETTINGS_VIEWPORT_OUTPUT_DIR:-$task_repo_dir/.build/settings-viewport-tests}"
task_scroll_source="${PICHI_SETTINGS_VIEWPORT_SOURCE:-$task_repo_dir/Sources/Fluid/UI/SettingsSearchPresentation.swift}"
task_bundle_dir="$task_test_dir/SettingsHeaderFixture.app"
mkdir -p "$task_bundle_dir/Contents/MacOS" "$task_bundle_dir/Contents/Resources"

# Exercise the actual settings rows, card, page padding and NSViewRepresentable.
# Inert bindings/services avoid persistent settings, audio and visible windows.
python3 -S - "$task_test_dir" "$task_scroll_source" <<'PY'
from pathlib import Path
import plistlib
import sys
out=Path(sys.argv[1])
src=Path('Sources/Fluid/UI/SettingsView.swift').read_text()
assert src.count('                        Label("App Settings",')==1
assert src.count('    private func settingsToggleRow(')==1
header=src[src.index('                        Label("App Settings",'):src.index('\n                        VStack(spacing: 16)',src.index('                        Label("App Settings",'))]
helper=src[src.index('    private func settingsToggleRow('):src.index('    private func backupUtilityRow()',src.index('    private func settingsToggleRow('))]
rows=src[src.index('                            // Launch at startup'):src.index('                            HStack {',src.index('                            // Launch at startup'))]
status_source=Path('Sources/Fluid/Persistence/SettingsStore.swift').read_text()
status_marker='    private(set) var launchAtStartupStatusMessage =\n'
assert status_source.count(status_marker)==1
status_literal=status_source.split(status_marker,1)[1].splitlines()[0].strip()
assert status_literal.startswith('"') and status_literal.endswith('"')
rows=rows.replace('self.launchAtStartupBinding','.constant(false)').replace('self.settings.launchAtStartupStatusMessage',status_literal).replace('self.settings.launchAtStartupErrorMessage','nil')
rows=rows.replace('Binding(\n                                    get: { SettingsStore.shared.showMainWindowAtLoginLaunch },\n                                    set: { SettingsStore.shared.showMainWindowAtLoginLaunch = $0 }\n                                )','.constant(false)').replace('Binding(\n                                    get: { SettingsStore.shared.hideFromDockAndAppSwitcher },\n                                    set: { SettingsStore.shared.hideFromDockAndAppSwitcher = $0 }\n                                )','.constant(false)')
rows=rows.replace('.settingsSearchTarget(.launchAtStartup)','.settingsSearchTarget(.header)').replace('.settingsSearchTarget(.showWindowAtLogin)','.settingsSearchTarget(.header)').replace('.settingsSearchTarget(.dockVisibility)','.settingsSearchTarget(.header)')
header += '\n                            .background(Marker(name:"header"))\n'
fragment='''import AppKit
import SwiftUI
struct RealContent:View {
 @Environment(\\.theme) var theme
 var settingsTitleText:Color {theme.palette.primaryText}
 var settingsSecondaryText:Color {theme.palette.primaryText}
 var body:some View {
 VStack(spacing:16) {
  ThemedCard(style:.standard) {
   VStack(alignment:.leading,spacing:14) {
'''+header+'''VStack(spacing:16) {
 ForEach(0..<5) {i in
 VStack(spacing:16) {
'''+rows+'''
 }.background(Marker(name:"row\\(i)"))
 }
 }
   }.padding(16)
  }
 }.padding(.bottom,28).fluidPageContent(width:.expanding)
 }
'''+helper+'}\n'
(out/'RealContent.swift').write_text(fragment)
theme=Path('Sources/Fluid/Theme/ThemeEnvironment.swift').read_text()
a=theme.index('struct AdaptiveAppTheme<Content: View>: View {');b=theme.index('// MARK: - Color Hex Initializer')
(out/'ThemeEnvironment.swift').write_text(theme[:a]+theme[b:])
scroll=Path(sys.argv[2]).read_text()
(out/'Scroll.swift').write_text(scroll)
pre=Path('Tests/UIContrastTests.swift').read_text().split('@main')[0]+'\nenum SettingsSearchTarget:Hashable {case header,lower}\n'
(out/'Doubles.swift').write_text(pre)
info={'CFBundleIdentifier':'ai.pichi.settings-viewport.fixture','CFBundleExecutable':'probe','CFBundlePackageType':'APPL','CFBundleDevelopmentRegion':'en','CFBundleLocalizations':['en','ru'],'LSUIElement':True}
(out/'SettingsHeaderFixture.app/Contents/Info.plist').write_bytes(plistlib.dumps(info))
PY
xcrun xcstringstool compile Sources/Fluid/Localization/Localizable.xcstrings \
    --output-directory "$task_bundle_dir/Contents/Resources" --language en --language ru
cp Sources/Fluid/Branding/brand-package.json "$task_bundle_dir/Contents/Resources/brand-package.json"
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    Sources/Fluid/Branding/AppBrand.swift Sources/Fluid/Branding/BrandPackage.swift \
    Sources/Fluid/Branding/BrandDistribution.swift Sources/Fluid/Theme/FluidTypography.swift \
    Sources/Fluid/Theme/AppTheme.swift "$task_test_dir/ThemeEnvironment.swift" \
    Sources/Fluid/Theme/Components/FluidOutlinedButtonStyle.swift \
    Sources/Fluid/Theme/Components/ThemedCard.swift \
    Sources/Fluid/Theme/Components/WindowSizingComponents.swift \
    Sources/Fluid/Theme/Components/FluidPageLayout.swift \
    "$task_test_dir/Doubles.swift" "$task_test_dir/Scroll.swift" \
    "$task_test_dir/RealContent.swift" Tests/SettingsViewportTests.swift \
    -o "$task_bundle_dir/Contents/MacOS/probe"
"$task_bundle_dir/Contents/MacOS/probe" > "$task_test_dir/report.json"
python3 -S - "$task_test_dir" "$task_scroll_source" <<'PY'
from pathlib import Path
import hashlib
import json
import sys
out=Path(sys.argv[1])
report=json.loads((out/'report.json').read_text())
paths=[Path(sys.argv[2]),Path('Sources/Fluid/UI/SettingsView.swift'),
       Path('Sources/Fluid/Theme/Components/ThemedCard.swift'),
       Path('Sources/Fluid/Theme/Components/FluidPageLayout.swift'),
       Path('Sources/Fluid/Persistence/SettingsStore.swift')]
report['productionSourceSHA256']={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
(out/'report.json').write_text(json.dumps(report,indent=2)+'\n')
if report['failures']:
    raise SystemExit('Settings viewport regression failed: '+'; '.join(report['failures']))
print('Settings viewport: 5 real hosting layout states, resize/content/search and hosting/anchor identity passed; no visible windows')
PY
