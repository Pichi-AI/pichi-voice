#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_developer_dir="${DEVELOPER_DIR:-$(xcode-select -p)}"
test -d "$task_developer_dir/Platforms/MacOSX.platform"
export DEVELOPER_DIR="$task_developer_dir"
task_test_dir=$(mktemp -d /tmp/pichi-summary-evidence.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
# Compile the production value types and pure evidence operations without starting
# the application, an inference server or the user's meeting/session stores.
python3 - "$task_test_dir/SummaryEvidence.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('Sources/Fluid/Services/Meeting/PichiMeetingSummaryDocument.swift').read_text()
types = source[:source.index('nonisolated enum PichiMeetingSummaryInput {')]
methods = []
for signature in ['static func normalized(', 'static func chunks(', 'static func evidenceChoices(']:
    start = source.index('    ' + signature)
    end = source.index('\n    }', start) + len('\n    }')
    methods.append(source[start:end])
start = source.index('nonisolated enum PichiMeetingSummaryError:')
end = source.index('\nnonisolated struct PichiMeetingSummaryArtifact:', start)
exports = source[source.index('extension PichiMeetingSummaryDocument {'):]
pathlib.Path(sys.argv[1]).write_text(types + '\nnonisolated enum PichiMeetingSummaryInput {\n'
    + '\n'.join(methods) + '\n}\n' + source[start:end]
    + '\n' + exports)
PY
sed '/^@MainActor/,$d' Sources/Fluid/Views/CommandMarkdownContent.swift > "$task_test_dir/Markdown.swift"
xcrun swiftc -parse-as-library -module-cache-path "$task_test_dir/ModuleCache" Sources/Fluid/Localization/PichiLocalization.swift \
    "$task_test_dir/SummaryEvidence.swift" "$task_test_dir/Markdown.swift" Tests/MeetingSummaryEvidenceTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
python3 -S Tests/meeting_summary_ui_parity.py
