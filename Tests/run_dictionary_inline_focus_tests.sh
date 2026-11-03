#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
task_test_dir=$(mktemp -d /tmp/pichi-inline-focus.XXXXXX)
trap 'rm -rf "$task_test_dir"' EXIT
sed '/^\/\/\/ A minimized stale window/,$d' Sources/Fluid/UI/DictionarySelectableTranscript.swift > "$task_test_dir/Transcript.swift"
xcrun swiftc -parse-as-library Sources/Fluid/UI/DictionaryInlineTextEdit.swift \
    "$task_test_dir/Transcript.swift" Tests/DictionaryInlineFocusTests.swift -o "$task_test_dir/inline-focus"
"$task_test_dir/inline-focus"
