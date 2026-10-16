#!/usr/bin/env bash
set -euo pipefail
pichi_root="$(git rev-parse --show-toplevel)"
cd "$pichi_root"
bash scripts/dev/assert-worktree.sh
pichi_build="$pichi_root/.build/pii-contact-rules"
mkdir -p "$pichi_build"
# Compile the actual rules without fetching ONNX. Only the DTO/error declarations
# are extracted; no model runtime or detector behavior is replaced in this check.
python3 - "$pichi_build" <<'PY'
import pathlib, sys
root = pathlib.Path('Vendor/PichiGigaAM/Sources/PichiTextPrivacy')
build = pathlib.Path(sys.argv[1])
span = (root / 'PIINERRuntime.swift').read_text().split('public struct PIINERSpan:', 1)[1].split('\nstruct PIIWordPrediction:', 1)[0]
error = (root / 'PIIModelDescriptor.swift').read_text().split('public enum TextPrivacyError:', 1)[1].split('\npublic struct PIIModelArtifact:', 1)[0]
(build / 'Contracts.swift').write_text('import Foundation\npublic struct PIINERSpan:' + span + '\npublic enum TextPrivacyError:' + error)
tests = pathlib.Path('Vendor/PichiGigaAM/Tests/PichiTextPrivacyTests/PIIContactRulesTests.swift').read_text()
# Existing model-free regressions also run against this exact implementation.
import re
baseline = pathlib.Path('Vendor/PichiGigaAM/Tests/PichiTextPrivacyTests/PichiTextPrivacyTests.swift').read_text()
names = ['KnownNonPersonPERDoesNotFreezeProvisionalMeetingContext',
    'IsolatedCompletedNamePrefixDoesNotBlockEveryLaterSentence',
    'ExplicitMedicationAndDosePreserveAnUnknownDrugWithoutExemptingPeople',
    'IdentifiersAndSpokenEmailInRUAndMixedEnglish', 'AddressContextCredentialsAndPaymentCard',
    'CardCandidatesStopAtActualGroupsAndPreserveFollowingAmount',
    'StructuredRussianAddressesStopBeforeUnpunctuatedDrugAndDose',
    'UngroupedAmountsAfterValidCardArePreservedAtAllGroupLengths',
    'NoBlindLongNumberDateLocationOrganizationOrMedicationRedaction',
    'OverlappingSpansMaskUnionAndDoNotLeakTail',
    'BadOffsetsFailClosedAndPlaceholdersIdempotentAcrossSegments',
    'CaselessNameRulesRequirePersonEvidenceAndKeepPharmaNumbers']
methods = []
for name in names:
    match = re.search(r'^    func test' + name + r'\(.*?(?=^    func test|^})', baseline, re.M | re.S)
    assert match, name
    methods.append(match.group())
fixtures = pathlib.Path('Vendor/PichiGigaAM/Tests/PichiTextPrivacyTests/PIIRussianASRFixtures.swift').read_text()
tests += '\n' + fixtures + '\nfinal class PIIRulesBaselineTests: XCTestCase {\n' + '\n'.join(methods) + '\n}\n'
runner = '\nlet suite = XCTestSuite(name: "PII rules")\nsuite.addTest(XCTestSuite(forTestCaseClass: PIIContactRulesTests.self))\nsuite.addTest(XCTestSuite(forTestCaseClass: PIIRulesBaselineTests.self))\nsuite.run()\nexit(suite.testRun!.totalFailureCount == 0 && suite.testRun!.executionCount == 17 ? 0 : 1)\n'

(build / 'main.swift').write_text(tests + runner)
PY
pichi_sources="Vendor/PichiGigaAM/Sources/PichiTextPrivacy"
swiftc -swift-version 6 -enable-testing -emit-library -emit-module -module-name PichiTextPrivacy \
    -module-cache-path "$pichi_build/ModuleCache" -emit-module-path "$pichi_build/PichiTextPrivacy.swiftmodule" \
    "$pichi_build/Contracts.swift" "$pichi_sources/PIIWordPieceTokenizer.swift" \
    "$pichi_sources/PIIRussianNameHeuristics.swift" "$pichi_sources/PIIRedactor.swift" \
    "$pichi_sources/PIIProvisionalPreview.swift" -o "$pichi_build/libPichiTextPrivacy.dylib"
pichi_test_frameworks="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/Library/Frameworks"
pichi_test_libs="$(xcode-select -p)/Platforms/MacOSX.platform/Developer/usr/lib"
swiftc -I "$pichi_test_libs" -L "$pichi_test_libs" -Xlinker -rpath -Xlinker "$pichi_test_libs" -F "$pichi_test_frameworks" -Xlinker -rpath -Xlinker "$pichi_test_frameworks" -swift-version 5 -I "$pichi_build" -L "$pichi_build" -lPichiTextPrivacy \
    -module-cache-path "$pichi_build/ModuleCache" -Xlinker -rpath -Xlinker "$pichi_build" \
    "$pichi_build/main.swift" -o "$pichi_build/tests"
"$pichi_build/tests"
