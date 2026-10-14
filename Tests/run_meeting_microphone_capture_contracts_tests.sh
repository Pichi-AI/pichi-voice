#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
mkdir -p .build
task_test_dir="$(mktemp -d "$PWD/.build/pichi-microphone-contracts.XXXXXX")"
trap 'rm -rf "$task_test_dir"' EXIT HUP INT TERM
python3 - "$task_test_dir/Identity.swift" <<'PY'
import pathlib, sys
source = pathlib.Path('Sources/Fluid/Services/Meeting/MeetingModels.swift').read_text()
a = source.index('nonisolated enum MeetingMicrophoneRole:')
b = source.index('nonisolated struct MeetingRecordingDefaults:', a)
c = source.index('nonisolated struct MeetingMicrophoneIdentity:')
d = source.index('/// Pure decision for the new-meeting sheet', c)
pathlib.Path(sys.argv[1]).write_text('import Foundation\n' + source[a:b] + '\n' + source[c:d])
PY
xcrun swiftc -parse-as-library -swift-version 6 "$task_test_dir/Identity.swift" \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Tests/MeetingMicrophoneCaptureContractsTests.swift -o "$task_test_dir/tests"
"$task_test_dir/tests"
xcrun swiftc -parse-as-library -typecheck -swift-version 6 -target arm64-apple-ios18.0 \
    -sdk "$(xcrun --sdk iphoneos --show-sdk-path)" "$task_test_dir/Identity.swift" \
    Sources/Fluid/Services/Meeting/MeetingPersistedMetadata.swift \
    Tests/MeetingMicrophoneCaptureContractsTests.swift
