#!/bin/bash
set -euo pipefail

prototype_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_dir="$(cd "$prototype_dir/../.." && pwd)"
output_dir="$repo_dir/.build/ipad-meeting-concepts"
mode="${1:-all}"
mkdir -p "$output_dir"

write_info() {
    local info_path="$1"
    local platform="$2"
    python3 - "$info_path" "$platform" <<'PY'
import plistlib,sys
info={
    'CFBundleIdentifier':'ai.pichi.voice.design.prototype',
    'CFBundleName':'MeetingConcepts',
    'CFBundleExecutable':'MeetingConcepts',
    'CFBundlePackageType':'APPL',
    'CFBundleShortVersionString':'0.1',
    'CFBundleVersion':'1',
    'CFBundleDevelopmentRegion':'en',
    'CFBundleLocalizations':['en','ru'],
}
if sys.argv[2]=='ios':
    info.update(LSRequiresIPhoneOS=True, MinimumOSVersion='17.0', UIDeviceFamily=[1,2],
        UISupportedInterfaceOrientations=['UIInterfaceOrientationPortrait','UIInterfaceOrientationLandscapeLeft','UIInterfaceOrientationLandscapeRight'],
        UILaunchScreen={})
else:
    info.update(LSMinimumSystemVersion='15.0', NSHighResolutionCapable=True)
with open(sys.argv[1],'wb') as file: plistlib.dump(info,file)
PY
}

copy_resources() {
    local resource_dir="$1"
    mkdir -p "$resource_dir"
    cp "$repo_dir/Sources/Fluid/Branding/brand-package.json" "$resource_dir/brand-package.json"
    cp "$prototype_dir/Resources/synthetic-fixtures.json" "$resource_dir/synthetic-fixtures.json"
    xcrun xcstringstool compile "$prototype_dir/Resources/Localizable.xcstrings" --output-directory "$resource_dir" --language en --language ru
}

if [[ "$mode" == "all" || "$mode" == "mac" ]]; then
    app_dir="$output_dir/mac/MeetingConcepts.app"
    mkdir -p "$app_dir/Contents/MacOS" "$app_dir/Contents/Resources"
    xcrun --sdk macosx swiftc -parse-as-library -target arm64-apple-macos15.0 \
        -sdk "$(xcrun --sdk macosx --show-sdk-path)" \
        "$prototype_dir"/Sources/*.swift -o "$app_dir/Contents/MacOS/MeetingConcepts"
    write_info "$app_dir/Contents/Info.plist" mac
    copy_resources "$app_dir/Contents/Resources"
    printf 'Compiled native Mac design preview: %s\n' "$app_dir"
fi

if [[ "$mode" == "all" || "$mode" == "ios" ]]; then
    app_dir="$output_dir/ios-simulator/MeetingConcepts.app"
    mkdir -p "$app_dir"
    xcrun --sdk iphonesimulator swiftc -parse-as-library -target arm64-apple-ios17.0-simulator \
        -sdk "$(xcrun --sdk iphonesimulator --show-sdk-path)" \
        "$prototype_dir"/Sources/*.swift -o "$app_dir/MeetingConcepts"
    write_info "$app_dir/Info.plist" ios
    copy_resources "$app_dir"
    printf 'Compiled iOS simulator design preview: %s\n' "$app_dir"
fi

if [[ "$mode" != "all" && "$mode" != "mac" && "$mode" != "ios" ]]; then
    printf 'Usage: bash Prototypes/iPadMeetingConcepts/build.sh [all|mac|ios]\n' >&2
    exit 2
fi
