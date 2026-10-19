#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
trace_build="$PWD/.build/meeting-timeline-trace-tests"
mkdir -p "$trace_build"
trace_case="$(mktemp -d "$trace_build/case.XXXXXX")"
# Child directory must not exist: disabled tracing must not create it.
env -u PICHI_MEETING_TIMELINE_PROFILE xcrun swiftc -swift-version 6 -default-isolation MainActor -parse-as-library \
    -module-cache-path "$trace_build/ModuleCache" \
    Sources/Fluid/Services/Meeting/MeetingTimelineTrace.swift Tests/MeetingTimelineTraceTests.swift -o "$trace_build/tests"
env -u PICHI_MEETING_TIMELINE_PROFILE "$trace_build/tests" "$trace_case/private"
