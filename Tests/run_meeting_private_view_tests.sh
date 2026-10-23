#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d /tmp/pichi-meeting-private-view-tests.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
python3 - "$task_test_dir/MeetingViewPrivateProjection.swift" <<'PY'
import pathlib
import sys
source = pathlib.Path("Sources/Fluid/UI/MeetingTranscriptionView.swift").read_text()
start = source.index("/// Owns only this view's transient payloads")
end = source.index("struct MeetingTranscriptionView: View {", start)
pathlib.Path(sys.argv[1]).write_text("import AppKit\nimport Combine\nimport Foundation\n" + source[start:end] + pathlib.Path("Tests/MeetingViewPrivateProjectionTests.swift").read_text())
PY
xcrun swiftc -parse-as-library -swift-version 6 -default-isolation MainActor \
    -module-cache-path "$task_test_dir/ModuleCache" \
    "$task_test_dir/MeetingViewPrivateProjection.swift" \
    -o "$task_test_dir/tests"
"$task_test_dir/tests"
xcrun swiftc -frontend -parse Sources/Fluid/UI/MeetingTranscriptionView.swift
