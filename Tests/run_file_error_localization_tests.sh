#!/bin/sh
set -eu
file_error_repo_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$file_error_repo_dir"
file_error_test_dir="$file_error_repo_dir/.build/file-error-localization-tests"
file_error_bundle="$file_error_test_dir/FileErrorFixture.app"
mkdir -p "$file_error_bundle/Contents/MacOS" "$file_error_bundle/Contents/Resources"

# Extract the actual error enum and throw expressions. The fixture does not
# construct the audio service, access models, operate UI or read user preferences.
python3 -S - "$file_error_test_dir" "${1:-}" <<'PY'
from pathlib import Path
import json
import plistlib
import re
import subprocess
import sys

output, reference = Path(sys.argv[1]), sys.argv[2]
service_path = 'Sources/Fluid/Services/FileTranscriptionService.swift'
def read(path):
    return subprocess.check_output(['git', 'show', f'{reference}:{path}'], text=True) if reference else Path(path).read_text()
source = read(service_path)
current = Path(service_path).read_text()
marker = '    enum TranscriptionError: LocalizedError {'
assert source.count(marker) == 1
start = source.index(marker)
end = source.index('\n    }', start) + len('\n    }')
error_enum = source[start:end]

def throws(text):
    found = []
    for match in re.finditer(r'throw\s+TranscriptionError\s*\.([A-Za-z]+)\(', text):
        first, offset, depth = match.end(), match.end(), 1
        while depth:
            depth += (text[offset] == '(') - (text[offset] == ')')
            offset += 1
        expression = text[first:offset - 1]
        found.append((match.group(1), expression))
    return found
actual, metadata = throws(source), throws(current)
assert len(actual) == len(metadata) and len(actual) >= 10, 'Production error sites changed; update the bounded extraction'
rows = []
for (case, expression), (expected_case, current_expression) in zip(actual, metadata):
    assert case == expected_case
    match = re.search(r'PichiLocalization\.(?:format|text)\("([^"\\]+)"', current_expression)
    key = match.group(1) if match else None
    rows.append('(kind: ' + json.dumps(case) + ', key: ' + (json.dumps(key) if key else 'nil')
                + ', error: TranscriptionError.' + case + '(' + expression + '))')
constant = re.search(r'    static let supportedFormatsDescription = ("[^"\n]+")', source)
drop_constant = re.search(r'    static let dropErrorCopy = ("[^"\n]+")', source)
assert constant and drop_constant
view = read('Sources/Fluid/UI/FileTranscriptionView.swift')
drop_expression = re.findall(r'self\.dropErrorMessage = (.+)\n', view)
drop_expression = [expression for expression in drop_expression if 'Self.dropErrorCopy' in expression]
assert len(drop_expression) == 1, 'Expected one production drop error assignment'
picker_calls = re.findall(r'FluidDropdownPicker\(\s*("[^"\n]+"),\s*selectedTitle: (.+),\n\s*selection: self\.\$settings\.fileTranscriptionExpectedSpeakerCount\n\s*\)', view)
assert len(picker_calls) == 1, 'Expected one production speaker-count picker'
title, selected = picker_calls[0]
dropdown = read('Sources/Fluid/Theme/Components/FluidDropdown.swift')
headings = re.findall(r'Picker\((.+), selection: self\.\$selection, content: self\.options\)', dropdown)
labels = re.findall(r'            Text\((.+)\)\n', dropdown)
assert len(headings) == 1 and labels == ['self.selectedTitle'], 'Shared native picker presentation changed'
auto_tags = re.findall(r'Text\("Auto"\)\.tag\((\d+)\)', view)
count_ranges = re.findall(r'ForEach\((\d+\.\.\.\d+), id: \\\.self\) \{ count in\n\s*Text\("\\\(count\)"\)\.tag\(count\)', view)
assert len(auto_tags) == len(count_ranges) == 1, 'Expected one actual Auto/count option set'
fixture = ('import Foundation\nenum FileTranscriptionService {\n' + error_enum + '\n'
           + '    static let supportedFormatsDescription = ' + constant.group(1) + '\n'
           + '    static let dropErrorCopy = ' + drop_constant.group(1) + '\n'
           + '    static func droppedFileError() -> String { ' + drop_expression[0] + ' }\n'
           + '    static func productionErrors(diagnostic: String, fileExtension: String) -> [(kind: String, key: String?, error: TranscriptionError)] {\n'
           + '        let error = NSError(domain: "synthetic.audio", code: 7, userInfo: [NSLocalizedDescriptionKey: diagnostic])\n'
           + '        return [\n' + ',\n'.join(rows) + '\n        ]\n    }\n}\n')
fixture += ('struct FileSpeakerCountPickerCopy {\n'
            + '    struct Settings { var fileTranscriptionExpectedSpeakerCount: Int }\n'
            + '    var settings: Settings\n'
            + '    var title: String { ' + title + ' }\n'
            + '    var selectedTitle: String { ' + selected + ' }\n'
            + '    var menuTitle: String { ' + headings[0] + ' }\n'
            + '    static var optionTags: [Int] { [' + auto_tags[0] + '] + Array(' + count_ranges[0] + ') }\n}\n'
            + 'struct SharedPickerSelectionCopy {\n'
            + '    var selectedTitle: String\n'
            + '    var label: String { ' + labels[0] + ' }\n}\n')
(output / 'ProductionFileErrors.swift').write_text(fixture)
(output / 'FileErrorFixture.app/Contents/Info.plist').write_bytes(plistlib.dumps({
    'CFBundleIdentifier': 'ai.pichi.file-error.fixture', 'CFBundleExecutable': 'tests',
    'CFBundlePackageType': 'APPL', 'CFBundleDevelopmentRegion': 'en', 'CFBundleLocalizations': ['en', 'ru'],
}))
PY

xcrun xcstringstool compile Sources/Fluid/Localization/Localizable.xcstrings \
    --output-directory "$file_error_bundle/Contents/Resources" --language en --language ru
xcrun swiftc -parse-as-library -module-cache-path "$file_error_test_dir/ModuleCache" \
    Sources/Fluid/Localization/PichiLocalization.swift \
    "$file_error_test_dir/ProductionFileErrors.swift" Tests/FileErrorLocalizationTests.swift \
    -o "$file_error_bundle/Contents/MacOS/tests"
"$file_error_bundle/Contents/MacOS/tests"
