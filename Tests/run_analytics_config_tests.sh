#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
pichi_test_dir=$(mktemp -d /tmp/pichi-analytics-config.XXXXXX)
trap 'rm -rf "$pichi_test_dir"' EXIT HUP INT TERM
xcrun swiftc -parse-as-library Sources/Fluid/Analytics/AnalyticsConfig.swift Sources/Fluid/Analytics/AnalyticsEvent.swift Sources/Fluid/Analytics/AnalyticsUploadTransport.swift Tests/AnalyticsConfigTests.swift -o "$pichi_test_dir/tests"
"$pichi_test_dir/tests"
