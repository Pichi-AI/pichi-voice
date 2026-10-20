#!/usr/bin/env bash
set -euo pipefail

ctc_root="$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../../.." && pwd)"
cd "$ctc_root"
bash scripts/dev/assert-worktree.sh
ctc_build="$ctc_root/.build/gigaam-ctc-timing"
mkdir -p "$ctc_build"
ctc_case="$(mktemp -d "$ctc_build/case.XXXXXX")"
# Compile only the actual Foundation decoder and its shared XCTest cases. No ORT,
# model loading, microphone, audio fixtures or application host participates.
cat > "$ctc_case/main.swift" <<'SWIFT'
import Foundation
import XCTest

let suite = XCTestSuite(forTestCaseClass: GigaAMCTCTimingTests.self)
guard suite.testCaseCount == 8 else {
    fatalError("Expected all eight shared decoder tests, found \(suite.testCaseCount)")
}
suite.run()
guard let result = suite.testRun, result.executionCount == 8 else {
    fatalError("Decoder tests did not execute")
}
print("CTC lexical timing: \(result.executionCount) tests, \(result.totalFailureCount) failures")
exit(result.hasSucceeded ? 0 : 1)

SWIFT
ctc_platform="$(xcrun --show-sdk-platform-path)"
ctc_frameworks="$ctc_platform/Developer/Library/Frameworks"
ctc_libraries="$ctc_platform/Developer/usr/lib"
xcrun swiftc -swift-version 5 -module-cache-path "$ctc_build/ModuleCache" \
    -F "$ctc_frameworks" -I "$ctc_libraries" -L "$ctc_libraries" \
    -Xlinker -rpath -Xlinker "$ctc_frameworks" -Xlinker -rpath -Xlinker "$ctc_libraries" \
    Vendor/PichiGigaAM/Sources/PichiGigaAM/GigaAMCTC.swift \
    Vendor/PichiGigaAM/Tests/PichiGigaAMTests/GigaAMCTCTimingTests.swift \
    "$ctc_case/main.swift" -o "$ctc_case/tests"
"$ctc_case/tests"
