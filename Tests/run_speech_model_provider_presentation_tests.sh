#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
model_mark_dir=$(mktemp -d /tmp/model-mark.XXXXXX)
trap 'rm -rf "$model_mark_dir"' EXIT HUP INT TERM
xcrun swiftc -default-isolation MainActor -parse-as-library \
    Sources/Fluid/UI/AISettings/SpeechModelProviderPresentation.swift \
    Tests/SpeechModelProviderPresentationTests.swift -o "$model_mark_dir/tests"
"$model_mark_dir/tests"
